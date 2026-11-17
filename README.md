# Day 1 Unstructured Data Lab

## What you will learn

- Extract financial metrics with `AI_EXTRACT`.
- Inspect document layout as Markdown with `AI_PARSE_DOCUMENT`.
- Normalize millions versus per-share units and match the correct fiscal period.
- Evaluate model output against independently sourced SEC facts.

Start with assets, revenue, and diluted EPS. Once those work, expand to all ten metrics or investigate another company.

For a controlled benchmark generated from structured fictional financial records, use the [synthetic earnings report workflow](docs/SYNTHETIC_EARNINGS.md). It includes five synthetic PDFs, 50 ground-truth values, and a Snowflake-compatible generator. Start with the [five-step student evaluation](sql/evaluate_synthetic_simple.sql); the detailed benchmark is optional.

Course integrations are already configured. Students do not create integrations or publish a repository. [Instructor setup](docs/INSTRUCTOR_SETUP.md) and [local execution](docs/LOCAL_SETUP.md) are separate guides.

## Repository layout

```text
README.md       Student walkthrough
python/         Snowpark ingestion, starter loader, and fixture builder
sql/            Setup, extraction, evaluation, and validation worksheets
docs/           Instructor and local-execution guides
fixtures/       Pinned PDF, SEC response, and provenance
tests/          Offline checks
```

## 1. Connect the course repository

In Snowsight, select `all_users_role`, then open **Projects → Workspaces → From Git repository**.

Use the course repository URL provided by your instructor, select the existing `dataexpert_github_api` integration, and use public-repository authentication if the course repository is public. If your account uses a differently named integration, use the instructor's supplied name. Select the course branch and open this lab's folder.

