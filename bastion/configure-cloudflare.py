#!/usr/bin/env python3
"""Provision this bastion's Access application, SSH CA, tunnel, and DNS.

Run from any directory. Uses only bastion/.env; never prints credentials.
Requires SSH administrative access to the VM at its libvirt address.
"""
import json
import pathlib
import re
import subprocess
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent
values = dict(line.split('=', 1) for line in (ROOT / '.env').read_text().splitlines()
              if '=' in line and not line.lstrip().startswith('#'))
token = values['CF_API_TOKEN'].strip().strip('\"\'')
assert token
HOSTNAME = values['BASTION_HOSTNAME'].strip()
ZONE_NAME = values['CF_ZONE_NAME'].strip()
VM = values['BASTION_SSH_TARGET'].strip()
assert re.fullmatch(r'[a-zA-Z0-9.-]+', HOSTNAME), 'Invalid hostname'
assert re.fullmatch(r'[a-zA-Z0-9.-]+', ZONE_NAME), 'Invalid zone name'
assert re.fullmatch(r'[a-z_][a-z0-9_-]*@[a-zA-Z0-9.-]+', VM), 'Invalid SSH target'
assert HOSTNAME.endswith('.' + ZONE_NAME), 'Hostname must belong to the configured zone'


def api(path, method='GET', body=None):
    req = urllib.request.Request(
        'https://api.cloudflare.com/client/v4/' + path,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            data = json.load(response)
    except urllib.error.HTTPError as exc:
        data = json.load(exc)
        raise RuntimeError(f'{method} {path}: HTTP {exc.code}, {data.get("errors")}') from None
    if not data.get('success'):
        raise RuntimeError(f'{method} {path}: {data.get("errors")}')
    return data['result']


def remote_write(path, content, mode='0644'):
    # Fixed paths only. Contents (including the tunnel token) travel over stdin.
    subprocess.run(['ssh', '-o', 'BatchMode=yes', VM,
                    f'sudo install -m {mode} /dev/stdin {path}'],
                   input=content, text=True, check=True)


zones = api('zones?name=' + ZONE_NAME)
assert len(zones) == 1, 'Expected exactly one zone'
zone = zones[0]['id']
account = zones[0]['account']['id']
base = f'accounts/{account}'
apps = [a for a in api(base + '/access/apps') if a.get('domain') == HOSTNAME]
assert len(apps) <= 1, 'Multiple matching Access applications'
policy = json.loads((ROOT / 'access-policy.local.json').read_text())
policy['precedence'] = 1
if apps:
    app = apps[0]
else:
    app = api(base + '/access/apps', 'POST', {
        'name': 'Bastion SSH', 'domain': HOSTNAME, 'type': 'ssh',
        'session_duration': '1h',
        'app_launcher_visible': True, 'policies': [policy],
    })
app_id = app['id']
app = api(base + f'/access/apps/{app_id}')
policies = api(base + f'/access/apps/{app_id}/policies')
assert len(policies) == 1, 'Unexpected Access policy count; review manually'
for field in ('decision', 'include', 'exclude', 'require'):
    assert policies[0].get(field, []) == policy[field], f'Unexpected policy {field}'
if app['type'] == 'self_hosted' and app['name'] == 'Bastion SSH':
    app = api(base + f'/access/apps/{app_id}', 'PUT', {
        'name': 'Bastion SSH', 'domain': HOSTNAME, 'type': 'ssh',
        'session_duration': '1h', 'app_launcher_visible': True,
        'policies': [{'id': policies[0]['id'], 'precedence': 1}],
    })
assert app['type'] == 'ssh', 'Expected browser SSH application'
print('Access application matches the local policy.', flush=True)

cas = api(base + '/access/apps/ca') or []
matches = [ca for ca in cas if ca.get('aud') == app['aud']]
assert len(matches) <= 1
ca = matches[0] if matches else api(base + f'/access/apps/{app_id}/ca', 'POST')
remote_write('/etc/ssh/cloudflare-access-ca.pub', ca['public_key'].strip() + '\n')
remote_write('/etc/ssh/sshd_config.d/01-cloudflare-access.conf',
             'TrustedUserCAKeys /etc/ssh/cloudflare-access-ca.pub\n')
subprocess.run(['ssh', '-o', 'BatchMode=yes', VM,
                'sudo sshd -t && sudo systemctl reload ssh'], check=True)

tunnels = [t for t in api(base + '/cfd_tunnel?is_deleted=false') if t['name'] == 'bastion']
assert len(tunnels) <= 1, 'Multiple bastion tunnels'
if tunnels:
    tunnel = tunnels[0]
    assert tunnel.get('config_src') == 'cloudflare'
else:
    tunnel = api(base + '/cfd_tunnel', 'POST', {'name': 'bastion', 'config_src': 'cloudflare'})
tunnel_id = tunnel['id']
desired = {'ingress': [
    {'hostname': HOSTNAME, 'service': 'ssh://localhost:22'},
    {'service': 'http_status:404'},
]}
existing = api(base + f'/cfd_tunnel/{tunnel_id}/configurations')
if (existing.get('config') or {}).get('ingress'):
    assert existing['config']['ingress'] == desired['ingress'], 'Unexpected tunnel routes; review manually'
else:
    api(base + f'/cfd_tunnel/{tunnel_id}/configurations', 'PUT', {'config': desired})
connector_token = api(base + f'/cfd_tunnel/{tunnel_id}/token')
subprocess.run(['ssh', '-o', 'BatchMode=yes', VM,
                'sudo install -d -m 0700 /etc/cloudflared'], check=True)
remote_write('/etc/cloudflared/token', connector_token + '\n', '0600')
remote_write('/etc/systemd/system/cloudflared.service', '''[Unit]
Description=Cloudflare Tunnel for bastion SSH
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
DynamicUser=yes
LoadCredential=token:/etc/cloudflared/token
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token-file %d/token
Restart=on-failure
RestartSec=5s
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
''')
subprocess.run(['ssh', '-o', 'BatchMode=yes', VM,
                'sudo systemctl daemon-reload && sudo systemctl enable cloudflared '
                '&& sudo systemctl restart cloudflared'], check=True)

# Publish only after Access protection and the SSH CA are installed.
records = api(f'zones/{zone}/dns_records?name={HOSTNAME}')
record = {'type': 'CNAME', 'name': HOSTNAME,
          'content': tunnel_id + '.cfargotunnel.com', 'proxied': True, 'ttl': 1}
if records:
    assert len(records) == 1
    for field in ('type', 'name', 'content', 'proxied'):
        assert records[0][field] == record[field], f'Conflicting DNS {field}; review manually'
else:
    api(f'zones/{zone}/dns_records', 'POST', record)
print(json.dumps({'hostname': HOSTNAME, 'account_id': account, 'zone_id': zone,
                  'app_id': app_id, 'tunnel_id': tunnel_id}, indent=2))
