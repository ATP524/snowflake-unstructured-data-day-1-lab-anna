USE ROLE all_users_role;
USE DATABASE bootcamp;
USE WAREHOUSE compute_wh;
USE SCHEMA atp524;

-- Step 05: find the consolidated statement pages of EVERY unapproved report in the
-- scope (lab_settings: ticker + year range, set in python/00.set_session_variables.ipynb)
-- while paying AI only for a narrow window:
--   1. TEXT pass (free): read every page's text layer with pdf_page_text (pypdf, see 01)
--   2. LOCATE: find the "Item 8. Financial Statements and Supplementary Data" page from the
--      text, and cross-check it with the report's index, if it has one:
--        TEXT+INDEX     heading found and the index agrees (within 2 pages)   e.g. AAPL, TSLA
--        TEXT           heading found, the report has no index                e.g. MSFT
--        MANUAL_REVIEW  heading and index disagree: not parsed, a person decides
--        AI_FALLBACK    no text layer (scanned PDF): AI parses pages 0..ai_fallback_page_cap
--        NOT_FOUND      text exists but no heading matched: add its wording to
--                       statement_heading_patterns (01) and re-run
--   3. WINDOW (AI): AI_PARSE_DOCUMENT on 15 pages from the Item 8 page
--   4. propose page_ranges from statement headings at the top of the AI-parsed pages
--   5. write every result to report_manifest (AUTO-APPROVED or AUTO-REJECTED)
-- A report is never skipped silently: whatever is not found is named in review_notes.
-- Approved reports are never changed.
-- Inputs:  lab_settings (scope + limits), statement_heading_patterns, report_manifest (04),
--          PDFs on @annual_report_pdfs.
-- Outputs: statement_page_scan (TEXT and WINDOW pages), report_manifest.page_ranges /
--          approved / review_notes / locator_method.
-- Page indexes are zero based; range end is exclusive (same as FL_FILTER_PAGES).
-- Verified: AAPL 2021-2025 (same ranges as before), MSFT 2023-2024 [43,49) via TEXT,
-- TSLA 2023 [49,56) and 2024 [50,57) via TEXT+INDEX.
-- Stored pages are never read or parsed (or paid for) twice.
-- Cost: 15 AI-parsed pages per new report (AI_FALLBACK: up to ai_fallback_page_cap).
-- Run after 04.prepare_manifest.sql; next is 06.check_readiness.sql.

-- The reports this run will work on: unapproved, in scope.
CREATE OR REPLACE TEMPORARY TABLE locate_targets AS
SELECT m.relative_path
FROM report_manifest m
JOIN lab_settings s
  ON m.ticker = s.ticker AND m.report_year BETWEEN s.first_year AND s.last_year
WHERE NOT COALESCE(m.approved, FALSE);

SELECT * FROM locate_targets ORDER BY relative_path;

-- Step 1 (free): store every page's text layer, once per report. Runs of spaces/tabs are
-- collapsed (some PDFs put a tab between every word). printed_page is the page number
-- printed on the page: an AAPL-style "10-K | 2" footer, else a number alone on the last
-- line, else a number starting the page (MSFT). Step 2 only trusts it when pages agree.
INSERT INTO statement_page_scan (relative_path, scan_type, page_index, printed_page, content)
WITH pages AS (
    SELECT t.relative_path, x.page_index, REGEXP_REPLACE(x.content, '[ \\t]+', ' ') AS content
    FROM locate_targets t,
         TABLE(pdf_page_text(BUILD_SCOPED_FILE_URL(@annual_report_pdfs, t.relative_path))) x
    WHERE NOT EXISTS (SELECT 1 FROM statement_page_scan p
                      WHERE p.relative_path = t.relative_path AND p.scan_type = 'TEXT')
)
SELECT relative_path, 'TEXT', page_index,
       COALESCE(TRY_TO_NUMBER(REGEXP_SUBSTR(content, '10-K\\s*\\|\\s*([0-9]{1,3})', 1, 1, 'e', 1)),
                TRY_TO_NUMBER(REGEXP_SUBSTR(content, '\\n\\s*([0-9]{1,3})\\s*$', 1, 1, 'e', 1)),
                TRY_TO_NUMBER(REGEXP_SUBSTR(content, '^\\s*([0-9]{1,3})\\s', 1, 1, 'e', 1))),
       content
