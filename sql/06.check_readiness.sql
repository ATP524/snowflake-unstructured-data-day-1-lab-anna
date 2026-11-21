USE ROLE all_users_role;
USE DATABASE bootcamp;
USE WAREHOUSE compute_wh;
USE SCHEMA atp524;

-- Step 06: confirm every report in scope is READY before spending AI credits in
-- 07.first_extraction and 08.extract_reports, and show exactly where any year stopped.
-- Scope = lab_settings (ticker + year range), set in python/00.set_session_variables.ipynb.
-- Inputs:  lab_settings, report_manifest, sec_facts, metric_catalog, metric_sec_concepts, stage,
--          lab_runs, extraction_results,
--          statement_page_scan and statement_heading_patterns (for heading_pattern_usage).
-- Outputs: views metric_ground_truth (the one SEC-value rule, also used by 09),
--          report_readiness, pipeline_coverage and heading_pattern_usage.
-- Calls AI: no. Changes data: no. Run after 05.locate_statement_pages.sql.

-- GROUND TRUTH: the ONE place a report's SEC value per metric is chosen; 06 (readiness,
-- detail) and 09 (evaluation) both read it. Grain: one report period (ticker, accession,
-- fiscal start/end) x metric. Only the report's OWN 10-K and period count (later 10-Ks
-- repeat prior years as comparatives). Concepts come from metric_sec_concepts (01):
-- the primary concept is used whenever the filing has it; a recorded fallback is used
-- only when no lower preference has a value. concept_used records which one was used.
CREATE OR REPLACE VIEW metric_ground_truth AS
WITH periods AS (
    SELECT ticker, sec_accession, period_start, period_end FROM report_manifest
    WHERE sec_accession IS NOT NULL AND period_start IS NOT NULL AND period_end IS NOT NULL
    UNION
    SELECT ticker, sec_accession, period_start, period_end FROM lab_runs
    WHERE sec_accession IS NOT NULL
), candidates AS (
    SELECT p.ticker, p.sec_accession, p.period_start, p.period_end, c.metric_id,
           k.concept, k.preference, s.fact_value, s.filed_date
    FROM periods p
    CROSS JOIN metric_catalog c
    JOIN metric_sec_concepts k ON k.metric_id = c.metric_id
    LEFT JOIN sec_facts s
      ON s.ticker = p.ticker AND s.accession = p.sec_accession
     AND s.concept = k.concept AND s.unit = c.expected_unit AND s.form = '10-K'
     AND s.end_date = p.period_end
     AND ((c.period_type = 'instant'  AND s.start_date IS NULL)
       OR (c.period_type = 'duration' AND s.start_date = p.period_start))
), chosen AS (
    SELECT ticker, sec_accession, period_start, period_end, metric_id,
           MIN(IFF(fact_value IS NOT NULL, preference, NULL)) AS preference_used
    FROM candidates
    GROUP BY ticker, sec_accession, period_start, period_end, metric_id
)
SELECT ch.ticker, ch.sec_accession, ch.period_start, ch.period_end, ch.metric_id,
       ch.preference_used,
       MAX(IFF(ca.preference = ch.preference_used, ca.concept, NULL))           AS concept_used,
       COUNT(IFF(ca.preference = ch.preference_used, ca.fact_value, NULL))      AS sec_rows,
       COUNT(DISTINCT IFF(ca.preference = ch.preference_used, ca.fact_value, NULL)) AS distinct_sec_values,
       MIN(IFF(ca.preference = ch.preference_used, ca.fact_value, NULL))        AS candidate_value,
       MIN(IFF(ca.preference = ch.preference_used, ca.filed_date, NULL))        AS sec_filed_date
FROM chosen ch
JOIN candidates ca
  ON ca.ticker = ch.ticker AND ca.sec_accession = ch.sec_accession
 AND ca.period_start = ch.period_start AND ca.period_end = ch.period_end
 AND ca.metric_id = ch.metric_id
GROUP BY ch.ticker, ch.sec_accession, ch.period_start, ch.period_end, ch.metric_id, ch.preference_used;

-- READINESS per in-scope report. Uses the same conditions as the lab_runs insert
-- in 08, plus ground-truth coverage (from metric_ground_truth). Only READY reports
-- produce a run. The metric filter matches include_all_metrics = FALSE; remove it for all ten.
CREATE OR REPLACE VIEW report_readiness AS
SELECT m.relative_path, m.ticker, m.report_year,
       COALESCE(m.approved, FALSE)                      AS approved,
       COALESCE(m.period_start IS NOT NULL AND m.period_end IS NOT NULL
           AND m.period_start < m.period_end, FALSE)    AS period_ok,
       m.sec_accession IS NOT NULL                      AS accession_ok,
       COALESCE(ARRAY_SIZE(m.page_ranges), 0) > 0       AS pages_ok,
       COUNT(DISTINCT c.metric_id)                      AS metrics_expected,
       COUNT(DISTINCT IFF(g.sec_rows > 0, c.metric_id, NULL)) AS metrics_with_ground_truth,
       IFF(approved AND period_ok AND accession_ok AND pages_ok
           AND metrics_with_ground_truth = metrics_expected,
           'READY', 'NOT READY') AS status,
       m.review_notes
