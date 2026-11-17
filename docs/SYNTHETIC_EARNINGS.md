# Synthetic earnings reports

Date: 2026-11-16  
POC: Lab instructor  
TL;DR: After the real-report exercise, generate five fictional reports and compare direct extraction with parse-then-extract against 50 known answers.

## Classroom workflow

Follow the optional synthetic section in [the student walkthrough](../README.md).

1. Run `python/generate_synthetic_batch.py` in the selected student schema.
2. Confirm `synthetic_ground_truth` has five companies and ten metrics per company.
3. Run `sql/evaluate_synthetic_simple.sql` one numbered step at a time in one SQL session.

The worksheet uses the same statement pages and questions for both methods:

```text
PDF -> AI_EXTRACT
PDF -> AI_PARSE_DOCUMENT -> Markdown -> AI_EXTRACT
```

Generation makes no AI calls. Extraction makes five direct extraction calls, five parsing calls, and up to five text extraction calls. Comparison and scoring read saved temporary tables and do not call AI again. Failed, empty, or oversized parses are skipped, not truncated; their missing answers count against accuracy.

Expect 50 comparisons per method, 100 total. This student worksheet scores numeric accuracy in base units, not separate unit/date/evidence correctness. Parsed Markdown and raw answers are available for inspection.

## Artifacts and reference sources

- `fixtures/synthetic_earnings_source.json`: base structured inputs for three fiscal years.
- `python/synthetic_earnings.py`: financial derivation, rendering, and upload helpers.
- `python/generate_synthetic_batch.py`: student entry point.
- `fixtures/synthetic_batch/`: checked-in reference outputs, not another required setup step.
- `sql/evaluate_synthetic_simple.sql`: two-method classroom comparison.
- `sql/evaluate_synthetic.sql`: optional detailed, direct-only benchmark with scale, unit, date, and evidence-presence checks.

The generator uploads five PDFs, five per-report answer JSON files, and `@annual_report_pdfs/synthetic/batch/manifest.json`. It also creates/replaces `synthetic_ground_truth` in the active schema. The beginner evaluator uses that table; the detailed direct-only benchmark uses the staged manifest.

Expected answers are derived from structured financial inputs, never from AI extraction. Synthetic references are kept separate from `sec_facts`. The reports use simplified financial statements and are marked fictional on every page; they are not SEC filings or complete GAAP statements.

Regeneration overwrites the same files and replaces the table. Uploads and table creation are not transactional. If generation fails, rerun successfully before evaluation; do not regenerate while evaluation is running. Save permanent run-keyed copies if historical results are needed.

## Customize the structured inputs

All five companies currently use the same template. Batch generation scales monetary inputs by factors one through five while keeping share counts unchanged, so EPS also changes. This tests financial-value variation, not generalization across layouts.

Edit the base input JSON or supply a dictionary with the same structure to `generate_batch_in_snowflake(session, source)`. Monetary inputs are whole USD millions, and share counts are millions of shares. Revenue, profit, EPS, assets, liabilities, and equity are derived. Cash movements must reconcile within each year and between comparative years; the generator rejects inconsistent cash inputs.

To use structured Snowflake rows after loading the source dictionary as `source`:

```python
session.create_dataframe(source["years"]).write.mode("errorifexists").save_as_table(
    "synthetic_financial_inputs"
)

from synthetic_earnings import generate_batch_in_snowflake

table_source = {key: value for key, value in source.items() if key != "years"}
table_source["years"] = [
    {key.lower(): value for key, value in row.as_dict().items()}
    for row in session.table("synthetic_financial_inputs")
        .sort("FISCAL_YEAR", ascending=False).collect()
]
batch = generate_batch_in_snowflake(session, table_source)
```

## Recover the ground-truth table without regenerating PDFs

Select the student schema containing the staged batch:

```python
import json
from synthetic_earnings import save_batch_ground_truth

with session.file.get_stream(
    "@annual_report_pdfs/synthetic/batch/manifest.json"
) as stream:
    batch = json.load(stream)
save_batch_ground_truth(session, batch)
```

This replaces the table from the saved manifest without model calls. Reload edited modules or restart the service before using updated helpers.

## Local development

```sh
python3 -m pip install reportlab pypdf pytest
python3 python/synthetic_earnings.py --batch --output-dir fixtures/synthetic_batch
python3 -m pytest -q
```

Local batch output includes five PDFs, per-report ground truth, `manifest.json`, and `sources.json`. The single-report `render_report` and `generate_in_snowflake` functions remain available for development; the single-report helper does not publish the batch manifest or populate the batch ground-truth table.

Offline tests cover financial reconciliation, printed values, page references, upload behavior, and worksheet structure. They do not execute Snowflake SQL or establish model accuracy. Rehearse the hosted flow before class and include real filings when assessing generalization.
