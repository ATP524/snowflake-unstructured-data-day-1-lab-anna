CREATE TABLE IF NOT EXISTS sec_facts (
    ticker STRING, cik STRING, concept STRING, label STRING, unit STRING,
    start_date DATE, end_date DATE, fact_value FLOAT, accession STRING,
    form STRING, filed_date DATE, fiscal_year INT, fiscal_period STRING,
    frame STRING, loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- One expected answer per synthetic PDF and metric; separate from SEC facts.
-- Run generate_synthetic_batch.py to populate 50 rows (five PDFs x ten metrics).
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

CREATE TABLE IF NOT EXISTS ingest_log (
    ticker STRING,
    fiscal_year INT,
    source STRING,
    source_url STRING,
    status STRING,
    detail STRING,
    logged_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- One row per staged PDF. Run prepare_lab.sql after ingestion to populate.
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

CREATE TABLE IF NOT EXISTS metric_catalog (
    metric_id STRING,
    metric_description STRING,
    sec_concept STRING,
    expected_unit STRING,
    period_type STRING,
    absolute_tolerance FLOAT,
    relative_tolerance FLOAT
);

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

-- Each execution gets a new run ID; previous outputs are retained.
CREATE TABLE IF NOT EXISTS lab_runs (
    run_id STRING,
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
