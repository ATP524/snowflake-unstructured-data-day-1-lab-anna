"""Offline checks; never call remote APIs or Snowflake."""
import ast
import importlib
import importlib.util
import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'python'))

# Step-numbered filenames cannot be imported by name; load them by path instead.
SCRIPT_FILES = {
    'ingest_annual_report_pdfs': '02.ingest_annual_report_pdfs.py',
    'ingest_sec_ground_truth': '03.ingest_sec_ground_truth.py',
}


def load_module(name):
    fake_requests = types.ModuleType('requests')
    fake_requests.RequestException = type('RequestException', (Exception,), {})
    fake_requests.get = MagicMock()
    with patch.dict(sys.modules, {'requests': fake_requests}):
        spec = importlib.util.spec_from_file_location(
            name, ROOT / 'python' / SCRIPT_FILES[name])
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    # patch.dict restores sys.modules, including removing newly imported modules.
    sys.modules[name] = module
    return module


def snowpark_stubs():
    modules = {name: types.ModuleType(name) for name in (
        'snowflake', 'snowflake.snowpark', 'snowflake.snowpark.types'
    )}
    for name in ('DoubleType', 'LongType', 'StringType', 'StructField', 'StructType'):
        setattr(modules['snowflake.snowpark.types'], name, MagicMock())
    modules['snowflake.snowpark'].Session = MagicMock()
    return modules


