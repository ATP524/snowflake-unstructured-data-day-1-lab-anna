USE ROLE all_users_role;
USE DATABASE bootcamp;
USE WAREHOUSE compute_wh;
USE SCHEMA atp524;

-- Step 09: score every extraction against SEC ground truth. Run after 08.extract_reports.
-- Inputs:  lab_runs, extraction_results, parse_results (08), metric_ground_truth and
--          scope_metrics (06),
--          metric_catalog; for report_status also report_manifest, ingest_log, the stage, lab_settings.
-- Outputs: function lab_number; views extracted_fields -> normalized_extractions ->
--          sec_reference -> compared_values -> metric_evaluation; report_status (every
--          ticker-year ever touched, all companies); method_comparison (both paths across
--          all reports' latest runs); result queries.
-- Calls AI: no. Changes data: no. The views cover ALL runs (history is kept);
-- the result queries below show the LATEST batch from 08, i.e. every report that
-- batch extracted. To review an older batch, SET batch_id = '<batch id>' instead.
SET batch_id = (SELECT batch_id FROM lab_runs ORDER BY created_at DESC LIMIT 1);
SELECT $batch_id AS batch_id, COUNT(*) AS reports_in_batch,
       LISTAGG(relative_path, ', ') WITHIN GROUP (ORDER BY report_year) AS reports
FROM lab_runs WHERE batch_id = $batch_id;

CREATE OR REPLACE FUNCTION lab_number(s STRING)
RETURNS FLOAT
LANGUAGE SQL
AS
$$
    TRY_TO_DOUBLE(
        IFF(REGEXP_LIKE(TRIM(s), '^[(][0-9]+([.][0-9]+)?[)]$'),
            '-' || REPLACE(REPLACE(TRIM(s), '(', ''), ')', ''),
            IFF(REGEXP_LIKE(TRIM(s), '^[+-]?[0-9]+([.][0-9]+)?$'), TRIM(s), NULL))
    )
$$;

-- Does the AI's scale answer agree with the table scale note it quoted as evidence?
-- 1000 needs "thousand", 1000000 "million", 1000000000 "billion" in the evidence; scale 1
-- must not quote an "in thousands/millions/billions" note. Used for currency amounts only
-- (per-share values are covered by the INVALID_EPS_SCALE rule). No AI call.
CREATE OR REPLACE FUNCTION lab_scale_matches_evidence(scale FLOAT, evidence STRING)
RETURNS BOOLEAN
LANGUAGE SQL
AS
$$
    COALESCE(CASE scale
        WHEN 1          THEN NOT (evidence ILIKE ANY ('%in thousands%', '%in millions%', '%in billions%'))
        WHEN 1000       THEN evidence ILIKE '%thousand%'
        WHEN 1000000    THEN evidence ILIKE '%million%'
        WHEN 1000000000 THEN evidence ILIKE '%billion%'
        ELSE FALSE
    END, FALSE)
$$;

-- 1. Read the saved fields from each method. No model calls occur here.
CREATE OR REPLACE VIEW extracted_fields AS
    SELECT r.run_id, r.batch_id, r.ticker, r.report_year, r.relative_path,
           r.period_start, r.period_end, r.sec_accession,
           c.*, methods.method,
           e.run_id IS NOT NULL AS has_extraction,
           e.raw_result:error::STRING AS extraction_error,
           GET(e.raw_result:response, c.metric_id || '__raw_value')::STRING AS raw_value,
           GET(e.raw_result:response, c.metric_id || '__scale')::STRING AS raw_scale,
           GET(e.raw_result:response, c.metric_id || '__unit')::STRING AS extracted_unit,
           TRY_TO_DATE(GET(e.raw_result:response, c.metric_id || '__start')::STRING) AS extracted_start,
           TRY_TO_DATE(GET(e.raw_result:response, c.metric_id || '__end')::STRING) AS extracted_end,
           GET(e.raw_result:response, c.metric_id || '__evidence')::STRING AS evidence,
           GET(e.raw_result:scoring:scores, c.metric_id || '__raw_value'):score::FLOAT AS value_score
    FROM lab_runs r
    CROSS JOIN metric_catalog c
    CROSS JOIN (SELECT column1 AS method FROM VALUES ('DIRECT_PDF'), ('PARSE_THEN_EXTRACT')) methods
    LEFT JOIN extraction_results e ON e.run_id = r.run_id AND e.method = methods.method
    WHERE GET(r.response_format, c.metric_id || '__raw_value') IS NOT NULL;

SELECT report_year, run_id, method, metric_id, raw_value, raw_scale
FROM extracted_fields WHERE batch_id = $batch_id ORDER BY report_year, metric_id, method;

-- 2. Convert printed amounts to base units (EPS stays unscaled).
CREATE OR REPLACE VIEW normalized_extractions AS
SELECT *,
       lab_number(raw_value) AS printed_value,
       lab_number(raw_scale) AS scale_multiplier,
       CASE WHEN lab_number(raw_scale) IN (1, 1000, 1000000, 1000000000)
            THEN lab_number(raw_value) * lab_number(raw_scale) END AS extracted_value
FROM extracted_fields;

-- SEC duplicates with identical values are harmless; conflicting values are
-- ambiguous and MUST NOT be resolved by comparing to the AI's answer.
-- The SEC value is chosen in ONE place, metric_ground_truth (06): the run's own 10-K and
-- period, the primary concept first, a recorded fallback only when the primary is absent.
CREATE OR REPLACE VIEW sec_reference AS
SELECT r.run_id, c.metric_id,
       COALESCE(g.sec_rows, 0)            AS sec_rows,
       COALESCE(g.distinct_sec_values, 0) AS distinct_sec_values,
       g.candidate_value,
       g.sec_filed_date,
       g.concept_used                     AS sec_concept_used
FROM lab_runs r CROSS JOIN metric_catalog c
LEFT JOIN metric_ground_truth g
  ON g.ticker = r.ticker AND g.sec_accession = r.sec_accession
 AND g.period_start = r.period_start AND g.period_end = r.period_end
 AND g.metric_id = c.metric_id
WHERE GET(r.response_format, c.metric_id || '__raw_value') IS NOT NULL;

-- 3. Join each extracted answer to its independently matched SEC reference.
CREATE OR REPLACE VIEW compared_values AS
    SELECT n.*, s.sec_rows, s.distinct_sec_values, s.sec_filed_date, s.sec_concept_used,
           IFF(s.distinct_sec_values = 1, s.candidate_value, NULL) AS sec_value,
           ABS(n.extracted_value - sec_value) AS absolute_error,
           absolute_error / NULLIF(ABS(sec_value), 0) AS relative_error,
           GREATEST(n.absolute_tolerance, ABS(sec_value) * n.relative_tolerance) AS allowed_error
    FROM normalized_extractions n
    JOIN sec_reference s ON s.run_id = n.run_id AND s.metric_id = n.metric_id;

SELECT report_year, run_id, method, metric_id, sec_value AS expected_value,
       extracted_value, absolute_error
FROM compared_values WHERE batch_id = $batch_id ORDER BY report_year, metric_id, method;

-- 4. Classify each answer. Missing answers still count against accuracy.
CREATE OR REPLACE VIEW metric_evaluation AS
SELECT *,
    CASE
        WHEN sec_rows = 0 THEN 'NO_SEC_REFERENCE'
        WHEN distinct_sec_values <> 1 THEN 'AMBIGUOUS_SEC_REFERENCE'
        WHEN NOT has_extraction THEN 'NO_EXTRACTION'
        WHEN extraction_error IS NOT NULL THEN 'EXTRACTION_ERROR'
        WHEN extracted_value IS NULL THEN 'MISSING_OR_INVALID_VALUE'
        WHEN extracted_unit IS NULL OR extracted_unit <> expected_unit THEN 'UNIT_MISMATCH'
        WHEN expected_unit = 'USD/shares' AND scale_multiplier <> 1 THEN 'INVALID_EPS_SCALE'
        WHEN extracted_end IS NULL OR extracted_end <> period_end THEN 'PERIOD_MISMATCH'
        WHEN period_type = 'duration'
             AND (extracted_start IS NULL OR extracted_start <> period_start) THEN 'PERIOD_MISMATCH'
        WHEN evidence IS NULL OR TRIM(evidence) IN ('', 'NOT_FOUND') THEN 'MISSING_EVIDENCE'
        -- the stated scale must agree with the scale note quoted as evidence, even when
        -- the scaled number happens to match SEC
        WHEN expected_unit <> 'USD/shares'
             AND NOT lab_scale_matches_evidence(scale_multiplier, evidence) THEN 'SCALE_EVIDENCE_MISMATCH'
        WHEN absolute_error <= allowed_error THEN 'PASS'
        ELSE 'VALUE_MISMATCH'
    END AS evaluation_status
FROM compared_values;

-- Includes missing extractions in the scorable denominator.
-- Missing or ambiguous SEC references are excluded and reported separately.
SELECT report_year, run_id, method, COUNT(*) AS expected_metrics,
       COALESCE(COUNT_IF(sec_rows > 0 AND distinct_sec_values = 1), 0) AS scorable_metrics,
       COALESCE(COUNT_IF(evaluation_status = 'PASS'), 0) AS passed_metrics,
       COALESCE(COUNT_IF(evaluation_status = 'PASS'), 0)::FLOAT
           / NULLIF(COUNT_IF(sec_rows > 0 AND distinct_sec_values = 1), 0) AS pass_rate,
       COALESCE(COUNT_IF(evaluation_status IN ('NO_SEC_REFERENCE', 'AMBIGUOUS_SEC_REFERENCE')), 0) AS reference_gaps
FROM metric_evaluation
WHERE batch_id = $batch_id
GROUP BY report_year, run_id, method
ORDER BY report_year, method;

SELECT report_year, run_id, relative_path, method, metric_id, raw_value, raw_scale,
       extracted_value, sec_value, absolute_error, relative_error,
       extracted_unit, extracted_start, extracted_end, evidence,
       value_score, evaluation_status
FROM metric_evaluation
WHERE batch_id = $batch_id
ORDER BY report_year, metric_id, method;

-- Review parse-stage failures and text-input guardrails separately.
SELECT r.report_year, p.run_id, p.raw_result:error AS parse_error,
       p.raw_result:value:error AS document_error,
       COUNT(pp.page_index) AS parsed_pages,
       SUM(LENGTH(pp.content)) AS parsed_characters
FROM parse_results p
JOIN lab_runs r ON r.run_id = p.run_id
LEFT JOIN parsed_pages pp ON p.run_id = pp.run_id
WHERE r.batch_id = $batch_id
GROUP BY r.report_year, p.run_id, p.raw_result:error, p.raw_result:value:error
ORDER BY r.report_year;

-- Compare methods on the same report and metric.
SELECT report_year, run_id, metric_id,
       MAX(IFF(method = 'DIRECT_PDF', evaluation_status, NULL)) AS direct_status,
       MAX(IFF(method = 'PARSE_THEN_EXTRACT', evaluation_status, NULL)) AS parsed_status
FROM metric_evaluation
WHERE batch_id = $batch_id
GROUP BY report_year, run_id, metric_id
ORDER BY report_year, metric_id;

-- Pass rate by prompt version and metric set (all batches). A change in pass rate between
-- two prompt_versions is attributable to the question wording or metric set, not the data.
SELECT LEFT(r.prompt_version, 12) AS prompt_version, r.include_all_metrics, r.metric_count,
       e.method, COUNT(DISTINCT r.run_id) AS runs,
       COUNT_IF(e.sec_rows > 0 AND e.distinct_sec_values = 1) AS scorable_answers,
       COUNT_IF(e.evaluation_status = 'PASS') AS passed_answers,
       passed_answers / NULLIF(scorable_answers, 0) AS pass_rate,
       MIN(r.created_at) AS first_run, MAX(r.created_at) AS last_run
FROM metric_evaluation e
JOIN lab_runs r ON r.run_id = e.run_id
GROUP BY ALL
ORDER BY first_run, method;

-- Coverage check: EVERY year in scope, with its latest evaluation (any batch).
-- A year with no evaluation shows its next step from pipeline_coverage (06)
-- instead of disappearing from the results.
WITH latest_eval AS (
    SELECT run_id,
           COUNT_IF(method = 'DIRECT_PDF' AND evaluation_status = 'PASS')         AS direct_pdf_passed,
           COUNT_IF(method = 'PARSE_THEN_EXTRACT' AND evaluation_status = 'PASS') AS parse_then_extract_passed,
           COUNT(DISTINCT metric_id)                                              AS metrics_evaluated
    FROM metric_evaluation
    GROUP BY run_id
)
SELECT c.ticker, c.report_year, c.readiness, c.latest_run_id,
       e.metrics_evaluated, e.direct_pdf_passed, e.parse_then_extract_passed,
       IFF(e.run_id IS NOT NULL, 'EVALUATED', c.next_step) AS status
FROM pipeline_coverage c
LEFT JOIN latest_eval e ON e.run_id = c.latest_run_id
ORDER BY c.report_year;

-- STATUS: one row for EVERY annual report the lab has ever touched, across all
-- companies (not just the scope): a ticker-year that was in the scope, attempted by 02
-- (ingest_log), staged, or in the manifest. A year whose PDF was never found still has a
-- row. Read by the export (SUMMARY.md) and by people. pipeline_coverage (06) stays
-- scope-only because the runner and 08 use the scope to choose their work. Defined here,
-- after metric_evaluation, because it shows each report's latest scores.
-- ground_truth_metrics counts all catalog metrics with an SEC value from the report's own
-- 10-K (metric_ground_truth). 'Stopped at 06' uses report_readiness's rule: every metric in
-- play (scope_metrics, 06) must have ground truth; next_step names the ones that do not.
CREATE OR REPLACE VIEW report_status AS
WITH years AS (
    SELECT ticker, report_year FROM report_manifest
    UNION SELECT ticker, fiscal_year FROM ingest_log WHERE source = 'PDF' AND fiscal_year > 0
    UNION SELECT SPLIT_PART(relative_path, '/', 1),
                 TO_NUMBER(REGEXP_SUBSTR(relative_path, '/([0-9]{4})[.]pdf$', 1, 1, 'e', 1))
          FROM DIRECTORY(@annual_report_pdfs)
          WHERE REGEXP_LIKE(relative_path, '[A-Z.]+/[0-9]{4}[.]pdf')
    UNION SELECT ls.ticker, ls.first_year + g.n
          FROM lab_settings ls
          JOIN (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS n
                FROM TABLE(GENERATOR(ROWCOUNT => 50))) g
            ON g.n <= ls.last_year - ls.first_year
), last_pdf_attempt AS (
    SELECT ticker, fiscal_year, status AS attempt_status, detail AS attempt_detail
    FROM ingest_log WHERE source = 'PDF' AND fiscal_year > 0
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ticker, fiscal_year ORDER BY logged_at DESC) = 1
), staged AS (
    SELECT relative_path FROM DIRECTORY(@annual_report_pdfs)
), truth AS (
    SELECT m.relative_path,
           COUNT_IF(g.sec_rows > 0)                                        AS ground_truth_metrics,
           COUNT(*)                                                        AS catalog_metrics,
           COUNT_IF(s.metric_id IS NOT NULL)                               AS in_play_metrics,
           COUNT_IF(s.metric_id IS NOT NULL AND g.sec_rows > 0)            AS in_play_with_truth,
           LISTAGG(IFF(s.metric_id IS NOT NULL AND COALESCE(g.sec_rows, 0) = 0, c.metric_id, NULL), ', ')
               WITHIN GROUP (ORDER BY c.metric_id)                         AS missing_in_play,
           LISTAGG(IFF(COALESCE(g.sec_rows, 0) = 0, c.metric_id, NULL), ', ')
               WITHIN GROUP (ORDER BY c.metric_id)                         AS missing_metrics,
           LISTAGG(IFF(g.preference_used > 1, c.metric_id || ' via ' || g.concept_used, NULL), ', ')
               WITHIN GROUP (ORDER BY c.metric_id)                         AS fallback_concepts
    FROM report_manifest m
    CROSS JOIN metric_catalog c
    LEFT JOIN scope_metrics s ON s.metric_id = c.metric_id
    LEFT JOIN metric_ground_truth g
      ON g.ticker = m.ticker AND g.sec_accession = m.sec_accession
     AND g.period_start = m.period_start AND g.period_end = m.period_end
     AND g.metric_id = c.metric_id
    GROUP BY m.relative_path
), latest_run AS (
    SELECT * FROM lab_runs
    QUALIFY ROW_NUMBER() OVER (PARTITION BY relative_path ORDER BY created_at DESC) = 1
), scores AS (
    SELECT run_id,
           COUNT_IF(method = 'DIRECT_PDF' AND evaluation_status = 'PASS')          AS direct_pass,
           COUNT_IF(method = 'DIRECT_PDF')                                         AS direct_n,
           COUNT_IF(method = 'PARSE_THEN_EXTRACT' AND evaluation_status = 'PASS')  AS parse_pass,
           COUNT_IF(method = 'PARSE_THEN_EXTRACT')                                 AS parse_n
    FROM metric_evaluation GROUP BY run_id
)
SELECT y.ticker, y.report_year,
       y.ticker || '/' || y.report_year::STRING || '.pdf'       AS relative_path,
       st.relative_path IS NOT NULL                             AS pdf_on_stage,
       a.attempt_status                                         AS last_pdf_attempt,
       m.sec_accession,
       t.ground_truth_metrics, t.catalog_metrics, t.missing_metrics, t.fallback_concepts,
       m.page_ranges[0]:start::INT                              AS page_start,
       m.page_ranges[0]:"end"::INT                              AS page_end,
       m.locator_method,
       COALESCE(m.approved, FALSE)                              AS approved,
       lr.created_at                                            AS latest_run_at,
       lr.metric_count, LEFT(lr.prompt_version, 8)              AS prompt_version,
       sc.direct_pass, sc.direct_n, sc.parse_pass, sc.parse_n,
       CASE
           WHEN st.relative_path IS NULL THEN 'Stopped at 02'
           WHEN m.relative_path IS NULL OR m.sec_accession IS NULL THEN 'Stopped at 04'
           WHEN NOT COALESCE(m.approved, FALSE) THEN 'Stopped at 05'
           WHEN COALESCE(t.in_play_with_truth, 0) < COALESCE(t.in_play_metrics, 1) THEN 'Stopped at 06'
           WHEN lr.run_id IS NULL THEN 'Ready, not extracted'
           WHEN sc.run_id IS NULL THEN 'Extracted, not evaluated'
           ELSE 'Evaluated'
       END AS status,
       CASE status
           WHEN 'Stopped at 02' THEN '02 PDF not found'
                || IFF(a.attempt_detail IS NOT NULL, ' (' || a.attempt_detail || ')', ' (not attempted yet)')
           WHEN 'Stopped at 04' THEN IFF(m.relative_path IS NULL, '04 prepare manifest',
                                         '04 no matching 10-K in SEC facts (run 03)')
           WHEN 'Stopped at 05' THEN '05 locate pages (see report_manifest.review_notes)'
           WHEN 'Stopped at 06' THEN '06 ground truth missing: ' || t.missing_in_play
           WHEN 'Ready, not extracted' THEN '08 extract (scope this ticker-year and run)'
           WHEN 'Extracted, not evaluated' THEN '09 evaluate'
           ELSE 'complete'
       END AS next_step
