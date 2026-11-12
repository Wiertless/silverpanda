#!/usr/bin/env bash
# Default to firewalld's "public" zone instead of Fedora Workstation's, which
# accepts incoming connections on every port from 1025 to 65535.
set -euo pipefail
conf=/etc/firewalld/firewalld.conf
grep -q '^DefaultZone=' "$conf"
sed -i 's/^DefaultZone=.*/DefaultZone=public/' "$conf"
grep -qx 'DefaultZone=public' "$conf"