FROM report_manifest m
JOIN lab_settings ls
  ON m.ticker = ls.ticker AND m.report_year BETWEEN ls.first_year AND ls.last_year
CROSS JOIN metric_catalog c
LEFT JOIN metric_ground_truth g
  ON g.ticker = m.ticker AND g.sec_accession = m.sec_accession
 AND g.period_start = m.period_start AND g.period_end = m.period_end
 AND g.metric_id = c.metric_id
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

-- Detail: the ground-truth value behind each metric of every approved in-scope report,
-- and which SEC concept supplied it (a fallback concept is named in concept_used).
-- Review concept semantics as well as dates, especially NetIncomeLoss and
-- StockholdersEquity when the company has noncontrolling interests.
SELECT m.relative_path, c.metric_id, c.sec_concept AS primary_concept, g.concept_used,
       c.expected_unit, m.period_start, m.period_end, g.candidate_value AS fact_value,
       g.sec_rows, g.distinct_sec_values, m.sec_accession, g.sec_filed_date
FROM report_manifest m
JOIN lab_settings ls
  ON m.ticker = ls.ticker AND m.report_year BETWEEN ls.first_year AND ls.last_year
CROSS JOIN metric_catalog c
LEFT JOIN metric_ground_truth g
  ON g.ticker = m.ticker AND g.sec_accession = m.sec_accession
 AND g.period_start = m.period_start AND g.period_end = m.period_end
 AND g.metric_id = c.metric_id
WHERE m.approved
ORDER BY m.relative_path, c.metric_id;

-- PATTERN USAGE: which reports each heading wording in statement_heading_patterns (01)
-- actually matches, computed from the pages 05 stored, with 05's own matching rules
-- (top of the page; Item 8 heading on the free text pass, statement headings on the
-- AI-parsed window, index pages excluded). All companies and years, not just the scope.
-- Nothing here is maintained by hand: a new company or year shows up after its 05 run.
-- reports_matched = 0 means no stored report uses that wording (a candidate to remove).
-- A report counts when the wording is at the top of ANY of its window pages, not only the
-- page 05 chose (e.g. an MSFT notes page that begins "...in our consolidated balance
-- sheets" counts for %CONSOLIDATED BALANCE SHEETS%); 05 itself uses the first match.
CREATE OR REPLACE VIEW heading_pattern_usage AS
WITH tops AS (
    SELECT p.relative_path, p.scan_type, LEFT(REGEXP_REPLACE(p.content, '\\s+', ' '), 200) AS head,
           LEFT(p.content, 300) AS head300
    FROM statement_page_scan p
    WHERE p.scan_type IN ('TEXT', 'WINDOW')
), matches AS (
    SELECT DISTINCT h.statement_type, h.pattern, t.relative_path
    FROM statement_heading_patterns h
    JOIN tops t
      ON (h.statement_type = 'item8_heading' AND t.scan_type = 'TEXT'   AND t.head ILIKE h.pattern)
      OR (h.statement_type = 'index_page'    AND t.scan_type = 'WINDOW' AND t.head300 ILIKE h.pattern)
      OR (h.statement_type NOT IN ('item8_heading', 'index_page')
          AND t.scan_type = 'WINDOW' AND t.head ILIKE h.pattern
          AND NOT EXISTS (SELECT 1 FROM statement_heading_patterns x
                          WHERE x.statement_type = 'index_page' AND t.head300 ILIKE x.pattern))
)
SELECT h.statement_type, h.pattern, h.added_for,
       COUNT(m.relative_path)                                            AS reports_matched,
       LISTAGG(DISTINCT r.ticker, ', ') WITHIN GROUP (ORDER BY r.ticker) AS tickers,
       MIN(r.report_year)                                                AS first_year,
       MAX(r.report_year)                                                AS last_year,
       LISTAGG(m.relative_path, ', ') WITHIN GROUP (ORDER BY m.relative_path) AS reports
FROM statement_heading_patterns h
LEFT JOIN matches m ON m.statement_type = h.statement_type AND m.pattern = h.pattern
LEFT JOIN report_manifest r ON r.relative_path = m.relative_path
GROUP BY h.statement_type, h.pattern, h.added_for;

SELECT statement_type, pattern, added_for, reports_matched, tickers, first_year, last_year
FROM heading_pattern_usage ORDER BY statement_type, pattern;
-- Next: 07.first_extraction.sql (optional exploration), then 08.extract_reports.ipynb.
