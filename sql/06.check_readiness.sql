USE ROLE all_users_role;
USE DATABASE bootcamp;
USE WAREHOUSE compute_wh;
USE SCHEMA atp524;

-- Step 06: confirm every report in scope is READY before spending AI credits in
-- 07.first_extraction and 08.extract_reports, and show exactly where any year stopped.
-- Scope = lab_settings (ticker + year range), set in python/00.set_session_variables.ipynb.
-- Run after 05.locate_statement_pages.sql. Reads tables only; no AI, no data changes.

-- READINESS per in-scope report. Uses the same conditions as the lab_runs insert
-- in 08, plus ground-truth coverage. Only READY reports produce a run.
-- The metric filter matches include_all_metrics = FALSE; remove it for all ten.
CREATE OR REPLACE VIEW report_readiness AS
SELECT m.relative_path, m.ticker, m.report_year,
       COALESCE(m.approved, FALSE)                      AS approved,
       COALESCE(m.period_start IS NOT NULL AND m.period_end IS NOT NULL
           AND m.period_start < m.period_end, FALSE)    AS period_ok,
       m.sec_accession IS NOT NULL                      AS accession_ok,
       COALESCE(ARRAY_SIZE(m.page_ranges), 0) > 0       AS pages_ok,
       COUNT(DISTINCT c.metric_id)                      AS metrics_expected,
       COUNT(DISTINCT IFF(s.fact_value IS NOT NULL, c.metric_id, NULL)) AS metrics_with_ground_truth,
       IFF(approved AND period_ok AND accession_ok AND pages_ok
           AND metrics_with_ground_truth = metrics_expected,
           'READY', 'NOT READY') AS status,
       m.review_notes
FROM report_manifest m
JOIN lab_settings ls
  ON m.ticker = ls.ticker AND m.report_year BETWEEN ls.first_year AND ls.last_year
CROSS JOIN metric_catalog c
LEFT JOIN sec_facts s
  ON s.ticker = m.ticker AND s.accession = m.sec_accession
 AND s.concept = c.sec_concept AND s.unit = c.expected_unit AND s.form = '10-K'
 AND s.end_date = m.period_end
 AND ((c.period_type = 'instant'  AND s.start_date IS NULL)
   OR (c.period_type = 'duration' AND s.start_date = m.period_start))
WHERE c.metric_id IN ('assets', 'revenue', 'eps_diluted')
GROUP BY m.relative_path, m.ticker, m.report_year, m.approved, m.period_start,
         m.period_end, m.sec_accession, m.page_ranges, m.review_notes;

SELECT * FROM report_readiness ORDER BY report_year;

