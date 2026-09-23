# Bastion VM

Intended path: browser → Cloudflare Access → Cloudflare Tunnel → bastion SSH
→ Tailscale → the destination SSH host.

The VM uses Debian 13, 1 vCPU, 1 GiB RAM, a 12 GiB sparse disk, and libvirt
NAT. It starts with the host and has no router port forwarding. Cloudflare
and Tailscale run inside the VM. The VM's disk and seed live outside this repo.

## Local configuration and privacy

Version control contains generic scripts and example configuration only.
Keep deployment identities, email allowlists, addresses, resource IDs, and
credentials in the following gitignored files:

- `.env`: API token, zone, public hostname, and VM SSH target.
- `access-policy.local.json`: the exact email allowlist.
- `README.local.md`: private deployment notes (if present).

For a new deployment:

```sh
cp bastion/.env.example bastion/.env
cp bastion/access-policy.example.json bastion/access-policy.local.json
chmod 600 bastion/.env bastion/access-policy.local.json
```

Edit the local copies before provisioning. Existing deployments should keep
those files. The example values are placeholders, not an active allowlist.
The Python script reads `.env` as literal `KEY=value` lines; use unquoted
values for hostnames and the SSH target. Update `BASTION_SSH_TARGET` if the
VM's DHCP address changes.

## Owner aliases and future users

The browser certificate flow uses the login email's prefix as its Unix
username. Create matching VM accounts. Two identities belonging to the
same owner can share a shell by running this **inside the VM**:

```sh
sudo bash map-owner-login.sh OWNER_USER ALIAS_USER
```

Both accounts must already exist. The script installs a forced SSH command
for the alias and a narrow sudo rule to open the owner's login shell.
Both identities then share the owner's home, SSH keys, and privileges,
including the owner's existing sudo access. SSH still records the initial
login name. Reconnect existing sessions to use the mapping. The alias
supports interactive sessions only; SSH exec/subsystem requests and SSH
forwarding are disabled. Normal owner SSH administration remains available.
The script restricts SSH logins to the two supplied accounts.

Do not add another person by simply expanding this VM's Cloudflare allowlist
or Unix user list. All traffic from this VM uses one Tailscale node identity;
separate Unix accounts do not inherit each browser user's tailnet permissions.

Other people need isolated environments with separate Tailscale clients
enrolled under their own identities and their own SSH credentials. Network
isolation must prevent bypass through the owner VM, its Tailscale socket,
or direct host/LAN routes. Destination OpenSSH authorization is still
required. Device-specific and posture policies need review for each new
bastion. This multi-user arrangement is not implemented by these scripts.
See [Tailscale identity](https://tailscale.com/docs/concepts/tailscale-identity).

## Create the VM

Run on the virtualization host in an interactive terminal (sudo needs your password):

```sh
sudo bash bastion/create-vm.sh ~/.ssh/id_ed25519.pub OWNER_USER
sudo virsh --connect qemu:///system domifaddr bastion
ssh OWNER_USER@<VM-IP>
sudo cloud-init status --wait
```

The script installs KVM/libvirt and uses its default NAT network. It refuses
to overwrite an existing bastion or disk directory. A failed provisioning
attempt may leave that directory behind; inspect it before retrying. The
download is verified against Debian's SHA512 manifest fetched over HTTPS.

## Join the tailnet

Inside the VM, install Tailscale using its official Debian 13 repository:

```sh
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg |
  sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list |
  sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
sudo apt-get update
sudo apt-get install -y tailscale
sudo tailscale up --hostname=bastion
```

Open the enrollment URL and approve the node. Do not enable Tailscale SSH on
the bastion: its OpenSSH server handles Cloudflare browser authentication.
Allow the bastion to reach destination-host TCP port 22 in the tailnet policy. If
destination-host uses Tailscale SSH, a separate SSH policy must authorize its source
identity and the destination user `OWNER_USER` as well.

```sh
tailscale ping destination-host
ssh OWNER_USER@destination-host
```

For ordinary OpenSSH on destination-host, generate a dedicated key as the bastion's
browser login user and install only its public key into destination-host's
`~/.ssh/authorized_keys`. Verify destination-host's host key fingerprint from the host
before accepting it. Do not copy destination-host's private key into the bastion.

## Connect Cloudflare

Set your hostname and zone in `.env`, and the exact allowed email addresses
in `access-policy.local.json`. Multiple email Include rules allow either
identity to log in. Restrict full email addresses even though SSH certificate
principals use their prefixes.

Install cloudflared in the VM from the official repository:

```sh
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg |
  sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' |
  sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
sudo apt-get update
sudo apt-get install -y cloudflared
```

After preparing the VM's login users, Tailscale, and SSH access, run on the
virtualization host:

```sh
python3 bastion/configure-cloudflare.py
```

The script uses only the dedicated API token from `.env`. Grant Access:
Apps and Policies Write and Cloudflare One Connector: cloudflared Write
on the relevant account, plus Zone Read and DNS Write on the selected zone.
It creates the Access application with browser SSH enabled, verifies the
local allowlist, installs its short-lived SSH CA, configures a dedicated
`bastion` tunnel, and publishes the protected hostname last. It stops on
conflicting policies or routes instead of replacing them.

The VM's OpenSSH server trusts `/etc/ssh/cloudflare-access-ca.pub`.
Cloudflared runs as a dynamic systemd user, with a root-only tunnel token in
`/etc/cloudflared/token` loaded using `LoadCredential`. The management API
token stays on the host and is not needed by the running connector.
The published route points to `ssh://localhost:22` inside the VM. The script
prints deployment resource IDs; keep these in private local notes if needed.

Cloudflare labels this certificate flow legacy, but documents it for
browser-rendered SSH. Its Access for Infrastructure alternative is a
different setup; do not substitute its CA into this configuration.

Visit the HTTPS hostname, authenticate, and run `ssh OWNER_USER@destination-host` in the
browser terminal. Verify `hostname` prints `destination-host`. Check the VM services
with `systemctl status tailscaled cloudflared ssh` if the connection fails.

An alternative is to route the tunnel straight to
`ssh://DESTINATION_TAILSCALE_IP:22`. That opens a destination-host shell directly and requires
Cloudflare-compatible SSH authentication on destination-host itself; it does not
provide a bastion shell first.

## Operations

```sh
sudo virsh --connect qemu:///system list --all
sudo virsh --connect qemu:///system shutdown bastion
sudo virsh --connect qemu:///system start bastion
```

Update packages within the VM periodically. This VM is not included in the
repository's Docker volume backups. Because it runs on destination-host, it cannot
provide recovery access when destination-host is powered off or its network is down.

References: [Cloudflare browser rendering](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/non-http/browser-rendering/),
[Cloudflare SSH certificates](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/non-http/short-lived-certificates-legacy/),
[Tailscale Debian packages](https://pkgs.tailscale.com/stable/#debian-trixie).
