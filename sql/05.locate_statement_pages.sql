USE ROLE all_users_role;
USE DATABASE bootcamp;
USE WAREHOUSE compute_wh;
USE SCHEMA atp524;

-- Step 05: find the consolidated statement pages of EVERY unapproved report in the
-- scope (lab_settings: ticker + year range, set in python/00.set_session_variables.ipynb)
-- without parsing whole PDFs:
--   1. parse PDF pages 0-5 of each report and read its table-of-contents line for "Financial Statements"
--   2. derive each report's printed-page -> PDF-index offset from footers such as "Apple Inc. | 2023 Form 10-K | 2"
--   3. parse a 15-page window around each report's predicted start of Item 8
--   4. propose page_ranges + a descriptive review note per report
--   5. write every result to report_manifest (AUTO-APPROVED or AUTO-REJECTED)
-- A report is never skipped silently: if any step finds nothing, it is AUTO-REJECTED
-- with the missing items named. Approved reports are never changed.
-- Page indexes are zero based; range end is exclusive (same as FL_FILTER_PAGES).
-- Tested on AAPL/2023.pdf: proposes [30, 36), matching fixtures/starter_manifest.json.
-- Parsed pages are stored, so re-running never parses (or pays for) the same pages twice.
-- Cost: about 21 parsed pages per new report. Run after 04.prepare_manifest.sql;
-- next is 06.check_readiness.sql.

-- The reports this run will work on: unapproved, in scope.
CREATE OR REPLACE TEMPORARY TABLE locate_targets AS
SELECT m.relative_path
FROM report_manifest m
JOIN lab_settings s
  ON m.ticker = s.ticker AND m.report_year BETWEEN s.first_year AND s.last_year
WHERE NOT COALESCE(m.approved, FALSE);

SELECT * FROM locate_targets ORDER BY relative_path;

-- Step 1: parse the first six pages (cover + table of contents) of each target not yet scanned.
INSERT INTO statement_page_scan (relative_path, scan_type, page_index, printed_page, content)
WITH parsed AS (
    SELECT t.relative_path,
           AI_PARSE_DOCUMENT(
               TO_FILE('@annual_report_pdfs', t.relative_path),
               {'mode': 'LAYOUT', 'page_split': TRUE, 'page_filter': [{'start': 0, 'end': 6}]}) AS doc
    FROM locate_targets t
    WHERE NOT EXISTS (SELECT 1 FROM statement_page_scan p
                      WHERE p.relative_path = t.relative_path AND p.scan_type = 'TOC')
)
SELECT p.relative_path, 'TOC', f.value:index::INT,
       TRY_TO_NUMBER(REGEXP_SUBSTR(f.value:content::STRING, '10-K\\s*\\|\\s*([0-9]+)', 1, 1, 'e', 1)),
       f.value:content::STRING
FROM parsed p,
LATERAL FLATTEN(INPUT => p.doc:pages) f;

-- Step 2: per report, the printed page of Item 8 from the TOC and the most common
-- footer offset, giving the window to parse. NULLs mean the TOC or footers were not
-- found; that report is AUTO-REJECTED in step 4 instead of being parsed further.
CREATE OR REPLACE TEMPORARY TABLE locate_windows AS
WITH toc AS (
    SELECT relative_path,
           TRY_TO_NUMBER(REGEXP_SUBSTR(content,
               'Financial Statements[^|\\n]*\\|\\s*([0-9]+)', 1, 1, 'ie', 1)) AS toc_item8_printed
    FROM statement_page_scan
    WHERE scan_type = 'TOC'
      -- the cover page also says "financial statements"; require a page number after it
      AND REGEXP_SUBSTR(content, 'Financial Statements[^|\\n]*\\|\\s*([0-9]+)', 1, 1, 'ie', 1) IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY relative_path ORDER BY page_index) = 1
), footer_offset AS (
    SELECT relative_path, MODE(page_index - printed_page) AS page_offset
    FROM statement_page_scan
    WHERE printed_page IS NOT NULL
    GROUP BY relative_path
)
SELECT t.relative_path, toc.toc_item8_printed, o.page_offset,
       GREATEST(toc.toc_item8_printed + o.page_offset - 1, 0) AS window_start
FROM locate_targets t
LEFT JOIN toc ON toc.relative_path = t.relative_path
LEFT JOIN footer_offset o ON o.relative_path = t.relative_path;

SELECT relative_path, toc_item8_printed, page_offset, window_start,
       window_start + 15 AS window_end_exclusive
FROM locate_windows ORDER BY relative_path;

-- Step 3: parse each report's 15-page window around Item 8 (only if not yet scanned).
INSERT INTO statement_page_scan (relative_path, scan_type, page_index, printed_page, content)
WITH parsed AS (
    SELECT w.relative_path,
           AI_PARSE_DOCUMENT(
               TO_FILE('@annual_report_pdfs', w.relative_path),
               OBJECT_CONSTRUCT('mode', 'LAYOUT', 'page_split', TRUE,
                                'page_filter', ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(
                                    'start', w.window_start, 'end', w.window_start + 15)))) AS doc
    FROM locate_windows w
    WHERE w.window_start IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM statement_page_scan p
                      WHERE p.relative_path = w.relative_path AND p.scan_type = 'WINDOW')
)
SELECT p.relative_path, 'WINDOW', f.value:index::INT,
       TRY_TO_NUMBER(REGEXP_SUBSTR(f.value:content::STRING, '10-K\\s*\\|\\s*([0-9]+)', 1, 1, 'e', 1)),
       f.value:content::STRING
