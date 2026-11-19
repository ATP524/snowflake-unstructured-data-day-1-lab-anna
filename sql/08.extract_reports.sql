USE ROLE all_users_role;
USE DATABASE bootcamp;
USE WAREHOUSE compute_wh;
USE SCHEMA atp524;

-- Step 08: run both extraction paths for EVERY READY report in scope, as one batch.
-- Scope = lab_settings (ticker + year range), set in python/00.set_session_variables.ipynb.
-- Check 06.check_readiness.sql first: only READY reports are included, and
-- pipeline_coverage shows any year that is not.
-- Each execution creates one batch_id and one run_id per report; earlier runs are kept.
-- Cost: per report, one direct AI_EXTRACT, one AI_PARSE_DOCUMENT and one text AI_EXTRACT.
-- FALSE: assets, revenue, diluted EPS (18 questions per report). TRUE: all ten (60).
SET include_all_metrics = FALSE;
SET batch_id = (SELECT UUID_STRING()); -- UUID_STRING() returns a new value per call, so it runs once in a subquery and is stored

-- Snapshot each READY report's filing selection and exact questions under its own run_id.
INSERT INTO lab_runs (
    run_id, batch_id, relative_path, ticker, report_year, period_start, period_end,
    sec_accession, page_ranges, response_format
)
WITH questions AS (
    SELECT m.relative_path, m.ticker, m.report_year, m.period_start, m.period_end,
           m.sec_accession, m.page_ranges, c.metric_id,
           'For ' || c.metric_description || ', use only the consolidated GAAP statements. '
           || IFF(c.period_type = 'instant',
                  'Use the balance at ' || TO_CHAR(m.period_end, 'YYYY-MM-DD') || '. ',
                  'Use the full fiscal year from ' || TO_CHAR(m.period_start, 'YYYY-MM-DD')
                  || ' to ' || TO_CHAR(m.period_end, 'YYYY-MM-DD') || '. ')
           || 'Ignore comparative-year, segment, quarterly, and non-GAAP figures. '
           || 'If the requested information is absent, return NOT_FOUND. ' AS context
    FROM report_manifest m
    JOIN report_readiness r ON r.relative_path = m.relative_path AND r.status = 'READY'
    CROSS JOIN metric_catalog c
    WHERE ($include_all_metrics OR c.metric_id IN ('assets', 'revenue', 'eps_diluted'))
), fields AS (
    SELECT q.*, f.key AS question_key, f.value AS question
    FROM questions q,
    LATERAL FLATTEN(INPUT => OBJECT_CONSTRUCT(
        q.metric_id || '__raw_value', q.context || 'Return only the signed number as printed, with a decimal point and no currency symbols or separators. Parentheses mean negative. Do not apply the table scale.',
        q.metric_id || '__scale', q.context || 'Return only the numeric multiplier that converts the printed number to base currency units: 1, 1000, 1000000, or 1000000000. Per-share amounts use 1 even if the statement is in millions.',
        q.metric_id || '__unit', q.context || 'Return the currency unit as USD or USD/shares for per-share values. If another currency is used, return that currency code; do not convert currencies.',
        q.metric_id || '__start', q.context || 'Return the fiscal period start date as YYYY-MM-DD. For balance-sheet instant values return NOT_APPLICABLE.',
        q.metric_id || '__end', q.context || 'Return the actual fiscal period end date as YYYY-MM-DD.',
        q.metric_id || '__evidence', q.context || 'Quote the statement line, column date/header and table scale note supporting this amount. Do not infer an absent value.'
    )) f
), per_report AS (
    SELECT relative_path, ticker, report_year, period_start, period_end,
           sec_accession, page_ranges, OBJECT_AGG(question_key, question) AS response_format
    FROM fields
    GROUP BY relative_path, ticker, report_year, period_start, period_end,
             sec_accession, page_ranges
)
SELECT UUID_STRING(), $batch_id, relative_path, ticker, report_year, period_start, period_end,
       sec_accession, page_ranges, response_format
