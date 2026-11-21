USE ROLE all_users_role;
USE DATABASE bootcamp;
USE WAREHOUSE compute_wh;
USE SCHEMA atp524;

-- Step 13 (optional): detailed direct-only synthetic benchmark (value, scale, unit, dates, evidence).
-- Inputs:  synthetic PDFs + manifest.json on the stage (11). Outputs: session TEMP tables/views only.
-- Calls AI: one AI_EXTRACT per synthetic PDF.
-- Run after 11.generate_synthetic_batch.py uploads five PDFs and the batch manifest.
-- Select the same database, student schema, and query warehouse as the lab.
-- This worksheet is independent of 08.extract_reports.ipynb/09.evaluate_results.sql.

-- Which pages the model sees. Page 0 is a "Full-year results" summary that restates revenue
-- and net income ROUNDED (USD billions, 2 decimals); pages 1-4 are the exact statements.
--   0 = the whole report, summary included (default): tests picking the exact figure.
--   1 = statements only (control).
SET first_page = 0;
CREATE FILE FORMAT IF NOT EXISTS synthetic_json_format TYPE = JSON;

CREATE OR REPLACE TEMP TABLE synthetic_reference AS
WITH batch AS (
    SELECT $1 AS payload
    FROM @annual_report_pdfs/synthetic/batch/manifest.json
        (FILE_FORMAT => 'synthetic_json_format')
)
SELECT f.value AS manifest
FROM batch, LATERAL FLATTEN(INPUT => payload:reports) f;

-- Expect five rows, each with ten metrics, before running the AI call.
SELECT COUNT(*) AS reports,
       COUNT(DISTINCT manifest:relative_path::STRING) AS distinct_reports,
       SUM(ARRAY_SIZE(OBJECT_KEYS(manifest:expected))) AS total_metrics
FROM synthetic_reference;
-- Stop if these values are not 5, 5, and 50.
SELECT manifest:relative_path::STRING AS report,
       ARRAY_SIZE(OBJECT_KEYS(manifest:expected)) AS expected_metrics
FROM synthetic_reference;

CREATE OR REPLACE TEMP TABLE synthetic_questions AS
WITH metrics AS (
    SELECT r.manifest, m.key::STRING AS metric_id, m.value AS expected,
           'Use only the consolidated statements for ' || m.value:label::STRING
           || '. Use the fiscal year ending ' || m.value:end::STRING || '. '
           || IFF(m.value:start IS NULL OR IS_NULL_VALUE(m.value:start),
                  'This is a balance-sheet amount at that date. ',
                  'The full fiscal year starts ' || m.value:start::STRING || '. ')
           || 'Ignore comparative years and rounded summary amounts. '
           || 'Return NOT_FOUND if absent. ' AS context
    FROM synthetic_reference r,
    LATERAL FLATTEN(INPUT => r.manifest:expected) m
), fields AS (
    SELECT manifest, f.key::STRING AS question_key, f.value AS question
    FROM metrics,
    LATERAL FLATTEN(INPUT => OBJECT_CONSTRUCT(
        metric_id || '__raw_value', context || 'Return only the signed number as printed, without commas or currency symbols. Do not apply the table scale.',
        metric_id || '__scale', context || 'Return only the multiplier to base units: 1, 1000, 1000000, or 1000000000. EPS uses 1.',
        metric_id || '__unit', context || 'Return USD or USD/shares.',
        metric_id || '__start', context || 'Return the fiscal start date as YYYY-MM-DD, or NOT_APPLICABLE for a balance-sheet instant.',
        metric_id || '__end', context || 'Return the fiscal end date as YYYY-MM-DD.',
        metric_id || '__evidence', context || 'Quote the statement line, date header, and scale note supporting the amount.'
    )) f
)
SELECT manifest:relative_path::STRING AS relative_path,
       OBJECT_AGG(question_key, question) AS response_format
FROM fields GROUP BY manifest:relative_path::STRING;

-- This statement performs FIVE AI_EXTRACT calls and incurs inference charges.
-- Rerunning it repeats all five calls and replaces temporary extraction results.
-- Ground-truth amounts are NOT in the prompt.
CREATE OR REPLACE TEMP TABLE synthetic_extraction AS
SELECT q.relative_path,
       AI_EXTRACT(
           file => FL_FILTER_PAGES(
               TO_FILE('@annual_report_pdfs', q.relative_path),
               ARRAY_CONSTRUCT(OBJECT_CONSTRUCT('start', $first_page, 'end', 5))),
           responseFormat => q.response_format,
           scores => TRUE
       ) AS raw_result
FROM synthetic_questions q;

-- Inspect errors and raw answers before scoring.
SELECT * FROM synthetic_extraction;