FROM years y
LEFT JOIN staged st          ON st.relative_path = y.ticker || '/' || y.report_year::STRING || '.pdf'
LEFT JOIN last_pdf_attempt a ON a.ticker = y.ticker AND a.fiscal_year = y.report_year
LEFT JOIN report_manifest m  ON m.relative_path = y.ticker || '/' || y.report_year::STRING || '.pdf'
LEFT JOIN truth t            ON t.relative_path = m.relative_path
LEFT JOIN latest_run lr      ON lr.relative_path = m.relative_path
LEFT JOIN scores sc          ON sc.run_id = lr.run_id;

SELECT ticker, report_year, status, next_step, ground_truth_metrics, fallback_concepts
FROM report_status ORDER BY ticker, report_year;

-- METHOD COMPARISON: the analyst view of the lab's question, "which extraction path should we
-- use?", across ALL reports (not just the latest batch). Grain: one row per ticker x report
-- year x method, for each report's LATEST run (same rule as report_status). Beyond pass rate
-- it shows the model's own confidence (value_score) and, for parse then extract, how much
-- text the extra AI_PARSE_DOCUMENT step produced. AI credits per method need ACCOUNT_USAGE
-- (see docs/PRODUCTION.md); this view uses only lab tables.
CREATE OR REPLACE VIEW method_comparison AS
WITH latest_run AS (
    SELECT run_id, relative_path, prompt_version FROM lab_runs
    QUALIFY ROW_NUMBER() OVER (PARTITION BY relative_path ORDER BY created_at DESC) = 1
), parsed AS (
    SELECT run_id, COUNT(*) AS parsed_pages, SUM(LENGTH(content)) AS parsed_characters
    FROM parsed_pages GROUP BY run_id
)
SELECT e.ticker, e.report_year, e.method, e.run_id, LEFT(lr.prompt_version, 8) AS prompt_version,
       COUNT(*)                                                       AS metrics_asked,
       COUNT_IF(e.evaluation_status = 'PASS')                         AS metrics_passed,
       metrics_passed / NULLIF(metrics_asked, 0)                      AS pass_rate,
       AVG(e.value_score)                                             AS avg_value_score,
       MIN(e.value_score)                                             AS min_value_score,
       COUNT_IF(e.value_score < 0.9)                                  AS low_confidence_answers,
       COUNT_IF(e.value_score < 0.9 AND e.evaluation_status = 'PASS') AS low_confidence_but_passed,
       IFF(e.method = 'PARSE_THEN_EXTRACT', MAX(p.parsed_pages), NULL)      AS parsed_pages,
       IFF(e.method = 'PARSE_THEN_EXTRACT', MAX(p.parsed_characters), NULL) AS parsed_characters
