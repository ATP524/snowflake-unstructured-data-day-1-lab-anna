USE ROLE all_users_role;
USE DATABASE bootcamp;
USE WAREHOUSE compute_wh;
USE SCHEMA atp524;

-- Step 10: data quality tests. Run after 09.evaluate_results.sql (also safe at any time).
-- Inputs: every lab table, the lab_number / lab_scale_matches_evidence functions from 09
-- and the locator_decision function from 01.
-- Outputs: result sets only.
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
    UNION ALL SELECT 'unique', 'metric_sec_concepts', 'metric_id, concept; exactly one preference 1 per metric',
           COUNT(*) - COUNT(DISTINCT metric_id, concept)
           + (SELECT COUNT(*) FROM metric_catalog c
              WHERE (SELECT COUNT(*) FROM metric_sec_concepts k
                     WHERE k.metric_id = c.metric_id AND k.preference = 1) <> 1)
           FROM metric_sec_concepts
    UNION ALL SELECT 'unique', 'ddl_applied', 'file_name; sha256 is a 64-character hex digest',
           COUNT(*) - COUNT(DISTINCT file_name) + COUNT_IF(NOT REGEXP_LIKE(sha256, '[0-9a-f]{64}'))
           FROM ddl_applied
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
    UNION ALL SELECT 'not_null', 'statement_heading_patterns', 'statement_type, pattern, added_for (one report, e.g. MSFT 2023)',
           COUNT_IF(statement_type IS NULL OR pattern IS NULL OR added_for IS NULL
                    OR NOT REGEXP_LIKE(added_for, '[A-Z.]+ [0-9]{4}')) FROM statement_heading_patterns
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
    UNION ALL SELECT 'accepted_values', 'metric_sec_concepts', 'preference 1 = metric_catalog.sec_concept; every row has a reason',
           COUNT_IF(k.preference = 1 AND k.concept <> c.sec_concept)
           + COUNT_IF(k.reason IS NULL OR TRIM(k.reason) = '')
           FROM metric_sec_concepts k JOIN metric_catalog c ON c.metric_id = k.metric_id
    UNION ALL SELECT 'relationships', 'metric_sec_concepts.metric_id', '-> metric_catalog.metric_id',
           COUNT(*) FROM metric_sec_concepts k
           WHERE NOT EXISTS (SELECT 1 FROM metric_catalog c WHERE c.metric_id = k.metric_id)
    UNION ALL SELECT 'accepted_values', 'metric_ground_truth', 'a fallback concept is used only when the own 10-K has no primary value',
           COUNT(*) FROM metric_ground_truth g JOIN metric_catalog c ON c.metric_id = g.metric_id
           WHERE g.preference_used > 1
             AND EXISTS (SELECT 1 FROM sec_facts s
                         WHERE s.ticker = g.ticker AND s.accession = g.sec_accession
                           AND s.concept = c.sec_concept AND s.unit = c.expected_unit
                           AND s.form = '10-K' AND s.end_date = g.period_end
                           AND ((c.period_type = 'instant'  AND s.start_date IS NULL)
                             OR (c.period_type = 'duration' AND s.start_date = g.period_start)))
    UNION ALL SELECT 'relationships', 'report_status', 'every attempted, staged or manifest ticker-year has a row (none hidden)',
           (SELECT COUNT(*) FROM (
                SELECT ticker, fiscal_year AS report_year FROM ingest_log WHERE source = 'PDF' AND fiscal_year > 0
                UNION SELECT ticker, report_year FROM report_manifest) w
            WHERE NOT EXISTS (SELECT 1 FROM report_status r
                              WHERE r.ticker = w.ticker AND r.report_year = w.report_year))
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

-- 5. Page-locator outcomes used by 05 (locator_decision, defined in 01). Covers every
-- outcome, including ones no real report has produced yet. Expect every row to say PASS.
WITH cases AS (
    SELECT column1 AS label, column2::BOOLEAN AS has_text, column3::INT AS item8_page,
           column4::INT AS index_pdf_page, column5::STRING AS expected
    FROM VALUES
        ('index agrees exactly (AAPL, TSLA)',  TRUE,  30,   30,   'TEXT+INDEX'),
        ('index 2 pages off still agrees',     TRUE,  30,   32,   'TEXT+INDEX'),
        ('no index (MSFT)',                    TRUE,  43,   NULL, 'TEXT'),
        ('index 3 pages off',                  TRUE,  30,   33,   'MANUAL_REVIEW'),
        ('index far before heading',           TRUE,  46,   10,   'MANUAL_REVIEW'),
        ('text but no Item 8 heading',         TRUE,  NULL, 30,   'NOT_FOUND'),
        ('scanned PDF, no text layer',         FALSE, NULL, NULL, 'AI_FALLBACK'),
        ('no text pass result at all',         NULL,  NULL, NULL, 'AI_FALLBACK')
)
SELECT label, locator_decision(has_text, item8_page, index_pdf_page) AS actual,
       IFF(actual = expected, 'PASS', 'FAIL') AS test_status
FROM cases;
