"""Generate five synthetic earnings PDFs and 50 ground-truth rows in Snowflake.

Select your student database and schema first. Requires reportlab and an
existing annual_report_pdfs stage. Generation does not call AI.
"""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

# Install reportlab into this kernel's environment if it is missing
# (needs the PyPI artifact repository attached to the service).
if importlib.util.find_spec("reportlab") is None:
    subprocess.run([sys.executable, "-m", "pip", "install", "-q", "reportlab"], check=True)

from synthetic_earnings import generate_batch_in_snowflake


def project_root():
    """Find the repo root; __file__ is undefined when run on the Workspaces kernel."""
    try:
        start = Path(__file__).resolve().parent
    except NameError:
        start = Path.cwd().resolve()
    for candidate in (start, *start.parents):
        if (candidate / "fixtures" / "synthetic_earnings_source.json").exists():
            return candidate
    raise FileNotFoundError("Could not find fixtures/synthetic_earnings_source.json")


def main(session):
    root = project_root()
    source_path = root / "fixtures" / "synthetic_earnings_source.json"
    source = json.loads(source_path.read_text())
    batch = generate_batch_in_snowflake(session, source)
    for report in batch["reports"]:
        print(report["relative_path"])
    print("Uploaded 5 PDFs and saved 50 rows in synthetic_ground_truth.")
    print("Next: run sql/12.evaluate_synthetic_simple.sql one step at a time.")
    return batch


if __name__ == "__main__":
    from snowflake.snowpark.context import get_active_session
    session = get_active_session()
    session.sql("USE WAREHOUSE compute_wh").collect()
    session.sql("USE DATABASE bootcamp").collect()
    session.sql("USE SCHEMA atp524").collect()
    print(json.dumps(main(session), indent=2))
