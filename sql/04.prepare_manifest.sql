USE ROLE all_users_role;
USE DATABASE bootcamp;
USE WAREHOUSE compute_wh;
USE SCHEMA atp524;

-- Step 04: prepare report_manifest for every report in the scope set in
-- python/00.set_session_variables.ipynb (lab_settings: ticker + year range).
-- Inputs:  lab_settings, PDFs on @annual_report_pdfs (02), sec_facts (03), ingest_log.
-- Outputs: report_manifest rows (one per staged PDF) with period_start/end + sec_accession.
-- Calls AI: no. Safe to re-run: yes; approved reports are never changed.
-- Run after 02.ingest_annual_report_pdfs.py and 03.ingest_sec_ground_truth.py.
-- Next: 05.locate_statement_pages.sql (page ranges + approval), then 06.check_readiness.sql.
-- See ../README.md and ../docs/LOCAL_SETUP.md for execution examples.

-- The scope every step processes.
SELECT ticker, first_year, last_year FROM lab_settings;

-- Verify the downloads succeeded before proceeding.
SELECT * FROM ingest_log ORDER BY logged_at DESC LIMIT 30;
ALTER STAGE annual_report_pdfs REFRESH;

-- One manifest row per staged PDF named <TICKER>/<YYYY>.pdf. Inserts only new PDFs.
MERGE INTO report_manifest t
USING (
    SELECT relative_path,
           SPLIT_PART(relative_path, '/', 1) AS ticker,
           TRY_TO_NUMBER(SPLIT_PART(SPLIT_PART(relative_path, '/', 2), '.', 1)) AS report_year
    FROM DIRECTORY(@annual_report_pdfs)
    WHERE REGEXP_LIKE(relative_path, '^[A-Z0-9-]+/[0-9]{4}[.]pdf$')
) s ON t.relative_path = s.relative_path
WHEN NOT MATCHED THEN INSERT (relative_path, ticker, report_year)
VALUES (s.relative_path, s.ticker, s.report_year);

-- Review: the original 10-K behind each in-scope year. Later filings repeat
-- prior-year values, so fiscal_year alone must never select ground truth.
SELECT f.ticker, f.accession, f.filed_date, f.fiscal_year, f.fiscal_period,
       f.start_date, f.end_date, DATEDIFF('day', f.start_date, f.end_date) AS duration_days,
       COUNT(DISTINCT f.concept) AS concepts
FROM sec_facts f
JOIN lab_settings s ON f.ticker = s.ticker
WHERE f.form = '10-K'
  AND (f.start_date IS NULL OR DATEDIFF('day', f.start_date, f.end_date) BETWEEN 330 AND 380)
GROUP BY ALL
ORDER BY f.ticker, f.filed_date, f.end_date, f.start_date;

-- PROPOSE: fill period_start, period_end and sec_accession from sec_facts for
-- every unapproved report in scope.
-- A 10-K's own period is its latest ~1-year duration (comparative years end earlier);
-- 330-380 days covers 52- and 53-week fiscal years but excludes quarters and YTD.
-- The original filing is the EARLIEST filed 10-K whose own period ends in report_year.
-- Assumes the PDF is named for the calendar year the fiscal year ends in; check
-- companies whose fiscal year ends in early January.
UPDATE report_manifest t
SET period_start  = s.period_start,
    period_end    = s.period_end,
    sec_accession = s.accession
FROM (
    WITH filing_periods AS (
        SELECT ticker, accession, MIN(filed_date) AS filed_date,
               MAX(end_date) AS period_end
        FROM sec_facts
        WHERE form = '10-K'
          AND start_date IS NOT NULL
          AND DATEDIFF('day', start_date, end_date) BETWEEN 330 AND 380
        GROUP BY ticker, accession
    ),
    with_start AS (
        SELECT fp.ticker, fp.accession, fp.filed_date, fp.period_end,
               MIN(f.start_date) AS period_start
        FROM filing_periods fp
        JOIN sec_facts f
          ON f.accession = fp.accession AND f.end_date = fp.period_end
         AND DATEDIFF('day', f.start_date, f.end_date) BETWEEN 330 AND 380
        GROUP BY ALL
    )
    SELECT m.relative_path, w.accession, w.period_start, w.period_end
    FROM report_manifest m
    JOIN lab_settings ls
      ON m.ticker = ls.ticker AND m.report_year BETWEEN ls.first_year AND ls.last_year
    JOIN with_start w
      ON w.ticker = m.ticker AND YEAR(w.period_end) = m.report_year
    QUALIFY ROW_NUMBER() OVER (PARTITION BY m.relative_path ORDER BY w.filed_date) = 1
) s
WHERE t.relative_path = s.relative_path
  AND NOT COALESCE(t.approved, FALSE);

-- In-scope manifest rows after proposing. Rows still missing dates mean their
-- SEC facts are not loaded: widen the scope in 00 and re-run 03.
SELECT m.*
FROM report_manifest m
JOIN lab_settings s
  ON m.ticker = s.ticker AND m.report_year BETWEEN s.first_year AND s.last_year
ORDER BY m.report_year;

-- MANUAL OVERRIDE (optional, normally not needed).
-- 05.locate_statement_pages.sql finds pages and approves reports automatically.
-- Use this only when 05 marks a report AUTO-REJECTED (its review_notes say what
-- was NOT FOUND): open that PDF, find the consolidated statement pages yourself,
-- fill in the report and range, then uncomment and run. This is the one place a
-- report is named by hand, because it records a person's review of that PDF.
-- Page indexes are zero based, end exclusive; ignore printed page numbers.
-- Use several ranges if statements are not contiguous.
--
-- UPDATE report_manifest
-- SET page_ranges  = PARSE_JSON('[{"start": <first_index>, "end": <after_last_index>}]')::ARRAY,
--     approved     = TRUE,
--     review_notes = 'HUMAN-REVIEWED ' || TO_CHAR(CURRENT_DATE(), 'YYYY-MM-DD') || ' by '
--                    || CURRENT_USER() || ': confirmed statement pages, period and accession in the PDF'
-- WHERE relative_path = '<TICKER>/<YEAR>.pdf';
