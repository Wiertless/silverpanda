#!/usr/bin/env bash
# Install Panda (https://github.com/Wiertless/panda-assistant), the NPU
# assistant app and its GNOME search provider, from a pinned, checksummed
# release. Bump VERSION and SHA256 together to update it.
set -euo pipefail

VERSION=0.1.1
SHA256=82048eddd19d31c15253774ea14216ecac63fdb72fb516394c01434f6cf59f08

url="https://github.com/Wiertless/panda-assistant/releases/download/v${VERSION}/panda-assistant-${VERSION}.tar.gz"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 3 -o "$work/panda.tar.gz" "$url"
echo "${SHA256}  $work/panda.tar.gz" | sha256sum -c -
tar -xzf "$work/panda.tar.gz" -C "$work"
"$work/panda-assistant-${VERSION}/install.sh" /usr

# /usr is read-only on the booted system: precompile now and refresh the
# icon cache so the app icon shows in the overview and search results.
python3 -m compileall -q /usr/share/panda-assistant
gtk-update-icon-cache -f -t /usr/share/icons/hicolor
