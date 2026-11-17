# Synthetic earnings report

Date: 2026-11-16  
POC: Lab instructor  
TL;DR: Render a fictional five-page financial report from structured records, upload it to the student stage, and score extraction against those records. No LLM is involved in PDF generation.

## Included artifacts

- `fixtures/synthetic_earnings_source.json`: three fiscal years of fictional inputs, newest first.
- `fixtures/SYN_ORCH_2025.pdf`: generated Orchard Devices earnings report.
- `fixtures/SYN_ORCH_2025.ground_truth.json`: ten expected metrics with units, periods, printed values, and page indexes.
- `python/synthetic_earnings.py`: renderer and Snowflake upload helper.
- `sql/evaluate_synthetic_simple.sql`: beginner worksheet with five inspectable steps.
- `sql/evaluate_synthetic.sql`: optional detailed benchmark for values, scales, units, dates, and evidence.

The report resembles the financial-statement portion of the AAPL fixture, not its full 80-page annual report. Every page is marked synthetic. Its statements are simplified teaching fixtures, not complete GAAP statements.

## Five-report batch in Snowflake Workspaces

The batch generates five fictional companies with different financial values:
Orchard Devices, Cedar Systems, Maple Computing, Birch Electronics, and Elm
Technologies. Each report has five pages and ten expected metrics. Values are
deterministic multiples of the original financial inputs, with unchanged share
counts so EPS also varies. All five use the same layout; this tests numeric
variation, not layout generalization.

1. Select your student database, schema, and query warehouse. Ensure the
   `annual_report_pdfs` stage exists and `reportlab` is installed.
2. Run `python/generate_synthetic_batch.py` in Workspaces, or run this in a
   notebook alongside the Python modules:

   ```python
   from snowflake.snowpark.context import get_active_session
   from generate_synthetic_batch import main

   session = get_active_session()
   session.use_database("bootcamp")
   session.use_schema("student_your_name")
   batch = main(session)
   ```

3. Run `sql/evaluate_synthetic_simple.sql` in one SQL session in the same student
   schema, one numbered step at a time. Start by checking that the ground-truth
   table contains five companies with ten metrics each (50 rows).

The beginner worksheet has five steps: inspect the correct answers, build the
questions, read the PDFs with AI, join answers to ground truth, and score them.
Each intermediate table can be inspected before moving on. It uses the persistent
`synthetic_ground_truth` table directly, without JSON flattening or regular
expressions. Only step 3 calls AI; rerunning the scoring steps costs no inference
credits.

This lesson scores numeric accuracy in base units. It asks the model to convert
millions to dollars and leaves EPS unscaled. It does not separately verify units,
fiscal dates, or evidence. For those checks, use `sql/evaluate_synthetic.sql`, the
optional detailed benchmark. That worksheet reads the staged manifest and should
show 5 reports, 5 distinct paths, and 50 metrics before its AI section.

The generator uploads five PDFs, five per-report ground-truth files, and
`@annual_report_pdfs/synthetic/batch/manifest.json`. The evaluator reads only the
reports listed in that manifest and joins each extraction to its own answers.
It returns per-report scores and an overall 50-metric score.

Generation also creates a persistent `synthetic_ground_truth` table in the active
student schema, with one row per report and metric (50 rows). It includes printed
and base-unit values, scale, unit, dates, page index, and source/PDF hashes. This
table is replaced when you regenerate the batch; keep a copy for historical runs.
The evaluator still uses the matching JSON answers from the staged manifest.

```sql
SELECT ticker, metric_id, expected_printed_value, expected_scale,
       expected_value, expected_unit, period_start, period_end
FROM synthetic_ground_truth
ORDER BY ticker, metric_id;
```

If you already generated the batch with the earlier version, create the table
without regenerating the PDFs or making AI calls:

```python
import json
from synthetic_earnings import save_batch_ground_truth

with session.file.get_stream(
    "@annual_report_pdfs/synthetic/batch/manifest.json"
) as stream:
    existing_batch = json.load(stream)
save_batch_ground_truth(session, existing_batch)
```

Reload edited Python modules or restart your notebook service before importing
the updated helper.

Generation makes no AI calls. Evaluation performs five `AI_EXTRACT` calls and
incurs inference charges. Rerunning generation overwrites the same batch paths;
do not regenerate while evaluation is running. Uploads are not transactional:
if generation fails, rerun it successfully before evaluating. Evaluation
replaces temporary results on rerun.

To generate the same five reports locally:

```sh
python3 python/synthetic_earnings.py --batch --output-dir fixtures/synthetic_batch
```

