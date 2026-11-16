-- Run after ddls.sql and load_starter(session).
-- This exploratory call is separate from the persisted benchmark.
-- Zero-based pages 30 through 35 contain statements and the fiscal-calendar note.
SELECT AI_EXTRACT(
    file => FL_FILTER_PAGES(
        TO_FILE('@annual_report_pdfs', 'AAPL/2023.pdf'),
        [{'start': 30, 'end': 36}]
    ),
    responseFormat => {
        'assets': 'What are total consolidated assets as of September 30, 2023? Return the printed value, currency, and table scale.',
        'revenue': 'What is total consolidated net sales for the fiscal year ended September 30, 2023? Return the printed value, currency, and table scale. Ignore product-only or services-only sales.',
        'eps_diluted': 'What is diluted earnings per share for the fiscal year ended September 30, 2023? Return the printed per-share amount and currency. Do not multiply by millions.'
    }
) AS extracted;

-- Reference values from the pinned SEC response, in base units.
SELECT concept, unit, fact_value, start_date, end_date, accession
FROM sec_facts
WHERE accession = '0000320193-23-000106'
  AND concept IN ('Assets',
      'RevenueFromContractWithCustomerExcludingAssessedTax', 'EarningsPerShareDiluted')
ORDER BY concept;

-- Discuss:
-- 1. Why does 352,583 in the PDF compare to 352,583,000,000 in SEC facts?
-- 2. Why does diluted EPS stay 6.13?
-- 3. Why is Apple's fiscal year different from a calendar year?
-- Next: run extract_reports.sql (defaults to these three metrics), then
-- evaluate_results.sql for the persisted two-path comparison.
