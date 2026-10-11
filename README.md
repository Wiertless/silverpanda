# SilverPanda &nbsp; [![bluebuild build badge](https://github.com/wiertless/silverpanda/actions/workflows/build.yml/badge.svg)](https://github.com/wiertless/silverpanda/actions/workflows/build.yml)

See the [BlueBuild docs](https://blue-build.org/how-to/setup/) for quick setup instructions for setting up your own repository based on this template.

After setup, it is recommended you update this README to describe your custom image.

## Installation

> [!WARNING]  
> [This is an experimental feature](https://www.fedoraproject.org/wiki/Changes/OstreeNativeContainerStable), try at your own discretion.

To rebase an existing atomic Fedora installation to the latest build:

- First rebase to the unsigned image, to get the proper signing keys and policies installed:
  ```
  rpm-ostree rebase ostree-unverified-registry:ghcr.io/wiertless/silverpanda:latest
  ```
- Reboot to complete the rebase:
  ```
  systemctl reboot
  ```
- Then rebase to the signed image, like so:
  ```
  rpm-ostree rebase ostree-image-signed:docker://ghcr.io/wiertless/silverpanda:latest
  ```
- Reboot again to complete the installation
  ```
  systemctl reboot
  ```

The `latest` tag will automatically point to the latest build. That build will still always use the Fedora version specified in `recipe.yml`, so you won't get accidentally updated to the next major version.

## ISO

A manual GitHub Actions workflow now generates a SilverPanda installer ISO and uploads it with a checksum as a temporary workflow artifact. See [Build an installer ISO](#build-an-installer-iso) below. For local ISO builds, follow the [BlueBuild ISO guide](https://blue-build.org/how-to/generate-iso/).

## Verification

These images are signed with [Sigstore](https://www.sigstore.dev/)'s [cosign](https://github.com/sigstore/cosign). You can verify the signature by downloading the `cosign.pub` file from this repo and running the following command:

```bash
cosign verify --key cosign.pub ghcr.io/wiertless/silverpanda
```

## First boot: TPM-assisted LUKS unlock

SilverPanda includes a one-time first-boot offer to enable TPM2 unlocking for the LUKS2 container backing `/`. It only proceeds when Secure Boot is enabled and a TPM2 resource-manager device is present. At the prompt, type `ENROLL` and enter the existing LUKS passphrase. The script adds a TPM keyslot without wiping existing passphrases or recovery keys, then stages a per-device `rd.luks.options=UUID=tpm2-device=auto` kernel argument. Reboot is required before that argument takes effect.

The enrollment is bound to PCR 7 (Secure Boot policy). That is more update-tolerant than binding to unstable bootloader/kernel measurements, but it does not measure the complete boot chain. Keep a tested LUKS passphrase or recovery key and verify multiple reboots before relying on TPM unlock. The service makes one automatic attempt; after a timeout, skip, or error, run the helper manually from a terminal. This helper stages `rpm-ostree` kernel arguments and requires a reboot to take effect:

```bash
sudo /usr/libexec/silverpanda/enroll-root-luks-tpm.sh
```

The helper only searches the block-device ancestry of `/`; it skips non-LUKS2 roots, and does not enroll unrelated data disks. If an existing TPM2 token is found, it does not create another token; it only offers to configure the matching boot option.

## KVM / libvirt

SilverPanda enables libvirt's modular systemd sockets and ensures that the packaged `default` NAT network is defined, enabled for autostart, and started. Open `virt-manager` and use **QEMU/KVM - system** (`qemu:///system`). Local privilege checks remain under polkit; the image does not automatically add accounts to the highly privileged `libvirt` group.

## Build an installer ISO

After the image has successfully built and been published to GHCR, go to **GitHub → Actions → Build SilverPanda ISO → Run workflow**. Choose an image tag (normally `latest`). The workflow detects the Fedora version from the selected image, builds an x86_64 Silverblue-style installer ISO with the published image as its payload, and uploads the ISO plus its checksum as a workflow artifact for seven days.

The ISO job runs manually so normal daily image builds do not spend the extra time and disk space needed for installer creation. If the ISO job fails, open its log and look for the first error in the **Build ISO** step. The workflow intentionally stops if the image is not accessible from GitHub-hosted runners or its Fedora version cannot be detected.

## GNOME Keyring auto-unlock (optional)

The `tpm-keyring-unlock` package is included, but its PAM changes and per-machine TPM enrollment are not run automatically. Configure it manually only after reviewing the upstream security notes at https://github.com/dmitriitimoshenko/tpm-keyring-unlock. In particular, the upstream project's README recommends it for systems without disk encryption; this Silverpanda setup uses LUKS, so treat keyring auto-unlock as optional and test login/recovery paths carefully.
