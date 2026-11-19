"""Fixture and starter-workflow checks, without network or Snowflake."""
import ast
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'python'))

from load_starter import (
    ingest_starter_pdf, ingest_starter_ground_truth,
    load_starter, read_fixture, reference_rows,
)


class StarterTests(unittest.TestCase):
    def test_fixture_integrity_and_entity(self):
        manifest, pdf, doc = read_fixture()
        self.assertTrue(pdf.startswith(b"%PDF-"))
        self.assertEqual(doc["entityName"], "Apple Inc.")
        self.assertEqual(manifest["page_ranges"], [{"start": 30, "end": 36}])

    def test_three_reference_values_and_exact_periods(self):
        manifest, _, doc = read_fixture()
        rows = reference_rows(manifest, doc)
        concepts = {
            "assets": "Assets",
            "revenue": "RevenueFromContractWithCustomerExcludingAssessedTax",
            "eps_diluted": "EarningsPerShareDiluted",
        }
        for metric, concept in concepts.items():
            matching = [r for r in rows if r[2] == concept]
            self.assertEqual({r[7] for r in matching}, {manifest["expected_values"][metric]})
        for row in rows:
            self.assertEqual(row[8], manifest["sec_accession"])
            self.assertEqual(row[6], manifest["period_end"])
            self.assertEqual(row[9], "10-K")
            if row[2] not in {"Assets", "Liabilities", "StockholdersEquity"}:
                self.assertEqual(row[5], manifest["period_start"])

    def test_all_ten_concepts_available(self):
        manifest, _, doc = read_fixture()
        rows = reference_rows(manifest, doc)
        self.assertEqual(len({r[2] for r in rows}), 10)

    def test_loader_uploads_and_approves_reviewed_manifest(self):
        session = MagicMock()
        result = load_starter(session)
        self.assertTrue(result["approved"])
        self.assertGreaterEqual(result["sec_rows"], 10)
        session.file.put_stream.assert_called_once()
        self.assertEqual(session.file.put_stream.call_args.args[1],
                         "@annual_report_pdfs/AAPL/2023.pdf")
        statements = [call.args[0] for call in session.sql.call_args_list]
        self.assertTrue(any('MERGE INTO sec_facts' in sql for sql in statements))
        self.assertFalse(any('DELETE FROM' in sql for sql in statements))
        self.assertFalse(any('INSERT INTO sec_facts' in sql for sql in statements))
        merge = session.sql.call_args
        self.assertIn("MERGE INTO report_manifest", merge.args[0])
        self.assertIn("0000320193-23-000106", merge.kwargs["params"])
        session.close.assert_not_called()

    def test_pdf_ingestion_does_not_load_sec_facts(self):
        session = MagicMock()
        ingest_starter_pdf(session)
        session.file.put_stream.assert_called_once()
        session.sql.assert_called_once_with("ALTER STAGE annual_report_pdfs REFRESH")

    def test_sec_ingestion_does_not_upload_pdf(self):
        session = MagicMock()
        result = ingest_starter_ground_truth(session)
        self.assertTrue(result["approved"])
        session.file.put_stream.assert_not_called()
        statements = [call.args[0] for call in session.sql.call_args_list]
        self.assertTrue(any("MERGE INTO sec_facts" in sql for sql in statements))
        self.assertTrue(any("MERGE INTO report_manifest" in sql for sql in statements))

    def test_integrity_failure_does_not_write(self):
        session = MagicMock()
        with patch("load_starter.read_fixture", side_effect=ValueError("hash mismatch")):
            with self.assertRaises(ValueError):
                load_starter(session)
        session.sql.assert_not_called()
        session.file.put_stream.assert_not_called()

    def test_starter_scope_and_evaluation_match(self):
        extraction = (ROOT / "sql" / "08.extract_reports.sql").read_text()
        self.assertIn("SET include_all_metrics = FALSE;", extraction)
        self.assertIn("c.metric_id IN ('assets', 'revenue', 'eps_diluted')", extraction)
        evaluation = (ROOT / "sql" / "09.evaluate_results.sql").read_text()
        self.assertEqual(evaluation.count(
            "WHERE GET(r.response_format, c.metric_id || '__raw_value') IS NOT NULL"
        ), 2)

    def test_pipeline_steps_process_the_whole_scope(self):
        # Steps 04-09 must read the scope (lab_settings) or the readiness view built
        # from it, never a hard-coded report, so no ingested year is silently skipped.
        import re
        for name in ("04.prepare_manifest.sql", "05.locate_statement_pages.sql",
                     "06.check_readiness.sql", "07.first_extraction.sql",
                     "08.extract_reports.sql", "09.evaluate_results.sql"):
            with self.subTest(file=name):
                sql = (ROOT / "sql" / name).read_text()
                self.assertRegex(sql, r"lab_settings|report_readiness|batch_id")
                code = "\n".join(line.split("--")[0] for line in sql.splitlines())
                self.assertIsNone(re.search(r"'[A-Z]+/[0-9]{4}\.pdf'", code), name)
                self.assertNotIn("report_path", code)
        coverage = (ROOT / "sql" / "06.check_readiness.sql").read_text()
        self.assertIn("CREATE OR REPLACE VIEW pipeline_coverage", coverage)
        self.assertIn("FROM scope_years y", coverage)

    def test_new_scripts_compile(self):
        for name in ("load_starter.py", "build_starter_fixture.py"):
            ast.parse((ROOT / "python" / name).read_text(), filename=name)

    def test_local_document_links_exist(self):
        import re
        for name in ("README.md", "docs/INSTRUCTOR_SETUP.md", "docs/LOCAL_SETUP.md", "fixtures/README.md"):
            path = ROOT / name
            for link in re.findall(r"\]\(([^)]+)\)", path.read_text()):
                if "://" not in link:
                    self.assertTrue((path.parent / link).exists(), (name, link))


if __name__ == "__main__":
    unittest.main()