-- COVERAGE: one row for EVERY year in the scope, built from the scope itself (not
-- from the manifest), so a year can never disappear because an earlier step failed.
-- Each column is one pipeline step; next_step names the first step still missing.
-- 09.evaluate_results.sql adds the evaluation result for each year.
CREATE OR REPLACE VIEW pipeline_coverage AS
WITH scope_years AS (
    SELECT ls.ticker, ls.first_year + g.n AS report_year,
           ls.ticker || '/' || (ls.first_year + g.n)::STRING || '.pdf' AS relative_path
    FROM lab_settings ls
    JOIN (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS n
          FROM TABLE(GENERATOR(ROWCOUNT => 50))) g
      ON g.n <= ls.last_year - ls.first_year
), staged AS (
    SELECT relative_path FROM DIRECTORY(@annual_report_pdfs)
), sec_years AS (
    -- Years whose OWN 10-K is loaded: a filing's own period is its latest ~1-year
    -- duration. Comparative prior-year rows inside later filings do not count.
    SELECT DISTINCT ticker, YEAR(MAX(end_date)) AS report_year
    FROM sec_facts
    WHERE form = '10-K' AND start_date IS NOT NULL
      AND DATEDIFF('day', start_date, end_date) BETWEEN 330 AND 380
    GROUP BY ticker, accession
), latest_run AS (
    SELECT relative_path, run_id, batch_id, created_at
    FROM lab_runs
    QUALIFY ROW_NUMBER() OVER (PARTITION BY relative_path ORDER BY created_at DESC) = 1
), extractions AS (
    SELECT run_id,
           COUNT_IF(method = 'DIRECT_PDF')         AS direct_pdf_rows,
           COUNT_IF(method = 'PARSE_THEN_EXTRACT') AS parse_then_extract_rows
    FROM extraction_results
    GROUP BY run_id
)
SELECT y.ticker, y.report_year, y.relative_path,
       st.relative_path IS NOT NULL                       AS pdf_on_stage,         -- step 02
       sy.report_year IS NOT NULL                         AS sec_facts_loaded,     -- step 03
       m.relative_path IS NOT NULL                        AS manifest_row,         -- step 04
       m.sec_accession IS NOT NULL                        AS period_proposed,      -- step 04
       COALESCE(ARRAY_SIZE(m.page_ranges), 0) > 0         AS pages_found,          -- step 05
       COALESCE(m.approved, FALSE)                        AS approved,             -- step 05
       COALESCE(r.status, 'NOT READY')                    AS readiness,            -- step 06
       lr.run_id                                          AS latest_run_id,        -- step 08
       lr.created_at                                      AS latest_run_at,
       COALESCE(e.direct_pdf_rows, 0) > 0                 AS direct_pdf_done,      -- step 08 path A
       COALESCE(e.parse_then_extract_rows, 0) > 0         AS parse_then_extract_done, -- step 08 path B
       CASE
           WHEN NOT pdf_on_stage      THEN '02 ingest PDF (no PDF found for this year)'
           WHEN NOT sec_facts_loaded  THEN '03 ingest SEC facts'
           WHEN NOT manifest_row      THEN '04 prepare manifest'
           WHEN NOT period_proposed   THEN '04 prepare manifest (no matching 10-K period)'
           WHEN NOT COALESCE(m.approved, FALSE) THEN '05 locate pages (see review_notes)'
           WHEN readiness <> 'READY'  THEN '06 check readiness (ground truth incomplete)'
           WHEN lr.run_id IS NULL     THEN '08 extract reports'
           WHEN NOT direct_pdf_done OR NOT parse_then_extract_done
                                      THEN '08 extract reports (a path did not finish)'
           ELSE 'COMPLETE through 08; evaluate in 09'
       END AS next_step,
       m.review_notes
FROM scope_years y
LEFT JOIN staged st          ON st.relative_path = y.relative_path
LEFT JOIN sec_years sy       ON sy.ticker = y.ticker AND sy.report_year = y.report_year
LEFT JOIN report_manifest m  ON m.relative_path = y.relative_path
LEFT JOIN report_readiness r ON r.relative_path = y.relative_path
LEFT JOIN latest_run lr      ON lr.relative_path = y.relative_path
LEFT JOIN extractions e      ON e.run_id = lr.run_id;

SELECT * FROM pipeline_coverage ORDER BY report_year;

-- Detail: the ground-truth value behind each metric of every approved in-scope report.
-- Review concept semantics as well as dates, especially NetIncomeLoss and
-- StockholdersEquity when the company has noncontrolling interests.
SELECT m.relative_path, c.metric_id, c.sec_concept, c.expected_unit,
       s.start_date, s.end_date, s.fact_value, s.accession, s.filed_date
FROM report_manifest m
JOIN lab_settings ls
  ON m.ticker = ls.ticker AND m.report_year BETWEEN ls.first_year AND ls.last_year
CROSS JOIN metric_catalog c
LEFT JOIN sec_facts s
  ON s.ticker = m.ticker AND s.accession = m.sec_accession
 AND s.concept = c.sec_concept AND s.unit = c.expected_unit AND s.form = '10-K'
 AND s.end_date = m.period_end
 AND ((c.period_type = 'instant' AND s.start_date IS NULL)
      OR (c.period_type = 'duration' AND s.start_date = m.period_start))
WHERE m.approved
ORDER BY m.relative_path, c.metric_id;
-- Next: 07.first_extraction.sql (optional exploration), then 08.extract_reports.ipynb.
