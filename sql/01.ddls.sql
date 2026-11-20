USE ROLE all_users_role;
USE DATABASE bootcamp;
USE WAREHOUSE compute_wh;
USE SCHEMA atp524;

-- Step 01: create every lab table, its keys and its documentation.
-- Inputs: none. Outputs: all tables below (empty) plus metric_catalog rows.
-- Calls AI: no. Safe to re-run: yes (IF NOT EXISTS, MERGE, add-if-missing constraints).
-- Next: python/02.ingest_annual_report_pdfs.py (after setting the scope in 00).
--
-- DATA LAYERS (logical now; see docs/ARCHITECTURE.md and docs/PRODUCTION.md for the
-- physical dbt layout these map to):
--   CONFIG   settings and reference data people edit       lab_settings, metric_catalog,
--                                                          statement_heading_patterns
--   RAW      landed as received, never edited             stage PDFs, sec_facts, ingest_log,
--                                                          statement_page_scan, parse_results,
--                                                          extraction_results, extracted_values,
--                                                          synthetic_ground_truth
--   CURATED  reviewed, one row per business entity         report_manifest, lab_runs
--   ANALYSIS views derived from the above, never written   report_readiness, pipeline_coverage,
--                                                          parsed_pages, metric_evaluation, ...
-- Every table states its GRAIN (what one row means) and KEY below. Snowflake does not
-- enforce PRIMARY KEY / UNIQUE / FOREIGN KEY constraints; they are declared to document
-- the grain and are tested by 10.validation.sql (the same checks become dbt tests).

-- =====================================================================================
-- CONFIG
-- =====================================================================================

-- Grain: exactly one row (setting_id = 1): the scope every step processes.
-- Set it ONLY in python/00.set_session_variables.ipynb.
CREATE TABLE IF NOT EXISTS lab_settings (
    setting_id INT NOT NULL DEFAULT 1,
    ticker STRING,
    first_year INT,
    last_year INT,
    updated_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);
-- Older schemas created lab_settings without setting_id: add it once.
EXECUTE IMMEDIATE $$
BEGIN
    IF (NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = CURRENT_SCHEMA() AND table_name = 'LAB_SETTINGS'
                      AND column_name = 'SETTING_ID')) THEN
        ALTER TABLE lab_settings ADD COLUMN setting_id INT NOT NULL DEFAULT 1;
    END IF;
    RETURN 'lab_settings.setting_id present';
END;
$$;
-- Page-locator limits used by 05 (defaults suit a 10-K; change them here, not in 05):
--   max_statement_pages   longest statement range 05 will auto-approve
--   ai_fallback_page_cap  pages AI_PARSE_DOCUMENT may read for a PDF with no text layer
EXECUTE IMMEDIATE $$
BEGIN
    IF (NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = CURRENT_SCHEMA() AND table_name = 'LAB_SETTINGS'
                      AND column_name = 'MAX_STATEMENT_PAGES')) THEN
        ALTER TABLE lab_settings ADD COLUMN max_statement_pages INT DEFAULT 10;
    END IF;
    IF (NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = CURRENT_SCHEMA() AND table_name = 'LAB_SETTINGS'
                      AND column_name = 'AI_FALLBACK_PAGE_CAP')) THEN
        ALTER TABLE lab_settings ADD COLUMN ai_fallback_page_cap INT DEFAULT 60;
    END IF;
    UPDATE lab_settings SET max_statement_pages = COALESCE(max_statement_pages, 10),
                            ai_fallback_page_cap = COALESCE(ai_fallback_page_cap, 60);
    RETURN 'lab_settings locator limits present';
END;
$$;

-- Grain: one heading wording per statement type. Key: (statement_type, pattern).
-- 05 matches these ILIKE patterns against the TOP of each page (first 200 characters).
-- Companies word their statements differently; add a row here (not code in 05) when a
-- new company's report is AUTO-REJECTED with a heading NOT FOUND.
--   item8_heading  the "Item 8. Financial Statements and Supplementary Data" page (anchor)
--   index_page     the Item 8 index that lists every heading (excluded from matching)
--   operations, comprehensive, balance_sheet, equity, cash_flows, first_notes
CREATE TABLE IF NOT EXISTS statement_heading_patterns (
    statement_type STRING NOT NULL,
    pattern STRING NOT NULL,
    example_source STRING        -- the report where this wording was verified
);

