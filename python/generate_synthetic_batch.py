"""Generate five synthetic earnings PDFs and 50 ground-truth rows in Snowflake.

Select your student database and schema first. Requires reportlab and an
existing annual_report_pdfs stage. Generation does not call AI.
"""
import json
from pathlib import Path

from synthetic_earnings import generate_batch_in_snowflake


def main(session):
    root = Path(__file__).resolve().parents[1]
    source_path = root / "fixtures" / "synthetic_earnings_source.json"
    source = json.loads(source_path.read_text())
    batch = generate_batch_in_snowflake(session, source)
    for report in batch["reports"]:
        print(report["relative_path"])
    print("Uploaded 5 PDFs and saved 50 rows in synthetic_ground_truth.")
    print("Next: run sql/evaluate_synthetic_simple.sql one step at a time.")
    return batch


if __name__ == "__main__":
    from snowflake.snowpark.context import get_active_session
    main(get_active_session())
