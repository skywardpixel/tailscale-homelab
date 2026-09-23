#!/usr/bin/env bash
# Run inside the bastion as root: map-owner-login.sh OWNER_USER ALIAS_USER
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
[[ $# == 2 ]] || { echo 'Usage: map-owner-login.sh OWNER_USER ALIAS_USER' >&2; exit 1; }
owner_user=$1
alias_user=$2
for login in "$owner_user" "$alias_user"; do
  [[ $login =~ ^[a-z_][a-z0-9_-]*$ && $login != root ]] || {
    echo 'Supply non-root Unix usernames.' >&2; exit 1;
  }
  id "$login" >/dev/null
done
[[ $owner_user != "$alias_user" ]] || { echo 'Owner and alias must differ.' >&2; exit 1; }
install -d -m 0755 /usr/local/sbin
cat > /usr/local/sbin/bastion-owner-shell <<'EOF'
#!/bin/sh
# Only interactive owner sessions are supported by this alias.
if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    echo 'Use an interactive SSH session for this owner login.' >&2
    exit 1
fi
EOF
printf 'exec /usr/bin/sudo -n -H -u %s /bin/bash -l\n' "$owner_user" >> /usr/local/sbin/bastion-owner-shell
chown root:root /usr/local/sbin/bastion-owner-shell
chmod 0755 /usr/local/sbin/bastion-owner-shell
tmp_rule=$(mktemp)
trap 'rm -f "$tmp_rule"' EXIT
printf '%s ALL=(%s) NOPASSWD: /bin/bash -l\n' "$alias_user" "$owner_user" > "$tmp_rule"
visudo -cf "$tmp_rule"
install -o root -g root -m 0440 "$tmp_rule" /etc/sudoers.d/bastion-owner-alias
cat > /etc/ssh/sshd_config.d/02-owner-logins.conf <<EOF
# This VM is an owner bastion, not a shared gateway for other tailnet users.
AllowUsers $owner_user $alias_user

Match User $alias_user
    ForceCommand /usr/local/sbin/bastion-owner-shell
    DisableForwarding yes
Match all
EOF
chown root:root /etc/ssh/sshd_config.d/02-owner-logins.conf
chmod 0644 /etc/ssh/sshd_config.d/02-owner-logins.conf
sshd -t
systemctl reload ssh
