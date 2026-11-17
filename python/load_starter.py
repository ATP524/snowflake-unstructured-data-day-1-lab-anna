"""Load the verified classroom fixture with an existing Snowpark session."""
import hashlib
import io
import json
from pathlib import Path

from sec_facts import merge_sec_facts


CONCEPTS = {
    "Assets", "EarningsPerShareBasic", "EarningsPerShareDiluted", "GrossProfit",
    "Liabilities", "NetIncomeLoss", "OperatingIncomeLoss",
    "RevenueFromContractWithCustomerExcludingAssessedTax", "StockholdersEquity",
    "NetCashProvidedByUsedInOperatingActivities",
}


def read_fixture(fixture_dir=None):
    root = Path(fixture_dir) if fixture_dir else Path(__file__).resolve().parents[1] / "fixtures"
    manifest = json.loads((root / "starter_manifest.json").read_text())
    pdf = (root / "AAPL_2023.pdf").read_bytes()
    sec = (root / "AAPL_companyfacts.json").read_bytes()
    for label, data, expected in (
        ("PDF", pdf, manifest["pdf_sha256"]),
        ("SEC", sec, manifest["sec_sha256"]),
    ):
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError(f"{label} fixture hash mismatch; restore the pinned artifact")
    doc = json.loads(sec)
    if str(doc["cik"]).zfill(10) != manifest["cik"]:
        raise ValueError("SEC fixture entity does not match manifest")
    return manifest, pdf, doc


def reference_rows(manifest, doc):
    rows = []
    for concept, metadata in doc["facts"]["us-gaap"].items():
        if concept not in CONCEPTS:
            continue
        unit = "USD/shares" if concept.startswith("EarningsPerShare") else "USD"
        for fact in metadata.get("units", {}).get(unit, []):
            if fact.get("accn") != manifest["sec_accession"] or fact.get("form") != "10-K":
                continue
            if fact.get("end") != manifest["period_end"]:
                continue
            if concept in {"Assets", "Liabilities", "StockholdersEquity"}:
                if fact.get("start") is not None:
                    continue
            elif fact.get("start") != manifest["period_start"]:
                continue
            rows.append([
                manifest["ticker"], manifest["cik"], concept, metadata.get("label"), unit,
                fact.get("start"), fact["end"], fact["val"], fact["accn"], fact["form"],
                fact["filed"], fact.get("fy"), fact.get("fp"), fact.get("frame"),
            ])
    return rows


def ingest_starter_pdf(session, fixture_dir=None):
    """Step 1: upload the verified bundled annual report; do not load SEC facts."""
    manifest, pdf, _ = read_fixture(fixture_dir)
    session.file.put_stream(
        io.BytesIO(pdf), "@annual_report_pdfs/" + manifest["relative_path"],
        auto_compress=False, overwrite=True,
    )
    session.sql("ALTER STAGE annual_report_pdfs REFRESH").collect()
    return {"report": manifest["relative_path"], "pdf_sha256": manifest["pdf_sha256"]}


def ingest_starter_ground_truth(session, fixture_dir=None):
    """Step 2: load the pinned SEC Company Facts response and reviewed metadata.

    This is SEC-sourced data from the bundled snapshot, not a live API request.
    """
    manifest, _, doc = read_fixture(fixture_dir)
    rows = reference_rows(manifest, doc)
    if not rows:
        raise ValueError("Fixture contains no matching SEC facts")
    merge_sec_facts(session, rows)
    session.sql(
        """MERGE INTO report_manifest t USING (
            SELECT ? AS relative_path, ? AS ticker, ? AS report_year,
                   TO_DATE(?) AS period_start, TO_DATE(?) AS period_end,
                   ? AS sec_accession, PARSE_JSON(?)::ARRAY AS page_ranges,
                   ? AS review_notes
        ) s ON t.relative_path = s.relative_path
        WHEN MATCHED THEN UPDATE SET ticker=s.ticker, report_year=s.report_year,
            period_start=s.period_start, period_end=s.period_end,
            sec_accession=s.sec_accession, page_ranges=s.page_ranges,
            approved=TRUE, review_notes=s.review_notes
        WHEN NOT MATCHED THEN INSERT
            (relative_path, ticker, report_year, period_start, period_end,
             sec_accession, page_ranges, approved, review_notes)
        VALUES (s.relative_path, s.ticker, s.report_year, s.period_start, s.period_end,
                s.sec_accession, s.page_ranges, TRUE, s.review_notes)""",
        params=[
            manifest["relative_path"], manifest["ticker"], manifest["report_year"],
            manifest["period_start"], manifest["period_end"], manifest["sec_accession"],
            json.dumps(manifest["page_ranges"]), manifest["review_notes"],
        ],
    ).collect()
    return {"report": manifest["relative_path"], "sec_rows": len(rows),
            "pdf_sha256": manifest["pdf_sha256"], "approved": True}


def load_starter(session, fixture_dir=None):
    """Compatibility helper: ingest the PDF, then the SEC ground truth."""
    ingest_starter_pdf(session, fixture_dir)
    return ingest_starter_ground_truth(session, fixture_dir)