class IngestionTests(unittest.TestCase):
    def test_python_compiles(self):
        for filename in SCRIPT_FILES.values():
            with self.subTest(filename=filename):
                ast.parse((ROOT / 'python' / filename).read_text(), filename=filename)

    def test_validation(self):
        module = load_module('ingest_sec_ground_truth')
        self.assertEqual(module.validate(' aapl ', 2023, 2023), 'AAPL')
        for args in (('AAPL/evil', 2023, 2023), ('AAPL', 2024, 2023),
                     ('AAPL', 2009, 2026)):
            with self.subTest(args=args), self.assertRaises(ValueError):
                module.validate(*args)

    def test_missing_pdf_returns_summary_without_refresh(self):
        module = load_module('ingest_annual_report_pdfs')
        session = MagicMock()
        with patch.object(module, 'fetch', return_value=None), \
             patch.object(module, 'log'), patch.object(module.time, 'sleep'):
            result = module.ingest_annual_report_pdfs(session, 'AAPL', 2023, 2023)
        self.assertEqual(result['pdf_years_missing'], [2023])
        self.assertEqual(result['pdf_years_downloaded'], [])
        session.sql.assert_not_called()

    def test_successful_pdf_is_uploaded_and_stage_refreshed(self):
        module = load_module('ingest_annual_report_pdfs')
        session = MagicMock()
        with patch.object(module, 'fetch', return_value=b'%PDF-1.7 test'), \
             patch.object(module, 'log'), patch.object(module.time, 'sleep'):
            result = module.ingest_annual_report_pdfs(session, 'AAPL', 2023, 2023)
        self.assertEqual(result['pdf_years_downloaded'], [2023])
        session.file.put_stream.assert_called_once()
        self.assertEqual(session.file.put_stream.call_args.args[1],
                         '@annual_report_pdfs/AAPL/2023.pdf')
        session.sql.assert_called_once_with('ALTER STAGE annual_report_pdfs REFRESH')

    def test_sec_retains_filing_provenance_and_filters_forms(self):
        module = load_module('ingest_sec_ground_truth')
        fact = {'form': '10-K', 'fy': 2023, 'fp': 'FY', 'val': 100,
                'end': '2023-09-30', 'filed': '2023-11-01', 'accn': 'original'}
        later = dict(fact, fy=2024, accn='later-comparative')
        quarterly = dict(fact, form='10-Q')
        doc = {'facts': {'us-gaap': {'Assets': {
            'label': 'Assets', 'units': {'USD': [fact, later, quarterly]}
        }}}}
        responses = [
            json.dumps({'0': {'ticker': 'AAPL', 'cik_str': 320193}}).encode(),
            json.dumps(doc).encode(),
        ]
        session = MagicMock()
        with patch.object(module, 'fetch', side_effect=responses), \
             patch.object(module, 'log'), patch.object(module.time, 'sleep'), \
             patch.dict(sys.modules, snowpark_stubs()):
            result = module.ingest_sec_facts(session, 'AAPL', 2023, 2023)
        self.assertEqual(result['xbrl_fact_rows'], 2)
        merge = session.sql.call_args
        self.assertIn('MERGE INTO sec_facts', merge.args[0])
        self.assertNotIn('DELETE', merge.args[0])
        rows = json.loads(merge.kwargs['params'][0])
        self.assertEqual({r[8] for r in rows}, {'original', 'later-comparative'})
        self.assertTrue(all(r[1] == '0000320193' for r in rows))

    @staticmethod
    def settings_session(rows):
        """A fake Snowpark session whose lab_settings query returns `rows`."""
        session = MagicMock()
        session.sql.return_value.collect.return_value = rows
        return session

    def test_main_ingests_the_scope_from_lab_settings(self):
        for name, function in (
            ('ingest_sec_ground_truth', 'ingest_sec_facts'),
            ('ingest_annual_report_pdfs', 'ingest_annual_report_pdfs'),
        ):
            with self.subTest(module=name):
                module = load_module(name)
                session = self.settings_session(
                    [{'TICKER': 'MSFT', 'FIRST_YEAR': 2022, 'LAST_YEAR': 2024}])
                with patch.object(module, function, return_value={'ok': True}) as job:
                    self.assertEqual(module.main(session), {'ok': True})
                    job.assert_called_once_with(session, 'MSFT', 2022, 2024)
                self.assertIn('FROM lab_settings', session.sql.call_args.args[0])
                session.close.assert_not_called()
                session.use_database.assert_not_called()
                session.use_schema.assert_not_called()

    def test_main_refuses_a_missing_or_incomplete_scope(self):
        for rows in ([], [{'TICKER': 'AAPL', 'FIRST_YEAR': 2023, 'LAST_YEAR': 2023}] * 2,
                     [{'TICKER': '', 'FIRST_YEAR': 2023, 'LAST_YEAR': 2023}],
                     [{'TICKER': 'AAPL', 'FIRST_YEAR': None, 'LAST_YEAR': 2023}]):
            for name, function in (
                ('ingest_sec_ground_truth', 'ingest_sec_facts'),
                ('ingest_annual_report_pdfs', 'ingest_annual_report_pdfs'),
            ):
                with self.subTest(module=name, rows=rows):
                    module = load_module(name)
                    with patch.object(module, function) as job, \
                         self.assertRaisesRegex(ValueError, 'lab_settings'):
                        module.main(self.settings_session(rows))
                    job.assert_not_called()

    def test_snowflake_only_entry_points_have_no_hard_coded_scope(self):
        for name in SCRIPT_FILES:
            with self.subTest(module=name):
                source = (ROOT / 'python' / SCRIPT_FILES[name]).read_text()
                for removed in ('argparse', 'run_cli', 'Session.builder', 'session.close(',
                                'TICKER =', 'FIRST_YEAR =', 'LAST_YEAR ='):
                    self.assertNotIn(removed, source)
                self.assertIn('read_ingest_settings(session)', source)
                self.assertIn('session = get_active_session()', source)
                self.assertIn('main(session)', source)

    def test_standalone_download_helpers(self):
        for name in ('ingest_sec_ground_truth', 'ingest_annual_report_pdfs'):
            with self.subTest(module=name):
                module = load_module(name)
                with self.assertRaises(ValueError):
                    module.fetch('https://example.com/report.pdf', {'www.sec.gov'})
                module.requests.get.assert_not_called()
                response = module.requests.get.return_value.__enter__.return_value
                response.status_code = 200
                response.iter_content.return_value = [b'data', b'', b'more']
                self.assertEqual(module.fetch('https://www.sec.gov/test', {'www.sec.gov'}),
                                 b'datamore')
                self.assertFalse(module.requests.get.call_args.kwargs['allow_redirects'])
                response.status_code = 302
                with self.assertRaisesRegex(ValueError, 'Redirect'):
                    module.fetch('https://www.sec.gov/test', {'www.sec.gov'})
                response.status_code = 429
                with patch.object(module.time, 'sleep') as sleep:
                    with self.assertRaises(RuntimeError):
                        module.fetch('https://www.sec.gov/test', {'www.sec.gov'})
                    self.assertEqual(sleep.call_count, 2)

    def test_pdf_size_cap(self):
        module = load_module('ingest_annual_report_pdfs')
        response = module.requests.get.return_value.__enter__.return_value
        response.status_code = 200
        response.iter_content.return_value = [b'12345']
        with patch.object(module, 'MAX_PDF_BYTES', 4):
            with self.assertRaisesRegex(ValueError, 'safety cap'):
                module.fetch('https://www.annualreports.com/test.pdf',
                             {'www.annualreports.com'})


if __name__ == '__main__':
    unittest.main()
