# Lab results exported 2026-11-20

Contains: 3 companies (AAPL, MSFT, TSLA), 9 annual reports, 16 extraction runs in 6 batches, 20 staged PDFs.  
Next run is set to: AAPL 2021-2025 (`lab_settings`; change it in step 00). This does not filter anything below.

## 1. Every annual report: status and latest result

Each report's most recent extraction run. Scores are metrics passing SEC ground truth / metrics asked.

| Ticker | Year | Pages | Located by | Status | Latest run | Metrics | Direct PDF | Parse then extract |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| AAPL | 2021 | [31, 37) | before locator_method | Evaluated | 2026-11-20 | 10 | 10/10 | 10/10 |
| AAPL | 2022 | [31, 37) | before locator_method | Evaluated | 2026-11-20 | 10 | 10/10 | 10/10 |
| AAPL | 2023 | [30, 36) | before locator_method | Evaluated | 2026-11-20 | 10 | 10/10 | 10/10 |
| AAPL | 2024 | [31, 37) | before locator_method | Evaluated | 2026-11-20 | 10 | 10/10 | 10/10 |
| AAPL | 2025 | [31, 37) | before locator_method | Evaluated | 2026-11-20 | 10 | 10/10 | 10/10 |
| MSFT | 2023 | [43, 49) | TEXT | Evaluated | 2026-11-20 | 3 | 3/3 | 3/3 |
| MSFT | 2024 | [43, 49) | TEXT | Evaluated | 2026-11-20 | 3 | 3/3 | 3/3 |
| TSLA | 2023 | [49, 56) | TEXT+INDEX | Evaluated | 2026-11-20 | 3 | 3/3 | 3/3 |
| TSLA | 2024 | [50, 57) | TEXT+INDEX | Evaluated | 2026-11-20 | 3 | 3/3 | 3/3 |

## 2. Not passing (latest runs only)

Every metric in every report's latest run passed.

## 3. Run history (one row per 08 batch, oldest first)

Includes earlier runs that section 1 replaces with a newer run (e.g. the 3-metric AAPL runs).

| Started | Batch | Companies | Reports | Metrics | Passed / expected |
| --- | --- | --- | --- | --- | --- |
| 2026-11-19 04:50 | `f950be90` | AAPL | 1 | 3 | 6/6 |
| 2026-11-20 05:43 | `49f07337` | AAPL | 5 | 3 | 30/30 |
| 2026-11-20 06:42 | `ced247f5` | AAPL | 5 | 10 | 100/100 |
| 2026-11-20 08:16 | `5bc0b1bc` | MSFT | 2 | 3 | 12/12 |
| 2026-11-20 08:20 | `9a4b7cb1` | TSLA | 2 | 3 | 11/12 |
| 2026-11-20 09:09 | `baafd8e4` | TSLA | 1 | 3 | 6/6 |

## 4. Files in this export

| File | Rows |
| --- | --- |
| lab_settings.csv | 1 |
| metric_catalog.csv | 10 |
| statement_heading_patterns.csv | 15 |
| sec_facts.csv | 357 |
| ingest_log.csv | 30 |
| statement_page_scan.csv | 1070 |
| parse_results.csv | 16 |
| extraction_results.csv | 32 |
| extracted_values.csv | 9 |
| synthetic_ground_truth.csv | 50 |
| report_manifest.csv | 9 |
| lab_runs.csv | 16 |
| report_readiness.csv | 5 |
| pipeline_coverage.csv | 5 |
| metric_evaluation.csv | 166 |
| pdfs/ | 20 files (sizes verified against the stage) |

Data-quality checks: run sql/10.validation.sql (or the runner's step 10 cell) on the live schema.