FROM metric_evaluation e
JOIN latest_run lr ON lr.run_id = e.run_id
LEFT JOIN parsed p ON p.run_id = e.run_id
GROUP BY e.ticker, e.report_year, e.method, e.run_id, lr.prompt_version;

-- Rollup by method (all companies), then by company and method.
SELECT method, COUNT(*) AS reports, SUM(metrics_asked) AS answers, SUM(metrics_passed) AS passed,
       SUM(metrics_passed) / NULLIF(SUM(metrics_asked), 0) AS pass_rate,
       ROUND(SUM(avg_value_score * metrics_asked) / NULLIF(SUM(metrics_asked), 0), 4) AS avg_value_score,
       MIN(min_value_score) AS min_value_score,
       SUM(low_confidence_answers) AS low_confidence_answers,
       SUM(low_confidence_but_passed) AS low_confidence_but_passed,
       ROUND(AVG(parsed_characters), 0) AS avg_parsed_characters
FROM method_comparison GROUP BY method ORDER BY method;

SELECT ticker, method, COUNT(*) AS reports, SUM(metrics_passed) || '/' || SUM(metrics_asked) AS passed,
       ROUND(SUM(avg_value_score * metrics_asked) / NULLIF(SUM(metrics_asked), 0), 4) AS avg_value_score,
       SUM(low_confidence_answers) AS low_confidence_answers
