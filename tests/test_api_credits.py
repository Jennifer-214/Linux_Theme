"""Credit accounting uses fixed fixtures and never contacts a billing or model API."""
from datetime import datetime, timedelta, timezone
from decimal import Decimal
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader('fox_credits', str(ROOT/'shared/bin/fox-credits'))
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

    def report(self, projects, **changes):
        start, end = credits.cycle(self.config, NOW)
        value = {'signature': credits.signature(self.config), 'cycle_start': credits.iso(start),
                 'cycle_end': credits.iso(end), 'updated_at': credits.iso(NOW),
                 'as_of': credits.iso(NOW-timedelta(hours=4)), 'projects': projects}
        value.update(changes)
        credits.atomic(credits.locations()[1]/'reported.json', value)

    def test_unconfirmed_cycle_and_unconnected_billing_are_unknown_not_zero(self):
        for config in [credits.defaults(), self.config]:
            value = credits.snapshot(config, NOW)
            self.assertIsNone(value['spent_usd'])
            self.assertIsNone(value['remaining_percent'])
            self.assertIsNone(value['remaining_usd'])
            self.assertEqual(value['meter'], '')
            self.assertNotIn('$200.00 left', value['short'])
        self.assertFalse(credits.locations()[1].exists(), 'offline display must not create state')

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

    def test_paginated_costs_are_cents_not_dollars_and_all_rows_count(self):
        self.config['projects']['trader']['api_key_ids'] = ['key-trader']
        self.config['projects']['plugins']['workspace_ids'] = ['workspace-plugins']
        stamp = credits.iso(NOW-timedelta(hours=4))
        pages = [
            {'data': [{'group': {'api_key_id': 'key-trader'}, 'cost': {'currency': 'USD', 'amount': '1234.500000'}}],
             'has_more': True, 'next_page': 'second', 'data_refreshed_at': stamp},
            {'data': [{'group': {'workspace_id': 'workspace-plugins'}, 'cost': {'currency': 'USD', 'amount': '200.250000'}},
                      {'group': {}, 'cost': {'currency': 'USD', 'amount': '10.000000'}}],
             'has_more': False, 'next_page': None, 'data_refreshed_at': stamp}]
        urls = []
        def fake(url, key):
            urls.append(url)
            self.assertEqual(key, 'fixture-only')
            return pages[len(urls)-1]
        start, end = credits.cycle(self.config, NOW)
        totals, refreshed = credits.collect(self.config, start, NOW, 'fixture-only', request=fake)
        self.assertEqual(totals, {'trader': Decimal('12.345'), 'plugins': Decimal('2.0025'), 'theme': Decimal(0),
                                  'other': Decimal('.10')})
        self.assertEqual(refreshed, stamp)
        self.assertIn('page=second', urls[1])
        self.assertTrue(all(url.startswith('https://api.anthropic.com/') for url in urls))
        self.assertTrue(all('fixture-only' not in url for url in urls))

    def test_incomplete_pagination_and_unknown_data_never_publish_a_zero(self):
        start, _ = credits.cycle(self.config, NOW)
        examples = [
            {'data': [], 'data_refreshed_at': None, 'has_more': False},
            {'data': [], 'data_refreshed_at': credits.iso(NOW), 'has_more': True, 'next_page': ''},
            {'data': [{'group': {}, 'cost': {'currency': 'EUR', 'amount': '10'}}], 'data_refreshed_at': credits.iso(NOW), 'has_more': False}]
        for page in examples:
            with self.subTest(page=page), self.assertRaises(ValueError):
                credits.collect(self.config, start, NOW, 'fixture', request=lambda *_: page)
        self.assertFalse((credits.locations()[1]/'reported.json').exists())

    def test_interactive_plan_cost_is_not_counted_as_monthly_api_credit_spend(self):
        start, _ = credits.cycle(self.config, NOW)
        page = {'data': [
            {'group': {'product': 'messages_api'}, 'cost': {'currency':'USD', 'amount':'125'}},
            {'group': {'product': 'claude_code'}, 'cost': {'currency':'USD', 'amount':'50000'}},
            {'group': {'product': 'chat'}, 'cost': {'currency':'USD', 'amount':'50000'}}],
            'data_refreshed_at': credits.iso(NOW), 'has_more': False}
        totals, _ = credits.collect(self.config, start, NOW, 'fixture', request=lambda *_: page)
        self.assertEqual(sum(totals.values()), Decimal('1.25'))

    def test_authoritative_snapshot_does_not_add_locally_recorded_costs_again(self):
        self.config['projects']['trader']['api_key_ids'] = ['key-trader']
        credits.record(self.config, 'trader', '12.345', 'call-1', credits.iso(NOW-timedelta(minutes=1)))
        self.report({'trader': '12.345', 'plugins': '2', 'other': '0.10'})
        value = credits.snapshot(self.config, NOW)
        self.assertEqual(value['source'], 'anthropic')
        self.assertEqual(Decimal(value['spent_usd']), Decimal('14.445'))
        self.assertEqual(Decimal(value['remaining_usd']), Decimal('185.555'))
        self.assertEqual(value['projects'][0]['detail'], '$12.34')
        self.assertIsNone(value['projects'][1]['spent_usd'], 'unmapped projects must not claim zero spend')

    def test_local_records_are_partial_deduplicated_and_cycle_bounded(self):
        stamp = credits.iso(NOW-timedelta(minutes=1))
        credits.record(self.config, 'trader', '3.25', 'call-1', stamp)
        credits.record(self.config, 'trader', '3.25', 'call-1', stamp)
        credits.record(self.config, 'plugins', '50', 'old-call', '2026-10-01T00:00:00Z')
        value = credits.snapshot(self.config, NOW)
        self.assertEqual(value['status'], 'partial')
        self.assertEqual(value['source'], 'local')
        self.assertEqual(Decimal(value['spent_usd']), Decimal('3.25'))
        self.assertIn('~', value['short'])
        self.assertIn('excludes untracked', value['detail'])
        with self.assertRaises(ValueError):
            credits.record(self.config, 'trader', '8', 'call-1', stamp)

    def test_renewal_mapping_changes_and_old_reports_invalidate_cached_figures(self):
        self.report({'trader': '20'})
        self.config['renewal_day'] = 1
        self.assertIsNone(credits.snapshot(self.config, NOW)['spent_usd'])
        self.config['renewal_day'] = 8
        self.config['projects']['plugins']['api_key_ids'] = ['different-key']
        self.assertIsNone(credits.snapshot(self.config, NOW)['spent_usd'])
        self.config['projects']['plugins']['api_key_ids'] = []
        future = datetime(2026, 12, 9, tzinfo=timezone.utc)
        self.assertIsNone(credits.snapshot(self.config, future)['spent_usd'])

    def test_old_data_and_old_sync_are_both_marked_stale(self):
        for changes in [{'updated_at': credits.iso(NOW-timedelta(hours=7))},
                        {'as_of': credits.iso(NOW-timedelta(hours=25))}]:
            self.report({'trader': '20'}, **changes)
            value = credits.snapshot(self.config, NOW)
            self.assertEqual(value['status'], 'stale')
            self.assertEqual(value['short'], 'API $180.00 left')
            self.assertEqual(credits.bar(value)['class'], ['warning'])

    def test_over_budget_is_visible_and_meter_clamped(self):
        self.report({'trader': '201.25'})
        value = credits.snapshot(self.config, NOW)
        self.assertEqual(Decimal(value['remaining_usd']), 0)
        self.assertEqual(value['remaining_percent'], 0)
        self.assertEqual(value['meter'], '▱'*10)
        self.assertEqual(credits.bar(value)['class'], ['critical'])
        self.assertIn('$201.25', value['headline'])

    def test_nonfinite_negative_costs_and_conflicting_project_ids_are_rejected(self):
        for value in ['NaN', 'Infinity', '-1', 'oops']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                credits.amount(value)
        self.config['projects']['trader']['api_key_ids'] = ['same']
        self.config['projects']['plugins']['api_key_ids'] = ['same']
        with self.assertRaises(ValueError):
            credits.validate(self.config)
        self.config['projects']['plugins']['api_key_ids'] = ['different']
        self.config['projects']['plugins']['workspace_ids'] = ['plugins']
        with self.assertRaises(ValueError):
            credits.project_for(self.config, {'api_key_id': 'same', 'workspace_id': 'plugins'})

    def test_credential_file_permissions_checked_before_any_request(self):
        key = self.root/'reporting.key'
        key.write_text('fixture-only')
        key.chmod(0o644)
        self.config['key_file'] = str(key)
        with patch.object(credits, 'collect') as collect:
            with self.assertRaises(ValueError):
                credits.sync(self.config, NOW)
            collect.assert_not_called()
        with self.assertRaises(ValueError):
            credits.NoRedirect().redirect_request(None, None, None, None, None, None)

    def test_offline_status_and_bar_never_contact_network(self):
        with patch.object(credits, 'request_report', side_effect=AssertionError('network called')):
            self.report({'trader': '0', 'plugins': '0', 'other': '0'})
            value = credits.snapshot(self.config, NOW)
            self.assertEqual(value['short'], 'API $200.00 left')
            self.assertNotIn('fixture', json.dumps(credits.bar(value)))


if __name__ == '__main__':
    unittest.main()
