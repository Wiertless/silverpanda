#!/usr/bin/env bash
# Install Lemonade Server (https://github.com/lemonade-sdk/lemonade) from a
# pinned, checksummed release. Assistant uses it when it's there: FastFlowLM
# on the NPU, llama.cpp on the graphics chip for bigger models. Bump VERSION
# and SHA256 together to update it.
#
# The RPM installs under /opt, which on Silverblue is /var/opt: what's put
# there while building the image doesn't reach installed systems on updates.
# So its files are unpacked into /usr/lib/lemonade instead (lemond finds its
# resources relative to itself), with a user unit of our own. Lemonade builds
# RPMs for Fedora 43 and 44; the checks at the end fail the image build if
# the Fedora 44 one doesn't run here.
set -euo pipefail

VERSION=2026.46.2
FEDORA=fc44
SHA256=72e33ab28b4f8348bee31f549526a19afd63a65f75d1bf96d35d33c0245b215a
PREFIX=/usr/lib/lemonade

url="https://github.com/lemonade-sdk/lemonade/releases/download/v${VERSION}/lemonade-server-${VERSION}-${FEDORA}.x86_64.rpm"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 3 -o "$work/lemonade.rpm" "$url"
echo "${SHA256}  $work/lemonade.rpm" | sha256sum -c -

# The libraries it links against (all from Fedora), and cpio to unpack it.
dnf install -y libcurl libwebsockets brotli libdrm libgomp libcap openssl-libs zlib-ng-compat cpio

mkdir -p "$work/root" "$PREFIX"
rpm2cpio "$work/lemonade.rpm" | (cd "$work/root" && cpio -idm --quiet)
test -x "$work/root/opt/bin/lemond"
cp -a "$work/root/opt/bin" "$work/root/opt/share" "$PREFIX/"
ln -sf "$PREFIX/bin/lemond" /usr/bin/lemond
ln -sf "$PREFIX/bin/lemonade" /usr/bin/lemonade
# It also looks for its resources in the usual share directories.
ln -sfn "$PREFIX/share/lemonade-server" /usr/share/lemonade-server

# Runs as the user, not as a system user of its own: only the user's session
# has the NPU's locked-memory limit (limits.d, render group), and it shares
# the FastFlowLM models the user already downloaded. Not started at login:
# Assistant starts it when it needs a model and stops it when it unloads.
install -Dm644 /dev/stdin /usr/lib/systemd/user/lemond.service <<'UNIT'
[Unit]
Description=Lemonade Server (user)
Documentation=https://lemonade-server.ai/docs/

[Service]
Type=simple
WorkingDirectory=%h
EnvironmentFile=-%E/lemonade/lemond.conf
ExecStart=/usr/bin/lemond
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
KillSignal=SIGINT
PrivateTmp=yes
NoNewPrivileges=yes
ProtectSystem=full
RestrictRealtime=yes
LockPersonality=yes
# Models are most of the memory (Gemma 4 E2B on the NPU is ~5 GB with the
# embedding model; two models at once can reach ~13 GB of 16). Past 8 GB the
# kernel reclaims this service's cache first; at 9 GB it kills the model
# server, which restarts, instead of the whole desktop freezing.
MemoryHigh=8G
MemoryMax=9G
UNIT

# Defaults for this image, on top of the package's:
# - two models at once, so a model on the graphics chip can run next to the
#   one on the NPU instead of replacing it;
# - the FastFlowLM the image ships (on PATH), not a second downloaded copy;
# - no model update checks at startup.
python3 - "$PREFIX/share/lemonade/defaults.json" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        d = json.load(f)
except FileNotFoundError:
    d = {}
d["max_loaded_models"] = 2
d.setdefault("flm", {})["prefer_system"] = True
d["auto_check_model_updates"] = False
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PY

# It has to run on this image before the image ships.
ldd /usr/bin/lemond | (! grep "not found")
lemond --version
lemonade --version
