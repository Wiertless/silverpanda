#!/usr/bin/env bash
# Install Panda (https://github.com/Wiertless/panda-assistant), the NPU
# assistant app and its GNOME search provider, from a pinned, checksummed
# release. Bump VERSION and SHA256 together to update it.
set -euo pipefail

VERSION=0.9.0
SHA256=c14be277221d4e4c0c23252a3340a0975d531728d0d810d5079b700f40777d15

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
