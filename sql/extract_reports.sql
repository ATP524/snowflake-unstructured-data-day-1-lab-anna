-- Run this worksheet for ONE approved report at a time.
SET report_path = 'AAPL/2023.pdf';
-- FALSE: assets, revenue, diluted EPS (18 questions). TRUE: all ten (60).
SET include_all_metrics = FALSE;
SET run_id = UUID_STRING();

-- Snapshot the filing selection and exact questions used by this run.
INSERT INTO lab_runs (
    run_id, relative_path, ticker, report_year, period_start, period_end,
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
    FROM report_manifest m CROSS JOIN metric_catalog c
    WHERE m.relative_path = $report_path AND m.approved
      AND ($include_all_metrics OR c.metric_id IN ('assets', 'revenue', 'eps_diluted'))
      AND m.period_start IS NOT NULL AND m.period_end IS NOT NULL
      AND m.period_start < m.period_end
      AND m.sec_accession IS NOT NULL AND ARRAY_SIZE(m.page_ranges) > 0
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
)
SELECT $run_id, relative_path, ticker, report_year, period_start, period_end,
       sec_accession, page_ranges, OBJECT_AGG(question_key, question)
FROM fields
GROUP BY relative_path, ticker, report_year, period_start, period_end,
         sec_accession, page_ranges;

-- Expect exactly one row. If zero, stop and complete the manifest review.
SELECT * FROM lab_runs WHERE run_id = $run_id;

-- Path A: direct extraction from the selected PDF pages.
INSERT INTO extraction_results (run_id, method, raw_result)
SELECT run_id, 'DIRECT_PDF',
       AI_EXTRACT(
           file => FL_FILTER_PAGES(TO_FILE('@annual_report_pdfs', relative_path), page_ranges),
           responseFormat => response_format,
           scores => TRUE
       )
FROM lab_runs WHERE run_id = $run_id;

-- Path B: parse layout to Markdown, then extract the same fields from that text.
-- return_error_details=TRUE returns an OBJECT, not the default JSON string.
INSERT INTO parse_results (run_id, raw_result)
SELECT run_id, TO_VARIANT(AI_PARSE_DOCUMENT(
    TO_FILE('@annual_report_pdfs', relative_path),
    OBJECT_CONSTRUCT('mode', 'LAYOUT', 'page_split', TRUE, 'page_filter', page_ranges),
    TRUE
))
FROM lab_runs WHERE run_id = $run_id;

CREATE OR REPLACE VIEW parsed_pages AS
SELECT p.run_id, f.value:index::INT AS page_index,
       f.value:content::STRING AS content
FROM parse_results p,
LATERAL FLATTEN(INPUT => p.raw_result:value:pages) f
WHERE p.raw_result:error::STRING IS NULL
  AND p.raw_result:value:error::STRING IS NULL;

-- Inspect parsing errors and page content before calling the text extractor.
SELECT * FROM parse_results WHERE run_id = $run_id;
SELECT * FROM parsed_pages WHERE run_id = $run_id ORDER BY page_index;

-- A conservative lab guardrail, not a documented model token limit.
-- Oversized inputs are flagged as missing extractions in the evaluation.
-- Select fewer pages and start a NEW run; never silently truncate statements.
INSERT INTO extraction_results (run_id, method, raw_result)
WITH documents AS (
    SELECT run_id,
           LISTAGG('[PDF page index ' || page_index::STRING || ']\n' || content, '\n\n')
               WITHIN GROUP (ORDER BY page_index) AS markdown
    FROM parsed_pages
    WHERE run_id = $run_id
    GROUP BY run_id
)
SELECT r.run_id, 'PARSE_THEN_EXTRACT',
       AI_EXTRACT(text => d.markdown, responseFormat => r.response_format, scores => TRUE)
FROM lab_runs r JOIN documents d ON d.run_id = r.run_id
WHERE r.run_id = $run_id
  AND LENGTH(d.markdown) BETWEEN 1 AND 60000;

SELECT run_id, method, raw_result FROM extraction_results WHERE run_id = $run_id;
-- To repeat either path, run this entire worksheet with a fresh run_id.
