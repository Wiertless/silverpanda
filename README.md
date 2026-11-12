# SilverPanda &nbsp; [![bluebuild build badge](https://github.com/wiertless/silverpanda/actions/workflows/build.yml/badge.svg)](https://github.com/wiertless/silverpanda/actions/workflows/build.yml)

A personal [Fedora Silverblue](https://fedoraproject.org/atomic-desktops/silverblue/) image built with [BlueBuild](https://blue-build.org/) on top of `ghcr.io/ublue-os/silverblue-main`. On top of the base image it adds:

- **Virtualization:** QEMU/KVM, libvirt (modular daemons) and virt-manager, with the default NAT network set up automatically
- **Disk encryption:** a one-time first-boot offer to unlock the LUKS2 root with the TPM
- **AMD NPU:** XDNA2 userspace (FastFlowLM/XRT) plus device permissions and memlock limits for it
- **Apps and tools:** fish (default shell for new users), Tailscale, Zed, Helium, Ptyxis, fastfetch, and LibreWolf, Loupe, Pika Backup and G4Music as Flatpaks
- **Removed:** Firefox, Yelp, GNOME Tour

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

The `latest` tag always points to the newest build. Each build uses the Fedora major version pinned by `image-version` in `recipes/recipe.yml`, so a new Fedora release only arrives when that value is bumped.

## ISO

A manual GitHub Actions workflow generates a SilverPanda installer ISO with [bootc-image-builder](https://github.com/osbuild/image-builder) and uploads it with a checksum as a temporary workflow artifact. See [Build an installer ISO](#build-an-installer-iso) below.

## Verification

These images are signed with [Sigstore](https://www.sigstore.dev/)'s [cosign](https://github.com/sigstore/cosign). You can verify the signature by downloading the `cosign.pub` file from this repo and running the following command:

```bash
cosign verify --key cosign.pub ghcr.io/wiertless/silverpanda
```

## First boot: TPM-assisted LUKS unlock

SilverPanda includes a one-time first-boot offer to enable TPM2 unlocking for the LUKS2 container backing `/`. It only proceeds when Secure Boot is enabled and a TPM2 resource-manager device is present. At the prompt, type `ENROLL` and enter the existing LUKS passphrase. The script adds a TPM keyslot without wiping existing passphrases or recovery keys, then stages a per-device `rd.luks.options=UUID=tpm2-device=auto` kernel argument. Reboot is required before that argument takes effect.

The enrollment is bound to PCR 7 (Secure Boot policy). That survives kernel and bootloader updates, but on Fedora the initramfs and kernel command line are **not** covered by PCR 7, and both sit unencrypted in `/boot`. Someone with physical access can change them and the TPM will still release the key. In practice this protects a disk removed from the machine, not a stolen laptop. For stronger protection, re-enroll with a PIN (`systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 --tpm2-with-pin=yes <device>`). Keep a tested LUKS passphrase or recovery key and verify multiple reboots before relying on TPM unlock. The service makes one automatic attempt; after a timeout, skip, or error, run the helper manually from a terminal. This helper stages `rpm-ostree` kernel arguments and requires a reboot to take effect:

```bash
sudo /usr/libexec/silverpanda/enroll-root-luks-tpm.sh
```

The helper only searches the block-device ancestry of `/`; it skips non-LUKS2 roots, and does not enroll unrelated data disks. If an existing TPM2 token is found, it does not create another token; it only offers to configure the matching boot option.

## KVM / libvirt

SilverPanda enables libvirt's modular systemd sockets and ensures that the packaged `default` NAT network is defined, enabled for autostart, and started. Open `virt-manager` and use **QEMU/KVM - system** (`qemu:///system`). Local privilege checks remain under polkit; the image does not automatically add accounts to the highly privileged `libvirt` group.

## Build an installer ISO

After the image has successfully built and been published to GHCR, go to **GitHub → Actions → Build SilverPanda ISO → Run workflow** and choose an image tag (normally `latest`). The workflow pulls the image, reads its Fedora version from `/usr/lib/os-release`, builds an x86_64 Anaconda installer ISO with [bootc-image-builder](https://github.com/osbuild/image-builder), and uploads the ISO plus a SHA-256 checksum as a workflow artifact for seven days.

The installer is interactive: it asks for language, time zone and disk layout (choose **Encrypt my data** there to get the LUKS2 root that the TPM first-boot offer expects). You can create your user account in the installer, or skip it and GNOME Initial Setup will ask on first boot. The settings live in [`iso/config.toml`](iso/config.toml). Don't remove its kickstart section: without one, bootc-image-builder makes an unattended installer that erases every disk.

After installing from the ISO, switch to the signed image once so updates are signature-checked, then reboot:

```bash
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/wiertless/silverpanda:latest
```

Notes:

- bootc-image-builder finds Fedora's installer packages from the image's os-release `ID`, so the recipe keeps `ID=fedora` (the name still shows as SilverPanda). The workflow stops early if the ID is anything else.
- To try an ISO from a branch before merging, use that branch's image tag, `br-<branch name with / replaced by _>-<fedora version>`, e.g. `br-my-feature-45`.
- To build locally, pull the image and then run bootc-image-builder:

  ```bash
  sudo podman pull ghcr.io/wiertless/silverpanda:latest
  ```

  ```bash
  sudo podman run --rm -it --privileged --pull=newer \
    --security-opt label=type:unconfined_t \
    -v ./iso/config.toml:/config.toml:ro -v ./output:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    ghcr.io/osbuild/bootc-image-builder:v90.0.0 \
    --type anaconda-iso --rootfs btrfs ghcr.io/wiertless/silverpanda:latest
  ```

  The ISO is written to `output/bootiso/install.iso`.

## Login keyring

Fedora 45 replaced GNOME Keyring with oo7 (`oo7-daemon` and `pam_oo7`). Password logins unlock it; fingerprint logins leave it locked until you type the password, as on stock Fedora. Since GNOME 51 (Fedora 45) the login screen after boot does not offer fingerprint at all, by upstream design; fingerprint still works on the lock screen and for `sudo`. SilverPanda no longer ships `tpm-keyring-unlock`, which only works with `pam_gnome_keyring`.

If you configured `tpm-keyring-unlock` on an earlier image, its edited copies of GDM's PAM files in `/etc/pam.d` still override Fedora 45's own files in `/usr/lib/pam.d`. That breaks keyring unlock and fingerprint at the login screen. Move them aside, unload its SELinux module, and reboot. Do not run `tpm-keyring-unlock-deconfigure`: it restores Fedora 44 copies of the files.

```bash
sudo mkdir -p /root/pam-f44 && sudo mv /etc/pam.d/gdm-* /root/pam-f44/
sudo semodule -r tpm_keyring_unlock
```

The sealed secret in `~/.local/share/tpm-keyring-unlock` and the persisted TPM key at handle `0x81018000` can then be removed (`rm -rf ~/.local/share/tpm-keyring-unlock`, `sudo tpm2_evictcontrol -C o -c 0x81018000`).

## AMD NPU

`recipes/ai-npu.yml` installs the XDNA2 userspace from the `abn/amd-npu` COPR and keeps Fedora's signed kernel driver. A udev rule gives the logged-in user (and the `render` group) access to `/dev/accel/*`. Locked-memory limits are raised for NPU buffers: unlimited for the `render` group in PAM sessions, and unlimited for every user's graphical session via a `user@.service` drop-in.
