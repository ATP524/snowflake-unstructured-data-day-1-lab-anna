"""Synthetic report checks without Snowflake or inference calls."""
from copy import deepcopy
from decimal import Decimal
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import MagicMock

from pypdf import PdfReader

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

# The entry point has a step-numbered filename (11.generate_synthetic_batch.py),
# which `import` cannot load; register it under its module name instead.
import importlib.util
_spec = importlib.util.spec_from_file_location(
    "generate_synthetic_batch", ROOT / "python" / "11.generate_synthetic_batch.py")
_module = importlib.util.module_from_spec(_spec)
sys.modules["generate_synthetic_batch"] = _module
_spec.loader.exec_module(_module)

from synthetic_earnings import (
    build_batch_sources, derive, generate_batch_in_snowflake,
    generate_in_snowflake, number, prepare, render_report,
)


class SyntheticEarningsTests(unittest.TestCase):
    def setUp(self):
        self.source = json.loads((ROOT / "fixtures/synthetic_earnings_source.json").read_text())

    def test_known_answers_and_reconciliations(self):
        years = prepare(self.source)
        r = years[0]
        self.assertEqual(r["revenue"], 332000)
        self.assertEqual(r["net_income"], 83720)
        self.assertEqual(r["assets"], 320000)
        self.assertEqual(r["eps_diluted"], Decimal("5.83"))
        for year in years:
            self.assertEqual(year["assets"], year["liabilities"] + year["equity"])
            self.assertEqual(year["beginning_cash"] + year["cash_change"], year["cash"])

    def test_rejects_inconsistent_cash_and_missing_synthetic_marker(self):
        bad = deepcopy(self.source["years"][0])
        bad["cash"] += 1
        with self.assertRaisesRegex(ValueError, "reconcile"):
            derive(bad)
        self.source["synthetic"] = False
        with self.assertRaisesRegex(ValueError, "synthetic"):
            render_report(self.source)

    def test_pdf_pages_and_all_ten_expected_values(self):
        pdf, manifest = render_report(self.source)
        pages = PdfReader(io.BytesIO(pdf)).pages
        self.assertEqual(len(pages), 5)
        self.assertIn("SYNTHETIC", pages[0].extract_text())
        self.assertEqual(len(manifest["expected"]), 10)
        self.assertEqual(manifest["page_ranges"], [{"start": 1, "end": 5}])
        for key, expected in manifest["expected"].items():
            text = pages[expected["page_index"]].extract_text()
            self.assertIn(expected["label"], text)
            self.assertIn(number(Decimal(expected["raw_value"]), key.startswith("eps_")), text)
            self.assertIn(expected["end"], text)
            self.assertEqual(expected["value"], float(Decimal(expected["raw_value"]) * expected["scale"]))
        self.assertIn("2024-09-29", pages[4].extract_text())
        self.assertIn("53 weeks", pages[4].extract_text())

    def test_changes_in_source_reach_pdf_and_truth(self):
        self.source["years"][0]["current_liabilities"] += 100
        pdf, manifest = render_report(self.source)
        self.assertEqual(manifest["expected"]["liabilities"]["value"], 290100000000)
        self.assertIn("290,100", PdfReader(io.BytesIO(pdf)).pages[2].extract_text())

    def test_uploads_pdf_and_truth_without_touching_sec_tables(self):
        session = MagicMock()
        manifest = generate_in_snowflake(session, self.source)
        self.assertEqual(session.file.put_stream.call_count, 2)
        self.assertEqual(session.file.put_stream.call_args_list[0].args[1],
                         "@annual_report_pdfs/synthetic/SYN_ORCH/2025.pdf")
        for call in session.file.put_stream.call_args_list:
            self.assertFalse(call.kwargs["auto_compress"])
        statements = [call.args[0] for call in session.sql.call_args_list]
        self.assertFalse(any("sec_facts" in s for s in statements))
        self.assertTrue(manifest["synthetic"])


