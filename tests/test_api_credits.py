"""Credit accounting is local: tracked runs against the monthly budget. Never contacts a network or model API."""
from datetime import datetime, timedelta, timezone
from decimal import Decimal
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader('fox_credits', str(ROOT/'shared/bin/desk-credits'))
spec = importlib.util.spec_from_loader(loader.name, loader)
credits = importlib.util.module_from_spec(spec)
loader.exec_module(credits)
NOW = datetime(2026, 11, 9, 18, tzinfo=timezone.utc)


class ApiCredits(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        env = {'XDG_CONFIG_HOME': str(self.root/'config'), 'XDG_STATE_HOME': str(self.root/'state')}
        self.patch = patch.dict(os.environ, env)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.config = credits.defaults()
        self.config.update(renewal_day=8, timezone='America/Chicago')

    def stamp(self, minutes=1):
        return credits.iso(NOW-timedelta(minutes=minutes))

    def test_without_a_renewal_day_spend_is_unknown_not_zero(self):
        value = credits.snapshot(credits.defaults(), NOW)
        self.assertIsNone(value['spent_usd'])
        self.assertIsNone(value['remaining_usd'])
        self.assertEqual(value['meter'], '')
        self.assertEqual(value['short'], 'API · setup')
        self.assertFalse(credits.locations()[1].exists(), 'offline display must not create state')

    def test_with_a_renewal_day_the_full_budget_shows_as_tracked_from_day_one(self):
        value = credits.snapshot(self.config, NOW)
        self.assertEqual(value['short'], 'API ~$200.00 left')
        self.assertEqual(value['status'], 'tracked')
        self.assertEqual(value['runs'], 0)
        self.assertIn('Tracked runs only', value['detail'])
        self.assertIn('Counts runs made through', credits.bar(value)['tooltip'])
        self.assertNotIn('connect', json.dumps(value).lower())

    def test_cycle_respects_day_timezone_dst_and_short_months(self):
        start, end = credits.cycle(self.config, NOW)
        self.assertEqual(credits.iso(start), '2026-11-08T06:00:00Z')
        self.assertEqual(credits.iso(end), '2026-12-08T06:00:00Z')
        october = datetime(2026, 11, 1, 12, tzinfo=timezone.utc)
        start, end = credits.cycle(self.config, october)
        self.assertEqual(credits.iso(start), '2026-10-08T05:00:00Z')
        self.assertEqual(credits.iso(end), '2026-11-08T06:00:00Z')
        self.config['renewal_day'] = 31
        start, end = credits.cycle(self.config, datetime(2027, 2, 28, 12, tzinfo=timezone.utc))
        self.assertEqual(start.day, 28)
        self.assertEqual(end.day, 31)

    def test_records_are_deduplicated_and_cycle_bounded(self):
        credits.record(self.config, 'trader', '3.25', 'call-1', self.stamp())
        credits.record(self.config, 'trader', '3.25', 'call-1', self.stamp())
        credits.record(self.config, 'plugins', '50', 'old-call', '2026-10-01T00:00:00Z')
        value = credits.snapshot(self.config, NOW)
        self.assertEqual(Decimal(value['spent_usd']), Decimal('3.25'))
        self.assertEqual(value['short'], 'API ~$196.75 left')
        self.assertEqual(value['runs'], 1)
        with self.assertRaises(ValueError):
            credits.record(self.config, 'trader', '8', 'call-1', self.stamp())

    def test_usage_groups_by_project_model_and_day_with_the_costliest_runs(self):
        runs = [('trader', '0.50', 'a', 'claude-sonnet-5-5', 30), ('trader', '1.50', 'b', 'claude-opus-5-5', 20),
                ('theme', '0.10', 'c', 'claude-sonnet-5-5', 2000), ('other', '0.05', 'd', 'claude-haiku-5-5', 1)]
        for project, cost, run, model, minutes in runs:
            credits.record(self.config, project, cost, run, self.stamp(minutes), True,
                           {'model': model, 'input_tokens': 1000, 'output_tokens': 200, 'cache_read_tokens': 50,
                            'source': 'task', 'label': project + ' review'})
        usage = credits.usage(self.config, NOW)
        self.assertEqual([p['id'] for p in usage['projects']], ['trader', 'theme', 'other'])
        self.assertEqual(Decimal(usage['projects'][0]['spent_usd']), Decimal('2.00'))
        self.assertEqual(usage['projects'][0]['average_usd'], '1.0000')
        models = {m['model']: m for m in usage['models']}
        self.assertEqual(models['claude-sonnet-5-5']['runs'], 2)
        self.assertEqual(models['claude-sonnet-5-5']['input_tokens'], 2100)
        self.assertEqual([d['day'] for d in usage['days']], ['2026-11-08', '2026-11-09'])
        self.assertEqual([t['id'] for t in usage['top']], ['b', 'a', 'c', 'd'])
        self.assertEqual(usage['top'][0]['label'], 'trader review')
        snapshot = credits.snapshot(self.config, NOW)
        self.assertIn('Other folders', [p['label'] for p in snapshot['projects']])

    def test_run_details_are_validated(self):
        self.assertEqual(credits.details('{"model":"claude-sonnet-5-5","turns":3,"source":"pi"}'),
                         {'model': 'claude-sonnet-5-5', 'turns': 3, 'source': 'pi'})
        for bad in ['[]', '{"model":"a b"}', '{"turns":-1}', '{"turns":1.5}', '{"source":"web"}',
                    '{"label":"x\\ny"}', '{"unknown":1}']:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                credits.details(bad)

    def test_over_budget_is_visible_and_meter_clamped(self):
        credits.record(self.config, 'trader', '201.25', 'big', self.stamp())
        value = credits.snapshot(self.config, NOW)
        self.assertEqual(Decimal(value['remaining_usd']), 0)
        self.assertEqual(value['remaining_percent'], 0)
        self.assertEqual(value['meter'], '▱'*10)
        self.assertEqual(credits.bar(value)['class'], ['critical'])
        self.assertIn('$201.25', value['headline'])

    def test_nonfinite_or_negative_costs_and_unknown_projects_are_rejected(self):
        for value in ['NaN', 'Infinity', '-1', 'oops']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                credits.amount(value)
        with self.assertRaises(ValueError):
            credits.record(self.config, 'nope', '1', 'x', self.stamp())

    def test_older_settings_with_billing_report_keys_still_load(self):
        old = dict(credits.defaults(), renewal_day=1, key_file='~/.config/foxml/secrets/reporting.key')
        old['projects'] = {'trader': {'label': 'Trader', 'workspace_ids': [], 'api_key_ids': []}}
        credits.atomic(credits.locations()[0], old)
        config = credits.read_config()
        self.assertNotIn('key_file', config)
        self.assertEqual(set(config['projects']), {'trader', 'plugins', 'theme', 'other'})

    def test_status_bar_and_usage_never_open_a_network_connection(self):
        credits.record(self.config, 'trader', '1', 'call', self.stamp())
        with patch.object(socket, 'socket', side_effect=AssertionError('network used')):
            credits.snapshot(self.config, NOW)
            credits.bar(credits.snapshot(self.config, NOW))
            credits.usage(self.config, NOW)
        self.assertFalse(hasattr(credits, 'sync'))


if __name__ == '__main__':
    unittest.main()
