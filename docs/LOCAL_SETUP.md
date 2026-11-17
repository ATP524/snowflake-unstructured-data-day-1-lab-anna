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

The fixture loader makes no HTTP calls. It uploads the bundled PDF to your stage, loads pinned SEC facts, and approves the verified manifest. Continue with `first_extraction.sql` and the remaining SQL worksheets in Snowflake.

## Live ingestion runs in Snowflake

Run the two ingestion jobs inside Snowflake, PDF first and SEC ground truth second. Each file exposes `TICKER`, `FIRST_YEAR`, `LAST_YEAR`, and `SEC_USER_AGENT` near the top. Select your student database/schema, enable the required external access integration, and run the file. It uses `get_active_session()` directly; it does not create connections or close the active session.

For an imported module, call `main(session)` to use its file settings, or call its ingestion function with explicit ticker/year parameters. See the [student walkthrough](../README.md) for notebook examples.

The downloader tests historical AnnualReports.com URLs, refuses redirects, caps PDFs at 30 MB, and limits each call to six report years. Check `ingest_log` and the returned summary rather than assuming a report downloaded.

For a new report, use `prepare_lab.sql` to review fiscal dates, accession, page ranges, and concept semantics. Never reuse the starter's reviewed manifest for a different PDF.

[Snowpark named connections](https://docs.snowflake.com/en/developer-guide/snowpark/python/creating-session)
