#!/usr/bin/env python3
"""Exercise the real notifier with isolated launchd/cmux substitutes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.state = self.home / 'inventory.json'
        self.bus = self.home / '.local/state/cmux-bus/workspaces/target'
        self.bus.mkdir(parents=True)
        (self.bus / 'agents.json').write_text('{"agents":{}}')
        (self.bus / 'bus.jsonl').write_text('{"id":"old"}\n')
        self.launch = self.home / 'Library/LaunchAgents'
        self.loaded = self.home / 'loaded'
        self.loaded.mkdir()
        self.env = dict(os.environ, HOME=str(self.home),
                        XDG_STATE_HOME=str(self.home / '.local/state'),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        AGENT_BUS_SCOPE='workspace', CMUX_WORKSPACE_ID='target',
                        AGENT_BUS_NOTIFY_CHECK_INTERVAL='1', AGENT_BUS_NOTIFY_CLOSE_GRACE='2',
                        AGENT_BUS_NOTIFY_RUNTIME_DIR=str(self.home / 'runtime'),
                        AGENT_BUS_LAUNCH_AGENTS_DIR=str(self.launch),
                        INVENTORY=str(self.state), LOADED=str(self.loaded))
        self.fake('cmux', '''import json, os, sys, time
from pathlib import Path
s=json.loads(Path(os.environ['INVENTORY']).read_text())
a=sys.argv[1:]
if '--json' not in a: sys.exit(0)
mode=s.get('mode','ok')
if mode=='error': sys.exit(1)
if mode=='timeout': time.sleep(20)
if mode=='malformed': print('invalid JSON'); sys.exit(0)
if 'list-windows' in a: print(json.dumps([{'id':i} for i in s['windows']]))
else:
 w=a[a.index('--window')+1]
 if mode=='bad-workspaces': print('{}')
 else: print(json.dumps({'workspaces':[{'id':i} for i in s['windows'][w]]}))
''')
        self.fake('launchctl', '''import os, sys
from pathlib import Path
a=sys.argv[1:]; root=Path(os.environ['LOADED'])
if a[0]=='bootstrap': (root/Path(a[2]).stem).touch()
elif a[0]=='print': sys.exit(0 if (root/a[1].split('/')[-1]).exists() else 1)
elif a[0]=='bootout': (root/a[1].split('/')[-1]).unlink(missing_ok=True)
''')
        self.inventory({'one': [], 'two': ['target']})

    def fake(self, name, body):
        p = self.bin / name
        p.write_text('#!/usr/bin/env python3\n' + body)
        p.chmod(0o755)

    def inventory(self, windows=None, mode='ok'):
        tmp = self.state.with_suffix('.tmp')
        tmp.write_text(json.dumps({'windows': windows or {'one': []}, 'mode': mode}))
        tmp.replace(self.state)

    def call(self, action):
        return subprocess.run([str(ROOT / 'bin/agent-notify'), '--bus-dir', str(self.bus),
                               action, '--label', 'Test'], env=self.env,
                              capture_output=True, text=True, check=True, timeout=10)

    def start(self):
        self.call('ensure')
        self.plist = next(self.launch.glob('*.plist'))
        self.proc = subprocess.Popen([str(ROOT / 'bin/agent-notify'), '--bus-dir', str(self.bus),
                                      'run', '--label', 'Test', '--interval', '0.1'],
                                     env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop)

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
        self.proc.communicate(timeout=5)

    def test_closed_workspace_retires_and_can_resume_without_opt_out_or_replay(self):
        self.start()
        time.sleep(.5)
        self.inventory()
        out, err = self.proc.communicate(timeout=8)
        self.assertEqual(self.proc.returncode, 0, (out, err))
        self.assertIn('retired closed workspace', out)
        self.assertFalse(self.plist.exists())
        self.assertFalse(list(self.loaded.iterdir()))
        self.assertFalse((self.bus / 'notifier/pid').exists())
        self.assertFalse((self.bus / 'notifier/disabled').exists())
        self.assertEqual((self.bus / 'notifier/cursor').read_text().strip(), '1')
        self.assertEqual((self.bus / 'bus.jsonl').read_text(), '{"id":"old"}\n')
        with (self.bus / 'bus.jsonl').open('a') as f:
            f.write('{"id":"new"}\n')
        self.inventory({'two': ['target']})
        self.call('ensure')
        self.assertTrue(self.plist.exists())
        self.assertEqual((self.bus / 'notifier/cursor').read_text().strip(), '1')

    def test_live_workspace_in_second_window_survives(self):
        self.start()
        time.sleep(3)
        self.assertIsNone(self.proc.poll())
        self.assertTrue(self.plist.exists())

    def test_unavailable_or_malformed_api_preserves_service(self):
        self.start()
        for mode in ['error', 'malformed', 'bad-workspaces', 'timeout']:
            self.inventory(mode=mode)
            time.sleep(3.2)
            self.assertIsNone(self.proc.poll(), mode)
            self.assertTrue(self.plist.exists(), mode)

    def test_reappearance_resets_closure_grace(self):
        self.env['AGENT_BUS_NOTIFY_CLOSE_GRACE'] = '4'
        self.start()
        self.inventory()
        time.sleep(2)
        self.inventory({'second': ['target']})
        time.sleep(2)
        self.inventory()
        time.sleep(2)
        self.assertIsNone(self.proc.poll())

    def test_api_failure_resets_absence_grace(self):
        self.env['AGENT_BUS_NOTIFY_CLOSE_GRACE'] = '4'
        self.start()
        self.inventory()
        time.sleep(2)
        self.inventory(mode='error')
        time.sleep(3)
        self.inventory()
        time.sleep(2)
        self.assertIsNone(self.proc.poll())
        self.assertTrue(self.plist.exists())

    def snapshot(self, workspaces, age=0):
        path = self.home / '.local/state/cmux-bus/presence/snapshot.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix('.tmp')
        tmp.write_text(json.dumps({'observedAt': time.time() - age,
                                   'workspaces': [{'id': w} for w in workspaces],
                                   'errors': []}))
        tmp.replace(path)

    def test_cmux_only_uses_fresh_presence_inventory(self):
        self.inventory(mode='error')
        self.snapshot(['target'])
        self.start()
        time.sleep(3)
        self.assertIsNone(self.proc.poll())
        self.snapshot([])
        out, err = self.proc.communicate(timeout=8)
        self.assertEqual(self.proc.returncode, 0, (out, err))
        self.assertFalse(self.plist.exists())

    def test_stale_and_malformed_presence_never_trigger_cleanup(self):
        self.inventory(mode='error')
        self.snapshot([], age=60)
        self.start()
        time.sleep(3)
        self.assertIsNone(self.proc.poll())
        path = self.home / '.local/state/cmux-bus/presence/snapshot.json'
        path.write_text('{"observedAt":true,"workspaces":[],"errors":[]}')
        time.sleep(3)
        self.assertIsNone(self.proc.poll())

    def test_repo_bus_is_not_retired_by_callers_workspace(self):
        self.bus = self.home / 'repo/.agents'
        self.bus.mkdir(parents=True)
        (self.bus / 'agents.json').write_text('{"agents":{}}')
        (self.bus / 'bus.jsonl').write_text('')
        self.env['AGENT_BUS_SCOPE'] = 'repo'
        self.inventory()
        self.start()
        time.sleep(3)
        self.assertIsNone(self.proc.poll())

    def test_ensure_migrates_legacy_keepalive_without_resetting_cursor(self):
        self.call('ensure')
        plist = next(self.launch.glob('*.plist'))
        plist.write_text(plist.read_text().replace(
            '<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>',
            '<key>KeepAlive</key><true/>'))
        with (self.bus / 'bus.jsonl').open('a') as f:
            f.write('{"id":"new"}\n')
        self.call('ensure')
        self.assertIn('<key>SuccessfulExit</key><false/>', plist.read_text())
        self.assertEqual((self.bus / 'notifier/cursor').read_text().strip(), '1')
        self.call('disable')
        self.call('ensure')
        self.assertFalse(plist.exists())
        self.assertTrue((self.bus / 'notifier/disabled').exists())


if __name__ == '__main__':
    unittest.main()
