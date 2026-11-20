USE ROLE all_users_role;
USE DATABASE bootcamp;
USE WAREHOUSE compute_wh;
USE SCHEMA atp524;

-- Step 10: data quality tests. Run after 09.evaluate_results.sql (also safe at any time).
-- Inputs: every lab table and the lab_number function from 09. Outputs: result sets only.
-- Calls AI: no. Modifies data: no.
--
-- Each check returns one row: check_type | object | rule | failures | status.
-- failures = number of rows breaking the rule; status = PASS when failures = 0.
-- The check types are the four standard dbt tests, so each row maps 1:1 to a dbt test
-- when the lab moves to dbt (see docs/PRODUCTION.md):
--   unique          the declared key (grain) has no duplicates
--   not_null        key columns are never NULL
--   relationships   every child row has its parent (no orphans)
--   accepted_values a coded column only holds its documented values
-- Keys and grains are declared in 01.ddls.sql.

-- 1. Grain and key tests. Expect every row to say PASS.
WITH checks AS (
    -- unique: each table's declared key
    SELECT 'unique' AS check_type, 'lab_settings' AS object, 'setting_id (and exactly one row)' AS rule,
           GREATEST(COUNT(*) - 1, 0) + IFF(COUNT(*) = 0, 1, 0) AS failures FROM lab_settings
    UNION ALL SELECT 'unique', 'metric_catalog', 'metric_id',
           COUNT(*) - COUNT(DISTINCT metric_id) FROM metric_catalog
    UNION ALL SELECT 'unique', 'statement_heading_patterns', 'statement_type, pattern',
           COUNT(*) - COUNT(DISTINCT statement_type, pattern) FROM statement_heading_patterns
    UNION ALL SELECT 'unique', 'sec_facts', 'ticker, accession, concept, unit, start_date, end_date, form, fiscal_year, fiscal_period, frame',
           COUNT(*) - (SELECT COUNT(*) FROM (SELECT DISTINCT ticker, accession, concept, unit, start_date, end_date,
                                                   form, fiscal_year, fiscal_period, frame FROM sec_facts)) FROM sec_facts
    UNION ALL SELECT 'unique', 'statement_page_scan', 'relative_path, scan_type, page_index',
           COUNT(*) - COUNT(DISTINCT relative_path, scan_type, page_index) FROM statement_page_scan
    UNION ALL SELECT 'unique', 'parse_results', 'run_id',
           COUNT(*) - COUNT(DISTINCT run_id) FROM parse_results
    UNION ALL SELECT 'unique', 'extraction_results', 'run_id, method',
           COUNT(*) - COUNT(DISTINCT run_id, method) FROM extraction_results
    UNION ALL SELECT 'unique', 'extracted_values', 'relative_path',
           COUNT(*) - COUNT(DISTINCT relative_path) FROM extracted_values
    UNION ALL SELECT 'unique', 'synthetic_ground_truth', 'relative_path, metric_id',
           COUNT(*) - COUNT(DISTINCT relative_path, metric_id) FROM synthetic_ground_truth
    UNION ALL SELECT 'unique', 'report_manifest', 'relative_path',
           COUNT(*) - COUNT(DISTINCT relative_path) FROM report_manifest
    UNION ALL SELECT 'unique', 'lab_runs', 'run_id',
           COUNT(*) - COUNT(DISTINCT run_id) FROM lab_runs
    UNION ALL SELECT 'unique', 'lab_runs', 'one run per report per batch (batch_id, relative_path)',
           COUNT(*) - COUNT(DISTINCT batch_id, relative_path) FROM lab_runs

    -- not_null: key columns (COUNT(DISTINCT) above ignores NULLs, so test them separately)
    UNION ALL SELECT 'not_null', 'lab_settings', 'ticker, first_year, last_year, max_statement_pages, ai_fallback_page_cap',
           COUNT_IF(ticker IS NULL OR first_year IS NULL OR last_year IS NULL
                    OR max_statement_pages IS NULL OR ai_fallback_page_cap IS NULL) FROM lab_settings
    UNION ALL SELECT 'not_null', 'sec_facts', 'ticker, accession, concept, unit, end_date',
           COUNT_IF(ticker IS NULL OR accession IS NULL OR concept IS NULL OR unit IS NULL OR end_date IS NULL) FROM sec_facts
    UNION ALL SELECT 'not_null', 'report_manifest', 'relative_path, ticker, report_year',
           COUNT_IF(relative_path IS NULL OR ticker IS NULL OR report_year IS NULL) FROM report_manifest
    UNION ALL SELECT 'not_null', 'report_manifest', 'approved => period, accession and page_ranges',
           COUNT_IF(approved AND (period_start IS NULL OR period_end IS NULL OR sec_accession IS NULL
                                  OR COALESCE(ARRAY_SIZE(page_ranges), 0) = 0)) FROM report_manifest
    UNION ALL SELECT 'not_null', 'lab_runs', 'run_id, batch_id, relative_path, response_format',
           COUNT_IF(run_id IS NULL OR batch_id IS NULL OR relative_path IS NULL OR response_format IS NULL) FROM lab_runs
    UNION ALL SELECT 'not_null', 'lab_runs', 'provenance: prompt_version, include_all_metrics, metric_count, metric_ids',
           COUNT_IF(prompt_version IS NULL OR include_all_metrics IS NULL OR metric_count IS NULL OR metric_ids IS NULL) FROM lab_runs
    UNION ALL SELECT 'accepted_values', 'lab_runs.metric_count', '= ARRAY_SIZE(metric_ids); = catalog size when include_all_metrics',
           COUNT_IF(metric_count <> ARRAY_SIZE(metric_ids)
                    OR (include_all_metrics AND metric_count <> (SELECT COUNT(*) FROM metric_catalog))) FROM lab_runs
    UNION ALL SELECT 'not_null', 'extraction_results', 'run_id, method',
           COUNT_IF(run_id IS NULL OR method IS NULL) FROM extraction_results

    -- relationships: no orphans
    UNION ALL SELECT 'relationships', 'lab_runs.relative_path', '-> report_manifest.relative_path',
           COUNT(*) FROM lab_runs r WHERE NOT EXISTS (SELECT 1 FROM report_manifest m WHERE m.relative_path = r.relative_path)
    UNION ALL SELECT 'relationships', 'extraction_results.run_id', '-> lab_runs.run_id',
           COUNT(*) FROM extraction_results e WHERE NOT EXISTS (SELECT 1 FROM lab_runs r WHERE r.run_id = e.run_id)
    UNION ALL SELECT 'relationships', 'parse_results.run_id', '-> lab_runs.run_id',
           COUNT(*) FROM parse_results p WHERE NOT EXISTS (SELECT 1 FROM lab_runs r WHERE r.run_id = p.run_id)
    UNION ALL SELECT 'relationships', 'report_manifest.sec_accession', '-> sec_facts.accession',
           COUNT(*) FROM report_manifest m
           WHERE m.sec_accession IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM sec_facts f WHERE f.accession = m.sec_accession)
    UNION ALL SELECT 'relationships', 'report_manifest.relative_path', '-> PDF on @annual_report_pdfs',
           COUNT(*) FROM report_manifest m
           WHERE NOT EXISTS (SELECT 1 FROM DIRECTORY(@annual_report_pdfs) d WHERE d.relative_path = m.relative_path)

    -- accepted_values: coded columns
    UNION ALL SELECT 'accepted_values', 'extraction_results.method', 'DIRECT_PDF, PARSE_THEN_EXTRACT',
           COUNT_IF(method NOT IN ('DIRECT_PDF', 'PARSE_THEN_EXTRACT')) FROM extraction_results
    UNION ALL SELECT 'accepted_values', 'statement_page_scan.scan_type', 'TEXT, WINDOW, TOC',
           COUNT_IF(scan_type NOT IN ('TEXT', 'WINDOW', 'TOC')) FROM statement_page_scan
    UNION ALL SELECT 'accepted_values', 'report_manifest.locator_method', 'TEXT+INDEX, TEXT, AI_FALLBACK, MANUAL_REVIEW, NOT_FOUND (or NULL if located earlier)',
           COUNT_IF(locator_method NOT IN ('TEXT+INDEX', 'TEXT', 'AI_FALLBACK', 'MANUAL_REVIEW', 'NOT_FOUND')) FROM report_manifest
    UNION ALL SELECT 'accepted_values', 'statement_heading_patterns.statement_type', 'every type 05 needs has at least one pattern',
           (SELECT COUNT(*) FROM (SELECT column1 AS t FROM VALUES ('item8_heading'), ('index_page'), ('operations'),
                    ('comprehensive'), ('balance_sheet'), ('equity'), ('cash_flows'), ('first_notes')) need
            WHERE need.t NOT IN (SELECT statement_type FROM statement_heading_patterns))
           + COUNT_IF(statement_type NOT IN ('item8_heading', 'index_page', 'operations', 'comprehensive',
                                             'balance_sheet', 'equity', 'cash_flows', 'first_notes'))
           FROM statement_heading_patterns
    UNION ALL SELECT 'accepted_values', 'metric_catalog.period_type', 'instant, duration',
           COUNT_IF(period_type NOT IN ('instant', 'duration')) FROM metric_catalog
    UNION ALL SELECT 'accepted_values', 'report_manifest.review_notes', 'AUTO-APPROVED / AUTO-REJECTED / HUMAN-REVIEWED prefix when approved',
           COUNT_IF(approved AND NOT REGEXP_LIKE(COALESCE(review_notes, ''), '^(AUTO-APPROVED|HUMAN-REVIEWED).*', 's'))
           FROM report_manifest
    UNION ALL SELECT 'accepted_values', 'lab_settings', 'first_year <= last_year, at most six years',
           COUNT_IF(NOT (first_year <= last_year AND last_year - first_year <= 5)) FROM lab_settings
)
SELECT check_type, object, rule, failures, IFF(failures = 0, 'PASS', 'FAIL') AS status
FROM checks
ORDER BY status, check_type, object;

