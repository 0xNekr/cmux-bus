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
        rendered=p.render([],123,error=True)
        self.assertIn('Suivi indisponible',rendered)
        self.assertTrue(rendered.startswith(p.MARKER))
        self.assertNotIn('lastBody',rendered)
        self.assertEqual(p.swift_string('"\\(evil)'),'"\\"\\\\(evil)"')

    def test_service_staleness_and_safe_render(self):
        w={'id':'workspace','agents':[{'surface':'s','state':'working'}],'counts':dict(needs_input=1,working=2,idle=0,unknown=0),'targets':{k:'s' for k in p.STATES}}
        text=p.render([w],123)
        self.assertIn('clock.epoch - 123 > 15',text)
        self.assertIn('surface.focus',text)
        self.assertIn('workspace.reorder',text)
        self.assertIn('en attente de réponse',text)

if __name__=='__main__': unittest.main()
