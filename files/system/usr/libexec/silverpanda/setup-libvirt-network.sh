#!/usr/bin/bash
set -euo pipefail

VIRSH=(/usr/bin/virsh --connect qemu:///system)
DEFAULT_NETWORK_XML=/usr/share/libvirt/networks/default.xml

if [[ ! -r "$DEFAULT_NETWORK_XML" ]]; then
  echo "Silverpanda: libvirt default network XML is missing: $DEFAULT_NETWORK_XML" >&2
  exit 1
fi

# Define the distro-provided default NAT network if it has not been defined yet.
if ! "${VIRSH[@]}" net-info default >/dev/null 2>&1; then
  "${VIRSH[@]}" net-define "$DEFAULT_NETWORK_XML"
fi

"${VIRSH[@]}" net-autostart default
if ! "${VIRSH[@]}" net-list --name | /usr/bin/grep -Fxq default; then
  "${VIRSH[@]}" net-start default
fi
