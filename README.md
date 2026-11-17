# Day 1 Unstructured Data Lab

Ingest annual-report PDFs, load independent SEC ground truth, and compare two ways to extract financial metrics in Snowflake.

## Lab sequence

| Step | What you do | Output | Calls AI? |
| --- | --- | --- | --- |
| 1 | Ingest PDFs into a stage | Annual-report files | No |
| 2 | Ingest SEC ground truth into a table | Structured financial facts | No |
| 3 | Run both extraction paths | Saved financial answers and parsed Markdown | Yes |
| 4 | Compare answers with SEC ground truth | Scores for each method | No |
| If time | Generate synthetic PDFs and ground truth, then repeat the comparison | Controlled evaluation dataset | Generation: no; extraction: yes |

Start with AAPL fiscal 2023 and three metrics: assets, revenue, and diluted EPS.

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

Run [sql/ddls.sql](sql/ddls.sql) in this schema. It creates the tables but does not populate them.

Everyone uses the shared role. Separate schemas organize your work; they do not provide security isolation. Do not modify classmates' objects or store personal credentials here.

Create a Python notebook inside `python/`, alongside the Python modules. Use the same database, schema, and warehouse. Initialize its session:

```python
from snowflake.snowpark.context import get_active_session

session = get_active_session()
session.use_database("bootcamp")
session.use_schema("student_your_name")  # Replace with your schema.
```

The ingestion jobs run only inside Snowflake. To run a file directly, edit `TICKER`, `FIRST_YEAR`, `LAST_YEAR`, and `SEC_USER_AGENT` near its top, then run it in the selected student database/schema. Each file uses the existing Snowflake session; there are no command-line arguments or connection credentials to configure. The notebook examples below pass ticker and years explicitly instead.

Live ingestion needs `requests` and the instructor-provided `public_filing_access` external access integration enabled on the notebook service. Set a real contact address for SEC requests:

```python
import ingest_sec_ground_truth
import ingest_annual_report_pdfs

ingest_sec_ground_truth.SEC_USER_AGENT = "AnnualReportsLab your.real.contact@example.com"
ingest_annual_report_pdfs.SEC_USER_AGENT = "AnnualReportsLab your.real.contact@example.com"
```

If source sites are unavailable or the instructor wants to avoid class-wide downloads, use the bundled snapshot alternatives in steps 1 and 2. These preserve the same learning sequence and need no HTTP access.

## 1. Ingest PDFs into the stage

Run in your notebook:

```python
from ingest_annual_report_pdfs import ingest_annual_report_pdfs

print(ingest_annual_report_pdfs(session, "AAPL", 2023, 2023))
```

Expect `2023` in `pdf_years_downloaded`. Inspect the staged file:

```sql
SELECT relative_path, size
FROM DIRECTORY(@annual_report_pdfs);
```

Expect `AAPL/2023.pdf`. If ingestion fails, inspect `ingest_log` before continuing.

**Bundled alternative:** upload the verified report included in the repository:

```python
from load_starter import ingest_starter_pdf

print(ingest_starter_pdf(session))
```

This step uploads the PDF only. It does not populate SEC ground truth.

## 2. Ingest SEC ground truth into the table

Run:

```python
from ingest_sec_ground_truth import ingest_sec_facts

print(ingest_sec_facts(session, "AAPL", 2023, 2023))
```

Inspect the independent structured source:

```sql
SELECT concept, unit, start_date, end_date, fact_value, accession
FROM sec_facts
WHERE ticker = 'AAPL'
ORDER BY concept, end_date;
```

There can be several filings and comparative periods. Do not compare an AI answer to an arbitrary row.

Run [sql/prepare_lab.sql](sql/prepare_lab.sql) to review and approve the report's SEC accession, exact fiscal dates, and PDF page ranges. For the AAPL starter, use:

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

This loads SEC-sourced structured facts from the bundled JSON snapshot, not a live API response. It does not upload the PDF. Use it with the bundled PDF from step 1; if you mix sources, verify they represent the same filing and pagination.

Confirm the report is ready:

```sql
SELECT relative_path, approved, period_start, period_end, sec_accession
FROM report_manifest;
```

Expect one approved `AAPL/2023.pdf` row with the dates and accession above. Do not continue with an unreviewed manifest.

## 3. Run AI extraction using both paths

Open [sql/extract_reports.sql](sql/extract_reports.sql). Keep its defaults:

```sql
SET report_path = 'AAPL/2023.pdf';
SET include_all_metrics = FALSE;
```

Run it in order in one SQL session, pausing at the inspection queries:

1. Save the report selection and questions under a new `run_id`.
2. Run `DIRECT_PDF`: selected PDF pages → `AI_EXTRACT`.
3. Run `AI_PARSE_DOCUMENT` and inspect the page-level Markdown and errors.
4. Run `PARSE_THEN_EXTRACT`: Markdown → `AI_EXTRACT`, using the same questions.
5. Inspect the saved answers from both methods.

Both methods ask for printed value, scale, unit, fiscal dates, and evidence for each metric. Expected numerical answers are not included in the prompts.

This step incurs inference charges. For one successful report it calls direct extraction once, parsing once, and text extraction once. The text path skips empty, failed, or oversized parses instead of silently truncating them. The 60,000-character guardrail is a lab choice, not a documented model limit.

Rerun the whole worksheet with a fresh run ID to repeat the experiment. Do not rerun individual inserts under an existing ID.

