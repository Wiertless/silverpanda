#!/usr/bin/env bash
# Install Assistant (https://github.com/Wiertless/panda-assistant), the NPU
# assistant: its window, its background service (which also serves GNOME
# search), from a pinned, checksummed release. Both are prebuilt Rust
# binaries. Bump VERSION and SHA256 together to update it.
set -euo pipefail

VERSION=0.35.1
SHA256=3238a8aee357569cee9b23bc6a0c6eb70db5d735ff776b839cb041ecf5909d90

url="https://github.com/Wiertless/panda-assistant/releases/download/v${VERSION}/panda-assistant-${VERSION}.tar.gz"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 3 -o "$work/panda.tar.gz" "$url"
echo "${SHA256}  $work/panda.tar.gz" | sha256sum -c -
tar -xzf "$work/panda.tar.gz" -C "$work"
"$work/panda-assistant-${VERSION}/install.sh" /usr

# Both binaries are prebuilt: make sure they run on this image (all their
# libraries are here) before the image ships.
/usr/libexec/panda-assistant/assistantd --version
/usr/bin/panda-assistant --version

# Assistant's clipboard history extension, on by default (users can turn it
# off in the Extensions app). Only Assistant's service can read it.
cat > /usr/share/glib-2.0/schemas/zz1-panda-assistant.gschema.override <<'OVERRIDE'
[org.gnome.shell]
enabled-extensions=['clipboard@assistant.wiertless.github.io']
OVERRIDE
test -f /usr/share/gnome-shell/extensions/clipboard@assistant.wiertless.github.io/metadata.json
glib-compile-schemas /usr/share/glib-2.0/schemas

# Super+Space opens Assistant's pop-up. With one keyboard layout that key does
# nothing in GNOME (it switches input sources), so it moves to the keyboard's
# layout key only. Defaults in a system dconf database: users can change both.
mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/50-panda-assistant <<'DCONF'
[org/gnome/settings-daemon/plugins/media-keys]
custom-keybindings=['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/panda-assistant/']

[org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/panda-assistant]
name='Assistant'
command='panda-assistant --popup'
binding='<Super>space'

[org/gnome/desktop/wm/keybindings]
switch-input-source=['XF86Keyboard']
switch-input-source-backward=['<Shift>XF86Keyboard']
DCONF
dconf update

# /usr is read-only on the booted system: refresh the icon cache now so the
# app icon shows in the overview and search results.
gtk-update-icon-cache -f -t /usr/share/icons/hicolor
