# Day 1 Unstructured Data Lab

Ingest annual-report PDFs, load independent SEC ground truth, and compare two ways to extract financial metrics in Snowflake.

## Lab sequence

Files are numbered in the order they run. You set **one scope**, a ticker and a year range, once in step 00. It is stored in the `lab_settings` table. Steps 02 and 03 ingest that scope, and every step from 04 on processes **every report in it**, so nothing you ingest is silently skipped. `pipeline_coverage` (step 06) lists every year in scope with the next step it still needs.

| Step | File | What you do | Calls AI? |
| --- | --- | --- | --- |
| 00 | `python/00.set_session_variables.ipynb` | Session settings, SEC contact, and the scope: ticker + first/last year (`lab_settings`) | No |
| 01 | `sql/01.ddls.sql` | Create the lab tables, grouped by layer, with declared keys and grain comments (the runner skips it when unchanged and complete) | No |
| 02 | `python/02.ingest_annual_report_pdfs.py` | Ingest the scope's PDFs into the stage | No |
| 03 | `python/03.ingest_sec_ground_truth.py` | Ingest the scope's SEC ground truth into a table | No |
| 04 | `sql/04.prepare_manifest.sql` | Manifest rows plus proposed fiscal dates and accession for every report in scope | No |
| 05 | `sql/05.locate_statement_pages.sql` | Find statement pages and approve every unapproved report in scope | Yes (parsing 15 pages per new report; finding them is free) |
| 06 | `sql/06.check_readiness.sql` | `metric_ground_truth` (the one SEC-value rule), `report_readiness` (READY / NOT READY) and `pipeline_coverage` (per-year step status) | No |
| 07 | `sql/07.first_extraction.sql` | First hands-on `AI_EXTRACT`: three metrics per READY report | Yes (one call per new report) |
| 08 | `sql/08.extract_reports.ipynb` | Run both extraction paths for every READY report, as one batch (export a `.sql` copy with `python/export_notebook_sql.py`) | Yes |
| 09 | `sql/09.evaluate_results.sql` | Compare the latest batch with SEC ground truth; per-year coverage check; `report_status` (every ticker-year, all companies); `method_comparison` (both paths across all reports) | No |
| 10 | `sql/10.validation.sql` | Data-quality tests: unique keys, not-null, relationships, accepted values | No |
| 11 | `python/11.generate_synthetic_batch.py` | If time: generate synthetic PDFs and ground truth | No |
| 12 | `sql/12.evaluate_synthetic_simple.sql` | Compare the two paths on the synthetic batch | Yes |
| 13 | `sql/13.evaluate_synthetic.sql` | Optional detailed, direct-only synthetic benchmark | Yes |

Unnumbered Python files are modules that numbered steps import, not steps you run: `lab_settings.py` (reads the scope), `sql_runner.py` (runs a step's SQL file in order), `export_notebook_sql.py` (writes a notebook's SQL cells to `build/*.sql`), `sec_facts.py`, `synthetic_earnings.py`, and `build_starter_fixture.py` (instructors refresh fixtures with it). `load_starter.py` is the **offline alternative to steps 02 + 03**: it loads the bundled AAPL 2023 PDF and SEC facts without internet access (see the *Bundled alternative* notes below); continue from step 04 afterwards. `sql/instructor_setup.sql` is for instructors only.

**Run everything at once:** [python/00.run_pipeline.ipynb](python/00.run_pipeline.ipynb) runs steps 01-10 in order, each from its own file, and ends with a step summary, `pipeline_coverage` and the step 10 checks. Internet steps (02, 03) and AI steps (05, 07, 08) only run when you set `RUN_INGESTION` / `RUN_AI_STEPS` to `True`; otherwise they are reported as `SKIPPED`. Running the steps one by one is still the way to learn what each does.