MERGE INTO statement_heading_patterns t
USING (
    SELECT column1 AS statement_type, column2 AS pattern, column3 AS example_source
    FROM VALUES
      ('item8_heading', '%Financial Statements and Supplementary Data%', 'AAPL, MSFT, TSLA 2023'),
      ('index_page',    '%Index to Consolidated Financial Statements%',  'AAPL, TSLA 2023'),
      ('operations',    '%CONSOLIDATED STATEMENTS OF OPERATIONS%',       'AAPL, TSLA 2023'),
      ('operations',    '%INCOME STATEMENTS%',                           'MSFT 2023'),
      ('comprehensive', '%STATEMENTS OF COMPREHENSIVE INCOME%',          'AAPL, TSLA 2023'),
      ('comprehensive', '%COMPREHENSIVE INCOME STATEMENTS%',             'MSFT 2023'),
      ('balance_sheet', '%CONSOLIDATED BALANCE SHEETS%',                 'AAPL, TSLA 2023'),
      ('balance_sheet', '%BALANCE SHEETS%',                              'MSFT 2023'),
      ('equity',        '%CONSOLIDATED STATEMENTS OF SHAREHOLDERS%',     'AAPL 2023'),
      ('equity',        '%STOCKHOLDERS%EQUITY STATEMENTS%',              'MSFT 2023'),
      ('equity',        '%STATEMENTS OF REDEEMABLE NONCONTROLLING INTERESTS AND EQUITY%', 'TSLA 2023'),
      ('cash_flows',    '%CONSOLIDATED STATEMENTS OF CASH FLOWS%',       'AAPL, TSLA 2023'),
      ('cash_flows',    '%CASH FLOWS STATEMENTS%',                       'MSFT 2023'),
      ('first_notes',   '%Notes to Consolidated Financial Statements%',  'AAPL, TSLA 2023'),
      ('first_notes',   '%NOTES TO FINANCIAL STATEMENTS%',               'MSFT 2023')
) s ON t.statement_type = s.statement_type AND t.pattern = s.pattern
WHEN NOT MATCHED THEN INSERT (statement_type, pattern, example_source)
VALUES (s.statement_type, s.pattern, s.example_source);

-- Grain: one row per metric the lab can extract. Key: metric_id.
-- No automatic revenue-tag fallback: different concepts may mean different things.
-- Tolerances allow small presentation-rounding differences and are configurable.
CREATE TABLE IF NOT EXISTS metric_catalog (
    metric_id STRING NOT NULL,
    metric_description STRING,
    sec_concept STRING,
    expected_unit STRING,
    period_type STRING,          -- 'instant' (balance at a date) or 'duration' (a period)
    absolute_tolerance FLOAT,
    relative_tolerance FLOAT
);

-- MERGE is idempotent: re-running inserts nothing new (an INSERT INTO would duplicate).
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

-- =====================================================================================
-- RAW (append or upsert only; never hand-edited)
-- =====================================================================================