That directory includes five PDFs, per-report ground truth, `manifest.json`,
and `sources.json` containing the structured records.

## Single-report generation in Snowflake Workspaces

Use your student role, database, schema, and query warehouse. Run the regular lab setup to create `annual_report_pdfs`. Install `reportlab` in your Python runtime; if installing from PyPI, your notebook service needs the appropriate external access integration. Once the package is installed, rendering requires no external requests.

From a notebook alongside the files in `python/`:

```python
import json
from pathlib import Path
from snowflake.snowpark.context import get_active_session
from synthetic_earnings import generate_in_snowflake

session = get_active_session()
session.use_database("bootcamp")
session.use_schema("student_your_name")

# Assumes your working directory is the repository's python/ directory.
# Adjust to the actual repository location in your runtime.
source_path = Path("../fixtures/synthetic_earnings_source.json")
source = json.loads(source_path.read_text())
manifest = generate_in_snowflake(session, source)
print(manifest["relative_path"])
```

Expected stage files:

```text
@annual_report_pdfs/synthetic/SYN_ORCH/2025.pdf
@annual_report_pdfs/synthetic/SYN_ORCH/2025.ground_truth.json
```

The same path is overwritten on rerun. Preserve separate paths before running variant experiments.

### Use structured Snowflake table rows instead

Create a table from the bundled inputs once:

```python
session.create_dataframe(source["years"]).write.mode("errorifexists").save_as_table(
    "synthetic_financial_inputs"
)
```

Then regenerate directly from the structured table:

```python
table_source = {
    key: value for key, value in source.items() if key != "years"
}
table_source["years"] = [
    {key.lower(): value for key, value in row.as_dict().items()}
    for row in session.table("synthetic_financial_inputs")
        .sort("FISCAL_YEAR", ascending=False).collect()
]
manifest = generate_in_snowflake(session, table_source)
```

Use whole numbers of USD millions for monetary inputs and millions of shares for share counts. EPS is computed and rounded to cents. When changing financial inputs, reconcile cash movements too: the generator rejects inconsistent beginning/ending cash, including across comparative years. Revenue, profit, EPS, assets, liabilities, and equity are calculated from the inputs rather than independently invented.

## Evaluate in Snowflake

Generate the five-report batch above, then run `sql/evaluate_synthetic.sql`
in a single SQL session using the same student schema. The single-report helper
does not publish the batch manifest and is not sufficient for this worksheet.

1. Confirm that the reference query shows five reports and 50 metrics.
2. Run the `AI_EXTRACT` statement; it incurs inference charges.
3. Inspect the raw response.
4. Run the scoring queries.

The worksheet checks printed value, scale, unit, fiscal dates, and presence of evidence. It does not independently verify whether an evidence quote actually supports the answer. Ground-truth numerical answers are kept out of the extraction prompt.

This workflow does not populate `sec_facts` or use the SEC evaluator. Synthetic references must not be presented as SEC observations. Temporary evaluation tables are replaced on rerun; save them to permanent run-keyed tables if you need benchmark history.

## Generate locally

```sh
python3 -m pip install reportlab pypdf pytest
python3 python/synthetic_earnings.py
python3 -m pytest tests/test_synthetic_earnings.py -q
```

The PDF and ground-truth JSON are written into `fixtures/`.

## Expected current-year answers

Fiscal year: 2024-09-29 through 2025-09-27.

| Metric | Printed value | Base-unit value |
| --- | ---: | ---: |
| Revenue | 332,000 million USD | 332,000,000,000 USD |
| Gross profit | 156,280 million USD | 156,280,000,000 USD |
| Operating income | 103,280 million USD | 103,280,000,000 USD |
| Net income | 83,720 million USD | 83,720,000,000 USD |
| Basic EPS | 5.90 USD/share | 5.90 USD/share |
| Diluted EPS | 5.83 USD/share | 5.83 USD/share |
| Assets | 320,000 million USD | 320,000,000,000 USD |
| Liabilities | 290,000 million USD | 290,000,000,000 USD |
| Equity | 30,000 million USD | 30,000,000,000 USD |
| Operating cash flow | 104,800 million USD | 104,800,000,000 USD |

Page ranges use zero-based indexes and exclusive ends. Indexes 1 through 4 contain the statements and fiscal-calendar notes. The summary page is excluded to avoid scoring against rounded narrative values.

## Validation scope

Offline tests check accounting identities, cash reconciliation, EPS, PDF page count, expected values on their stated pages, and mocked stage uploads. Run the SQL in your Snowflake account to validate permissions, package installation, and actual model extraction. Synthetic-template scores do not establish accuracy on unseen real filings.