- **Standing check:** before every class and after any code edit, Run All with both gates `False`. It is free and verifies the whole pipeline wiring; expect no `FAILED` step and every step 10 check passing.
- **One source per step:** to change a step, edit that step's own file (`sql/NN...`, the 08 notebook, `python/NN...`), then run it. Never paste step SQL into the runner; a unit test enforces this.
- **Save your work and results:** `workspace_export.ipynb` writes every table and result view to `results/<date>/` (CSV plus the staged PDFs and a `SUMMARY.md`) and then zips the whole workspace, so the export contains both code and results. `SUMMARY.md` is built from `report_status` alone, so every ticker-year appears, including ones that stopped early.
- **Known gap: TSLA 2021.** annualreports.com (the course's PDF source) has no Tesla 2021 annual report, and SEC EDGAR serves 10-Ks as HTML, not PDF. The lab does not work around this: `report_status` and `SUMMARY.md` show TSLA 2021 as `Stopped at 02` with the reason. Uploading a PDF to `@annual_report_pdfs/TSLA/2021.pdf` later would let 04 onward pick it up. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for this and for the TSLA 2022 revenue tag (`metric_sec_concepts`).

**How it fits together:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the pipeline flow diagram, the data layers (CONFIG, RAW, CURATED, ANALYSIS), and a catalog of every table with its grain, key, writer and readers. [docs/PRODUCTION.md](docs/PRODUCTION.md) maps the lab to dbt models and tests and to a scheduled Snowflake Task DAG.

Start with AAPL fiscal 2023 and three metrics: assets, revenue, and diluted EPS. Widen the year range in step 00 when you are ready for more reports.

The two paths are:

```text
PDF -> AI_EXTRACT -> financial answers
PDF -> AI_PARSE_DOCUMENT -> Markdown -> AI_EXTRACT -> financial answers
```

`AI_PARSE_DOCUMENT` produces document content, not the final financial fields. Both paths use the same pages and extraction questions.

## Before you begin

### Connect the private course repository

Your instructor manages the GitHub token, Snowflake secret, and Git integration. You do not generate a token or create a secret.

1. Select `all_users_role` in Snowsight.
2. Open **Projects → Workspaces → From Git repository**.
3. Enter `https://github.com/DataExpert-io/snowflake-unstructured-data-day-1-lab.git`.
4. Select the API integration `dataexpert_course_git`.
5. Choose personal access token / secret authentication and select `course_credentials.git.dataexpert_course_token`. Select the saved secret; do not paste a token.
6. Select the course branch and open the lab folder.

Use different integration or secret names if supplied by your instructor. If either is missing, ask the instructor to check the grants. The private repository requires authenticated access; do not select public authentication.

### Create your lab objects

Select your assigned warehouse. Replace `student_your_name` with your own unique schema name:

```sql
USE ROLE all_users_role;
USE DATABASE bootcamp;

CREATE SCHEMA IF NOT EXISTS student_your_name;
USE SCHEMA student_your_name;

CREATE STAGE IF NOT EXISTS annual_report_pdfs
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

SELECT CURRENT_ROLE(), CURRENT_DATABASE(), CURRENT_SCHEMA();
```

Run [sql/01.ddls.sql](sql/01.ddls.sql) in this schema. It creates the tables but does not populate them.

Everyone uses the shared role. Separate schemas organize your work; they do not provide security isolation. Do not modify classmates' objects or store personal credentials here.

Create a Python notebook inside `python/`, alongside the Python modules. Use the same database, schema, and warehouse. Initialize its session:

```python
from snowflake.snowpark.context import get_active_session

session = get_active_session()
session.use_database("bootcamp")
session.use_schema("student_your_name")  # Replace with your schema.
```

The ingestion jobs run only inside Snowflake, in the selected student database/schema, using the existing Snowflake session; there are no command-line arguments or connection credentials to configure. They do **not** contain a ticker or years: both read the scope from `lab_settings`, which you set in step 00. Set a real contact address for SEC requests in `SEC_USER_AGENT` (near the top of each file, or in the 00 notebook).

Live ingestion needs `requests` and the instructor-provided `public_filing_access` external access integration enabled on the notebook service.

### Choose the scope (step 00)

In [python/00.set_session_variables.ipynb](python/00.set_session_variables.ipynb), edit the **Choose what to process** cell and run the notebook:

```sql
MERGE INTO bootcamp.atp524.lab_settings t
USING (SELECT 1 AS setting_id, 'AAPL' AS ticker, 2023 AS first_year, 2024 AS last_year,
              FALSE AS include_all_metrics) s
...
```

This is the only place the ticker, years and metric set are written. Use `first_year = last_year` for a single report; a range covers at most six years. `include_all_metrics = FALSE` (the default) uses the starter metrics (assets, revenue, diluted EPS, flagged `is_starter` in `metric_catalog`); `TRUE` uses all ten. Readiness (06), extraction (08) and `report_status` (09) all read it through one view, `scope_metrics`, so they always agree: with `TRUE` a report is READY only when SEC has a value for all ten, and any missing metric is named.

If source sites are unavailable or the instructor wants to avoid class-wide downloads, use the bundled snapshot alternatives in steps 1 and 2. These preserve the same learning sequence and need no HTTP access, but cover AAPL 2023 only.

## 1. Ingest PDFs into the stage

Run [python/02.ingest_annual_report_pdfs.py](python/02.ingest_annual_report_pdfs.py). It downloads one PDF per year in scope to `@annual_report_pdfs/<TICKER>/<YEAR>.pdf`. Expect each year in `pdf_years_downloaded`; any year in `pdf_years_missing` stays visible in `pipeline_coverage` as "02 ingest PDF". Inspect the staged files:

```sql
SELECT relative_path, size
FROM DIRECTORY(@annual_report_pdfs);
```

If ingestion fails, inspect `ingest_log` before continuing.

**Bundled alternative:** upload the verified report included in the repository:

```python
from load_starter import ingest_starter_pdf

print(ingest_starter_pdf(session))
```

This step uploads the PDF only. It does not populate SEC ground truth.

## 2. Ingest SEC ground truth into the table

Run [python/03.ingest_sec_ground_truth.py](python/03.ingest_sec_ground_truth.py). It loads the SEC facts for the same scope.

Inspect the independent structured source:

```sql
SELECT concept, unit, start_date, end_date, fact_value, accession
FROM sec_facts
WHERE ticker = 'AAPL'
ORDER BY concept, end_date;
```

There can be several filings and comparative periods. Do not compare an AI answer to an arbitrary row.

Prepare the manifest in two steps; both process every report in scope:

1. Run [sql/04.prepare_manifest.sql](sql/04.prepare_manifest.sql). It adds a manifest row per staged PDF and proposes each in-scope report's SEC accession and exact fiscal dates from `sec_facts`.
2. Run [sql/05.locate_statement_pages.sql](sql/05.locate_statement_pages.sql). For each unapproved report in scope, it first reads every page's text for free (no AI) to find the "Item 8. Financial Statements and Supplementary Data" page, cross-checks it with the report's index when there is one, then AI-parses only a 15-page window, finds the statement pages, and approves the report (`AUTO-APPROVED` with evidence) or explains why not (`AUTO-REJECTED`, naming what was NOT FOUND). `report_manifest.locator_method` says how the pages were found (`TEXT+INDEX`, `TEXT`, `MANUAL_REVIEW`, `AI_FALLBACK`, `NOT_FOUND`). This works for reports with an index (AAPL, TSLA) and without one (MSFT). If a new company's headings are worded differently, add the wording to `statement_heading_patterns` in `01.ddls.sql` rather than editing 05. Fix a rejected report with the manual override at the end of `04.prepare_manifest.sql`; that is the only place a report is named by hand, because it records a person's review of that PDF.

For the AAPL starter, the reviewed values are:

| Setting | Reviewed value |
| --- | --- |
| Report path | `AAPL/2023.pdf` |
| SEC accession | `0000320193-23-000106` |
| Fiscal start | `2022-09-25` |
| Fiscal end | `2023-09-30` |
| Page range | Start `30`, end `36` (zero-based, end excluded) |

Open the PDF and verify that the downloaded version has the expected statement pages before approving it. Do not reuse these values for another filing.

**Bundled alternative:** load the pinned SEC Company Facts response and its reviewed report metadata:

```python
from load_starter import ingest_starter_ground_truth

print(ingest_starter_ground_truth(session))
```

This loads SEC-sourced structured facts from the bundled JSON snapshot, not a live API response. It does not upload the PDF. Use it with the bundled PDF from step 1; if you mix sources, verify they represent the same filing and pagination. Keep the scope in step 00 covering AAPL 2023 when using the bundled data.

Confirm readiness by running [sql/06.check_readiness.sql](sql/06.check_readiness.sql). It creates two views:

- `report_readiness`: one row per in-scope report with `READY` or `NOT READY`, which check failed, and the approval note.
- `pipeline_coverage`: one row for **every year in scope**, built from the scope itself rather than from the manifest. It has one column per step (PDF staged, SEC facts loaded, manifest row, period proposed, pages found, approved, READY, extracted by each path) and a `next_step` naming the first step still missing.

Expect every in-scope report to show `READY` (AAPL 2023 with the dates and accession above). Only READY reports are extracted; any other year stays listed in `pipeline_coverage` with what to run next.

Optionally, run [sql/07.first_extraction.sql](sql/07.first_extraction.sql) for a first hands-on `AI_EXTRACT`: three plain-language questions per READY report, compared side by side with SEC facts. The fiscal year end in each question comes from the manifest. Reports already extracted there are not called again.

## 3. Run AI extraction using both paths

Open [sql/08.extract_reports.ipynb](sql/08.extract_reports.ipynb), the only source of step 08's SQL (`python/export_notebook_sql.py` writes a generated `build/08.extract_reports.sql` copy if you need a worksheet). It processes **every READY report in scope** as one batch; you do not edit report paths or years here. Every insert skips rows that already exist, so re-running a cell never duplicates or pays twice. Keep its defaults (which metrics to ask is not set here; it comes from the scope in step 00):

```sql
SET only_new_reports = TRUE;
SET batch_id = (SELECT UUID_STRING());
```

Run it in order in one SQL session, pausing at the inspection queries:

1. Save each READY report's selection and questions under its own `run_id`, all sharing the batch's `batch_id`. Expect one row per READY report.
2. Run `DIRECT_PDF`: selected PDF pages → `AI_EXTRACT`, for every report in the batch.
3. Run `AI_PARSE_DOCUMENT` and inspect the page-level Markdown and errors.
4. Run `PARSE_THEN_EXTRACT`: Markdown → `AI_EXTRACT`, using the same questions.
5. Inspect the saved answers from both methods.

Both methods ask for printed value, scale, unit, fiscal dates, and evidence for each metric. Expected numerical answers are not included in the prompts.

This step incurs inference charges. For each successful report it calls direct extraction once, parsing once, and text extraction once. The text path skips empty, failed, or oversized parses instead of silently truncating them; such a report shows "a path did not finish" in `pipeline_coverage`. The 60,000-character guardrail is a lab choice, not a documented model limit.

Rerun the whole worksheet (a new `batch_id`) to repeat the experiment. Do not rerun individual inserts under an existing batch. By default (`only_new_reports = TRUE`) a new batch only extracts reports that have not already been extracted with the same questions, so a rerun costs nothing for finished years; changing the questions or the metric set (`include_all_metrics` in step 00) re-extracts automatically. Set `only_new_reports = FALSE` for a deliberate full re-extraction.

Each run records its provenance in `lab_runs`: `prompt_version` (a hash of the question template with fiscal dates masked, so identical wording has the same version in every year), `include_all_metrics` (the setting used), `metric_count` (how many metrics were asked, e.g. 3 or 10) and `metric_ids` (exactly which). Step 09 reports the pass rate by `prompt_version`.

## 4. Evaluate and compare the methods

Run [sql/09.evaluate_results.sql](sql/09.evaluate_results.sql). This step reads saved outputs and does not call AI. It sets `$batch_id` to the latest batch from step 08, so its results cover every report that batch extracted. It ends with a per-year coverage check: each year in scope shows `EVALUATED` with its pass counts, or the step it still needs. To compare the two paths across **every** report rather than one batch, query `method_comparison` (pass rate, the model's confidence and parsed text size per company, year and method); the export's `SUMMARY.md` shows its rollup.

Follow its intermediate views:

| View | What it means |
| --- | --- |
| `normalized_extractions` | AI answers converted into comparable numeric values |
| `sec_reference` | SEC facts matched to the exact filing, unit, and period |
| `metric_evaluation` | Expected value, extracted value, error, and pass/fail status |

Start by reading these columns:

```sql
SELECT report_year, method, metric_id, sec_value AS expected_value,
       extracted_value, absolute_error, evaluation_status
FROM metric_evaluation
WHERE batch_id = $batch_id
ORDER BY report_year, metric_id, method;
```

The views keep every run, so earlier batches stay comparable; set `$batch_id` to a saved batch ID to review one. The evaluator's built-in queries also show scores by report and method, parsing errors, and side-by-side statuses.

For orientation, the starter's three reference values are:

| Metric | Printed value | Base-unit value |
| --- | ---: | ---: |
| Assets | 352,583 million USD | 352,583,000,000 USD |
| Revenue | 383,285 million USD | 383,285,000,000 USD |
| Diluted EPS | 6.13 USD/share | 6.13 USD/share |

### What counts as a passing answer?

Each metric is scored separately for each method. An answer receives `PASS` only when it satisfies every applicable check below.

| Check | Requirement |
| --- | --- |
| Usable SEC reference | SEC facts must match the selected company, filing accession, concept, unit, and period, with exactly one distinct reference value. Identical duplicate values are allowed. |
| Successful extraction | The method must have a saved extraction result without an extraction error. |
| Numeric value and scale | The returned value must parse as a number, and the scale multiplier must be `1`, `1000`, `1000000`, or `1000000000`. The evaluator multiplies them to get the base-unit value. EPS must use scale `1`. |
| Unit | The returned unit must exactly match the metric catalog: `USD` for dollar amounts or `USD/shares` for EPS. |
| Fiscal period | The end date must match the selected report's period end. Duration metrics, such as revenue and EPS, must also match its period start. Instant metrics, such as assets, do not require a start date. |
| Evidence present | The evidence field must contain text other than an empty string or `NOT_FOUND`. The automated check only tests presence; manually verify that the quote supports the metric, value, and period. |
| Value within tolerance | The absolute difference between the normalized answer and SEC reference must be less than or equal to the allowed error. Dollar amounts default to the larger of $1,000,000 and 0.01% of the absolute SEC value. EPS allows $0.01 per share. |

For example, the starter revenue reference is $383,285,000,000. Its allowed error is $38,328,500 (0.01%), which is larger than $1,000,000. Returning `383285` with scale `1000000` produces the correct base-unit value. Returning the same number with scale `1` fails the value check. Even an exact numeric match fails if its unit, required dates, or evidence do not meet the checks above.

`evaluation_status` shows the first failing check in SQL order, so fixing one problem may reveal another. `NO_SEC_REFERENCE` and `AMBIGUOUS_SEC_REFERENCE` indicate reference-data problems. Other non-`PASS` statuses identify extraction or answer problems. The model's `value_score` is shown for inspection but does not determine `PASS`.

### How the method score is calculated

- `expected_metrics`: all requested metrics for that run and method.
- `scorable_metrics`: requested metrics with a usable SEC reference.
- `passed_metrics`: scorable metrics that satisfy all pass conditions.
- `pass_rate = passed_metrics / scorable_metrics`. Multiply by 100 to express it as a percentage.
- `reference_gaps`: metrics with missing or conflicting SEC references. These are excluded from the pass-rate denominator and reported separately. The evaluator never chooses a reference by proximity to the AI answer.

Missing answers and extraction errors stay in the denominator when a usable reference exists. For example, with three scorable metrics, two passes and one missing answer give a pass rate of `2 / 3`, or about 66.7%. If no metrics are scorable, the pass rate is `NULL`, not zero.

### What to compare and explain

Compare `DIRECT_PDF` and `PARSE_THEN_EXTRACT` on the same run and metrics. Keep SEC facts and tolerances unchanged while comparing runs; the evaluator reads those tables live.

In your discussion:

- Report each method's passed/scorable counts, pass rate, and reference gaps. If the rates are equal, report a tie.
- Inspect non-passing rows and explain the causes you can verify, such as a wrong year, incorrect scale, missing evidence, or extraction error.
- Check the supporting quotes manually. For the parsed path, use the saved Markdown and parsing errors to investigate where information was lost or misread.
- Explain whether any observed accuracy benefit justifies the extra parsing call. Separate the measured pass rates from your judgment about cost; if you did not measure cost, say so.

## If there is time: generate and evaluate synthetic PDFs

### Generate five reports and their ground truth

`reportlab` is installed automatically on first run if it is missing; installing from PyPI needs the instructor-provided artifact repository or external access integration. Rendering itself uses no external requests or AI.

Run [python/11.generate_synthetic_batch.py](python/11.generate_synthetic_batch.py) in the student schema.

This generates five fictional earnings reports with three comparative years, uploads them to `@annual_report_pdfs/synthetic/batch/`, and writes 50 expected answers to `synthetic_ground_truth`. The answers are calculated from the structured inputs, not extracted from the PDFs.

```sql
SELECT ticker, COUNT(*) AS expected_metrics
FROM synthetic_ground_truth
GROUP BY ticker
ORDER BY ticker;
```

Expect five companies with ten metrics each. Rerunning generation replaces the batch files and ground-truth table. Do not regenerate while evaluating.

### Compare the same two AI paths

Run [sql/12.evaluate_synthetic_simple.sql](sql/12.evaluate_synthetic_simple.sql) in one SQL session, one numbered step at a time:

1. Inspect the correct answers.
2. Build and inspect the shared questions.
3. Run direct extraction and parse-then-extract on the same pages. By default (`SET first_page = 0;` at the top) that is the **whole report**, including page 0, a "Full-year results" summary that restates revenue and net income **rounded** to USD 0.01 billion. The statement values are deliberately not round, so the summary differs from the exact figure by $1-3 million: a model that reads the summary instead of the statement is caught. Set `first_page = 1` to send only the statements (the control).
4. Join each method's answers to ground truth.
5. Compare per-company and overall accuracy by method, then the rounding-trap result: for the 10 trap answers per method, how many took the exact statement figure and how many the rounded summary.

There are **50 expected answers per method**, or 100 comparison rows. Each answer receives one status:

| Status | Criterion |
| --- | --- |
| `ERROR` | The extraction result contains an error. |
| `MISSING` | The answer is absent or cannot be converted to a number. |
| `PASS` | The absolute difference from ground truth is at most $0.005 per share for EPS or $0.50 for other amounts. |
| `USED_ROUNDED_SUMMARY` | The answer is wrong but equals the rounded page-0 summary figure (revenue and net income only): the model read the summary, not the statement. |
| `FAIL` | A numeric answer is present but falls outside that tolerance. |

The evaluator applies these checks in the order shown. Answers must already be in base units; the comparison does not apply a scale multiplier.

`accuracy_percent = 100 × passing answers / expected answers`: ten expected answers per company and 50 overall for each method. `ERROR`, `MISSING`, and `FAIL` all remain in the denominator. For example, 45 passes out of 50 expected answers is 90% accuracy.

Step 3 makes five direct extraction calls, five parsing calls, and up to five text extraction calls. Other steps do not call AI. This beginner synthetic evaluation checks numeric accuracy only; it does not separately score dates, units, or supporting evidence. A synthetic `PASS` therefore does not establish that those fields are correct. Its tolerances and pass conditions differ from the real-filing evaluation above.

The five reports vary company names and financial values but share a layout. Their scores do not establish accuracy on unseen real filings. See [synthetic customization and implementation notes](docs/SYNTHETIC_EARNINGS.md). The [detailed direct-only synthetic benchmark](sql/13.evaluate_synthetic.sql) remains available for additional field validation, but is not the two-method classroom exercise.

## Further experiments

- Set `include_all_metrics = TRUE` in step 00 for ten metrics, rerun 06 and 08, then rerun evaluation; set it back to `FALSE` afterwards.
- Widen the year range in `00.set_session_variables.ipynb` (for example AAPL 2021-2025), run 02 and 03, then 04-06; `pipeline_coverage` shows each year's progress, and 08 extracts every year that reaches `READY`.
- Choose another US-GAAP, USD-denominated original `10-K` company: change the ticker in step 00 and run the same steps. Never reuse AAPL's accession, dates, or page ranges.
- Use [sql/10.validation.sql](sql/10.validation.sql) to investigate duplicate rows and reference gaps.

## Troubleshooting and instructor resources

| Symptom | Check |
| --- | --- |
| Git connection denied | Saved secret, integration, and GitHub token Contents: Read-only permission |
| Python import fails | Notebook must be alongside modules in `python/`; inspect the runtime directory before changing import paths |
| Table/stage not found | SQL and Python must select the same database and student schema |
| Live download fails | External access integration, `requests`, contact User-Agent, and `ingest_log` |
| No approved report | Run `04.prepare_manifest.sql` and `05.locate_statement_pages.sql`, then check `06.check_readiness.sql`; for an `AUTO-REJECTED` report use the manual override in `04` |
| A year is missing from results | `SELECT * FROM pipeline_coverage` (step 06) for the scope, or `SELECT * FROM report_status` (step 09) for every company and year: `next_step` names the step that year still needs |
| `lab_settings must contain exactly one row` | Run the **Choose what to process** cell in `00.set_session_variables.ipynb` |
| Missing text-path result | Inspect parsing errors, Markdown, and input length |
| Fixture hash mismatch | Restore the pinned files; do not bypass checks |

The bundled AAPL report is an 80-page 2023 Form 10-K. The selected pages are PDF indexes 30 through 35, not printed page numbers. See [fixture provenance](fixtures/README.md) for hashes and sources.

The hosted workflow still needs a live rehearsal in the student Snowflake runtime; offline tests do not validate SQL execution or model accuracy. Students do not run instructor setup or refresh the bundled fixtures.

[Instructor setup](docs/INSTRUCTOR_SETUP.md) · [Local execution](docs/LOCAL_SETUP.md) · [AI_EXTRACT](https://docs.snowflake.com/en/sql-reference/functions/ai_extract) · [AI_PARSE_DOCUMENT](https://docs.snowflake.com/en/sql-reference/functions/ai_parse_document)