FROM method_comparison GROUP BY ticker, method ORDER BY ticker, method;

-- Agreement: on each report's latest run, how often both paths returned the same base-unit
-- value, and whether a disagreement was resolved in favour of either path by SEC.
WITH latest AS (
    SELECT DISTINCT run_id FROM method_comparison
), pairs AS (
    SELECT e.ticker, e.run_id, e.metric_id,
           MAX(IFF(e.method = 'DIRECT_PDF', e.extracted_value, NULL))         AS direct_value,
           MAX(IFF(e.method = 'PARSE_THEN_EXTRACT', e.extracted_value, NULL)) AS parsed_value,
           MAX(IFF(e.method = 'DIRECT_PDF', e.evaluation_status, NULL))         AS direct_status,
           MAX(IFF(e.method = 'PARSE_THEN_EXTRACT', e.evaluation_status, NULL)) AS parsed_status
    FROM metric_evaluation e JOIN latest l ON l.run_id = e.run_id
    GROUP BY e.ticker, e.run_id, e.metric_id
)
SELECT ticker, COUNT(*) AS report_metrics,
       COUNT_IF(EQUAL_NULL(direct_value, parsed_value)) AS same_value,
       COUNT_IF(direct_status = 'PASS' AND parsed_status = 'PASS') AS both_pass,
       COUNT_IF(direct_status = 'PASS' AND parsed_status <> 'PASS') AS only_direct_pass,
       COUNT_IF(parsed_status = 'PASS' AND direct_status <> 'PASS') AS only_parsed_pass
FROM pairs GROUP BY ROLLUP (ticker) ORDER BY ticker NULLS LAST;

