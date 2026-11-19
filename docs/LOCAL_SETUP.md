# Local Snowpark execution

Date: 2026-11-16  
POC: Course instructor  
TL;DR: Instructor-only fallback for loading the verified starter from a computer. Student ingestion jobs run inside Snowflake; they do not accept command-line arguments.

Run commands from the lab root. SQL worksheet basenames below refer to files in `sql/`; Python scripts and helpers are in `python/`.

## Environment and connection

Install the packages in a Python environment supported by your Snowpark version:

```sh
python -m pip install snowflake-snowpark-python requests
```

Configure a named connection called `lab` in Snowflake's `connections.toml`. Use your account's approved authentication method and include the role `all_users_role`, database `bootcamp`, assigned warehouse, and your student schema. Do not commit credentials.

Create the schema, stage, and tables using the student README before loading data.

## Offline starter loading

From this lab directory, use a Python notebook or interactive Python environment:

```python
from pathlib import Path
import sys

# Run from this lab's root directory.
sys.path.insert(0, str(Path('python').resolve()))

from snowflake.snowpark import Session
from load_starter import load_starter

session = Session.builder.config('connection_name', 'lab').create()
try:
    session.use_database('bootcamp')
    session.use_schema('student_your_name')
    print(load_starter(session))
finally:
    session.close()
```

The fixture loader makes no HTTP calls; it is the offline alternative to steps 02 + 03 for AAPL 2023 only. It uploads the bundled PDF to your stage, loads pinned SEC facts, and approves the verified manifest. Set the scope in `python/00.set_session_variables.ipynb` to cover AAPL 2023, then continue with `04.prepare_manifest.sql` and the remaining SQL steps in Snowflake (04 and 05 leave the approved starter report unchanged).

## Live ingestion runs in Snowflake

Run the two ingestion jobs inside Snowflake, PDF first and SEC ground truth second. Neither file contains a ticker or years: `main(session)` reads the scope (ticker, first year, last year) from the `lab_settings` table, which you set once in `python/00.set_session_variables.ipynb`, so both always cover the same years. Set `SEC_USER_AGENT` near the top of each file to a real contact address. Select your student database/schema, enable the required external access integration, and run the file. It uses `get_active_session()` directly; it does not create connections or close the active session.

The ingestion functions (`ingest_annual_report_pdfs`, `ingest_sec_facts`) still accept explicit ticker/year parameters for tests and one-off use, but the lab steps use `main(session)` so the scope is set in one place. See the [student walkthrough](../README.md).

The downloader tests historical AnnualReports.com URLs, refuses redirects, caps PDFs at 30 MB, and limits each call to six report years. Check `ingest_log` and the returned summary rather than assuming a report downloaded; any year that did not arrive stays listed in `pipeline_coverage` (step 06) with the step it needs.

For new reports, widen or change the scope in step 00, run 02 and 03, then `04.prepare_manifest.sql` (fiscal dates and accession), `05.locate_statement_pages.sql` (page ranges and approval) and `06.check_readiness.sql`; review concept semantics in 06's detail query. Never reuse the starter's reviewed manifest for a different PDF.

[Snowpark named connections](https://docs.snowflake.com/en/developer-guide/snowpark/python/creating-session)