FROM parsed p,
LATERAL FLATTEN(INPUT => p.doc:pages) f;

-- Step 4: propose page_ranges and a descriptive review note for every target.
-- A heading counts only at the TOP of a page (first 200 characters), which skips
-- cross-references inside the notes. The Item 8 index page lists every heading,
-- so it is excluded. The range ends after the first notes page (Note 1 holds the
-- accounting policies and fiscal-calendar note).
CREATE OR REPLACE TEMPORARY TABLE page_range_proposal AS
WITH pages AS (
    SELECT relative_path, page_index, LEFT(content, 200) AS head
    FROM statement_page_scan
    WHERE scan_type = 'WINDOW'
      AND LEFT(content, 300) NOT ILIKE '%Index to Consolidated Financial Statements%'
), found AS (
    SELECT relative_path,
           MIN(IFF(head ILIKE '%CONSOLIDATED STATEMENTS OF OPERATIONS%', page_index, NULL))           AS operations,
           MIN(IFF(head ILIKE '%CONSOLIDATED STATEMENTS OF COMPREHENSIVE INCOME%', page_index, NULL)) AS comprehensive,
           MIN(IFF(head ILIKE '%CONSOLIDATED BALANCE SHEETS%', page_index, NULL))                     AS balance_sheet,
           MIN(IFF(head ILIKE '%CONSOLIDATED STATEMENTS OF SHAREHOLDERS%', page_index, NULL))         AS equity,
           MIN(IFF(head ILIKE '%CONSOLIDATED STATEMENTS OF CASH FLOWS%', page_index, NULL))           AS cash_flows,
           MIN(IFF(head ILIKE '%Notes to Consolidated Financial Statements%', page_index, NULL))      AS first_notes
    FROM pages
    GROUP BY relative_path
)
SELECT w.relative_path,
       f.operations, f.comprehensive, f.balance_sheet, f.equity, f.cash_flows, f.first_notes,
       LEAST(f.operations, f.comprehensive, f.balance_sheet, f.equity, f.cash_flows) AS range_start,
       f.first_notes + 1 AS range_end,
       COALESCE(f.operations IS NOT NULL AND f.comprehensive IS NOT NULL AND f.balance_sheet IS NOT NULL
           AND f.equity IS NOT NULL AND f.cash_flows IS NOT NULL AND f.first_notes IS NOT NULL
           AND range_end - range_start <= 10, FALSE) AS passes_rules,
       IFF(passes_rules,
           ARRAY_CONSTRUCT(OBJECT_CONSTRUCT('start', range_start, 'end', range_end)),
           NULL) AS proposed_page_ranges,
       IFF(passes_rules, 'AUTO-APPROVED ', 'AUTO-REJECTED ') || TO_CHAR(CURRENT_DATE(), 'YYYY-MM-DD')
       || ': TOC "Financial Statements" -> printed p.' || COALESCE(w.toc_item8_printed::STRING, 'NOT FOUND')
       || ', offset +' || COALESCE(w.page_offset::STRING, 'NOT FOUND') || ' (footers). Headings: '
       || 'Operations p.' || COALESCE(f.operations::STRING, 'NOT FOUND')
       || ', Comprehensive Income p.' || COALESCE(f.comprehensive::STRING, 'NOT FOUND')
       || ', Balance Sheets p.' || COALESCE(f.balance_sheet::STRING, 'NOT FOUND')
       || ', Shareholders'' Equity p.' || COALESCE(f.equity::STRING, 'NOT FOUND')
       || ', Cash Flows p.' || COALESCE(f.cash_flows::STRING, 'NOT FOUND')
       || ', first Notes p.' || COALESCE(f.first_notes::STRING, 'NOT FOUND')
       || '. Range [' || COALESCE(range_start::STRING, '?') || ',' || COALESCE(range_end::STRING, '?') || ').'
       AS proposed_review_notes
FROM locate_windows w
LEFT JOIN found f ON f.relative_path = w.relative_path;

SELECT * FROM page_range_proposal ORDER BY relative_path;

-- Step 5: write every result to report_manifest. Approved rows (by a person or an
-- earlier run) are never changed. A rejected report keeps approved = FALSE and gets
-- a note listing what was NOT FOUND; fix it with the manual override in
-- 04.prepare_manifest.sql.
UPDATE report_manifest t
SET page_ranges  = IFF(p.passes_rules, p.proposed_page_ranges, t.page_ranges),
    approved     = p.passes_rules,
    review_notes = p.proposed_review_notes
FROM page_range_proposal p
WHERE t.relative_path = p.relative_path
  AND NOT COALESCE(t.approved, FALSE);

SELECT m.relative_path, m.page_ranges, m.approved, m.review_notes
FROM report_manifest m
JOIN lab_settings s
  ON m.ticker = s.ticker AND m.report_year BETWEEN s.first_year AND s.last_year
ORDER BY m.report_year;
-- Next: 06.check_readiness.sql.