FROM pages;

-- Step 2 (free): decide each report's window from the text.
CREATE OR REPLACE TEMPORARY TABLE locate_windows AS
WITH txt AS (
    SELECT p.relative_path, p.page_index, p.printed_page,
           REGEXP_REPLACE(p.content, '\\s+', ' ') AS flat,
           -- the 10-K index lists every Item; a real Item 8 heading page does not
           REGEXP_COUNT(p.content, 'Item\\s*[0-9]+[A-C]?\\.', 1, 'i') >= 6 AS is_index_page
    FROM statement_page_scan p
    JOIN locate_targets t ON t.relative_path = p.relative_path
    WHERE p.scan_type = 'TEXT'
), text_layer AS (
    SELECT relative_path, AVG(LENGTH(flat)) >= 50 AS has_text
    FROM txt GROUP BY relative_path
), heads AS (
    -- statement headings only count at the TOP of a page (skips cross-references)
    SELECT t.relative_path, t.page_index, t.is_index_page, h.statement_type
    FROM txt t
    JOIN statement_heading_patterns h ON LEFT(t.flat, 200) ILIKE h.pattern
), item8 AS (
    -- the first Item 8 heading page that is not the index and is followed (within 5
    -- pages) by a real statement heading
    SELECT a.relative_path, MIN(a.page_index) AS item8_page
    FROM heads a
    WHERE a.statement_type = 'item8_heading' AND NOT a.is_index_page
      AND EXISTS (SELECT 1 FROM heads s
                  WHERE s.relative_path = a.relative_path
                    AND s.statement_type IN ('operations', 'comprehensive', 'balance_sheet', 'equity', 'cash_flows')
                    AND s.page_index BETWEEN a.page_index AND a.page_index + 5)
    GROUP BY a.relative_path
), idx AS (
    -- the index line "Financial Statements and Supplementary Data [|] <printed page>"
    SELECT relative_path,
           TRY_TO_NUMBER(REGEXP_SUBSTR(flat, 'Financial Statements and Supplementary Data\\s*\\|?\\s*([0-9]{1,3})', 1, 1, 'ie', 1)) AS index_printed
    FROM txt
    WHERE is_index_page
      AND REGEXP_SUBSTR(flat, 'Financial Statements and Supplementary Data\\s*\\|?\\s*([0-9]{1,3})', 1, 1, 'ie', 1) IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY relative_path ORDER BY page_index) = 1
), offsets AS (
    -- printed page -> PDF page offset, measured only on pages printed within 10 of the
    -- index's page (numbering can shift mid-report, e.g. an unnumbered extra page) and
    -- accepted only when at least 3 of those pages agree
    SELECT t.relative_path, t.page_index - t.printed_page AS page_offset, COUNT(*) AS agreeing_pages
    FROM txt t
    JOIN idx ON idx.relative_path = t.relative_path
    WHERE t.printed_page BETWEEN idx.index_printed - 10 AND idx.index_printed + 10
    GROUP BY t.relative_path, page_offset
    QUALIFY ROW_NUMBER() OVER (PARTITION BY t.relative_path ORDER BY agreeing_pages DESC, page_offset) = 1
)
SELECT t.relative_path,
       i8.item8_page,
       idx.index_printed,
       IFF(o.agreeing_pages >= 3, o.page_offset, NULL) AS page_offset,
       idx.index_printed + IFF(o.agreeing_pages >= 3, o.page_offset, NULL) AS index_pdf_page,
       CASE
           WHEN NOT COALESCE(tl.has_text, FALSE)                       THEN 'AI_FALLBACK'
           WHEN i8.item8_page IS NULL                                  THEN 'NOT_FOUND'
           WHEN index_pdf_page IS NULL                                 THEN 'TEXT'
           WHEN ABS(index_pdf_page - i8.item8_page) <= 2               THEN 'TEXT+INDEX'
           ELSE 'MANUAL_REVIEW'
       END AS locator_method,
       CASE locator_method
           WHEN 'AI_FALLBACK' THEN 0
           WHEN 'TEXT'        THEN i8.item8_page
           WHEN 'TEXT+INDEX'  THEN i8.item8_page
       END AS window_start,                                -- NULL = nothing to parse
       IFF(locator_method = 'AI_FALLBACK', s.ai_fallback_page_cap, 15) AS window_pages