## 4. Evaluate and compare the methods

Run [sql/evaluate_results.sql](sql/evaluate_results.sql). This step reads saved outputs and does not call AI.

Follow its intermediate views:

| View | What it means |
| --- | --- |
| `normalized_extractions` | AI answers converted into comparable numeric values |
| `sec_reference` | SEC facts matched to the exact filing, unit, and period |
| `metric_evaluation` | Expected value, extracted value, error, and pass/fail status |

Start by reading these columns:

```sql
SELECT method, metric_id, sec_value AS expected_value,
       extracted_value, absolute_error, evaluation_status
FROM metric_evaluation
WHERE run_id = $run_id
ORDER BY metric_id, method;
```

Use the same SQL session as extraction for `$run_id`, or replace it with a saved run ID. The evaluator's built-in queries also show scores by run and method, parsing errors, and side-by-side statuses.

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

Install `reportlab` in your Python runtime. Installing from PyPI needs the instructor-provided external access integration; rendering itself uses no external requests or AI.

In the same notebook and student schema:

```python
from generate_synthetic_batch import main

batch = main(session)
```

This generates five fictional earnings reports with three comparative years, uploads them to `@annual_report_pdfs/synthetic/batch/`, and writes 50 expected answers to `synthetic_ground_truth`. The answers are calculated from the structured inputs, not extracted from the PDFs.

```sql
SELECT ticker, COUNT(*) AS expected_metrics
FROM synthetic_ground_truth
GROUP BY ticker
ORDER BY ticker;
```

Expect five companies with ten metrics each. Rerunning generation replaces the batch files and ground-truth table. Do not regenerate while evaluating.

### Compare the same two AI paths

Run [sql/evaluate_synthetic_simple.sql](sql/evaluate_synthetic_simple.sql) in one SQL session, one numbered step at a time:

1. Inspect the correct answers.
2. Build and inspect the shared questions.
3. Run direct extraction and parse-then-extract on the same statement pages.
4. Join each method's answers to ground truth.
5. Compare per-company and overall accuracy by method.

There are **50 expected answers per method**, or 100 comparison rows. Each answer receives one status:

| Status | Criterion |
| --- | --- |
| `ERROR` | The extraction result contains an error. |
| `MISSING` | The answer is absent or cannot be converted to a number. |
| `PASS` | The absolute difference from ground truth is at most $0.005 per share for EPS or $0.50 for other amounts. |
| `FAIL` | A numeric answer is present but falls outside that tolerance. |

The evaluator applies these checks in the order shown. Answers must already be in base units; the comparison does not apply a scale multiplier.

`accuracy_percent = 100 × passing answers / expected answers`: ten expected answers per company and 50 overall for each method. `ERROR`, `MISSING`, and `FAIL` all remain in the denominator. For example, 45 passes out of 50 expected answers is 90% accuracy.

Step 3 makes five direct extraction calls, five parsing calls, and up to five text extraction calls. Other steps do not call AI. This beginner synthetic evaluation checks numeric accuracy only; it does not separately score dates, units, or supporting evidence. A synthetic `PASS` therefore does not establish that those fields are correct. Its tolerances and pass conditions differ from the real-filing evaluation above.

The five reports vary company names and financial values but share a layout. Their scores do not establish accuracy on unseen real filings. See [synthetic customization and implementation notes](docs/SYNTHETIC_EARNINGS.md). The [detailed direct-only synthetic benchmark](sql/evaluate_synthetic.sql) remains available for additional field validation, but is not the two-method classroom exercise.

## Further experiments

- Set `include_all_metrics = TRUE` in `extract_reports.sql` for ten metrics, then rerun evaluation.
- Choose another US-GAAP, USD-denominated original `10-K`. Ingest its PDFs first and SEC facts second, then review its manifest with `prepare_lab.sql`. Never reuse AAPL's accession, dates, or page ranges.
- Use [sql/validation.sql](sql/validation.sql) to investigate duplicate rows and reference gaps.

## Troubleshooting and instructor resources

| Symptom | Check |
| --- | --- |
| Git connection denied | Saved secret, integration, and GitHub token Contents: Read-only permission |
| Python import fails | Notebook must be alongside modules in `python/`; inspect the runtime directory before changing import paths |
| Table/stage not found | SQL and Python must select the same database and student schema |
| Live download fails | External access integration, `requests`, contact User-Agent, and `ingest_log` |
| No approved report | Complete the filing and page review in `prepare_lab.sql` |
| Missing text-path result | Inspect parsing errors, Markdown, and input length |
| Fixture hash mismatch | Restore the pinned files; do not bypass checks |

The bundled AAPL report is an 80-page 2023 Form 10-K. The selected pages are PDF indexes 30 through 35, not printed page numbers. See [fixture provenance](fixtures/README.md) for hashes and sources.

The hosted workflow still needs a live rehearsal in the student Snowflake runtime; offline tests do not validate SQL execution or model accuracy. Students do not run instructor setup or refresh the bundled fixtures.

[Instructor setup](docs/INSTRUCTOR_SETUP.md) · [Local execution](docs/LOCAL_SETUP.md) · [AI_EXTRACT](https://docs.snowflake.com/en/sql-reference/functions/ai_extract) · [AI_PARSE_DOCUMENT](https://docs.snowflake.com/en/sql-reference/functions/ai_parse_document)
