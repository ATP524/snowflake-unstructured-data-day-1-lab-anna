-- Extension exercise: use this for a SECOND report, not the pinned starter.
-- Create your student schema/stage and run ddls.sql, then ingest the new report
-- using ingest_sec_ground_truth.py and ingest_annual_report_pdfs.py.
-- See ../README.md and ../docs/LOCAL_SETUP.md for execution examples.
-- Start with one report. Verify a download succeeded before proceeding.
SELECT * FROM ingest_log ORDER BY logged_at DESC LIMIT 30;
ALTER STAGE annual_report_pdfs REFRESH;

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

-- Select the original 10-K that corresponds to the PDF. Later filings repeat
-- prior-year values, so fiscal_year alone must never select ground truth.
SELECT ticker, accession, filed_date, fiscal_year, fiscal_period,
       start_date, end_date, DATEDIFF('day', start_date, end_date) AS duration_days,
       COUNT(DISTINCT concept) AS concepts
FROM sec_facts
WHERE form = '10-K'
  AND (start_date IS NULL OR DATEDIFF('day', start_date, end_date) BETWEEN 330 AND 380)
GROUP BY ALL
ORDER BY ticker, filed_date, end_date, start_date;

SELECT * FROM report_manifest ORDER BY ticker, report_year;

-- Open the PDF and identify the consolidated financial statement pages,
-- including table headings, dates, and unit/scale notes. Page indexes are
-- zero based, inclusive start / exclusive end; ignore printed page numbers.
-- Fill in actual values; the following is intentionally a template:
--
-- UPDATE report_manifest
-- SET period_start = '<YYYY-MM-DD>',
--     period_end = '<YYYY-MM-DD>',
--     sec_accession = '<accession verified against this PDF>',
--     page_ranges = PARSE_JSON('[{"start": <first_index>, "end": <after_last_index>}]')::ARRAY,
--     approved = TRUE,
--     review_notes = 'Verified original 10-K, consolidated statements, currency, and concept meanings'
-- WHERE relative_path = 'AAPL/2023.pdf';
--
-- Use several ranges if statements are not contiguous. The SAME selected
-- pages feed both paths. This is a selected-statement benchmark, not an
-- automatic full-report retrieval benchmark.
-- Review concept semantics as well as dates, especially NetIncomeLoss and
-- StockholdersEquity when the company has noncontrolling interests.
SELECT m.relative_path, c.metric_id, c.sec_concept, c.expected_unit,
       s.start_date, s.end_date, s.fact_value, s.accession, s.filed_date
FROM report_manifest m
CROSS JOIN metric_catalog c
LEFT JOIN sec_facts s
  ON s.ticker = m.ticker AND s.accession = m.sec_accession
 AND s.concept = c.sec_concept AND s.unit = c.expected_unit AND s.form = '10-K'
 AND s.end_date = m.period_end
 AND ((c.period_type = 'instant' AND s.start_date IS NULL)
      OR (c.period_type = 'duration' AND s.start_date = m.period_start))
WHERE m.approved
ORDER BY m.relative_path, c.metric_id;
