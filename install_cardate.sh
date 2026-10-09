#!/usr/bin/env bash
# CardATe installer for Ubuntu 24.04-based Linux Mint (amd64).
# Downloaded packages and temporary test artifacts are removed on every exit.
# No PIN is stored; an optional signature test requests PINs interactively.
# Author: Gianni 'guelfoweb' Amato
set -Eeuo pipefail
umask 077

readonly TOOL='CardATe'
readonly BIT_URL='https://cdn.bit4id.com/es/soporte/downloads/middleware/Bit4id_Middleware.zip'
readonly BIT_VERSION='1.4.11.836-0'
# SHA-256 of the PKCS#11 library confirmed in the working installation.
readonly BIT_SHA256='143cf72f50b0a6300d83b7c9344c39a6456ce3eb9bea57f0e236254ca8bb0c69'
readonly JSIGN_VERSION='3.2.1'
readonly JSIGN_ASSET="jsignpdf-${JSIGN_VERSION}-linux-x64.deb"
readonly JSIGN_SUMS="jsignpdf-${JSIGN_VERSION}-SHA256SUMS.txt"
readonly JSIGN_URL='https://github.com/intoolswetrust/jsignpdf/releases/download/JSignPdf_3_2_1'
readonly APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/cardate"
readonly INSTALL_DIR="$APP_DIR/middleware/$BIT_VERSION"
readonly LIB="$INSTALL_DIR/usr/lib/bit4id/libbit4xpki.so"
readonly PKCS_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/jsignpdf/pkcs11.cfg"
readonly PREF_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/jsignpdf/config.properties"
readonly JSIGN_CLI='/opt/jsignpdf/bin/JSignPdfC'
readonly JSIGN_GUI='/opt/jsignpdf/bin/JSignPdf'
readonly SHORTCUT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
readonly SHORTCUT="$SHORTCUT_DIR/jsignpdf.desktop"

WORK=''
STAGING=''
INSTALLED_THIS_RUN=0
CONFIG_CHANGED=0
PREF_CHANGED=0
HAS_CONFIG=0
HAS_PREF=0
CHECK_ONLY=0
SIGN_TEST=0
CARD_STATUS='not_checked'
SHORTCUT_CREATED=0

info() { printf '[%s] %s\n' "$TOOL" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$TOOL" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$TOOL" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./install_cardate.sh [--check | --sign-test | --help]

  (no option)  Install, configure, add the application menu shortcut, and run PIN-free checks.
  --check      Verify an existing installation without sudo or downloads.
  --sign-test  Install/check, then sign sample data once with interactive PINs.
  --help       Show this help message.

The installer removes all downloaded archives and temporary files on exit.
No PIN is stored, logged, or accepted as a command-line argument.
EOF
}

cleanup() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 )); then
    if (( SHORTCUT_CREATED )); then
      rm -f -- "$SHORTCUT" || warn 'Cannot remove the new application menu shortcut.'
    fi
    if (( CONFIG_CHANGED )); then
      if (( HAS_CONFIG )); then
        cp -p -- "$WORK/original-pkcs11.cfg" "$PKCS_CFG" || warn 'Cannot restore the previous PKCS#11 configuration.'
      else
        rm -f -- "$PKCS_CFG" || true
      fi
    fi
    if (( PREF_CHANGED )); then
      if (( HAS_PREF )); then
        cp -p -- "$WORK/original-config.properties" "$PREF_CFG" || warn 'Cannot restore previous preferences.'
      else
        rm -f -- "$PREF_CFG" || true
      fi
    fi
    if (( INSTALLED_THIS_RUN )); then
      rm -rf -- "$INSTALL_DIR" || warn 'Cannot remove incomplete middleware installation.'
    fi
  fi
  [[ -z "$STAGING" ]] || rm -rf -- "$STAGING"
  [[ -z "$WORK" ]] || rm -rf -- "$WORK"
  # Remove only directories that are empty. Never touch unrelated user files.
  rmdir -- "$APP_DIR/middleware" "$APP_DIR" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