CREATE OR REPLACE TEMP VIEW synthetic_metric_evaluation AS
WITH fields AS (
    SELECT r.manifest:relative_path::STRING AS relative_path,
           m.key::STRING AS metric_id, m.value AS expected,
           e.raw_result:error::STRING AS extraction_error,
           GET(e.raw_result:response, m.key || '__raw_value')::STRING AS raw_value,
           TRY_TO_DOUBLE(GET(e.raw_result:response, m.key || '__scale')::STRING) AS scale,
           GET(e.raw_result:response, m.key || '__unit')::STRING AS unit,
           TRY_TO_DATE(GET(e.raw_result:response, m.key || '__start')::STRING) AS period_start,
           TRY_TO_DATE(GET(e.raw_result:response, m.key || '__end')::STRING) AS period_end,
           GET(e.raw_result:response, m.key || '__evidence')::STRING AS evidence
    FROM synthetic_reference r
    LEFT JOIN synthetic_extraction e
      ON e.relative_path = r.manifest:relative_path::STRING,
    LATERAL FLATTEN(INPUT => r.manifest:expected) m
), normalized AS (
    SELECT *,
        TRY_TO_DOUBLE(IFF(REGEXP_LIKE(TRIM(raw_value), '^[(][0-9]+([.][0-9]+)?[)]$'),
            '-' || REPLACE(REPLACE(TRIM(raw_value), '(', ''), ')', ''),
            IFF(REGEXP_LIKE(TRIM(raw_value), '^[+-]?[0-9]+([.][0-9]+)?$'),
                TRIM(raw_value), NULL))) AS printed_value,
        printed_value * scale AS extracted_value
    FROM fields
)
SELECT *,
    CASE
        WHEN extraction_error IS NOT NULL THEN 'EXTRACTION_ERROR'
        WHEN printed_value IS NULL OR scale IS NULL THEN 'MISSING_OR_INVALID_VALUE'
        -- Checked before scale: a value read from the page-0 summary (billions) would
        -- otherwise show only as SCALE_MISMATCH and hide that the summary was used.
        WHEN NOT IS_NULL_VALUE(expected:summary_value)
             AND ABS(extracted_value - expected:summary_value::FLOAT) <= 0.5
             AND ABS(extracted_value - expected:value::FLOAT) > 0.5 THEN 'USED_ROUNDED_SUMMARY'
        WHEN scale <> expected:scale::FLOAT THEN 'SCALE_MISMATCH'
        WHEN unit IS NULL OR unit <> expected:unit::STRING THEN 'UNIT_MISMATCH'
        WHEN period_end IS NULL OR period_end <> expected:end::DATE THEN 'PERIOD_MISMATCH'
        WHEN NOT IS_NULL_VALUE(expected:start)
             AND (period_start IS NULL OR period_start <> expected:start::DATE) THEN 'PERIOD_MISMATCH'
        WHEN evidence IS NULL OR TRIM(evidence) IN ('', 'NOT_FOUND') THEN 'MISSING_EVIDENCE'
        WHEN ABS(extracted_value - expected:value::FLOAT) <=
             IFF(expected:unit::STRING = 'USD/shares', 0.005, 0.5) THEN 'PASS'
        ELSE 'VALUE_MISMATCH'
    END AS evaluation_status
FROM normalized;

SELECT relative_path, metric_id, raw_value, scale, extracted_value,
       expected:value::FLOAT AS expected_value, evaluation_status, evidence
FROM synthetic_metric_evaluation ORDER BY relative_path, metric_id;

SELECT relative_path, COUNT(*) AS expected_metrics,
       COUNT_IF(evaluation_status = 'PASS') AS passed_metrics,
       COUNT_IF(evaluation_status = 'PASS')::FLOAT / NULLIF(COUNT(*), 0) AS pass_rate
FROM synthetic_metric_evaluation
GROUP BY relative_path ORDER BY relative_path;

SELECT COUNT(*) AS expected_metrics,
       COUNT_IF(evaluation_status = 'PASS') AS passed_metrics,
       COUNT_IF(evaluation_status = 'PASS')::FLOAT / NULLIF(COUNT(*), 0) AS pass_rate
FROM synthetic_metric_evaluation;

-- Rounding trap: the 10 answers (revenue and net income x 5 reports) whose page-0 summary
-- differs from the exact statement figure. With first_page = 1 this is the control.
SELECT $first_page AS first_page, COUNT(*) AS trap_answers,
       COUNT_IF(evaluation_status = 'PASS') AS picked_exact_statement,
       COUNT_IF(evaluation_status = 'USED_ROUNDED_SUMMARY') AS picked_rounded_summary,
       COUNT_IF(evaluation_status NOT IN ('PASS', 'USED_ROUNDED_SUMMARY')) AS other_errors
FROM synthetic_metric_evaluation
WHERE NOT IS_NULL_VALUE(expected:summary_value) AND expected:summary_value IS NOT NULL;
