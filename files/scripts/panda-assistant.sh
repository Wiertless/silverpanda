#!/usr/bin/env bash
# Install Assistant (https://github.com/Wiertless/panda-assistant), the NPU
# assistant: its window, its background service (which also serves GNOME
# search), from a pinned, checksummed release. Both are prebuilt Rust
# binaries. Bump VERSION and SHA256 together to update it.
set -euo pipefail

VERSION=0.23.0
SHA256=088cf4607de0d36033a70dc0700b2188618aa9035064bc5770c7a2d0df0f2cd1

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

# /usr is read-only on the booted system: refresh the icon cache now so the
# app icon shows in the overview and search results.
gtk-update-icon-cache -f -t /usr/share/icons/hicolor
