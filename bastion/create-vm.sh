#!/usr/bin/env bash
# Run on the host: sudo bash bastion/create-vm.sh ~/.ssh/id_ed25519.pub OWNER_USER
set -euo pipefail

[[ $EUID == 0 ]] || { echo 'Run this script with sudo.' >&2; exit 1; }
[[ $# == 2 && -f $1 ]] || { echo 'Usage: create-vm.sh PUBLIC_KEY OWNER_USER' >&2; exit 1; }
owner_user=$2
[[ $owner_user =~ ^[a-z_][a-z0-9_-]*$ && $owner_user != root ]] || {
  echo 'Supply a non-root Unix username.' >&2; exit 1;
}
[[ -c /dev/kvm ]] || { echo 'KVM is unavailable.' >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo 'This image requires x86_64.' >&2; exit 1; }
public_key=$(cat "$1")
[[ $public_key == ssh-ed25519\ * && $public_key != *$'\n'* ]] || {
  echo 'Expected a single-line Ed25519 public key.' >&2; exit 1;
}
vm_dir=/var/lib/libvirt/images/bastion
[[ ! -e $vm_dir ]] || { echo "$vm_dir already exists; refusing to overwrite." >&2; exit 1; }

apt-get update
apt-get install -y qemu-system-x86 qemu-utils libvirt-daemon-system \
  libvirt-clients virtinst cloud-image-utils curl ca-certificates python3
systemctl enable --now libvirtd
virsh --connect qemu:///system dominfo bastion >/dev/null 2>&1 && {
  echo 'A bastion VM already exists; refusing to replace it.' >&2; exit 1;
}
# Preserve existing network definitions; use libvirt's packaged NAT network.
if ! virsh --connect qemu:///system net-info default >/dev/null 2>&1; then
  virsh --connect qemu:///system net-define /usr/share/libvirt/networks/default.xml
fi
if ! virsh --connect qemu:///system net-list --name | grep -qx default; then
  virsh --connect qemu:///system net-start default
fi
virsh --connect qemu:///system net-autostart default
install -d -m 0755 "$vm_dir"
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
base=https://cloud.debian.org/images/cloud/trixie/latest
curl --fail --location --retry 3 "$base/SHA512SUMS" -o "$build_dir/SHA512SUMS"
curl --fail --location --retry 3 "$base/debian-13-generic-amd64.qcow2" \
  -o "$build_dir/debian-13-generic-amd64.qcow2"
(
  cd "$build_dir"
  grep -E ' [*]?debian-13-generic-amd64.qcow2$' SHA512SUMS > image.sha512
  [[ $(wc -l < image.sha512) == 1 ]]
  sha512sum --check image.sha512
)
install -m 0600 "$build_dir/debian-13-generic-amd64.qcow2" "$vm_dir/disk.qcow2"
qemu-img resize "$vm_dir/disk.qcow2" 12G
python3 - "$public_key" "$owner_user" > "$build_dir/user-data" <<'PY'
import json, sys
print('#cloud-config')
print(json.dumps({
    'hostname': 'bastion',
    'manage_etc_hosts': True,
    'ssh_pwauth': False,
    'disable_root': True,
    'users': [{
        'name': sys.argv[2], 'shell': '/bin/bash', 'lock_passwd': True,
        'sudo': ['ALL=(ALL) NOPASSWD:ALL'],
        'ssh_authorized_keys': [sys.argv[1]],
    }],
    'package_update': True,
    'packages': ['qemu-guest-agent', 'curl', 'ca-certificates', 'openssh-server'],
    'write_files': [{
        'path': '/etc/ssh/sshd_config.d/00-bastion.conf',
        'content': 'PermitRootLogin no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n',
        'permissions': '0644',
    }],
    'runcmd': [
        ['systemctl', 'enable', '--now', 'qemu-guest-agent'],
        ['systemctl', 'restart', 'ssh'],
    ],
}))
PY
printf 'instance-id: bastion-01\nlocal-hostname: bastion\n' > "$build_dir/meta-data"
cloud-localds "$vm_dir/seed.iso" "$build_dir/user-data" "$build_dir/meta-data"
chmod 0600 "$vm_dir/seed.iso"
virt-install --connect qemu:///system --name bastion \
  --memory 1024 --vcpus 1 --osinfo debian13 --import \
  --disk "path=$vm_dir/disk.qcow2,format=qcow2,bus=virtio" \
  --disk "path=$vm_dir/seed.iso,device=cdrom" \
  --network network=default,model=virtio \
  --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
  --serial none --console pty,target_type=virtio \
  --graphics none --noautoconsole --autostart
echo 'VM started. Wait for DHCP, then find its address:'
echo '  sudo virsh --connect qemu:///system domifaddr bastion'
printf '  ssh %s@<VM-IP> sudo cloud-init status --wait\n' "$owner_user"
echo 'Continue with bastion/README.md to enroll Tailscale and configure Cloudflare.'