-- 2. Number parsing used by 09 (lab_number). Expect every row to say PASS.
WITH cases AS (
    SELECT column1 AS input, column2::FLOAT AS expected
    FROM VALUES ('383285', 383285), ('6.13', 6.13), ('(123.50)', -123.50),
        ('-45', -45), ('0', 0), ('NOT_FOUND', NULL), ('1,234', NULL),
        ('$123', NULL), ('12 million', NULL), ('', NULL)
)
SELECT input, expected, lab_number(input) AS actual,
       IFF(EQUAL_NULL(actual, expected), 'PASS', 'FAIL') AS test_status
FROM cases;

-- 3. Tolerance rule used by 09. Expect every row to say PASS.
WITH cases AS (
    SELECT column1 AS label, column2::STRING AS printed,
           column3::STRING AS scale, column4::FLOAT AS reference,
           column5::FLOAT AS abs_tolerance, column6::FLOAT AS rel_tolerance,
           column7::BOOLEAN AS expected_pass
    FROM VALUES
        ('USD millions', '383285', '1000000', 383285000000, 1000000, 0.0001, TRUE),
        ('EPS unscaled', '6.13', '1', 6.13, 0.01, 0, TRUE),
        ('Wrong scale', '383285', '1', 383285000000, 1000000, 0.0001, FALSE),
        ('Negative cash flow', '(123)', '1000000', -123000000, 1000000, 0.0001, TRUE),
        ('Zero reference inside absolute tolerance', '0.005', '1', 0, 0.01, 0, TRUE),
        ('Zero reference outside absolute tolerance', '2', '1', 0, 0.01, 0, FALSE)
)
SELECT label,
       ABS(lab_number(printed) * lab_number(scale) - reference)
           <= GREATEST(abs_tolerance, ABS(reference) * rel_tolerance) AS actual_pass,
       IFF(actual_pass = expected_pass, 'PASS', 'FAIL') AS test_status
