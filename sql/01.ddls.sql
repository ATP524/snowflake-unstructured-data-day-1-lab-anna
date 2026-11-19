USE ROLE all_users_role;
USE DATABASE bootcamp;
USE warehouse compute_wh;
USE SCHEMA atp524;

//ground truth
CREATE TABLE IF NOT EXISTS sec_facts (
    ticker STRING, cik STRING, concept STRING, label STRING, unit STRING,
    start_date DATE, end_date DATE, fact_value FLOAT, accession STRING,
    form STRING, filed_date DATE, fiscal_year INT, fiscal_period STRING,
    frame STRING, loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

//we generate from our fixtures
-- One expected answer per synthetic PDF and metric; separate from SEC facts.
-- Run 11.generate_synthetic_batch.py to populate 50 rows (five PDFs x ten metrics).
CREATE TABLE IF NOT EXISTS synthetic_ground_truth (
    relative_path STRING,
    ticker STRING,
    report_year INT,
    metric_id STRING,
    metric_label STRING,
    expected_printed_value NUMBER(38, 2),
    expected_scale NUMBER(38, 0),
    expected_value NUMBER(38, 2),
    expected_unit STRING,
    period_start DATE,
    period_end DATE,
    page_index INT,
    source_sha256 STRING,
    pdf_sha256 STRING,
    reference_source STRING
);
//when we hit a different datasource we log info about source
CREATE TABLE IF NOT EXISTS ingest_log (
    ticker STRING,
    fiscal_year INT,
    source STRING,
    source_url STRING,
    status STRING,
    detail STRING,
    logged_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- One row per staged PDF. Run 04.prepare_manifest.sql after ingestion to populate.
-- Fiscal year in a filename is a label, not a reliable XBRL period join key.
CREATE TABLE IF NOT EXISTS report_manifest (
    relative_path STRING,
    ticker STRING,
    report_year INT,
    period_start DATE,
    period_end DATE,
    sec_accession STRING,
    page_ranges ARRAY,
    approved BOOLEAN DEFAULT FALSE,
    review_notes STRING
);

// all of the metrics we want to extract from the PDFs
CREATE TABLE IF NOT EXISTS metric_catalog (
    metric_id STRING,
    metric_description STRING,
    sec_concept STRING,
    expected_unit STRING,
    period_type STRING,
    absolute_tolerance FLOAT,
    relative_tolerance FLOAT
);

// objective: select metrics (first item in single quotes), plus ground truth from sec data to see if AI parsing is working as intended
//merge is idemopotent, it won't insert more data verses INSERT INTO which would
-- No automatic revenue-tag fallback: different concepts may mean different things.
-- Tolerances allow small presentation-rounding differences and are configurable.
MERGE INTO metric_catalog t
USING (
    SELECT column1 AS metric_id, column2 AS metric_description,
           column3 AS sec_concept, column4 AS expected_unit,
           column5 AS period_type, column6 AS absolute_tolerance,
           column7 AS relative_tolerance
    FROM VALUES
      ('assets', 'Total consolidated assets', 'Assets', 'USD', 'instant', 1000000, 0.0001),
      ('eps_basic', 'Basic earnings per share attributable to parent common shareholders; not adjusted EPS', 'EarningsPerShareBasic', 'USD/shares', 'duration', 0.01, 0),
      ('eps_diluted', 'Diluted earnings per share attributable to parent common shareholders; not adjusted EPS', 'EarningsPerShareDiluted', 'USD/shares', 'duration', 0.01, 0),
      ('gross_profit', 'Consolidated gross profit', 'GrossProfit', 'USD', 'duration', 1000000, 0.0001),
      ('liabilities', 'Total consolidated liabilities', 'Liabilities', 'USD', 'instant', 1000000, 0.0001),
      ('net_income', 'Net income or loss attributable to parent, excluding noncontrolling interests', 'NetIncomeLoss', 'USD', 'duration', 1000000, 0.0001),
      ('operating_income', 'Consolidated operating income or loss', 'OperatingIncomeLoss', 'USD', 'duration', 1000000, 0.0001),
      ('revenue', 'Revenue from contracts with customers excluding assessed tax', 'RevenueFromContractWithCustomerExcludingAssessedTax', 'USD', 'duration', 1000000, 0.0001),
      ('equity', 'Stockholders equity attributable to parent, excluding noncontrolling interests', 'StockholdersEquity', 'USD', 'instant', 1000000, 0.0001),
      ('operating_cash_flow', 'Net cash provided by or used in consolidated operating activities', 'NetCashProvidedByUsedInOperatingActivities', 'USD', 'duration', 1000000, 0.0001)
) s ON t.metric_id = s.metric_id
WHEN NOT MATCHED THEN INSERT (
    metric_id, metric_description, sec_concept, expected_unit,
    period_type, absolute_tolerance, relative_tolerance
) VALUES (
    s.metric_id, s.metric_description, s.sec_concept, s.expected_unit,
    s.period_type, s.absolute_tolerance, s.relative_tolerance
);

// helps with labs
-- Each execution gets a new run ID; previous outputs are retained.
-- batch_id groups the runs created together by one execution of 08.extract_reports.
CREATE TABLE IF NOT EXISTS lab_runs (
    run_id STRING,
    batch_id STRING,
    relative_path STRING,
    ticker STRING,
    report_year INT,
    period_start DATE,
    period_end DATE,
    sec_accession STRING,
    page_ranges ARRAY,
    response_format VARIANT,
    created_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS parse_results (
    run_id STRING,
    raw_result VARIANT,
    created_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS extraction_results (
    run_id STRING,
    method STRING,
    raw_result VARIANT,
    created_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- One row: the scope being processed (ticker + year range). Set it ONLY in
-- python/00.set_session_variables.ipynb. Steps 02 and 03 ingest this scope and
-- every SQL step from 04 on processes every report in it.
CREATE TABLE IF NOT EXISTS lab_settings (
    ticker STRING,
    first_year INT,
    last_year INT,
    updated_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Parsed pages saved by 05.locate_statement_pages.sql so no page is parsed twice.
CREATE TABLE IF NOT EXISTS statement_page_scan (
    relative_path STRING,
    scan_type STRING,
    page_index INT,
    printed_page INT,
    content STRING,
    scanned_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);
