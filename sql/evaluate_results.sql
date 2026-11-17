-- Run after extract_reports.sql. These views never call AI functions.
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

-- 1. Read the saved fields from each method. No model calls occur here.
CREATE OR REPLACE VIEW extracted_fields AS
    SELECT r.run_id, r.ticker, r.report_year, r.relative_path,
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

SELECT run_id, method, metric_id, raw_value, raw_scale FROM extracted_fields;

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
CREATE OR REPLACE VIEW sec_reference AS
SELECT r.run_id, c.metric_id, COUNT(s.fact_value) AS sec_rows,
       COUNT(DISTINCT s.fact_value) AS distinct_sec_values,
       MIN(s.fact_value) AS candidate_value,
       MIN(s.filed_date) AS sec_filed_date
FROM lab_runs r CROSS JOIN metric_catalog c
LEFT JOIN sec_facts s
  ON s.ticker = r.ticker AND s.accession = r.sec_accession
 AND s.concept = c.sec_concept AND s.unit = c.expected_unit
 AND s.form = '10-K' AND s.end_date = r.period_end
 AND ((c.period_type = 'instant' AND s.start_date IS NULL)
      OR (c.period_type = 'duration' AND s.start_date = r.period_start))
WHERE GET(r.response_format, c.metric_id || '__raw_value') IS NOT NULL
GROUP BY r.run_id, c.metric_id;

-- 3. Join each extracted answer to its independently matched SEC reference.
CREATE OR REPLACE VIEW compared_values AS
    SELECT n.*, s.sec_rows, s.distinct_sec_values, s.sec_filed_date,
           IFF(s.distinct_sec_values = 1, s.candidate_value, NULL) AS sec_value,
           ABS(n.extracted_value - sec_value) AS absolute_error,
           absolute_error / NULLIF(ABS(sec_value), 0) AS relative_error,
           GREATEST(n.absolute_tolerance, ABS(sec_value) * n.relative_tolerance) AS allowed_error
    FROM normalized_extractions n
    JOIN sec_reference s ON s.run_id = n.run_id AND s.metric_id = n.metric_id;

SELECT run_id, method, metric_id, sec_value AS expected_value,
       extracted_value, absolute_error FROM compared_values;

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
        WHEN absolute_error <= allowed_error THEN 'PASS'
        ELSE 'VALUE_MISMATCH'
    END AS evaluation_status
FROM compared_values;

-- Includes missing extractions in the scorable denominator.
-- Missing or ambiguous SEC references are excluded and reported separately.
SELECT run_id, method, COUNT(*) AS expected_metrics,
       COALESCE(COUNT_IF(sec_rows > 0 AND distinct_sec_values = 1), 0) AS scorable_metrics,
       COALESCE(COUNT_IF(evaluation_status = 'PASS'), 0) AS passed_metrics,
       COALESCE(COUNT_IF(evaluation_status = 'PASS'), 0)::FLOAT
           / NULLIF(COUNT_IF(sec_rows > 0 AND distinct_sec_values = 1), 0) AS pass_rate,
       COALESCE(COUNT_IF(evaluation_status IN ('NO_SEC_REFERENCE', 'AMBIGUOUS_SEC_REFERENCE')), 0) AS reference_gaps
FROM metric_evaluation
GROUP BY run_id, method
ORDER BY run_id, method;

SELECT run_id, relative_path, method, metric_id, raw_value, raw_scale,
       extracted_value, sec_value, absolute_error, relative_error,
       extracted_unit, extracted_start, extracted_end, evidence,
       value_score, evaluation_status
FROM metric_evaluation
ORDER BY run_id, metric_id, method;

-- Review parse-stage failures and text-input guardrails separately.
SELECT p.run_id, p.raw_result:error AS parse_error,
       p.raw_result:value:error AS document_error,
       COUNT(pp.page_index) AS parsed_pages,
       SUM(LENGTH(pp.content)) AS parsed_characters
FROM parse_results p LEFT JOIN parsed_pages pp ON p.run_id = pp.run_id
GROUP BY p.run_id, p.raw_result:error, p.raw_result:value:error;

-- Compare methods on the same report and metric.
SELECT run_id, metric_id,
       MAX(IFF(method = 'DIRECT_PDF', evaluation_status, NULL)) AS direct_status,
       MAX(IFF(method = 'PARSE_THEN_EXTRACT', evaluation_status, NULL)) AS parsed_status
FROM metric_evaluation
GROUP BY run_id, metric_id
ORDER BY run_id, metric_id;
