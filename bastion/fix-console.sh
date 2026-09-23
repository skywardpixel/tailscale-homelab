#!/usr/bin/env bash
# Work around Debian GRUB bug #1111240 for a bastion stuck before Linux boots.
# This power-cycles the VM; run only while it is stuck at the bootloader.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
export LC_ALL=C
backup_dir=$(mktemp -d /var/lib/libvirt/images/bastion/console-fix.XXXXXX)
virsh --connect qemu:///system dumpxml bastion --inactive > "$backup_dir/original.xml"
python3 - "$backup_dir/original.xml" "$backup_dir/fixed.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
tree = ET.parse(sys.argv[1])
devices = tree.getroot().find('devices')
assert devices is not None
for device in list(devices):
    if device.tag in ('serial', 'console'):
        devices.remove(device)
console = ET.SubElement(devices, 'console', {'type': 'pty'})
ET.SubElement(console, 'target', {'type': 'virtio', 'port': '0'})
tree.write(sys.argv[2], encoding='unicode')
PY
# Validate and persist the next-boot configuration before stopping the VM.
virsh --connect qemu:///system define --validate "$backup_dir/fixed.xml"
state=$(virsh --connect qemu:///system domstate bastion)
if [[ $state != 'shut off' ]]; then
  virsh --connect qemu:///system destroy bastion
fi
virsh --connect qemu:///system start bastion
echo "Original VM definition saved in $backup_dir/original.xml"
echo 'Wait about a minute, then check:'
echo '  sudo virsh --connect qemu:///system net-dhcp-leases default'
echo 'The virtio console may show no early boot text; use the DHCP lease to connect by SSH.'