Confirm you can see `python/load_starter.py`, `fixtures/`, `sql/first_extraction.sql`, and `sql/ddls.sql`. [Snowflake Workspace Git guide](https://docs.snowflake.com/en/user-guide/ui-snowsight/workspaces-git)

### Optional: connect with a GitHub personal access token

Skip this section when using public-repository authentication. For a private repository, Snowflake can store your GitHub personal access token (PAT) in a secret and use it through a Git API integration.

Do not create a personal-token secret under `all_users_role` or in a shared student schema. Everyone using that role shares its privileges. Ask your instructor or Snowflake administrator to provide a private schema and a role restricted to you. Do not paste the token into chat, commit it to Git, or save it in a shared worksheet.

1. **Create your own database and schema before creating the GitHub secret.** Use the private role assigned to you by your instructor, not `all_users_role`. Replace the example names with unique names for your account:

   ```sql
   USE ROLE YOUR_PRIVATE_ROLE;

   CREATE DATABASE IF NOT EXISTS YOUR_PRIVATE_DB;
   CREATE SCHEMA IF NOT EXISTS YOUR_PRIVATE_DB.YOUR_PRIVATE_SCHEMA;

   USE DATABASE YOUR_PRIVATE_DB;
   USE SCHEMA YOUR_PRIVATE_SCHEMA;
   ```

   Your role needs `CREATE DATABASE` on the account to create the database. If you lack that privilege, ask the instructor to create the database and schema for your private role. A uniquely named database is not private if it is owned by a role shared with classmates. Keep this credential database separate from the shared `bootcamp` lab database.

2. In GitHub, open **Settings → Developer settings → Personal access tokens → Fine-grained tokens**. Select the repository owner and the repository you want to connect. Grant **Repository permissions → Contents → Read-only** to fetch files, or **Read and write** if you need to push changes. Generate and copy the token. Organization-owned repositories may require approval.

3. Open a private SQL worksheet in Snowsight using your restricted role. Replace `YOUR_PRIVATE_DB`, `YOUR_PRIVATE_SCHEMA`, `YOUR_GITHUB_USERNAME`, and `YOUR_GITHUB_PAT`, then run:

   ```sql
   CREATE SECRET YOUR_PRIVATE_DB.YOUR_PRIVATE_SCHEMA.github_token
     TYPE = PASSWORD
     USERNAME = 'YOUR_GITHUB_USERNAME'
     PASSWORD = 'YOUR_GITHUB_PAT';
   ```

4. Have an administrator, or a role with `CREATE INTEGRATION` and the required access to the secret, create a dedicated integration. Replace `YOUR_OWNER` with the GitHub username or organization that owns the repository. Leave the shared `dataexpert_github_api` integration unchanged.

   ```sql
   CREATE API INTEGRATION github_token_integration
     API_PROVIDER = git_https_api
     API_ALLOWED_PREFIXES = ('https://github.com/YOUR_OWNER/')
     ALLOWED_AUTHENTICATION_SECRETS = (
       YOUR_PRIVATE_DB.YOUR_PRIVATE_SCHEMA.github_token
     )
     ENABLED = TRUE;
   ```

   Your restricted role needs `USAGE` on the integration, `USAGE` on the secret, and access to its database and schema. Creating the secret requires `CREATE SECRET` on its schema. Ask the administrator to grant these permissions to your restricted role, not `all_users_role`.

5. Return to **Projects → Workspaces → From Git repository**. Enter the repository's HTTPS URL, select `github_token_integration`, and select the personal access token authentication option with your secret.

   If you need a SQL Git repository clone instead of a Workspace, run the following using your restricted role. It also needs `CREATE GIT REPOSITORY` on the target schema.

   ```sql
   CREATE GIT REPOSITORY YOUR_PRIVATE_DB.YOUR_PRIVATE_SCHEMA.my_repo
     API_INTEGRATION = github_token_integration
     GIT_CREDENTIALS = YOUR_PRIVATE_DB.YOUR_PRIVATE_SCHEMA.github_token
     ORIGIN = 'https://github.com/YOUR_OWNER/YOUR_REPO.git';

   -- Fetch the latest changes to the SQL Git repository clone:
   ALTER GIT REPOSITORY YOUR_PRIVATE_DB.YOUR_PRIVATE_SCHEMA.my_repo FETCH;
   ```

Keep the private repository connection separate from the shared course role. Continue the lab's data setup below using `all_users_role`.

See [Snowflake's token authentication guide](https://docs.snowflake.com/en/developer-guide/git/git-setting-up-public#configure-for-authenticating-with-a-token).

## 2. Create your schema and PDF stage

Run this in a SQL worksheet. Replace `student_your_name` with a unique name such as `student_jane_smith` and select your assigned warehouse.

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

Run `sql/ddls.sql` in that schema to create your tables. Do not run `sql/instructor_setup.sql` or the old ingestion `.sql` files.

Every student has a separate namespace, but the shared role does not provide security isolation. Do not modify another student's schema.

## 3. Open a Python notebook and load the starter

Create a notebook in the Workspace inside `python/`, alongside the lab's Python files. Select `bootcamp`, your student schema, and the assigned warehouse. Ensure `snowflake-snowpark-python` is available. The starter uses bundled files and requires no HTTP downloads, `requests`, or notebook external access.

Run:

```python
from snowflake.snowpark.context import get_active_session
from load_starter import load_starter

session = get_active_session()
session.use_database('bootcamp')
session.use_schema('student_your_name')  # Use your actual schema name.

print(load_starter(session))
session.sql("""
    SELECT relative_path, approved, period_start, period_end, sec_accession
    FROM report_manifest
""").show()
session.sql("""
    SELECT relative_path, size
    FROM DIRECTORY(@annual_report_pdfs)
""").show()
```

Expect an approved `AAPL/2023.pdf` manifest row and the PDF in your own stage. The loader checks source hashes before writing anything, loads the pinned SEC facts, and supplies reviewed dates and page ranges. It does not call AI functions.

The notebook needs access to the actual repo files. If `load_starter` cannot be imported, inspect your working directory and locate the lab folder before adding it to `sys.path`:

```python
from pathlib import Path
import sys

print(Path.cwd())
print([p.name for p in Path.cwd().iterdir()])
# Set this to the actual lab directory visible in your runtime:
lab_dir = Path('REPLACE_WITH_ACTUAL_LAB_DIRECTORY').resolve()
assert (lab_dir / 'python' / 'load_starter.py').is_file()
assert (lab_dir / 'fixtures' / 'starter_manifest.json').is_file()
sys.path.insert(0, str(lab_dir / 'python'))
```

Rerun the import cell. Restart the notebook service after editing imported modules. If your runtime does not support `session.file.put_stream`, use [local loading](docs/LOCAL_SETUP.md) or ask your instructor for a staged copy.

## 4. Get your first result

In a SQL worksheet using the same `bootcamp` student schema, run `sql/first_extraction.sql` one section at a time.

The first query is a short, literal `AI_EXTRACT` call. Inspect its response before reading the SEC values:

| Metric | Printed in the PDF | SEC value in base units |
| --- | --- | --- |
| Total assets | 352,583 million USD | 352,583,000,000 USD |
| Revenue (total net sales) | 383,285 million USD | 383,285,000,000 USD |
| Diluted EPS | 6.13 USD per share | 6.13 USD per share |

Explain why the first two values need a multiplier of one million while EPS does not. Apple's fiscal year here runs from September 25, 2022 through September 30, 2023, not January through December.

This exploratory query consumes inference credits but is separate from the saved benchmark.

## 5. Compare both extraction paths

Run `sql/extract_reports.sql` with its default settings:

```sql
SET report_path = 'AAPL/2023.pdf';
SET include_all_metrics = FALSE;
```

Execute the entire worksheet in the same SQL session so its run ID remains available. Pause at the inspection queries.

1. Confirm exactly one run snapshot was created.
2. Inspect `DIRECT_PDF`, which extracts directly from the selected PDF pages.
3. Inspect the page-level Markdown produced by `AI_PARSE_DOCUMENT` in LAYOUT mode.
4. Inspect `PARSE_THEN_EXTRACT`, which asks the same questions of the Markdown.

Both methods use the same six pages and the same 18 questions: printed value, scale, unit, start date, end date, and supporting text for each of three metrics. `AI_PARSE_DOCUMENT` produces content, so the second path still needs `AI_EXTRACT` to produce financial fields.

The text path skips inputs above a conservative 60,000-character guardrail instead of truncating statements. Inspect parsing errors if the text extraction is missing.

## 6. Evaluate and explain the results

Run `sql/evaluate_results.sql`. Evaluation does not invoke AI again.

Expect three metric rows per method for each starter run. SEC matching uses the reviewed accession, concept, unit, and exact dates. A missing or ambiguous SEC reference is reported separately from extraction failures.

A full pass requires a valid number, scale, unit, dates, supporting text, and an amount within the catalog tolerance. This is stricter than a numeric-only accuracy measure. Model scores are confidence signals, not measured accuracy, and supporting quotes still need checking against the PDF.

Currency tolerances default to the larger of $1 million and 0.01% of the reference. EPS tolerance is $0.01. These are teaching defaults; discuss whether they fit the statement's rounding. Zero references use the absolute tolerance.

Answer these questions:

- Did both paths choose the correct year and consolidated total?
- Did either method lose a scale note or misinterpret EPS?
- What did the intermediate Markdown help you diagnose?
- Would the extra parsing step be worth its cost for this report?

## 7. Expand the exercise

### All ten metrics

Set `include_all_metrics = TRUE` and rerun the entire extraction worksheet to create a new run, then rerun evaluation. This expands to 60 questions and includes basic EPS, gross profit, liabilities, net income, operating income, equity, and operating cash flow.

Do not rerun individual INSERTs with an existing run ID: the tables do not enforce uniqueness, and duplicates can distort evaluation. `sql/validation.sql` includes duplicate checks.

### A second company

Enable `public_filing_access` in the notebook's external access settings and add `requests`. Import the live ingestion modules:

```python
import ingestion_common
from ingest_sec_ground_truth import ingest_sec_facts
from ingest_annual_report_pdfs import ingest_annual_report_pdfs

ingestion_common.SEC_USER_AGENT = 'AnnualReportsLab your.real.contact@example.com'
# Choose a company/report year, then call:
# ingest_sec_facts(session, ticker, first_year, last_year)
# ingest_annual_report_pdfs(session, ticker, first_year, last_year)
```

Coordinate downloads with the instructor instead of having the whole class fetch the same SEC endpoint at once. Inspect `ingest_log` for download failures.

Use `sql/prepare_lab.sql` to discover the new PDF and review its accession, fiscal dates, statement pages, and concept meanings before approving it. Do not reuse Apple's dates or page ranges. Change `report_path` in the extraction worksheet.

The lab targets original US-GAAP, USD-denominated `10-K` reports. Foreign issuers, amendments, extension concepts, and non-GAAP figures need additional handling.

## 8. Generate and evaluate five synthetic earnings reports

Use this exercise to test extraction against answers calculated from structured fictional data. Each PDF contains three years of financial statements. The five companies have different values but share one layout.

### Generate the PDFs and ground truth

Return to your notebook alongside the files in `python/`. Ensure `reportlab` and `snowflake-snowpark-python` are installed. If installing `reportlab` from PyPI, enable the instructor-provided external access integration first. PDF generation itself needs no external requests or AI calls.

Select your assigned warehouse and use the same lab schema as before. This is the shared-role lab environment, **not your private GitHub-secret database**.

```python
from snowflake.snowpark.context import get_active_session
from generate_synthetic_batch import main

session = get_active_session()
session.use_database("bootcamp")
session.use_schema("student_your_name")  # Replace with your lab schema.

batch = main(session)
```

This uploads five PDFs and their JSON ground truth under `@annual_report_pdfs/synthetic/batch/`. It also populates `synthetic_ground_truth` with **50 rows: five reports × ten metrics**. The expected values come from the structured inputs, not from extracting the PDFs. They stay separate from `sec_facts`.

Rerunning the generator overwrites the batch files and replaces the ground-truth table. Do not regenerate while evaluating an existing batch.

### Inspect the correct answers

In a SQL worksheet using the same database and student schema, run:

```sql
SELECT ticker, COUNT(*) AS expected_metrics
FROM synthetic_ground_truth
GROUP BY ticker
ORDER BY ticker;

SELECT ticker, metric_id, expected_value, expected_unit
FROM synthetic_ground_truth
ORDER BY ticker, metric_id;
```

Expect five companies with ten metrics each. Running `sql/ddls.sql` creates the table, but you must run the generator to populate it.

### Extract, compare, and score

Open [sql/evaluate_synthetic_simple.sql](sql/evaluate_synthetic_simple.sql) and run one numbered step at a time in the same SQL session:

1. Inspect the ground-truth answers.
2. Read the questions and group them by PDF.
3. Call `AI_EXTRACT` to read each PDF.
4. Join the extracted answers to the correct answers.
5. Mark each result and calculate accuracy per company and overall.

Only step 3 calls AI: **five extraction calls**, which consume inference credits. Rerun the comparison and scoring steps without repeating extraction. Missing or invalid answers count as incorrect.

This beginner worksheet checks numeric accuracy only. Discuss whether errors come from selecting the wrong year, forgetting the millions multiplier, or scaling EPS incorrectly. For separate unit, date, scale, and evidence checks, use the optional [detailed evaluator](sql/evaluate_synthetic.sql).

See the [synthetic earnings guide](docs/SYNTHETIC_EARNINGS.md) for source-data customization and local generation. These reports test financial-value variation in one template; they do not establish accuracy on unseen real filings.

## Starter provenance and limitations

The bundled report is Apple's 80-page 2023 Form 10-K from AnnualReports.com, checked against SEC accession `0000320193-23-000106`. Selected pages are zero-based indexes 30 through 35, with exclusive end 36. Operations are on index 30, balance sheet on 32, cash flows on 34, and the fiscal-calendar note on 35. These are PDF indexes, not printed page numbers.

See [fixture provenance](fixtures/README.md) for hashes, sources, and verification details. The loader uses pinned files, so it is also the fallback when source websites are unavailable.

Keep SEC data and catalog settings unchanged while comparing runs. Evaluation reads these tables live, so reingestion or catalog edits can change historical results.

Source artifacts and reference values were verified locally. The hosted workflow and SQL still need a live Snowflake rehearsal in the chosen student runtime. AI queries consume credits. Reevaluate saved outputs instead of repeating inference unnecessarily.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Git connection denied | Use the supplied URL, existing integration, and correct authentication |
| Schema creation denied | Ask the instructor to check the course database grants |
| Table/stage not found | SQL and notebook must use `bootcamp` and your student schema |
| Fixture hash mismatch | Restore the pinned fixture files; do not bypass verification |
| Missing text-path result | Inspect parse output and the text-size guardrail |
| AI function unavailable | Check course Cortex grants and regional availability |

[Instructor setup and validation](docs/INSTRUCTOR_SETUP.md) · [Local execution](docs/LOCAL_SETUP.md) · [AI_EXTRACT](https://docs.snowflake.com/en/sql-reference/functions/ai_extract) · [AI_PARSE_DOCUMENT](https://docs.snowflake.com/en/sql-reference/functions/ai_parse_document)
