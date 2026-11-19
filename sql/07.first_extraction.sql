USE ROLE all_users_role;
USE DATABASE bootcamp;
USE WAREHOUSE compute_wh;
USE SCHEMA atp524;

-- Step 07: first hands-on AI_EXTRACT, one quick call per READY report in scope.
-- Run after 06.check_readiness.sql. Everything report-specific (PDF path, pages,
-- fiscal year end, SEC accession) comes from report_manifest for the scope set in
-- python/00.set_session_variables.ipynb; nothing is typed in here.
-- This exploratory call is separate from the persisted benchmark (08 + 09).
-- Cost: one AI_EXTRACT per READY report not yet extracted here.
-- (Offline alternative to steps 02 + 03 for AAPL 2023 only: load_starter(session).)

-- ask AI to look at this PDF; a simple approach
-- note: we got this to MATCH for AAPL but this prompt might get it wrong for TSLA so we need ground truth and comparison methods
CREATE TABLE IF NOT EXISTS extracted_values (
    extracted     OBJECT,
    relative_path STRING,
    ticker        STRING,
    report_year   INT,
    period_end    DATE,
    sec_accession STRING,
    extracted_at  TIMESTAMP_LTZ
);

-- One row per READY in-scope report that has not been extracted here yet.
INSERT INTO extracted_values (extracted, relative_path, ticker, report_year,
                              period_end, sec_accession, extracted_at)
SELECT AI_EXTRACT(
    -- we are not giving AI all the pages, only the reviewed statement pages
    file => FL_FILTER_PAGES(TO_FILE('@annual_report_pdfs', m.relative_path), m.page_ranges),
    -- this is like our prompt to pull data out, in this case 3 values;
    -- the fiscal year end is filled in from the manifest for each report
    responseFormat => OBJECT_CONSTRUCT(
        'Assets', 'What are total consolidated assets as of '
            || TO_CHAR(m.period_end, 'MMMM DD, YYYY')
            || '? Return the printed value, currency, and table scale.',
        'RevenueFromContractWithCustomerExcludingAssessedTax', 'What is total consolidated net sales for the fiscal year ended '
            || TO_CHAR(m.period_end, 'MMMM DD, YYYY')
            || '? Return the printed value, currency, and table scale. Ignore product-only or services-only sales.',
        'EarningsPerShareDiluted', 'What is diluted earnings per share for the fiscal year ended '
            || TO_CHAR(m.period_end, 'MMMM DD, YYYY')
            || '? Return the printed per-share amount and currency. Do not apply any table scale.'
    )
), m.relative_path, m.ticker, m.report_year, m.period_end, m.sec_accession, CURRENT_TIMESTAMP()
FROM report_manifest m
JOIN report_readiness r ON r.relative_path = m.relative_path AND r.status = 'READY'
WHERE NOT EXISTS (SELECT 1 FROM extracted_values v WHERE v.relative_path = m.relative_path);

-- In-scope extractions (one row per report).
SELECT v.*
FROM extracted_values v
JOIN lab_settings s
  ON v.ticker = s.ticker AND v.report_year BETWEEN s.first_year AND s.last_year
ORDER BY v.report_year;
-- OUTPUT

SELECT v.report_year,
    v.extracted['response']['Assets']
    ,v.extracted['response']['RevenueFromContractWithCustomerExcludingAssessedTax']
    ,v.extracted['response']['EarningsPerShareDiluted']
FROM extracted_values v
JOIN lab_settings s
  ON v.ticker = s.ticker AND v.report_year BETWEEN s.first_year AND s.last_year
ORDER BY v.report_year;

-- values are on same row and we want them on separate for extracted values
SELECT v.report_year, f.key AS concept, f.value AS extracted_value
FROM extracted_values v
JOIN lab_settings s
  ON v.ticker = s.ticker AND v.report_year BETWEEN s.first_year AND s.last_year,
    LATERAL FLATTEN(input => v.extracted['response']) f
ORDER BY v.report_year, concept;

-- ground truth values
-- Reference values from SEC facts, in base units, for each report's own
-- accession and fiscal year end (taken from the manifest, not typed in).
-- 3 values of ground truth data per report
SELECT m.report_year, f.concept, f.unit, f.fact_value, f.start_date, f.end_date, f.accession
FROM report_manifest m
JOIN report_readiness r ON r.relative_path = m.relative_path AND r.status = 'READY'
JOIN sec_facts f
  ON f.ticker = m.ticker AND f.accession = m.sec_accession AND f.end_date = m.period_end
WHERE f.concept IN ('Assets',
     'RevenueFromContractWithCustomerExcludingAssessedTax', 'EarningsPerShareDiluted')
ORDER BY m.report_year, f.concept;


-- Side by Side comparsion on extracted_values and sec_facts data to compare, per report
WITH extracted AS (
    SELECT
        v.relative_path,
        v.report_year,
        f.key AS concept,
        f.value::STRING AS extracted_raw,
        TRY_TO_DOUBLE(REGEXP_SUBSTR(REPLACE(f.value::STRING, ',', ''), '-?[0-9]+(\\.[0-9]+)?'))
          * CASE
              WHEN f.value::STRING ILIKE '%billion%'  THEN 1e9
              WHEN f.value::STRING ILIKE '%million%'  THEN 1e6
              WHEN f.value::STRING ILIKE '%thousand%' THEN 1e3
              ELSE 1
            END AS extracted_value
    FROM extracted_values v
    JOIN lab_settings s
      ON v.ticker = s.ticker AND v.report_year BETWEEN s.first_year AND s.last_year,
        LATERAL FLATTEN(input => v.extracted['response']) f
),
sec AS (
    SELECT m.relative_path, f.concept, f.unit, f.fact_value
    FROM report_manifest m
    JOIN sec_facts f
      ON f.ticker = m.ticker AND f.accession = m.sec_accession AND f.end_date = m.period_end
    WHERE f.concept IN ('Assets','RevenueFromContractWithCustomerExcludingAssessedTax', 'EarningsPerShareDiluted')
    QUALIFY ROW_NUMBER() OVER (PARTITION BY m.relative_path, f.concept ORDER BY f.start_date) = 1
)
SELECT
    e.report_year,
    e.concept,
    e.extracted_raw,
    e.extracted_value,
    s.fact_value AS sec_value,
    s.unit,
    e.extracted_value - s.fact_value AS difference,
    IFF(ABS(e.extracted_value - s.fact_value) < 0.005, 'MATCH', 'MISMATCH') AS status
FROM extracted e
LEFT JOIN sec s ON s.relative_path = e.relative_path AND s.concept = e.concept
ORDER BY e.report_year, e.concept;


--OUTPUT (AAPL 2023, recorded during the hands-on lab):
/*
Assets  352,583 million USD  352583000000  352583000000  USD  0  MATCH
EarningsPerShareDiluted  6.13 USD  6.13  6.13  USD/shares  0  MATCH
RevenueFromContractWithCustomerExcludingAssessedTax  383,285 million USD  383285000000  383285000000  USD  0  MATCH
*/
-- Discuss:
-- 1. Why does 352,583 in the PDF compare to 352,583,000,000 in SEC facts?
-- 2. Why does diluted EPS stay 6.13?
-- 3. Why is Apple's fiscal year different from a calendar year?
-- Next: run 08.extract_reports.ipynb (defaults to these three metrics), then
-- 09.evaluate_results.sql for the persisted two-path comparison.

//using spark 1 petabyte of data using spark is about 500,000 USD in 2026 so using AI on this amount of data isn't cost effective
--in data engineering there are 3vs: volume, velocity, and variety 
--this is a variety topic