-- Ground truth. Grain: one SEC XBRL observation (a concept value for one period in one
-- filing). Key: the loader's merge key (sec_facts.py KEY_COLUMNS). start_date is NULL
-- for instant facts, so this is a UNIQUE key rather than a primary key.
-- A later 10-K repeats prior years as comparatives: always join on accession + period.
CREATE TABLE IF NOT EXISTS sec_facts (
    ticker STRING, cik STRING, concept STRING, label STRING, unit STRING,
    start_date DATE, end_date DATE, fact_value FLOAT, accession STRING,
    form STRING, filed_date DATE, fiscal_year INT, fiscal_period STRING,
    frame STRING, loaded_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Grain: one download or load attempt (an event log). No natural key: the same year
-- can be attempted many times. Written by 02 and 03.
CREATE TABLE IF NOT EXISTS ingest_log (
    ticker STRING,
    fiscal_year INT,             -- -1 for whole-company loads (SEC facts)
    source STRING,
    source_url STRING,
    status STRING,
    detail STRING,
    logged_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Grain: one parsed PDF page used to locate statements. Key: (relative_path, scan_type,
-- page_index). Written by 05 so no page is ever parsed (or paid for) twice.
CREATE TABLE IF NOT EXISTS statement_page_scan (
    relative_path STRING NOT NULL,
    scan_type STRING NOT NULL,   -- 'TEXT' (every page, free pypdf text layer), 'WINDOW' (AI parse
                                 -- around Item 8), 'TOC' (AI parse of pages 0-5; legacy locator)
    page_index INT NOT NULL,     -- zero based
    printed_page INT,            -- printed page number from the page footer/header, if found
    content STRING,
    scanned_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Grain: one AI_PARSE_DOCUMENT result per run. Key: run_id. Written by 08 (path B).
CREATE TABLE IF NOT EXISTS parse_results (
    run_id STRING NOT NULL,
    raw_result VARIANT,
    created_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Grain: one AI_EXTRACT result per run and method. Key: (run_id, method).
-- method is 'DIRECT_PDF' (path A) or 'PARSE_THEN_EXTRACT' (path B). Written by 08.
CREATE TABLE IF NOT EXISTS extraction_results (
    run_id STRING NOT NULL,
    method STRING NOT NULL,
    raw_result VARIANT,
    created_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Grain: one exploratory AI_EXTRACT per report. Key: relative_path. Written by 07.
CREATE TABLE IF NOT EXISTS extracted_values (
    extracted     OBJECT,
    relative_path STRING NOT NULL,
    ticker        STRING,
    report_year   INT,
    period_end    DATE,
    sec_accession STRING,
    extracted_at  TIMESTAMP_LTZ
);

-- Grain: one expected answer per synthetic PDF and metric. Key: (relative_path, metric_id).
-- Separate from SEC facts. Run 11.generate_synthetic_batch.py to populate 50 rows.
CREATE TABLE IF NOT EXISTS synthetic_ground_truth (
    relative_path STRING NOT NULL,
    ticker STRING,
    report_year INT,
    metric_id STRING NOT NULL,
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

-- =====================================================================================
-- CURATED (reviewed entities)
-- =====================================================================================

-- Grain: one row per staged annual-report PDF. Key: relative_path ('<TICKER>/<YEAR>.pdf').
-- Populated by 04 (period + accession) and 05 (page ranges + approval).
-- Fiscal year in a filename is a label, not a reliable XBRL period join key.
CREATE TABLE IF NOT EXISTS report_manifest (
    relative_path STRING NOT NULL,
    ticker STRING,
    report_year INT,
    period_start DATE,
    period_end DATE,
    sec_accession STRING,
    page_ranges ARRAY,           -- zero-based, end-exclusive [{start, end}]
    approved BOOLEAN DEFAULT FALSE,
    review_notes STRING,         -- AUTO-APPROVED / AUTO-REJECTED / HUMAN-REVIEWED evidence
    locator_method STRING        -- how 05 found the pages: TEXT+INDEX, TEXT, AI_FALLBACK,
                                 -- MANUAL_REVIEW, NOT_FOUND (NULL = located before this column)
);
ALTER TABLE report_manifest ADD COLUMN IF NOT EXISTS locator_method STRING;

-- Grain: one extraction run = one report in one 08 batch, with the exact questions asked.
-- Key: run_id. batch_id groups the runs created by one execution of 08.extract_reports.
-- Previous runs are kept so results stay comparable over time.
CREATE TABLE IF NOT EXISTS lab_runs (
    run_id STRING NOT NULL,
    batch_id STRING,
    relative_path STRING,
    ticker STRING,
    report_year INT,
    period_start DATE,
    period_end DATE,
    sec_accession STRING,
    page_ranges ARRAY,
    response_format VARIANT,
    prompt_version STRING,       -- SHA2 of the question template (fiscal dates masked): same wording = same version across years
    include_all_metrics BOOLEAN, -- the 08 setting: FALSE = starter 3 metrics, TRUE = every catalog metric
    metric_count INT,            -- how many metrics this run actually asked (e.g. 3 or 10)
    metric_ids ARRAY,            -- exactly which metrics, sorted; authoritative even if the catalog changes
    created_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Older schemas created lab_runs without the provenance columns: add them once and
-- backfill existing runs from their stored questions (response_format).
EXECUTE IMMEDIATE $$
DECLARE
    missing INT;
BEGIN
    SELECT COUNT(*) INTO :missing
    FROM (SELECT column1 AS c FROM VALUES ('PROMPT_VERSION'), ('INCLUDE_ALL_METRICS'), ('METRIC_COUNT'), ('METRIC_IDS')) want
    WHERE want.c NOT IN (SELECT column_name FROM information_schema.columns
                         WHERE table_schema = CURRENT_SCHEMA() AND table_name = 'LAB_RUNS');
    IF (missing > 0) THEN
        ALTER TABLE lab_runs ADD COLUMN IF NOT EXISTS prompt_version STRING;
        ALTER TABLE lab_runs ADD COLUMN IF NOT EXISTS include_all_metrics BOOLEAN;
        ALTER TABLE lab_runs ADD COLUMN IF NOT EXISTS metric_count INT;
        ALTER TABLE lab_runs ADD COLUMN IF NOT EXISTS metric_ids ARRAY;
    END IF;
    UPDATE lab_runs r
    SET prompt_version      = SHA2(REGEXP_REPLACE(TO_JSON(r.response_format), '[0-9]{4}-[0-9]{2}-[0-9]{2}', 'YYYY-MM-DD')),
        metric_ids          = m.metric_ids,
        metric_count        = ARRAY_SIZE(m.metric_ids),
        include_all_metrics = ARRAY_SIZE(m.metric_ids) = (SELECT COUNT(*) FROM metric_catalog)
    FROM (SELECT run_id,
                 ARRAY_SORT(ARRAY_AGG(DISTINCT SPLIT_PART(k.value::STRING, '__', 1))) AS metric_ids
          FROM lab_runs, LATERAL FLATTEN(INPUT => OBJECT_KEYS(response_format)) k
          GROUP BY run_id) m
    WHERE r.run_id = m.run_id AND r.prompt_version IS NULL;
    RETURN 'lab_runs provenance columns present';
END;
$$;

-- =====================================================================================
-- FUNCTIONS
-- =====================================================================================

-- Free text-layer pass used by 05: one row per PDF page (zero-based page_index) read with
-- pypdf from the Snowflake Anaconda channel. No AI charge (warehouse compute only).
-- Scanned PDFs have no text layer and return empty pages; 05 then falls back to AI.
CREATE OR REPLACE FUNCTION pdf_page_text(file_url STRING)
RETURNS TABLE (page_index INT, content STRING)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'pypdf==6.21.4')
HANDLER = 'PageText'
COMMENT = 'Free text-layer pass (no AI charge): one row per PDF page. Used by 05 to locate Item 8.'
AS $$
from pypdf import PdfReader
from snowflake.snowpark.files import SnowflakeFile

class PageText:
    def process(self, file_url):
        with SnowflakeFile.open(file_url, 'rb') as f:
            reader = PdfReader(f)
            for i, page in enumerate(reader.pages):
                try:
                    text = page.extract_text() or ''
                except Exception:
                    text = ''   # one unreadable page must not stop the report
                yield (i, text)
$$;

-- =====================================================================================
-- KEYS: add each declared constraint if it is missing (works for new and existing
-- schemas, so this file stays safe to re-run). Not enforced by Snowflake; tested in 10.
-- =====================================================================================
EXECUTE IMMEDIATE $$
DECLARE
    c CURSOR FOR
        SELECT k.name, k.ddl
        -- ordered: primary keys before the foreign keys that reference them
        FROM (SELECT column1 AS seq, column2 AS name, column3 AS ddl FROM VALUES
            ( 1, 'PK_LAB_SETTINGS',          'ALTER TABLE lab_settings ADD CONSTRAINT pk_lab_settings PRIMARY KEY (setting_id)'),
            ( 2, 'PK_METRIC_CATALOG',        'ALTER TABLE metric_catalog ADD CONSTRAINT pk_metric_catalog PRIMARY KEY (metric_id)'),
            ( 3, 'UQ_SEC_FACTS',             'ALTER TABLE sec_facts ADD CONSTRAINT uq_sec_facts UNIQUE (ticker, accession, concept, unit, start_date, end_date, form, fiscal_year, fiscal_period, frame)'),
            ( 4, 'PK_STATEMENT_PAGE_SCAN',   'ALTER TABLE statement_page_scan ADD CONSTRAINT pk_statement_page_scan PRIMARY KEY (relative_path, scan_type, page_index)'),
            ( 5, 'PK_EXTRACTED_VALUES',      'ALTER TABLE extracted_values ADD CONSTRAINT pk_extracted_values PRIMARY KEY (relative_path)'),
            ( 6, 'PK_SYNTHETIC_GROUND_TRUTH','ALTER TABLE synthetic_ground_truth ADD CONSTRAINT pk_synthetic_ground_truth PRIMARY KEY (relative_path, metric_id)'),
            ( 7, 'PK_REPORT_MANIFEST',       'ALTER TABLE report_manifest ADD CONSTRAINT pk_report_manifest PRIMARY KEY (relative_path)'),
            ( 8, 'PK_LAB_RUNS',              'ALTER TABLE lab_runs ADD CONSTRAINT pk_lab_runs PRIMARY KEY (run_id)'),
            ( 9, 'FK_LAB_RUNS_MANIFEST',     'ALTER TABLE lab_runs ADD CONSTRAINT fk_lab_runs_manifest FOREIGN KEY (relative_path) REFERENCES report_manifest (relative_path)'),
            (10, 'PK_PARSE_RESULTS',         'ALTER TABLE parse_results ADD CONSTRAINT pk_parse_results PRIMARY KEY (run_id)'),
            (11, 'FK_PARSE_RESULTS_RUN',     'ALTER TABLE parse_results ADD CONSTRAINT fk_parse_results_run FOREIGN KEY (run_id) REFERENCES lab_runs (run_id)'),
            (12, 'PK_EXTRACTION_RESULTS',    'ALTER TABLE extraction_results ADD CONSTRAINT pk_extraction_results PRIMARY KEY (run_id, method)'),
            (13, 'FK_EXTRACTION_RESULTS_RUN','ALTER TABLE extraction_results ADD CONSTRAINT fk_extraction_results_run FOREIGN KEY (run_id) REFERENCES lab_runs (run_id)'),
            (14, 'PK_STATEMENT_HEADING_PATTERNS', 'ALTER TABLE statement_heading_patterns ADD CONSTRAINT pk_statement_heading_patterns PRIMARY KEY (statement_type, pattern)')
        ) k
        WHERE k.name NOT IN (SELECT constraint_name FROM information_schema.table_constraints
                             WHERE constraint_schema = CURRENT_SCHEMA())
        ORDER BY k.seq;
    added INT DEFAULT 0;
BEGIN
    FOR rec IN c DO
        EXECUTE IMMEDIATE rec.ddl;
        added := added + 1;
    END FOR;
    RETURN 'constraints added: ' || added;
END;
$$;

-- =====================================================================================
-- DOCUMENTATION: layer + grain on each table (visible in Snowsight > table details).
-- =====================================================================================
COMMENT ON TABLE lab_settings IS 'CONFIG. Grain: exactly one row (setting_id = 1): ticker + year range every step processes, plus page-locator limits. Set in python/00.set_session_variables.ipynb.';
COMMENT ON TABLE statement_heading_patterns IS 'CONFIG. Grain: one heading wording per statement type. Key: statement_type, pattern. Read by 05.';
COMMENT ON TABLE metric_catalog IS 'CONFIG. Grain: one row per extractable metric. Key: metric_id.';
COMMENT ON TABLE sec_facts IS 'RAW. Grain: one SEC XBRL observation (concept, unit, period, filing). Unique key: ticker, accession, concept, unit, start_date, end_date, form, fiscal_year, fiscal_period, frame. Loaded by 03.';
COMMENT ON TABLE ingest_log IS 'RAW. Grain: one download/load attempt (event log, no natural key). Written by 02 and 03.';
COMMENT ON TABLE statement_page_scan IS 'RAW. Grain: one parsed PDF page used to locate statements. Key: relative_path, scan_type, page_index. Written by 05.';
COMMENT ON TABLE parse_results IS 'RAW. Grain: one AI_PARSE_DOCUMENT result per run. Key: run_id. Written by 08.';
COMMENT ON TABLE extraction_results IS 'RAW. Grain: one AI_EXTRACT result per run and method. Key: run_id, method. Written by 08.';
COMMENT ON TABLE extracted_values IS 'RAW. Grain: one exploratory AI_EXTRACT per report. Key: relative_path. Written by 07.';
COMMENT ON TABLE synthetic_ground_truth IS 'RAW. Grain: one expected answer per synthetic PDF and metric. Key: relative_path, metric_id. Written by 11.';
COMMENT ON TABLE report_manifest IS 'CURATED. Grain: one row per staged annual-report PDF. Key: relative_path. Written by 04 (period, accession) and 05 (pages, approval).';
COMMENT ON TABLE lab_runs IS 'CURATED. Grain: one extraction run = one report in one 08 batch. Key: run_id. Provenance: prompt_version (hash of the exact questions), include_all_metrics, metric_count, metric_ids. Written by 08.';
