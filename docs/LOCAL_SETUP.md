# Local Snowpark execution

Date: 2026-11-16  
POC: Course instructor  
TL;DR: Use a named Snowflake connection to load the same verified starter or run the live ingestion scripts from your computer.

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

The fixture loader makes no HTTP calls. It uploads the bundled PDF to your stage, loads pinned SEC facts, and approves the verified manifest. Continue with `first_extraction.sql` and the remaining SQL worksheets in Snowflake.

## Live ingestion

Set a descriptive `SEC_USER_AGENT` with a real contact email in `python/ingestion_common.py`, then run:

```sh
python python/ingest_sec_ground_truth.py --connection lab --ticker AAPL --first-year 2023 --last-year 2023
python python/ingest_annual_report_pdfs.py --connection lab --ticker AAPL --first-year 2023 --last-year 2023
```

These commands open and close their own sessions. Imported functions accept an existing session and leave it open.

Downloads originate from your computer, so Snowflake external access integration is unnecessary for local execution. You still need Snowflake privileges on the destination objects.

The downloader tests historical AnnualReports.com URLs, refuses redirects, caps PDFs at 30 MB, and limits each call to six report years. Check `ingest_log` and the returned summary rather than assuming a report downloaded.

For a new report, use `prepare_lab.sql` to review fiscal dates, accession, page ranges, and concept semantics. Never reuse the starter's reviewed manifest for a different PDF.

[Snowpark named connections](https://docs.snowflake.com/en/developer-guide/snowpark/python/creating-session)