class SyntheticBatchTests(SyntheticEarningsTests):
    def test_five_distinct_reconciled_reports(self):
        original = deepcopy(self.source)
        sources = build_batch_sources(self.source)
        self.assertEqual(self.source, original)
        self.assertEqual(len(sources), 5)
        paths, revenues, eps_values = set(), set(), set()
        for source in sources:
            pdf, manifest = render_report(source)
            pages = PdfReader(io.BytesIO(pdf)).pages
            self.assertEqual(len(pages), 5)
            self.assertIn(source["company"], pages[0].extract_text())
            self.assertIn(source["ticker"], pages[1].extract_text())
            for metric, expected in manifest["expected"].items():
                text = pages[expected["page_index"]].extract_text()
                self.assertIn(number(Decimal(expected["raw_value"]), metric.startswith("eps_")), text)
            paths.add(manifest["relative_path"])
            revenues.add(manifest["expected"]["revenue"]["value"])
            eps_values.add(manifest["expected"]["eps_diluted"]["value"])
        self.assertEqual(len(paths), 5)
        self.assertEqual(len(revenues), 5)
        self.assertEqual(len(eps_values), 5)

    def test_batch_uploads_five_pdfs_and_publishes_manifest_last(self):
        session = MagicMock()
        batch = generate_batch_in_snowflake(session, self.source)
        self.assertEqual(batch["report_count"], 5)
        self.assertEqual(sum(len(m["expected"]) for m in batch["reports"]), 50)
        calls = session.file.put_stream.call_args_list
        self.assertEqual(len(calls), 11)
        self.assertEqual(sum(c.args[1].endswith(".pdf") for c in calls), 5)
        self.assertEqual(calls[-1].args[1],
                         "@annual_report_pdfs/synthetic/batch/manifest.json")
        self.assertEqual(json.loads(calls[-1].args[0].getvalue()), batch)
        self.assertEqual(len({m["relative_path"] for m in batch["reports"]}), 5)
        for call in calls:
            self.assertFalse(call.kwargs["auto_compress"])
        statements = [call.args[0] for call in session.sql.call_args_list]
        self.assertIn("ALTER STAGE annual_report_pdfs REFRESH", statements)
        table_call = session.sql.call_args_list[-1]
        self.assertIn("CREATE OR REPLACE TABLE synthetic_ground_truth", table_call.args[0])
        saved = json.loads(table_call.kwargs["params"][0])
        self.assertEqual(saved, batch)
        rows = [(r["relative_path"], metric, expected)
                for r in saved["reports"] for metric, expected in r["expected"].items()]
        self.assertEqual(len(rows), 50)
        self.assertEqual(len({(path, metric) for path, metric, _ in rows}), 50)
        self.assertTrue(all(expected["value"] ==
                            float(Decimal(expected["raw_value"]) * expected["scale"])
                            for _, _, expected in rows))

    def test_simple_sql_keeps_scoring_readable_and_answers_private(self):
        sql = (ROOT / "sql/12.evaluate_synthetic_simple.sql").read_text()
        self.assertNotIn("LATERAL FLATTEN", sql)
        self.assertNotIn("REGEXP", sql)
        self.assertEqual(sql.count("AI_EXTRACT("), 2)
        self.assertEqual(sql.count("AI_PARSE_DOCUMENT("), 1)
        self.assertIn("AND methods.method = answers.method", sql)
        self.assertIn("GROUP BY method", sql)
        self.assertIn("LENGTH(parsed.markdown) BETWEEN 1 AND 60000", sql)
        self.assertIn("responseFormat => questions.questions", sql)
        self.assertIn("LEFT JOIN student_answers AS answers", sql)
        self.assertIn("ON truth.relative_path = answers.relative_path", sql)
        self.assertIn("WHEN extracted_value IS NULL THEN 'MISSING'", sql)
        questions = sql.split("CREATE OR REPLACE TEMP TABLE student_question_list AS")[1]
        questions = questions.split("GROUP BY relative_path;")[0]
        self.assertNotIn("expected_value", questions)
        self.assertIn("SUM(CASE WHEN status = 'PASS' THEN 1 ELSE 0 END)", sql)

    def test_restored_batch_entry_point(self):
        from generate_synthetic_batch import main
        from unittest.mock import patch
        saved_sources = json.loads((ROOT / "fixtures/synthetic_batch/sources.json").read_text())
        self.assertEqual(self.source, saved_sources[0])
        session = MagicMock()
        expected = {"reports": [{"relative_path": "example.pdf"}]}
        with patch("generate_synthetic_batch.generate_batch_in_snowflake",
                   return_value=expected) as generate, patch("builtins.print"):
            self.assertEqual(main(session), expected)
        generate.assert_called_once_with(session, self.source)

    def test_sql_scores_by_report_not_cross_product(self):
        sql = (ROOT / "sql/13.evaluate_synthetic.sql").read_text()
        self.assertIn("payload:reports", sql)
        self.assertIn("ON e.relative_path = r.manifest:relative_path::STRING", sql)
        self.assertNotIn("CROSS JOIN synthetic_extraction", sql)
        self.assertIn("GROUP BY relative_path ORDER BY relative_path", sql)


if __name__ == "__main__":
    unittest.main()
