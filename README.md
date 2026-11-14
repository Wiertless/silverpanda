# SilverPanda &nbsp; [![bluebuild build badge](https://github.com/wiertless/silverpanda/actions/workflows/build.yml/badge.svg)](https://github.com/wiertless/silverpanda/actions/workflows/build.yml)

A personal [Fedora Silverblue](https://fedoraproject.org/atomic-desktops/silverblue/) image built with [BlueBuild](https://blue-build.org/) on top of `ghcr.io/ublue-os/silverblue-main`. On top of the base image it adds:

- **Virtualization:** QEMU/KVM, libvirt (modular daemons) and virt-manager, with the default NAT network set up automatically
- **Disk encryption:** a one-time first-boot offer to unlock the LUKS2 root with the TPM
- **AMD NPU:** XDNA2 userspace (FastFlowLM/XRT) plus device permissions and memlock limits for it
- **Zed C/C++ support:** a `zed` toolbox with clangd and the GCC toolchain, so includes like `<iostream>` resolve
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

The `latest` tag always points to the newest build. `image-version` in `recipes/recipe.yml` is `latest`, so builds follow the newest Fedora release the base image offers; set it to a number (e.g. `45`) to stay on one release.

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
    ghcr.io/osbuild/bootc-image-builder:v90.0.0@sha256:2d29e039bbc0a87506055368fa1ac1c1a511cefe762a95dd099e89e517701080 \
    --type anaconda-iso --rootfs btrfs ghcr.io/wiertless/silverpanda:latest
  ```

  The ISO is written to `output/bootiso/install.iso`.

## Login keyring

Fedora 45 replaced GNOME Keyring with oo7 (`oo7-daemon` and `pam_oo7`). Password logins unlock it; fingerprint logins leave it locked until you type the password, as on stock Fedora. Since GNOME 51 (Fedora 45) the login screen after boot does not offer fingerprint at all, by upstream design; fingerprint still works on the lock screen and for `sudo`. SilverPanda no longer ships `tpm-keyring-unlock`, which only works with `pam_gnome_keyring`.

Machines that had `tpm-keyring-unlock` configured on an earlier image keep its edited GDM PAM files in `/etc/pam.d`, which override Fedora 45's own and break keyring unlock. The image removes its SELinux module on boot. To clean up the rest (do not use `tpm-keyring-unlock-deconfigure`, which restores Fedora 44 copies):

```bash
sudo mkdir -p /root/pam-f44 && sudo mv /etc/pam.d/gdm-* /root/pam-f44/
rm -rf ~/.local/share/tpm-keyring-unlock && sudo tpm2_evictcontrol -C o -c 0x81018000
```

## Zed C/C++ toolbox

The host image has no compiler headers, so a host clangd reports `'iostream' file not found`. SilverPanda instead ships `/usr/bin/clangd` as a wrapper that runs the real clangd inside a toolbox named `zed`. That toolbox uses `ghcr.io/wiertless/silverpanda-toolbox`, built daily from [`toolbox/Containerfile`](toolbox/Containerfile): Fedora's toolbox image plus `clang-tools-extra`, `gcc-c++`, `make`, `cmake`, `ninja-build`, `gdb`, `git` and `fish`, without weak dependencies or package caches. The image is signed with the same key as the OS image, and the OS image's container policy requires that signature. If it can't be pulled, the setup falls back to Fedora's toolbox image and installs the same packages. Zed uses clangd from `PATH` when it finds one, so no Zed settings are needed.

Nothing is downloaded until it's needed: the toolbox is created the first time something starts clangd (usually opening a C/C++ file in Zed), which downloads the toolbox image and takes a minute or two that one time.

- Build and run your code in the same toolbox (`toolbox enter zed`) so it uses the headers clangd sees. Install more libraries there with `sudo dnf install ...`.
- To make Zed's built-in terminal open in that toolbox, add this to `~/.config/zed/settings.json`:

  ```json
  "terminal": { "shell": { "with_arguments": { "program": "/usr/bin/toolbox", "args": ["enter", "zed"] } } }
  ```
- Projects with a `compile_commands.json` (CMake: `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`) get the most accurate results.
- Toolbox containers don't update with their image. To move to a newer toolchain, or from an older `zed` toolbox to the prebuilt image, run `toolbox rm --force zed` and restart Zed.
- Layering `clang-tools-extra` on the host would conflict with the wrapper; install it in the toolbox instead.

## Firewall

The default firewalld zone is `public` (SSH, mDNS and DHCPv6 client only) instead of Fedora Workstation's zone, which accepts incoming connections on ports 1025–65535. Open what you need per service, e.g. `sudo firewall-cmd --permanent --add-service=kdeconnect && sudo firewall-cmd --reload`. The `tailscale0` interface is in the `trusted` zone, so the tailnet is not filtered; Tailscale ACLs control who can reach the machine. If you changed `/etc/firewalld/firewalld.conf` yourself, your copy is kept; set the zone with `sudo firewall-cmd --set-default-zone=public`.

## Panda (NPU assistant)

[Panda](https://github.com/Wiertless/panda-assistant) is a GNOME app that chats with a model on the NPU through FastFlowLM and can open apps, files and websites, change settings and read system info. Type anything in the overview search and pick **Ask: …** to send it to Panda. The image installs a pinned release: bump `VERSION` and `SHA256` in [`files/scripts/panda-assistant.sh`](files/scripts/panda-assistant.sh) to update it.

## AMD NPU

`recipes/ai-npu.yml` installs the XDNA2 userspace from the `abn/amd-npu` COPR and keeps Fedora's signed kernel driver. A udev rule gives the logged-in user (and the `render` group) access to `/dev/accel/*`. Locked memory is unlimited for members of the `render` group only (PAM sessions and the systemd user manager, so graphical apps too). Add your user to it once, then reboot (logging out is not enough: the systemd user manager keeps running with the old groups). On Silverblue the group lives in `/usr/lib/group`, so copy it to `/etc/group` first:

```bash
grep -E '^render:' /etc/group || grep -E '^render:' /usr/lib/group | sudo tee -a /etc/group
sudo usermod -aG render "$USER"
```
