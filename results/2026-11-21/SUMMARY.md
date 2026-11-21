# Lab results exported 2026-11-21

Contains: 3 companies (AAPL, MSFT, TSLA), 15 ticker-years (14 evaluated, 1 not complete), 30 extraction runs in 12 batches, 25 staged files.  
Next run is set to: AAPL 2021-2025, 3 metrics (starter set) (`lab_settings`; change it in step 00). This does not filter anything below.

## 1. Every annual report: status and latest result

One row per ticker-year the lab has touched (`report_status`). Scores are metrics passing SEC ground truth / metrics asked, for each report's most recent run. Ground truth = catalog metrics with an SEC value in the report's own 10-K.

| Ticker | Year | Status | Pages | Located by | Ground truth | Latest run | Metrics | Direct PDF | Parse then extract |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| AAPL | 2021 | Evaluated | [31, 37) | TEXT+INDEX | 10/10 | 2026-11-20 | 10 | 10/10 | 10/10 |
| AAPL | 2022 | Evaluated | [31, 37) | TEXT+INDEX | 10/10 | 2026-11-20 | 10 | 10/10 | 10/10 |
| AAPL | 2023 | Evaluated | [30, 36) | TEXT+INDEX | 10/10 | 2026-11-20 | 10 | 10/10 | 10/10 |
| AAPL | 2024 | Evaluated | [31, 37) | TEXT+INDEX | 10/10 | 2026-11-20 | 10 | 10/10 | 10/10 |
| AAPL | 2025 | Evaluated | [31, 37) | TEXT+INDEX | 10/10 | 2026-11-20 | 10 | 10/10 | 10/10 |
| MSFT | 2021 | Evaluated | [47, 53) | TEXT | 10/10 | 2026-11-20 | 10 | 10/10 | 10/10 |
| MSFT | 2022 | Evaluated | [48, 54) | TEXT | 10/10 | 2026-11-20 | 10 | 10/10 | 10/10 |
| MSFT | 2023 | Evaluated | [43, 49) | TEXT | 10/10 | 2026-11-20 | 10 | 10/10 | 10/10 |
| MSFT | 2024 | Evaluated | [43, 49) | TEXT | 10/10 | 2026-11-20 | 10 | 10/10 | 10/10 |
| MSFT | 2025 | Evaluated | [39, 45) | TEXT | 10/10 | 2026-11-20 | 10 | 10/10 | 10/10 |
| TSLA | 2021 | Stopped at 02 | - | - | - | - | - | - | - |
| TSLA | 2022 | Evaluated | [47, 53) | TEXT+INDEX | 10/10 (revenue via Revenues) | 2026-11-21 | 10 | 10/10 | 10/10 |
| TSLA | 2023 | Evaluated | [49, 56) | TEXT+INDEX | 10/10 | 2026-11-20 | 10 | 10/10 | 10/10 |
| TSLA | 2024 | Evaluated | [50, 57) | TEXT+INDEX | 10/10 | 2026-11-20 | 10 | 10/10 | 10/10 |
| TSLA | 2025 | Evaluated | [51, 57) | TEXT+INDEX | 10/10 | 2026-11-20 | 10 | 10/10 | 10/10 |

## 2. Not complete (what each needs next)

| Ticker | Year | Status | Next step |
| --- | --- | --- | --- |
| TSLA | 2021 | Stopped at 02 | 02 PDF not found (No valid PDF found at tested URLs) |

## 3. Not passing (latest runs only)

Every metric in every report's latest run passed.

## 4. Method comparison (latest runs)

From `method_comparison`: each report's latest run, by company and overall. Confidence is the model's own `value_score` for the printed number; low confidence = below 0.9. Parsed characters = text produced by the extra AI_PARSE_DOCUMENT step.

| Company | Method | Reports | Passed | Avg confidence | Min confidence | Low confidence (of which passed) | Avg parsed characters |
| --- | --- | --- | --- | --- | --- | --- | --- |
| AAPL | DIRECT_PDF | 5 | 50/50 | 0.953 | 0.87 | 3 (3) | - |
| AAPL | PARSE_THEN_EXTRACT | 5 | 50/50 | 0.957 | 0.92 | 0 (0) | 12,769 |
| MSFT | DIRECT_PDF | 5 | 50/50 | 0.956 | 0.92 | 0 (0) | - |
| MSFT | PARSE_THEN_EXTRACT | 5 | 50/50 | 0.956 | 0.89 | 1 (1) | 11,296 |
| TSLA | DIRECT_PDF | 4 | 40/40 | 0.949 | 0.78 | 4 (4) | - |
| TSLA | PARSE_THEN_EXTRACT | 4 | 40/40 | 0.952 | 0.78 | 4 (4) | 16,574 |
| **All** | DIRECT_PDF | 14 | 140/140 | 0.953 | 0.78 | 7 (7) | - |
| **All** | PARSE_THEN_EXTRACT | 14 | 140/140 | 0.955 | 0.78 | 5 (5) | 13,330 |

## 5. Run history (one row per 08 batch, oldest first)

Includes earlier runs that section 1 replaces with a newer run (e.g. the 3-metric AAPL runs).

| Started | Batch | Companies | Reports | Metrics | Passed / expected |
| --- | --- | --- | --- | --- | --- |
| 2026-11-19 04:50 | `f950be90` | AAPL | 1 | 3 | 6/6 |
| 2026-11-20 05:43 | `49f07337` | AAPL | 5 | 3 | 30/30 |
| 2026-11-20 06:42 | `ced247f5` | AAPL | 5 | 10 | 100/100 |
| 2026-11-20 08:16 | `5bc0b1bc` | MSFT | 2 | 3 | 12/12 |
| 2026-11-20 08:20 | `9a4b7cb1` | TSLA | 2 | 3 | 11/12 |
| 2026-11-20 09:09 | `baafd8e4` | TSLA | 1 | 3 | 6/6 |
| 2026-11-20 12:08 | `b564cebf` | AAPL | 5 | 10 | 100/100 |
| 2026-11-20 12:11 | `6339079a` | MSFT | 2 | 10 | 40/40 |
| 2026-11-20 12:17 | `acf0b0a2` | TSLA | 2 | 10 | 40/40 |
| 2026-11-20 13:19 | `a3f213b0` | MSFT | 3 | 10 | 60/60 |
| 2026-11-20 13:26 | `c3c07e23` | TSLA | 1 | 10 | 20/20 |
| 2026-11-21 05:13 | `ebb07191` | TSLA | 1 | 10 | 20/20 |

## 6. Files in this export

| File | Rows |
| --- | --- |
| lab_settings.csv | 1 |
| metric_catalog.csv | 10 |
| metric_sec_concepts.csv | 11 |
| statement_heading_patterns.csv | 15 |
| sec_facts.csv | 495 |
| ingest_log.csv | 42 |
| statement_page_scan.csv | 1810 |
| parse_results.csv | 30 |
| extraction_results.csv | 60 |
| extracted_values.csv | 14 |
| synthetic_ground_truth.csv | 50 |
| report_manifest.csv | 14 |
| lab_runs.csv | 30 |
| report_status.csv | 15 |
| method_comparison.csv | 28 |
| metric_ground_truth.csv | 140 |
| scope_metrics.csv | 3 |
| report_readiness.csv | 5 |
| pipeline_coverage.csv | 5 |
| heading_pattern_usage.csv | 15 |
| metric_evaluation.csv | 446 |
| pdfs/ | 25 files (sizes verified against the stage) |

Data-quality checks: run sql/10.validation.sql (or the runner's step 10 cell) on the live schema.
