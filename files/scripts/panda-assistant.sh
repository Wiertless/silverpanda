#!/usr/bin/env bash
# Install Panda (https://github.com/Wiertless/panda-assistant), the NPU
# assistant app and its GNOME search provider, from a pinned, checksummed
# release. Bump VERSION and SHA256 together to update it.
set -euo pipefail

VERSION=0.11.0
SHA256=79ec3cd456dc18e467456dcbe3a8755eb46550c26404e75f9453db4cd4987844

url="https://github.com/Wiertless/panda-assistant/releases/download/v${VERSION}/panda-assistant-${VERSION}.tar.gz"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 3 -o "$work/panda.tar.gz" "$url"
echo "${SHA256}  $work/panda.tar.gz" | sha256sum -c -
tar -xzf "$work/panda.tar.gz" -C "$work"
"$work/panda-assistant-${VERSION}/install.sh" /usr

# The background service is a prebuilt binary: make sure it runs on this
# image (all its libraries are here) before the image ships.
/usr/libexec/panda-assistant/assistantd --version

# /usr is read-only on the booted system: precompile now and refresh the
# icon cache so the app icon shows in the overview and search results.
python3 -m compileall -q /usr/share/panda-assistant
gtk-update-icon-cache -f -t /usr/share/icons/hicolor