FROM per_report;

-- Expect one row per READY report in scope. If a year is missing, see pipeline_coverage (06).
SELECT batch_id, run_id, relative_path, report_year, period_start, period_end, sec_accession, page_ranges
FROM lab_runs WHERE batch_id = $batch_id ORDER BY report_year;

-- Path A: direct extraction from each report's selected PDF pages.
INSERT INTO extraction_results (run_id, method, raw_result)
SELECT run_id, 'DIRECT_PDF',
       AI_EXTRACT(
           file => FL_FILTER_PAGES(TO_FILE('@annual_report_pdfs', relative_path), page_ranges),
           responseFormat => response_format,
           scores => TRUE
       )
FROM lab_runs WHERE batch_id = $batch_id;

-- Path B: parse layout to Markdown, then extract the same fields from that text.
-- return_error_details=TRUE returns an OBJECT, not the default JSON string.
INSERT INTO parse_results (run_id, raw_result)
SELECT run_id, TO_VARIANT(AI_PARSE_DOCUMENT(
    TO_FILE('@annual_report_pdfs', relative_path),
    OBJECT_CONSTRUCT('mode', 'LAYOUT', 'page_split', TRUE, 'page_filter', page_ranges),
    TRUE
))
FROM lab_runs WHERE batch_id = $batch_id;

CREATE OR REPLACE VIEW parsed_pages AS
SELECT p.run_id, f.value:index::INT AS page_index,
       f.value:content::STRING AS content
FROM parse_results p,
LATERAL FLATTEN(INPUT => p.raw_result:value:pages) f
WHERE p.raw_result:error::STRING IS NULL
  AND p.raw_result:value:error::STRING IS NULL;

-- Inspect parsing errors and page content before calling the text extractor.
SELECT r.report_year, p.run_id, p.raw_result:error AS parse_error, p.raw_result:value:error AS document_error
FROM parse_results p JOIN lab_runs r ON r.run_id = p.run_id
WHERE r.batch_id = $batch_id ORDER BY r.report_year;
SELECT r.report_year, pp.page_index, LEFT(pp.content, 120) AS page_start
FROM parsed_pages pp JOIN lab_runs r ON r.run_id = pp.run_id
WHERE r.batch_id = $batch_id ORDER BY r.report_year, pp.page_index;

-- A conservative lab guardrail, not a documented model token limit.
-- Oversized inputs are flagged as missing extractions in the evaluation.
-- Select fewer pages and start a NEW run; never silently truncate statements.
INSERT INTO extraction_results (run_id, method, raw_result)
WITH documents AS (
    SELECT pp.run_id,
           LISTAGG('[PDF page index ' || pp.page_index::STRING || ']\n' || pp.content, '\n\n')
               WITHIN GROUP (ORDER BY pp.page_index) AS markdown
    FROM parsed_pages pp
    JOIN lab_runs r ON r.run_id = pp.run_id
    WHERE r.batch_id = $batch_id
    GROUP BY pp.run_id
)
SELECT r.run_id, 'PARSE_THEN_EXTRACT',
       AI_EXTRACT(text => d.markdown, responseFormat => r.response_format, scores => TRUE)
FROM lab_runs r JOIN documents d ON d.run_id = r.run_id
WHERE r.batch_id = $batch_id
  AND LENGTH(d.markdown) BETWEEN 1 AND 60000;

-- Both paths for every report in this batch.
SELECT r.report_year, e.run_id, e.method, e.raw_result
FROM extraction_results e JOIN lab_runs r ON r.run_id = e.run_id
WHERE r.batch_id = $batch_id ORDER BY r.report_year, e.method;
-- Next: 09.evaluate_results.sql. To repeat the experiment, run this whole worksheet again
-- (a new batch_id). Do not rerun individual inserts under an existing batch.
