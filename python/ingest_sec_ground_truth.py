"""Load SEC Company Facts into the current schema with Snowpark."""
import json
import time

from ingestion_common import fetch, log, run_cli, validate
from sec_facts import merge_sec_facts


def ingest_sec_facts(session, target_ticker, first_year, last_year):
    """Load selected US-GAAP facts from original 10-K filings."""
    ticker = validate(target_ticker, first_year, last_year)
    allowed_sec = {"www.sec.gov", "data.sec.gov"}

    lookup_url = "https://www.sec.gov/files/company_tickers.json"
    ticker_json = fetch(lookup_url, allowed_sec)
    if not ticker_json:
        raise ValueError("SEC ticker lookup returned no data")
    all_companies = json.loads(ticker_json)
    row = next(
        (item for item in all_companies.values()
         if item.get("ticker", "").upper() == ticker),
        None,
    )
    if row is None:
        raise ValueError("No SEC CIK found for ticker " + ticker)
    cik = str(row["cik_str"]).zfill(10)
    time.sleep(0.2)

    facts_url = f"https://data.sec.gov/api/xbrl/companyfacts/CIK{cik}.json"
    raw = fetch(facts_url, allowed_sec)
    if not raw:
        raise ValueError("SEC Company Facts not found for CIK " + cik)
    doc = json.loads(raw)
    concepts = {
        "Revenues", "RevenueFromContractWithCustomerExcludingAssessedTax",
        "SalesRevenueNet", "NetIncomeLoss", "Assets", "Liabilities",
        "StockholdersEquity", "OperatingIncomeLoss", "GrossProfit",
        "EarningsPerShareBasic", "EarningsPerShareDiluted",
        "NetCashProvidedByUsedInOperatingActivities",
    }
    rows = []
    for tag, meta in doc.get("facts", {}).get("us-gaap", {}).items():
        if tag not in concepts:
            continue
        for unit, observations in meta.get("units", {}).items():
            for observation in observations:
                if observation.get("form") != "10-K":
                    continue
                if not (first_year <= int(observation.get("fy") or 0) <= last_year + 1):
                    continue
                rows.append((
                    ticker, cik, tag, meta.get("label"), unit,
                    observation.get("start"), observation.get("end"),
                    None if observation.get("val") is None else float(observation["val"]),
                    observation.get("accn"), observation.get("form"),
                    observation.get("filed"), observation.get("fy"),
                    observation.get("fp"), observation.get("frame"),
                ))

    merge_sec_facts(session, rows)
    log(session, ticker, None, "SEC_XBRL", facts_url, "SUCCESS", f"{len(rows)} facts loaded")
    return {"ticker": ticker, "cik": cik, "xbrl_fact_rows": len(rows)}


def main(session):
    """Notebook entry point; the caller owns and closes the session."""
    return ingest_sec_facts(session, "AAPL", 2023, 2023)


if __name__ == "__main__":
    run_cli(ingest_sec_facts)