check_host() {
  [[ $EUID -ne 0 ]] || die 'Run as a regular user (do not use sudo).'
  [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'Linux x86_64 is required.'
  [[ $(dpkg --print-architecture) == amd64 ]] || die 'A Debian/Ubuntu amd64 system is required.'
  [[ -d "$HOME" ]] || die 'HOME is not a directory.'
  for path in "$APP_DIR" "$(dirname "$PKCS_CFG")" "$PKCS_CFG" "$PREF_CFG" "$INSTALL_DIR" "$SHORTCUT_DIR" "$SHORTCUT"; do
    [[ ! -L "$path" ]] || die "Symbolic link detected; inspect manually: $path"
  done
  if (( ! CHECK_ONLY )); then
    command -v apt-get >/dev/null || die 'apt-get is required.'
    command -v sudo >/dev/null || die 'sudo is required.'
  fi
}

fetch() {
  local url=$1 dest=$2
  curl --fail --location --silent --show-error \
    --proto '=https' --proto-redir '=https' --connect-timeout 20 \
    --retry 2 --retry-delay 2 --max-time 600 --max-filesize 600000000 \
    --output "$dest" "$url" || die "Download failed: $url"
  [[ -s "$dest" ]] || die "Empty download: $url"
}

install_prerequisites() {
  info 'Installing required packages (sudo may prompt for authentication)...'
  sudo apt-get update
  sudo apt-get install -y --no-remove \
    ca-certificates curl unzip opensc pcscd pcsc-tools libccid \
    poppler-utils openssl file
  for cmd in curl unzip pkcs11-tool openssl sha256sum dpkg-deb timeout; do
    command -v "$cmd" >/dev/null || die "Required command not found: $cmd"
  done
}

# ZIP layouts differ between releases. Find one DEB by its basename; do not
# extract untrusted ZIP paths into the filesystem.
extract_bit_deb() {
  local archive=$1 output=$2 entry
  local -a matches=() preferred=()
  local listing
  listing=$(unzip -Z -1 "$archive") || die 'Cannot list Bit4id ZIP contents.'
  while IFS= read -r entry; do
    [[ "$entry" == *.deb ]] || continue
    [[ "$entry" != /* && "$entry" != *'..'* && "$entry" != *\\* ]] || die 'Unsafe ZIP entry path.'
    matches+=("$entry")
    [[ "${entry##*/}" == 'Bit4id_Middleware.deb' ]] && preferred+=("$entry")
  done <<< "$listing"
  if (( ${#preferred[@]} == 1 )); then
    entry=${preferred[0]}
  elif (( ${#preferred[@]} == 0 && ${#matches[@]} == 1 )); then
    entry=${matches[0]}
  else
    die "Expected one Bit4id DEB inside the ZIP; found ${#matches[@]} candidate(s)."
  fi
  info "Found package in ZIP: $entry"
  unzip -p "$archive" "$entry" > "$output" || die 'Failed to extract the DEB from ZIP.'
  [[ -s "$output" ]] || die 'Extracted DEB is empty.'
}

check_bit() {
  [[ -f "$LIB" && ! -L "$LIB" && -f "$LIB.conf" ]] || die 'Middleware files are missing.'
  [[ $(sha256sum "$LIB" | awk '{print $1}') == "$BIT_SHA256" ]] ||
    die 'Middleware library hash differs from the tested build.'
  if ldd "$LIB" 2>&1 | grep -q 'not found'; then
    die 'Missing shared library dependency for the middleware.'
  fi
  grep -Eiq '^DSPinIsCnsPin=false[[:space:]]*$' "$LIB.conf" || die 'Invalid DSPinIsCnsPin setting.'
  grep -Eiq '^DSPinUseGui=true[[:space:]]*$' "$LIB.conf" || die 'Invalid DSPinUseGui setting.'
}

install_bit() {
  if [[ -d "$INSTALL_DIR" ]]; then
    info 'Existing middleware found; checking it without overwriting.'
    check_bit
    return
  fi
  info 'Downloading Bit4id middleware...'
  local archive="$WORK/middleware.zip" deb="$WORK/middleware.deb"
  fetch "$BIT_URL" "$archive"
  extract_bit_deb "$archive" "$deb"
  [[ $(dpkg-deb -f "$deb" Package) == libbit4xpki ]] || die 'Unexpected middleware package name.'
  [[ $(dpkg-deb -f "$deb" Version) == "$BIT_VERSION" ]] || die 'Unexpected middleware package version.'
  [[ $(dpkg-deb -f "$deb" Architecture) == amd64 ]] || die 'Unexpected middleware architecture.'

  mkdir -p -- "$APP_DIR/middleware"
  STAGING=$(mktemp -d "$APP_DIR/middleware/.stage.XXXXXXXX")
  dpkg-deb -x "$deb" "$STAGING" || die 'Failed to extract middleware package.'
  local stage_lib="$STAGING/usr/lib/bit4id/libbit4xpki.so"
  [[ -f "$stage_lib" && ! -L "$stage_lib" && -f "$stage_lib.conf" ]] || die 'Middleware library/configuration is missing.'
  [[ $(sha256sum "$stage_lib" | awk '{print $1}') == "$BIT_SHA256" ]] ||
    die 'Middleware SHA-256 mismatch; refusing to install an untested build.'
  # The vendor file may use CRLF line endings.
  sed -i -e 's/\r$//' \
    -e 's/^[Dd][Ss][Pp][Ii][Nn][Ii][Ss][Cc][Nn][Ss][Pp][Ii][Nn][[:space:]]*=.*/DSPinIsCnsPin=false/' \
    -e 's/^[Dd][Ss][Pp][Ii][Nn][Uu][Ss][Ee][Gg][Uu][Ii][[:space:]]*=.*/DSPinUseGui=true/' \
    "$stage_lib.conf"
  grep -Eiq '^DSPinIsCnsPin=false$' "$stage_lib.conf" || die 'Middleware configuration key not found.'
  grep -Eiq '^DSPinUseGui=true$' "$stage_lib.conf" || die 'Middleware configuration key not found.'
  mv -- "$STAGING" "$INSTALL_DIR"
  STAGING=''
  INSTALLED_THIS_RUN=1
  check_bit
  info "Middleware installed at: $INSTALL_DIR"
}

check_jsign_sum() {
  local package=$1 sums=$2 expected actual
  expected=$(awk -v name="$JSIGN_ASSET" '
    { sub(/\r$/, "", $2) }
    length($1)==64 && $1 ~ /^[[:xdigit:]]+$/ &&
    ($2 == name || $2 == "*" name || $2 == "./" name) { print tolower($1) }
  ' "$sums")
  [[ -n "$expected" && "$expected" != *$'\n'* ]] || die 'Cannot find a unique JSignPdf SHA-256 in the release manifest.'
  actual=$(sha256sum "$package" | awk '{print $1}')
  [[ "$expected" == "$actual" ]] || die 'JSignPdf SHA-256 check failed.'
}

install_jsign() {
  local version=''
  version=$(dpkg-query -W -f='${Version}' jsignpdf 2>/dev/null || true)
  if [[ "$version" == "$JSIGN_VERSION" && -x "$JSIGN_CLI" ]]; then
    info 'JSignPdf 3.2.1 is already installed.'
    return
  fi
  if [[ -n "$version" ]] && dpkg --compare-versions "$version" gt "$JSIGN_VERSION"; then
    die "JSignPdf $version is newer; refusing to downgrade."
  fi
  info 'Downloading JSignPdf 3.2.1 and its checksum manifest...'
  local package="$WORK/$JSIGN_ASSET" sums="$WORK/$JSIGN_SUMS"
  fetch "$JSIGN_URL/$JSIGN_ASSET" "$package"
  fetch "$JSIGN_URL/$JSIGN_SUMS" "$sums"
  check_jsign_sum "$package" "$sums"
  [[ $(dpkg-deb -f "$package" Package) == jsignpdf ]] || die 'Unexpected JSignPdf package name.'
  [[ $(dpkg-deb -f "$package" Version) == "$JSIGN_VERSION" ]] || die 'Unexpected JSignPdf version.'
  [[ $(dpkg-deb -f "$package" Architecture) == amd64 ]] || die 'Unexpected JSignPdf architecture.'
  sudo apt-get install -y --no-remove "$package"
  [[ -x "$JSIGN_CLI" ]] || die 'JSignPdf CLI is missing after installation.'
}

write_configuration() {
  local config_dir
  config_dir=$(dirname "$PKCS_CFG")
  mkdir -p -- "$config_dir"
  local planned="$WORK/new-pkcs11.cfg" tmp
  printf 'name = CardATe\nlibrary = "%s"\nslotListIndex = 0\n' "$LIB" > "$planned"
  if [[ -f "$PKCS_CFG" ]] && cmp -s "$PKCS_CFG" "$planned"; then
    info 'JSignPdf PKCS#11 configuration is already correct.'
  else
    if [[ -e "$PKCS_CFG" ]]; then
      [[ -f "$PKCS_CFG" && ! -L "$PKCS_CFG" ]] || die 'Cannot overwrite a non-regular PKCS#11 config.'
      cp -p -- "$PKCS_CFG" "$WORK/original-pkcs11.cfg"
      HAS_CONFIG=1
    fi
    tmp=$(mktemp "$config_dir/.cardate-pkcs11.XXXXXXXX")
    cat "$planned" > "$tmp"
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$PKCS_CFG"
    CONFIG_CHANGED=1
  fi

  # Preserve all unrelated preferences and explicitly disable PIN storage.
  local planned_prefs="$WORK/new-config.properties"
  if [[ -e "$PREF_CFG" ]]; then
    [[ -f "$PREF_CFG" && ! -L "$PREF_CFG" ]] || die 'Cannot overwrite non-regular preferences.'
    cp -p -- "$PREF_CFG" "$WORK/original-config.properties"
    HAS_PREF=1
    awk '!/^[[:space:]]*(store\.passwords|keystore\.type|keystore\.alias)[[:space:]]*=/' \
      "$PREF_CFG" > "$planned_prefs"
  else
    : > "$planned_prefs"
  fi
  printf 'store.passwords=false\nkeystore.type=JSIGNPKCS11\nkeystore.alias=DS0\n' >> "$planned_prefs"
  if [[ ! -f "$PREF_CFG" ]] || ! cmp -s "$planned_prefs" "$PREF_CFG"; then
    tmp=$(mktemp "$config_dir/.cardate-prefs.XXXXXXXX")
    cat "$planned_prefs" > "$tmp"
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$PREF_CFG"
    PREF_CHANGED=1
  fi
}

check_provider() {
  [[ -x "$JSIGN_CLI" ]] || die 'JSignPdf CLI not installed.'
  local result
  result=$(timeout 45s "$JSIGN_CLI" -lkt 2>&1) || {
    printf '%s\n' "$result" >&2
    die 'JSignPdf keystore check failed.'
  }
  grep -Fxq JSIGNPKCS11 <<< "$result" || { printf '%s\n' "$result" >&2; die 'JSIGNPKCS11 not available.'; }
  grep -Fxq PKCS11 <<< "$result" || die 'PKCS11 not available.'
  info 'JSignPdf PKCS#11 providers: OK.'
}

# Create a per-user desktop entry. Preserve any existing user-defined entry.
# This shortcut is deliberately installed even when JSignPdf was already present.
check_shortcut() {
  [[ -f "$SHORTCUT" && ! -L "$SHORTCUT" ]] ||
    die 'JSignPdf application menu shortcut is missing. Re-run the installer.'
  grep -Fxq 'Type=Application' "$SHORTCUT" || die 'Invalid application menu shortcut (Type).'
  grep -Fxq 'Name=JSignPdf' "$SHORTCUT" || die 'Invalid application menu shortcut (Name).'
  grep -Fxq "Exec=$JSIGN_GUI" "$SHORTCUT" || die 'Invalid application menu shortcut (Exec).'
  [[ -x "$JSIGN_GUI" ]] || die 'JSignPdf graphical launcher is missing.'
}

install_shortcut() {
  [[ -x "$JSIGN_GUI" ]] || die 'JSignPdf graphical launcher is missing.'
  mkdir -p -- "$SHORTCUT_DIR"
  if [[ -e "$SHORTCUT" || -L "$SHORTCUT" ]]; then
    # Never replace a manually customized launcher or follow symbolic links.
    [[ -f "$SHORTCUT" && ! -L "$SHORTCUT" ]] ||
      die "A non-regular application shortcut exists: $SHORTCUT"
    check_shortcut
    info 'JSignPdf application menu shortcut already exists; leaving it unchanged.'
    return
  fi

  local temporary
  temporary=$(mktemp "$SHORTCUT_DIR/.jsignpdf.XXXXXXXX")
  cat > "$temporary" <<EOF
[Desktop Entry]
Type=Application
Name=JSignPdf
Comment=Sign PDF documents with a smart card
Exec=$JSIGN_GUI
Icon=application-pdf
Terminal=false
Categories=Office;Utility;
StartupNotify=true
EOF
  chmod 644 "$temporary"
  # Avoid clobbering a concurrently created shortcut.
  if ! ln -- "$temporary" "$SHORTCUT" 2>/dev/null; then
    rm -f -- "$temporary"
    die "Cannot create application menu shortcut safely: $SHORTCUT"
  fi
  SHORTCUT_CREATED=1
  rm -f -- "$temporary"
  check_shortcut
  info 'JSignPdf is now available in the application menu (Office).'
}

check_card() {
  CARD_STATUS=not_present
  local slots certs
  if ! slots=$(timeout 30s pkcs11-tool --module "$LIB" --list-slots 2>&1); then
    warn 'Reader check unavailable; insert the card and run --check later.'
    return
  fi
  if ! grep -Eq 'token label[[:space:]]*:[[:space:]]*ATe([[:space:]]|$)' <<< "$slots"; then
    warn 'ATe card not detected; hardware check deferred.'
    return
  fi
  CARD_STATUS=found
  certs=$(timeout 30s pkcs11-tool --module "$LIB" --list-objects --type cert 2>&1) ||
    die 'Failed to read public certificates.'
  grep -Eq 'label:[[:space:]]+DS0([[:space:]]|$)' <<< "$certs" || die 'DS0 certificate not found.'
  CARD_STATUS=verified
  info 'Card and DS0 certificate: OK (no PIN requested).'
}

sign_test() {
  (( SIGN_TEST )) || return 0
  [[ "$CARD_STATUS" == verified ]] || die 'Insert the ATe card before running --sign-test.'
  [[ -t 0 && -t 1 ]] || die 'Signature test needs an interactive terminal.'
  warn 'One signature attempt only. Do not repeat after an authentication error.'
  info 'Enter the card PIN, then the signing PIN when prompted.'
  local sample="$WORK/sample.txt" sig="$WORK/sample.sig" cert="$WORK/cert.der" pub="$WORK/pub.pem"
  printf 'CardATe signature test: %s\n' "$(date -u +%FT%TZ)" > "$sample"
  timeout 180s pkcs11-tool --module "$LIB" --login --sign --id 445330 \
    --mechanism SHA256-RSA-PKCS --input-file "$sample" --output-file "$sig" ||
    die 'Signature attempt failed. Do not retry automatically.'
  [[ -s "$sig" ]] || die 'No signature was produced.'
  pkcs11-tool --module "$LIB" --read-object --type cert --id 445330 --output-file "$cert" >/dev/null
  openssl x509 -inform DER -in "$cert" -pubkey -noout > "$pub"
  openssl dgst -sha256 -verify "$pub" -signature "$sig" "$sample" | grep -Fxq 'Verified OK' ||
    die 'Signature verification failed.'
  info 'Test signature: Verified OK.'
}

main() {
  for arg in "$@"; do
    case "$arg" in
      --help|-h) usage; return ;;
      --check) CHECK_ONLY=1 ;;
      --sign-test) SIGN_TEST=1 ;;
      *) usage >&2; die "Unknown option: $arg" ;;
    esac
  done
  check_host
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/cardate.XXXXXXXX")
  if (( ! CHECK_ONLY )); then
    install_prerequisites
    install_bit
    install_jsign
    write_configuration
  else
    info 'Checking the existing installation (no download or sudo)...'
  fi
  check_bit
  [[ -f "$PKCS_CFG" ]] || die 'Missing JSignPdf PKCS#11 configuration.'
  grep -Fxq 'name = CardATe' "$PKCS_CFG" || die 'Incorrect provider name.'
  grep -Fxq "library = \"$LIB\"" "$PKCS_CFG" || die 'Incorrect provider library path.'
  check_provider
  check_card
  sign_test
  if (( CHECK_ONLY )); then
    check_shortcut
    info 'JSignPdf application menu shortcut: OK.'
  else
    install_shortcut
  fi
  printf '\n'
  info 'INSTALLATION CHECKS PASSED.'
  if [[ "$CARD_STATUS" != verified ]]; then warn 'Smart-card checks were skipped; use --check after inserting the card.'; fi
  info 'Use JSIGNPKCS11, key alias DS0, and disable Store passwords in the GUI.'
  info 'Card PIN: keystore password; signing PIN: key password.'
  info "Installed middleware: $INSTALL_DIR"
  info "Launch JSignPdf from the application menu or run: $JSIGN_GUI"
  info 'All downloaded archives and temporary test files have been removed.'
}

main "$@"