FROM locate_targets t
CROSS JOIN lab_settings s
LEFT JOIN text_layer tl ON tl.relative_path = t.relative_path
LEFT JOIN item8 i8      ON i8.relative_path = t.relative_path
LEFT JOIN offsets o     ON o.relative_path = t.relative_path
LEFT JOIN idx           ON idx.relative_path = t.relative_path;

SELECT relative_path, locator_method, item8_page, index_printed, page_offset, index_pdf_page,
       window_start, window_start + window_pages AS window_end_exclusive
FROM locate_windows ORDER BY relative_path;

-- Step 3 (AI): parse each report's window (only if not yet parsed).
INSERT INTO statement_page_scan (relative_path, scan_type, page_index, printed_page, content)
WITH parsed AS (
    SELECT w.relative_path,
           AI_PARSE_DOCUMENT(
               TO_FILE('@annual_report_pdfs', w.relative_path),
               OBJECT_CONSTRUCT('mode', 'LAYOUT', 'page_split', TRUE,
                                'page_filter', ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(
                                    'start', w.window_start, 'end', w.window_start + w.window_pages)))) AS doc
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

-- Step 4: propose page_ranges and a descriptive review note for every target, from the
-- AI-parsed WINDOW pages. Headings come from statement_heading_patterns and count only at
-- the TOP of a page (first 200 characters). The Item 8 index page lists every heading,
-- so it is excluded. The range ends after the first notes page (Note 1 holds the
-- accounting policies and fiscal-calendar note).
CREATE OR REPLACE TEMPORARY TABLE page_range_proposal AS
WITH pages AS (
    SELECT p.relative_path, p.page_index, LEFT(p.content, 200) AS head
    FROM statement_page_scan p
    JOIN locate_windows w ON w.relative_path = p.relative_path
    WHERE p.scan_type = 'WINDOW'
      AND NOT EXISTS (SELECT 1 FROM statement_heading_patterns x
                      WHERE x.statement_type = 'index_page' AND LEFT(p.content, 300) ILIKE x.pattern)
), found AS (
    SELECT p.relative_path,
           MIN(IFF(h.statement_type = 'operations',    p.page_index, NULL)) AS operations,
           MIN(IFF(h.statement_type = 'comprehensive', p.page_index, NULL)) AS comprehensive,
           MIN(IFF(h.statement_type = 'balance_sheet', p.page_index, NULL)) AS balance_sheet,
           MIN(IFF(h.statement_type = 'equity',        p.page_index, NULL)) AS equity,
           MIN(IFF(h.statement_type = 'cash_flows',    p.page_index, NULL)) AS cash_flows,
           MIN(IFF(h.statement_type = 'first_notes',   p.page_index, NULL)) AS first_notes
    FROM pages p
    JOIN statement_heading_patterns h ON p.head ILIKE h.pattern
    GROUP BY p.relative_path
)
SELECT w.relative_path, w.locator_method,
       f.operations, f.comprehensive, f.balance_sheet, f.equity, f.cash_flows, f.first_notes,
       LEAST(f.operations, f.comprehensive, f.balance_sheet, f.equity, f.cash_flows) AS range_start,
       f.first_notes + 1 AS range_end,
       COALESCE(w.locator_method IN ('TEXT+INDEX', 'TEXT', 'AI_FALLBACK')
           AND f.operations IS NOT NULL AND f.comprehensive IS NOT NULL AND f.balance_sheet IS NOT NULL
           AND f.equity IS NOT NULL AND f.cash_flows IS NOT NULL AND f.first_notes IS NOT NULL
           AND range_end > range_start AND range_end - range_start <= s.max_statement_pages, FALSE) AS passes_rules,
       IFF(passes_rules,
           ARRAY_CONSTRUCT(OBJECT_CONSTRUCT('start', range_start, 'end', range_end)),
           NULL) AS proposed_page_ranges,
       IFF(passes_rules, 'AUTO-APPROVED ', 'AUTO-REJECTED ') || TO_CHAR(CURRENT_DATE(), 'YYYY-MM-DD')
       || ': locator ' || w.locator_method
       || CASE w.locator_method
              WHEN 'MANUAL_REVIEW' THEN ' (heading and index disagree; check both pages, then use the manual override in 04)'
              WHEN 'NOT_FOUND'     THEN ' (no Item 8 heading in the text; add its wording to statement_heading_patterns in 01)'
              WHEN 'AI_FALLBACK'   THEN ' (no text layer; AI parsed pages 0-' || w.window_pages || ')'
              ELSE '' END
       || '. Item 8 heading p.' || COALESCE(w.item8_page::STRING, 'NOT FOUND')
       || ', index "Financial Statements" printed p.' || COALESCE(w.index_printed::STRING, 'NOT FOUND')
       || ' -> p.' || COALESCE(w.index_pdf_page::STRING, 'NOT FOUND')
       || ' (offset ' || COALESCE(w.page_offset::STRING, 'NOT FOUND') || '). Headings: '
       || 'Operations p.' || COALESCE(f.operations::STRING, 'NOT FOUND')
       || ', Comprehensive Income p.' || COALESCE(f.comprehensive::STRING, 'NOT FOUND')
       || ', Balance Sheets p.' || COALESCE(f.balance_sheet::STRING, 'NOT FOUND')
       || ', Equity p.' || COALESCE(f.equity::STRING, 'NOT FOUND')
       || ', Cash Flows p.' || COALESCE(f.cash_flows::STRING, 'NOT FOUND')
       || ', first Notes p.' || COALESCE(f.first_notes::STRING, 'NOT FOUND')
       || '. Range [' || COALESCE(range_start::STRING, '?') || ',' || COALESCE(range_end::STRING, '?') || ').'
       AS proposed_review_notes
FROM locate_windows w
CROSS JOIN lab_settings s
LEFT JOIN found f ON f.relative_path = w.relative_path;

SELECT * FROM page_range_proposal ORDER BY relative_path;

-- Step 5: write every result to report_manifest. Approved rows (by a person or an
-- earlier run) are never changed. A rejected report keeps approved = FALSE and gets
-- a note listing what was NOT FOUND; fix it with the manual override in
-- 04.prepare_manifest.sql.
UPDATE report_manifest t
SET page_ranges    = IFF(p.passes_rules, p.proposed_page_ranges, t.page_ranges),
    approved       = p.passes_rules,
    review_notes   = p.proposed_review_notes,
    locator_method = p.locator_method
FROM page_range_proposal p
WHERE t.relative_path = p.relative_path
  AND NOT COALESCE(t.approved, FALSE);

SELECT m.relative_path, m.page_ranges, m.approved, m.locator_method, m.review_notes
FROM report_manifest m
JOIN lab_settings s
  ON m.ticker = s.ticker AND m.report_year BETWEEN s.first_year AND s.last_year
ORDER BY m.report_year;
-- Next: 06.check_readiness.sql.
