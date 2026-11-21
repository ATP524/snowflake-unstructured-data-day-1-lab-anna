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
        from sql_runner import notebook_sql_text
        extraction = notebook_sql_text(ROOT / "sql" / "08.extract_reports.ipynb")
        # The metric set is part of the scope (00 -> lab_settings), read through scope_metrics.
        self.assertNotIn("SET include_all_metrics", extraction)
        self.assertIn("CROSS JOIN scope_metrics c", extraction)
        self.assertIn("(SELECT include_all_metrics FROM lab_settings)", extraction)
        ddl = (ROOT / "sql" / "01.ddls.sql").read_text()
        self.assertIn("UPDATE metric_catalog SET is_starter = metric_id IN ('assets', 'revenue', 'eps_diluted')", ddl)
        evaluation = (ROOT / "sql" / "09.evaluate_results.sql").read_text()
        self.assertEqual(evaluation.count(
            "WHERE GET(r.response_format, c.metric_id || '__raw_value') IS NOT NULL"
        ), 2)

    def test_metric_set_is_chosen_once_and_read_through_one_view(self):
        from sql_runner import notebook_sql_text
        readiness = (ROOT / "sql" / "06.check_readiness.sql").read_text()
        self.assertIn("CREATE OR REPLACE VIEW scope_metrics", readiness)
        self.assertIn("WHERE ls.include_all_metrics OR c.is_starter", readiness)
        self.assertNotIn("remove it for all ten", readiness)
        ready_view = readiness.split("CREATE OR REPLACE VIEW report_readiness")[1].split(";", 1)[0]
        self.assertIn("CROSS JOIN scope_metrics c", ready_view)
        evaluation = (ROOT / "sql" / "09.evaluate_results.sql").read_text()
        self.assertIn("LEFT JOIN scope_metrics s ON s.metric_id = c.metric_id",
                      evaluation.split("CREATE OR REPLACE VIEW report_status")[1])
        # The starter list is data in 01 only: no step names the metrics in its SQL.
        sources = {
            "06": readiness, "09": evaluation,
            "08": notebook_sql_text(ROOT / "sql" / "08.extract_reports.ipynb"),
            "10": (ROOT / "sql" / "10.validation.sql").read_text(),
        }
        for step, sql in sources.items():
            self.assertNotIn("'assets', 'revenue', 'eps_diluted'", sql, step)
        settings = json.loads((ROOT / "python" / "00.set_session_variables.ipynb").read_text())
        scope_cell = next("".join(c["source"]) for c in settings["cells"]
                          if "MERGE INTO bootcamp.atp524.lab_settings" in "".join(c["source"]))
        self.assertIn("FALSE AS include_all_metrics", scope_cell)
        self.assertIn("include_all_metrics = s.include_all_metrics", scope_cell)

    def test_pipeline_steps_process_the_whole_scope(self):
        # Steps 04-09 must read the scope (lab_settings) or the readiness view built
        # from it, never a hard-coded report, so no ingested year is silently skipped.
        import re
        from sql_runner import notebook_sql_text
        for name in ("04.prepare_manifest.sql", "05.locate_statement_pages.sql",
                     "06.check_readiness.sql", "07.first_extraction.sql",
                     "08.extract_reports.ipynb", "09.evaluate_results.sql"):
            with self.subTest(file=name):
                path = ROOT / "sql" / name
                sql = notebook_sql_text(path) if path.suffix == ".ipynb" else path.read_text()
                self.assertRegex(sql, r"lab_settings|report_readiness|batch_id")
                code = "\n".join(line.split("--")[0] for line in sql.splitlines())
                self.assertIsNone(re.search(r"'[A-Z]+/[0-9]{4}\.pdf'", code), name)
                self.assertNotIn("report_path", code)
        coverage = (ROOT / "sql" / "06.check_readiness.sql").read_text()
        self.assertIn("CREATE OR REPLACE VIEW pipeline_coverage", coverage)
        self.assertIn("FROM scope_years y", coverage)

    def test_step_05_reads_headings_from_config_and_guards_every_scan(self):
        # 05 must stay company-neutral: heading wording lives in statement_heading_patterns
        # (01), stored pages are never read or parsed twice, and each locator outcome is
        # documented in 01 and tested in 10.
        from sql_runner import split_sql
        sql = (ROOT / "sql" / "05.locate_statement_pages.sql").read_text()
        statements = split_sql(sql)
        inserts = [s for s in statements if s.lstrip().upper().startswith("INSERT")]
        self.assertEqual(len(inserts), 2)
        for statement, scan_type in zip(inserts, ("'TEXT'", "'WINDOW'")):
            with self.subTest(scan_type=scan_type):
                self.assertIn("NOT EXISTS", statement)
                self.assertIn("p.scan_type = %s" % scan_type, statement)
        self.assertIn("pdf_page_text", inserts[0])
        self.assertNotIn("AI_PARSE_DOCUMENT", inserts[0])
        code = "\n".join(line.split("--")[0] for line in sql.splitlines())
        self.assertIn("JOIN statement_heading_patterns", code)
        # every heading match uses the config table, never a hard-coded wording
        self.assertNotRegex(code, r"(?i)ILIKE\s+'%")
        self.assertIn("max_statement_pages", code)
        ddl = (ROOT / "sql" / "01.ddls.sql").read_text()
        validation = (ROOT / "sql" / "10.validation.sql").read_text()
        for method in ("TEXT+INDEX", "TEXT", "AI_FALLBACK", "MANUAL_REVIEW", "NOT_FOUND"):
            with self.subTest(method=method):
                self.assertIn("'%s'" % method, code)
                self.assertIn(method, ddl)
                self.assertIn("'%s'" % method, validation)
        self.assertIn("CREATE OR REPLACE FUNCTION pdf_page_text", ddl)
        # one tested decision function; check_only (approved) reports are never AI-parsed
        # and step 6 changes only their locator_method
        self.assertIn("CREATE OR REPLACE FUNCTION locator_decision", ddl)
        self.assertIn("locator_decision(", code)
        self.assertIn("NOT w.check_only", inserts[1])
        updates = [s for s in statements if s.lstrip().upper().startswith("UPDATE")]
        self.assertEqual(len(updates), 2)
        backfill = updates[1]
        self.assertRegex(backfill, r"SET locator_method = p\.locator_method\s+FROM")
        self.assertIn("EQUAL_NULL(p.proposed_page_ranges, t.page_ranges)", backfill)
        self.assertIn("locator_decision(has_text, item8_page, index_pdf_page)", validation)
        import re
        section = validation.split("-- 5. Page-locator outcomes")[1]
        for method in ("TEXT+INDEX", "TEXT", "AI_FALLBACK", "MANUAL_REVIEW", "NOT_FOUND"):
            with self.subTest(expected_outcome=method):
                # each outcome is the expected value of at least one test case row
                self.assertRegex(section, r",\s*'%s'\)" % re.escape(method))

    def test_step_08_is_notebook_only_and_every_insert_is_guarded(self):
        from sql_runner import notebook_sql_text, split_sql
        self.assertFalse((ROOT / "sql" / "08.extract_reports.sql").exists())
        inserts = [s for s in split_sql(notebook_sql_text(ROOT / "sql" / "08.extract_reports.ipynb"))
                   if s.lstrip().upper().startswith("INSERT")]
        self.assertEqual(len(inserts), 4)
        for statement in inserts:
            with self.subTest(insert=statement.split("(")[0]):
                self.assertIn("NOT EXISTS", statement)
                self.assertIn("$batch_id", statement)

    def test_every_table_documents_layer_grain_and_key(self):
        import re
        ddl = (ROOT / "sql" / "01.ddls.sql").read_text()
        tables = re.findall(r"CREATE TABLE IF NOT EXISTS (\w+)", ddl)
        self.assertGreaterEqual(len(tables), 11)
        for table in tables:
            with self.subTest(table=table):
                comment = re.search(r"COMMENT ON TABLE %s IS '([^']*)'" % table, ddl)
                self.assertIsNotNone(comment, table)
                self.assertRegex(comment.group(1), r"^(CONFIG|RAW|CURATED)\. Grain: ")
        validation = (ROOT / "sql" / "10.validation.sql").read_text()
        for check in ("'unique'", "'not_null'", "'relationships'", "'accepted_values'"):
            self.assertIn(check, validation)
        for table in tables:
            if table != "ingest_log":  # event log: documented as having no natural key
                self.assertIn("'%s" % table, validation, table)

    def test_sql_splitter_keeps_scripting_blocks_and_drops_comments(self):
        from sql_runner import _split_sql_fallback, split_sql
        text = ("-- header only\nSELECT 1;\nEXECUTE IMMEDIATE $$ BEGIN RETURN 'a;b'; END; $$;\n"
                "SELECT 'it''s; fine';\n-- trailing note\n")
        for splitter in (split_sql, lambda s: [p.strip() for p in _split_sql_fallback(s)
                                               if p.strip().rstrip(";").strip()]):
            statements = splitter(text)
            self.assertEqual(len(statements), 3, statements)
            self.assertIn("$$ BEGIN RETURN 'a;b'; END; $$", statements[1])

    def test_step_08_defaults_to_only_new_reports_and_records_provenance(self):
        from sql_runner import notebook_sql_text
        sql = notebook_sql_text(ROOT / "sql" / "08.extract_reports.ipynb")
        self.assertIn("SET only_new_reports = TRUE;", sql)
        self.assertNotIn("$include_all_metrics", sql)
        for column in ("prompt_version", "include_all_metrics", "metric_count", "metric_ids"):
            self.assertIn(column, sql)
        self.assertIn("NOT ($only_new_reports AND EXISTS", sql)

    def test_runner_tags_each_step_and_restores_the_previous_tag(self):
        from unittest.mock import MagicMock
        from sql_runner import run_sql_text
        session = MagicMock()
        previous = MagicMock()
        previous.as_dict.return_value = {"value": "my_tag"}
        session.sql.return_value.collect.side_effect = [[previous], [], [], []]
        run_sql_text(session, "SELECT 1;", label="x", show=False, query_tag="lab:x.sql")
        calls = [c.args[0] for c in session.sql.call_args_list]
        self.assertEqual(calls[1], "ALTER SESSION SET QUERY_TAG = 'lab:x.sql'")
        self.assertEqual(calls[2].rstrip(";"), "SELECT 1")
        self.assertEqual(calls[3], "ALTER SESSION SET QUERY_TAG = 'my_tag'")

    def test_runner_notebook_holds_no_pipeline_sql(self):
        # One source per step: the runner calls step files, it never contains their SQL.
        nb = json.loads((ROOT / "python" / "00.run_pipeline.ipynb").read_text())
        for cell in nb["cells"]:
            source = "".join(cell.get("source", []))
            if cell.get("cell_type") != "code":
                continue
            for keyword in ("INSERT INTO", "MERGE INTO", "CREATE ", "UPDATE ", "DELETE FROM", "AI_EXTRACT(", "AI_PARSE_DOCUMENT("):
                self.assertNotIn(keyword, source.upper() if keyword.isupper() else source, keyword)

    def test_ddl_objects_lists_every_table_and_function_in_01(self):
        from sql_runner import ddl_objects
        found = ddl_objects((ROOT / "sql" / "01.ddls.sql").read_text())
        for table in ("LAB_SETTINGS", "METRIC_SEC_CONCEPTS", "DDL_APPLIED", "REPORT_MANIFEST", "LAB_RUNS"):
            self.assertIn(table, found["TABLE"])
        self.assertEqual(found["FUNCTION"], {"PDF_PAGE_TEXT", "LOCATOR_DECISION"})

    def _ddl_session(self, applied_sha, tables, functions):
        from datetime import datetime
        session = MagicMock()
        def sql(text, params=None):
            q = MagicMock()
            if "FROM ddl_applied" in text:
                q.collect.return_value = [] if applied_sha is None else [(applied_sha, datetime(2026, 11, 21))]
            elif "information_schema.tables" in text:
                q.collect.return_value = [(t,) for t in tables]
            elif "information_schema.functions" in text:
                q.collect.return_value = [(f,) for f in functions]
            return q
        session.sql.side_effect = sql
        return session

    def test_runner_skips_01_only_when_unchanged_and_complete(self):
        from sql_runner import ddl_objects, ddl_status, file_sha256
        path = ROOT / "sql" / "01.ddls.sql"
        objs = ddl_objects(path.read_text())
        sha = file_sha256(path)
        ok, why = ddl_status(self._ddl_session(sha, objs["TABLE"], objs["FUNCTION"]), path)
        self.assertTrue(ok, why)
        ok, why = ddl_status(self._ddl_session(None, objs["TABLE"], objs["FUNCTION"]), path)
        self.assertFalse(ok)
        ok, why = ddl_status(self._ddl_session("an-older-hash", objs["TABLE"], objs["FUNCTION"]), path)
        self.assertFalse(ok); self.assertIn("changed", why)
        ok, why = ddl_status(self._ddl_session(sha, objs["TABLE"] - {"METRIC_SEC_CONCEPTS"}, objs["FUNCTION"]), path)
        self.assertFalse(ok); self.assertIn("table METRIC_SEC_CONCEPTS", why)
        ok, why = ddl_status(self._ddl_session(sha, objs["TABLE"], set()), path)
        self.assertFalse(ok); self.assertIn("function LOCATOR_DECISION", why)
        broken = MagicMock(); broken.sql.side_effect = Exception("does not exist")
        self.assertFalse(ddl_status(broken, path)[0])

    def test_runner_01_cell_logs_skip_and_records_success(self):
        nb = json.loads((ROOT / "python" / "00.run_pipeline.ipynb").read_text())
        cell = next("".join(c["source"]) for c in nb["cells"]
                    if c.get("cell_type") == "code" and "01.ddls.sql" in "".join(c["source"]))
        self.assertIn("ddl_status(session, DDL_FILE)", cell)
        self.assertIn("SKIPPED (schema up to date)", cell)
        self.assertIn("STEP_LOG.append", cell)
        self.assertLess(cell.index('run_step("01 ddls"'), cell.index("record_ddl_applied(session, DDL_FILE)"))

    def test_sec_value_is_chosen_in_one_place_with_recorded_fallbacks(self):
        ddl = (ROOT / "sql" / "01.ddls.sql").read_text()
        self.assertIn("CREATE TABLE IF NOT EXISTS metric_sec_concepts", ddl)
        self.assertIn("SELECT 'revenue', 'Revenues', 2,", ddl)
        readiness = (ROOT / "sql" / "06.check_readiness.sql").read_text()
        evaluate = (ROOT / "sql" / "09.evaluate_results.sql").read_text()
        self.assertIn("CREATE OR REPLACE VIEW metric_ground_truth", readiness)
        for sql in (readiness.split("CREATE OR REPLACE VIEW metric_ground_truth")[1].split(";", 1)[1], evaluate):
            # outside the one view, no step matches sec_facts to a metric concept itself
            self.assertNotIn("s.concept = c.sec_concept", sql.split("CREATE OR REPLACE VIEW heading_pattern_usage")[0])
        self.assertIn("LEFT JOIN metric_ground_truth g", evaluate)
        validation = (ROOT / "sql" / "10.validation.sql").read_text()
        self.assertIn("a fallback concept is used only when the own 10-K has no primary value", validation)

    def test_report_status_covers_every_year_and_is_built_after_evaluation(self):
        evaluate = (ROOT / "sql" / "09.evaluate_results.sql").read_text()
        self.assertLess(evaluate.index("CREATE OR REPLACE VIEW metric_evaluation"),
                        evaluate.index("CREATE OR REPLACE VIEW report_status"))
        status = evaluate.split("CREATE OR REPLACE VIEW report_status")[1]
        for source in ("FROM report_manifest", "FROM ingest_log", "DIRECTORY(@annual_report_pdfs)", "FROM lab_settings"):
            self.assertIn(source, status.split("last_pdf_attempt AS")[0])
        self.assertIn("'02 PDF not found'", status)
        nb = json.loads((ROOT / "workspace_export.ipynb").read_text())
        export = "".join("".join(c["source"]) for c in nb["cells"] if c.get("cell_type") == "code")
        self.assertIn('session.sql("SELECT * FROM report_status ORDER BY ticker, report_year")', export)

    def test_method_comparison_covers_latest_runs_and_is_exported(self):
        evaluate = (ROOT / "sql" / "09.evaluate_results.sql").read_text()
        self.assertLess(evaluate.index("CREATE OR REPLACE VIEW metric_evaluation"),
                        evaluate.index("CREATE OR REPLACE VIEW method_comparison"))
        view = evaluate.split("CREATE OR REPLACE VIEW method_comparison")[1].split(";", 1)[0]
        self.assertIn("PARTITION BY relative_path ORDER BY created_at DESC", view)
        for column in ("pass_rate", "avg_value_score", "low_confidence_answers", "parsed_characters"):
            self.assertIn(column, view)
        validation = (ROOT / "sql" / "10.validation.sql").read_text()
        self.assertIn("'unique', 'method_comparison', 'ticker, report_year, method'", validation)
        nb = json.loads((ROOT / "workspace_export.ipynb").read_text())
        export = "".join("".join(c["source"]) for c in nb["cells"] if c.get("cell_type") == "code")
        self.assertIn('"method_comparison"', export)
        self.assertIn("Method comparison (latest runs)", export)

    def test_synthetic_step_12_runs_end_to_end(self):
        # Three defects that stopped 12 before 2026-11-21; each failed only at run time.
        sql = (ROOT / "sql" / "12.evaluate_synthetic_simple.sql").read_text()
        self.assertIn("OBJECT_AGG(metric_id, question::VARIANT)", sql)        # OBJECT_AGG needs VARIANT
        self.assertIn("'DIRECT_PDF'::STRING AS method", sql)                 # column must fit PARSE_THEN_EXTRACT
        code = "\n".join(line.split("--")[0] for line in sql.splitlines())
        self.assertNotIn("'page_split', FALSE", code)                         # page_filter needs page_split TRUE
        self.assertIn("LATERAL FLATTEN(INPUT => p.parsed_result:value:pages, OUTER => TRUE)", sql)

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
