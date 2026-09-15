#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

loader = importlib.machinery.SourceFileLoader('presence', str(Path(__file__).resolve().parents[1]/'bin/agent-presence'))
spec = importlib.util.spec_from_loader(loader.name, loader)
p = importlib.util.module_from_spec(spec)
loader.exec_module(p)

class PresenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.file = Path(self.tmp.name)/'rollout.jsonl'
        self.file.touch()
        self.record = {'transcriptPath': str(self.file)}
        self.turns = p.CodexTurns()
        self.tick = 0

    def event(self, kind, event_type='event_msg', newline=True, **kwargs):
        self.tick += 1
        row = {'timestamp': f'2026-09-14T15:00:{self.tick:02d}Z', 'type': event_type,
               'payload': {'type': kind, **kwargs}}
        with self.file.open('a') as f:
            f.write(json.dumps(row) + ('\n' if newline else ''))

    def state(self):
        return self.turns.read(self.record)['state']

    def test_work_question_answer_completion(self):
        self.event('task_started', turn_id='a')
        self.assertEqual(self.state(), 'working')
        self.event('function_call', 'response_item', name='request_user_input', call_id='q')
        self.assertEqual(self.state(), 'needs_input')
        self.event('function_call_output', 'response_item', call_id='unrelated')
        self.assertEqual(self.state(), 'needs_input')
        self.event('function_call_output', 'response_item', call_id='q')
        self.assertEqual(self.state(), 'working')
        self.event('task_complete', turn_id='a')
        self.assertEqual(self.state(), 'idle')
        self.assertEqual(self.state(), 'idle')

    def test_async_question_remains_after_acceptance_until_user_reply(self):
        self.event('task_started', turn_id='a')
        self.event('function_call','response_item',name='request_user_input_async',call_id='q')
        self.event('function_call_output','response_item',call_id='q',output='{"accepted":true}')
        self.assertEqual(self.state(),'needs_input')
        self.event('task_complete',turn_id='a')
        self.assertEqual(self.state(),'needs_input')
        self.event('message','response_item',role='user',content=[])
        self.assertEqual(self.state(),'idle')

    def test_partial_line_rotation_and_stale_stop(self):
        self.event('task_started', turn_id='a')
        self.event('task_started', turn_id='b')
        self.event('task_complete', turn_id='a')
        self.assertEqual(self.state(), 'working')
        self.event('task_complete', turn_id='b', newline=False)
        self.assertEqual(self.state(), 'working')
        with self.file.open('a') as f: f.write('\n')
        self.assertEqual(self.state(), 'idle')
        self.file.unlink(); self.file.touch()
        self.event('task_started', turn_id='c')
        self.assertEqual(self.state(), 'working')

    def test_resume_clears_question(self):
        self.event('task_started', turn_id='a')
        self.event('request_user_input', call_id='q', turn_id='a')
        self.assertEqual(self.state(), 'needs_input')
        self.event('task_started', turn_id='b')
        self.assertEqual(self.state(), 'working')
        self.event('turn_aborted', turn_id='b')
        self.assertEqual(self.state(), 'idle')

    def test_never_guess_from_silence_or_final_text(self):
        self.event('task_started', turn_id='a')
        self.event('message', 'response_item', role='assistant', content=[{'text': 'Do you agree?'}])
        self.assertEqual(self.state(), 'working')
        self.assertEqual(p.classify({'runtimeStatus':'idle','activePromptDepth':1}), 'working')
        self.assertEqual(p.classify({}), 'unknown')

    def test_native_request_priority_and_newer_transcript(self):
        self.assertEqual(p.classify({'runtimeStatus':'needsInput','updatedAt':20}, {'state':'working','at':10}), 'needs_input')
        self.assertEqual(p.classify({'runtimeStatus':'needsInput','updatedAt':10}, {'state':'working','at':20}), 'working')
        self.assertEqual(p.classify({'runtimeStatus':'idle','activePromptDepth':1}, {'state':'idle','at':20}), 'idle')

    def test_surface_move_duplicate_dead_and_unknown(self):
        tree = {'windows':[{'workspaces':[{'id':'new','panes':[{'surfaces':[{'id':'s'},{'id':'u'}]}]}, {'id':'other','panes':[]}]}]}
        records = [dict(sessionId='old',surfaceId='s', workspaceId='old',provider='claude',startedAt=1,updatedAt=99,alive=True,runtimeStatus='idle'),
                   dict(sessionId='new',surfaceId='s', workspaceId='old',provider='claude',startedAt=2,alive=True,runtimeStatus='running'),
                   dict(sessionId='dead',surfaceId='s', provider='claude',startedAt=3,alive=False,runtimeStatus='needsInput'),
                   dict(sessionId='closed',surfaceId='gone',provider='claude',alive=True,runtimeStatus='running'),
                   dict(sessionId='uncertain',surfaceId='u',provider='claude',alive=None,runtimeStatus='idle')]
        result = p.aggregate(tree, records, lambda r:r['alive'], self.turns)
        self.assertEqual(result[0]['counts'],dict(needs_input=0,working=1,idle=0,unknown=1))
        self.assertEqual(result[0]['targets']['working'],'s')
        self.assertEqual(sum(result[1]['counts'].values()),0)

    def test_invalid_store_visible_and_no_content_exported(self):
        folder=Path(self.tmp.name)
        (folder/'codex-hook-sessions.json').write_text('{')
        records,errors=p.read_records(folder)
        self.assertTrue(errors)
        self.assertEqual(records,[])
        rows=p.status_rows(dict.fromkeys(p.STATES,0),unavailable=True)
        self.assertEqual(list(rows),['health'])
        self.assertEqual(rows['health'][0],'Suivi indisponible')

    def test_native_updates_only_changed_lines_and_clear_removed(self):
        class Client:
            def __init__(self): self.commands=[]
            def request(self,command): self.commands.append(command)
        client=Client()
        monitor=p.Monitor(None,client)
        counts=dict(needs_input=1,working=2,idle=0,unknown=1)
        rows=p.status_rows(counts)
        monitor.publish('workspace',rows)
        self.assertEqual(len(client.commands),4)
        self.assertIn('1 agent en attente de réponse',client.commands[0])
        client.commands.clear()
        monitor.publish('workspace',rows)
        self.assertEqual(client.commands,[])
        counts.update(working=1,unknown=0)
        monitor.publish('workspace',p.status_rows(counts))
        self.assertEqual(len(client.commands),2)
        self.assertTrue(any(c.startswith('clear_status agent-presence-unknown') for c in client.commands))
        self.assertTrue(any('1 agent au travail' in c for c in client.commands))
        self.assertFalse(any('workspace.select' in c for c in client.commands))

    def test_restored_session_rebinds_pid_and_surface_without_trusting_old_state(self):
        tree = {'windows':[{'workspaces':[{'id':'w','panes':[{'surfaces':[
            {'id':'restored','tty':'ttys002'}]}]}]}]}
        record = dict(sessionId='session',provider='codex',surfaceId='old',pid=11,
                      pidStartSeconds=1,startedAt=1,runtimeStatus='needsInput',
                      updatedAt=100,transcriptPath=str(self.file))
        process = dict(sessionId='session',pid=22,pidStartSeconds=2,tty='ttys002')
        result = p.recover_codex_resumes(tree,[record],[process],lambda r:False)
        self.assertEqual(result[0]['pid'],22)
        self.assertEqual(result[0]['surfaceId'],'restored')
        self.assertEqual(record['pid'],11)
        self.assertEqual(p.classify(result[0]),'unknown')
        self.event('task_started',turn_id='restored')
        aggregated=p.aggregate(tree,result,lambda r:True,self.turns)
        self.assertEqual(aggregated[0]['counts']['working'],1)
        self.event('task_complete',turn_id='restored')
        self.assertEqual(p.aggregate(tree,result,lambda r:True,self.turns)[0]['counts']['idle'],1)
        result[0]['startedAt']=9999999999
        self.assertEqual(p.aggregate(tree,result,lambda r:True,self.turns)[0]['counts']['unknown'],1)
        self.assertEqual(p.recover_codex_resumes(tree,[record],[],lambda r:False),[record])
        self.assertEqual(p.recover_codex_resumes(tree,[record],[process,process],lambda r:False),[record])
        self.assertEqual(p.recover_codex_resumes(tree,[record],[process],lambda r:True),[record])
        self.assertEqual(p.recover_codex_resumes(tree,[record],[process],lambda r:None),[record])
        process['tty']='closed'
        self.assertEqual(p.recover_codex_resumes(tree,[record],[process],lambda r:False),[record])

    def test_resume_process_parser_excludes_wrappers_and_other_commands(self):
        prefix='22 ttys002 Tue Sep 15 09:24:53 2026 '
        output='\n'.join([
            prefix+'/opt/vendor/bin/codex -c \'hooks.example="value"\' resume session -a on-request',
            prefix+'node /opt/bin/codex resume session',
            prefix+'/opt/vendor/bin/codex exec task',
            prefix+'/opt/vendor/bin/codex resume',
            prefix+'/opt/vendor/bin/codex "unterminated',
        ])
        records=p.parse_codex_resumes(output)
        self.assertEqual(len(records),1)
        self.assertEqual(records[0]['sessionId'],'session')
        self.assertEqual(records[0]['pid'],22)
        self.assertNotIn('args',records[0])

    def test_broken_connection_cleanup_always_closes_socket(self):
        from unittest.mock import Mock
        client=p.Client.__new__(p.Client)
        client.stream=Mock()
        client.socket=Mock()
        client.stream.close.side_effect=BrokenPipeError()
        client.close()
        client.socket.close.assert_called_once()

    def test_shell_install_idempotent_and_preserves_user_config(self):
        rc=Path(self.tmp.name)/'.zshrc'
        original='export CUSTOM=value\n'
        rc.write_text(original)
        p.shell_config(rc,True,Path('/tmp/runtime path/agent-presence'))
        once=rc.read_text()
        p.shell_config(rc,True,Path('/tmp/runtime path/agent-presence'))
        self.assertEqual(rc.read_text(),once)
        self.assertIn('--parent-pid $$',once)
        self.assertIn('CMUX_SOCKET_PATH',once)
        p.shell_config(rc,False,Path())
        self.assertEqual(rc.read_text().strip(),original.strip())

if __name__=='__main__': unittest.main()
