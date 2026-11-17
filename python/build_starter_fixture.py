"""Fetch source artifacts once; run locally before publishing course fixtures."""
import hashlib
import io
import json
from pathlib import Path
import time

import requests
from pypdf import PdfReader

PDF_URL = "https://www.annualreports.com/HostedData/AnnualReportArchive/a/NASDAQ_AAPL_2023.pdf"
SEC_URL = "https://data.sec.gov/api/xbrl/companyfacts/CIK0000320193.json"


SEC_USER_AGENT = "FinancialDocumentsCourse zach@dataexpert.io"


def main():
    target = Path(__file__).resolve().parents[1] / "fixtures"
    target.mkdir(exist_ok=True)
    headers = {"User-Agent": SEC_USER_AGENT}
    for url, filename in ((PDF_URL, "AAPL_2023.pdf"), (SEC_URL, "AAPL_companyfacts.json")):
        response = requests.get(url, headers=headers, timeout=90)
        response.raise_for_status()
        data = response.content
        if filename.endswith(".pdf"):
            if not data.startswith(b"%PDF-"):
                raise ValueError("Source is not a PDF")
            reader = PdfReader(io.BytesIO(data))
            print("PDF SHA256:", hashlib.sha256(data).hexdigest())
            print("PDF page count:", len(reader.pages))
            for index, page in enumerate(reader.pages):
                text = page.extract_text() or ""
                if index in (0, 30, 32, 34, 35):
                    print("REVIEW PAGE INDEX", index, text[:1800])
        else:
            doc = response.json()
            print("SEC entity:", doc["entityName"])
            for concept in ("Assets", "RevenueFromContractWithCustomerExcludingAssessedTax", "EarningsPerShareDiluted"):
                matches = [
                    dict(fact, unit=unit)
                    for unit, observations in doc["facts"]["us-gaap"][concept]["units"].items()
                    for fact in observations
                    if fact.get("accn") == "0000320193-23-000106"
                    and fact.get("end") == "2023-09-30"
                    and (concept == "Assets" or fact.get("start") == "2022-09-25")
                ]
                print(concept, json.dumps(matches))
        (target / filename).write_bytes(data)
        time.sleep(0.3)


if __name__ == "__main__":
    main()