FROM cases;

-- 4. Scale-vs-evidence rule used by 09 (lab_scale_matches_evidence). Expect every row to say PASS.
WITH cases AS (
    SELECT column1 AS label, column2::FLOAT AS scale, column3::STRING AS evidence,
           column4::BOOLEAN AS expected
    FROM VALUES
        ('millions agrees',          1000000,    'Total assets | $122,070 (in millions, except per share data)', TRUE),
        ('thousands agrees',         1000,       'Revenue | 1,234 (in thousands)', TRUE),
        ('billions agrees',          1000000000, 'Total assets | 1.2 (in billions)', TRUE),
        ('scale 1, no note',         1,          'Net sales | $1,234,567', TRUE),
        ('millions note, scale 1000', 1000,      'Total assets | $122,070 (in millions, except per share data)', FALSE),
        ('millions note, scale 1',   1,          'Total assets | $122,070 (in millions)', FALSE),
        ('scale stated, no note',    1000000,    'Total assets | $122,070', FALSE),
        ('invalid scale',            100,        'Total assets (in millions)', FALSE),
        ('missing evidence',         1000000,    NULL, FALSE)
)
SELECT label, lab_scale_matches_evidence(scale, evidence) AS actual,
       IFF(actual = expected, 'PASS', 'FAIL') AS test_status
FROM cases;
