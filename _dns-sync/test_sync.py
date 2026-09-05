"""Run with python3 -m unittest discover -s _dns-sync -p 'test_*.py'."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('sync.sh').resolve()


class SyncTests(unittest.TestCase):
    def run_sync(self, records, ip='100.86.69.87', failure=False):
        with tempfile.TemporaryDirectory() as tmp:
            mock = Path(tmp, 'curl')
            mock.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
method = args[args.index('-X')+1] if '-X' in args else 'GET'
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps({'method': method, 'args': args})+'\\n')
if os.environ['FAILURE'] == '1':
    print(json.dumps({'success': False, 'errors': [{'message': 'denied'}]}))
elif method != 'GET':
    print(json.dumps({'success': True, 'result': {}}))
elif any('/dns_records?' in a for a in args):
    print(json.dumps({'success': True, 'result': json.loads(os.environ['RECORDS'])}))
else:
    print(json.dumps({'success': True, 'result': [{'id': 'zone'}]}))
''')
            mock.chmod(0o755)
            calls_file = Path(tmp, 'calls')
            env = dict(os.environ, PATH=tmp+':'+os.environ['PATH'],
                       CF_API_TOKEN='test', CUSTOM_DOMAIN='app.example.com',
                       TS_IPV4=ip, RECORDS=json.dumps(records),
                       CALLS=str(calls_file), FAILURE=str(int(failure)))
            result = subprocess.run(['bash', str(SCRIPT)], env=env,
                                    capture_output=True, text=True)
            calls = [json.loads(line) for line in calls_file.read_text().splitlines()] if calls_file.exists() else []
            return result, calls

    def test_migrate_cname_in_place(self):
        result, calls = self.run_sync([{'id': 'old', 'type': 'CNAME', 'content': 'node.ts.net'}])
        self.assertEqual(result.returncode, 0, result.stderr)
        writes = [c for c in calls if c['method'] != 'GET']
        self.assertEqual([c['method'] for c in writes], ['PUT'])
        args = writes[0]['args']
        self.assertIn('https://api.cloudflare.com/client/v4/zones/zone/dns_records/old', args)
        self.assertEqual(json.loads(args[args.index('--data')+1]),
                         {'type': 'A', 'name': 'app.example.com', 'content': '100.86.69.87', 'ttl': 1, 'proxied': False})

    def test_existing_correct_a_with_txt_is_unchanged(self):
        result, calls = self.run_sync([{'id': 'a', 'type': 'A', 'content': '100.86.69.87', 'proxied': False}, {'id': 'txt', 'type': 'TXT'}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(c['method'] == 'GET' for c in calls))

    def test_create_preserves_txt(self):
        result, calls = self.run_sync([{'id': 'txt', 'type': 'TXT'}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c['method'] for c in calls if c['method'] != 'GET'], ['POST'])

    def test_wrong_ip_or_proxied_record_is_updated(self):
        for ip, proxied in [('100.64.1.2', False), ('100.86.69.87', True)]:
            result, calls = self.run_sync([{'id': 'a', 'type': 'A', 'content': ip, 'proxied': proxied}])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls[-1]['method'], 'PUT')

    def test_conflicts_do_not_mutate_dns(self):
        for records in [[{'type': 'AAAA'}], [{'type': 'A'}, {'type': 'A'}]]:
            result, calls = self.run_sync(records)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(all(c['method'] == 'GET' for c in calls))

    def test_invalid_ips_make_no_api_calls(self):
        for ip in ['', '192.168.1.1', '100.63.1.1', '100.128.1.1', '100.64.1.256', '100.64.1', '100.64.01.1', 'nope']:
            result, calls = self.run_sync([], ip=ip)
            self.assertNotEqual(result.returncode, 0, ip)
            self.assertEqual(calls, [], ip)

    def test_api_error_stops_sync(self):
        result, calls = self.run_sync([], failure=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)


if __name__ == '__main__':
    unittest.main()
