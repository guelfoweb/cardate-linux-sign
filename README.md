# CardATe Linux Sign

Sign PDF documents on Linux with compatible **ATe smart cards that require two PINs**, without Windows or a virtual machine.

This installer configures [Bit4id Universal Middleware](https://cdn.bit4id.com/es/soporte/downloads/middleware/Bit4id_Middleware.zip) and [JSignPdf](https://github.com/intoolswetrust/jsignpdf/releases). Bit4id provides access to the smart card through PKCS#11; JSignPdf creates the signed PDF. Its **JSIGNPKCS11** provider supports the separate authorization required for signing.

## Tested environment

- Linux Mint 22.3 (Ubuntu 24.04 base), x86-64
- ATe IDEMIA smart card with separate **Card PIN** and **Signing PIN**
- Alcor Micro AU9540 smart card reader
- Bit4id middleware **1.4.11.836-0** and JSignPdf **3.2.1**

Other cards, readers, and Linux distributions have not been validated.

## Install

Run as your regular user, **not with `sudo`**:

```bash
chmod +x install_cardate.sh
./install_cardate.sh
```

The script uses `sudo` only when installing system packages. It downloads and checks the required packages, configures PKCS#11, creates a JSignPdf application-menu shortcut, runs PIN-free checks, and removes downloaded archives and temporary files afterward.

## Sign a PDF

Open **JSignPdf** from the application menu and use:

| Setting | Value |
| --- | --- |
| Keystore type | `JSIGNPKCS11` |
| Keystore file | Leave empty |
| Keystore password | **Card PIN** |
| Key alias | `DS0` (after **Load Keys**) |
| Key password | **Signing PIN** |
| Store passwords | **Disabled** |

Select a PDF and click **Sign**. Never share or save PINs in files or command-line arguments.

## What the installer configures

The Bit4id middleware is extracted to a versioned directory under `~/.local/share/cardate/middleware/`. In its `libbit4xpki.so.conf` the installer sets:

```ini
DSPinIsCnsPin=false
DSPinUseGui=true
```

The JSignPdf configuration file, `~/.config/jsignpdf/pkcs11.cfg`, identifies the native PKCS#11 library using `name = CardATe` and `slotListIndex = 0`. JSignPdf uses **JSIGNPKCS11** so the two PINs can be handled separately.

## Check and troubleshoot

```bash
./install_cardate.sh --check
./install_cardate.sh --sign-test
```

- `--check` runs configuration and card/certificate checks without downloading packages or requesting PINs.
- `--sign-test` requests the two PINs interactively, creates **one raw cryptographic test signature**, and verifies it using OpenSSL. It does **not** produce a signed PDF. Do not repeat it after a PIN error.

After signing a PDF, you can inspect it with:

```bash
pdfsig /path/to/document_signed.pdf
```

`Signature Validation: Signature is Valid` confirms the cryptographic signature. Certificate trust, revocation status, and qualified-signature status require separate validation with a trusted certificate chain and current trust lists.

## Security and scope

The installer does not store PINs and does not bundle third-party proprietary libraries in this repository. It verifies the tested Bit4id library hash and checks the JSignPdf package against its release checksum manifest. It will reject a changed Bit4id build until the script is explicitly updated and retested.

**Note:** The tested installation produced a valid PDF signature on Linux Mint 22.3, but clean-machine compatibility and other card models should be checked before broader deployment.
