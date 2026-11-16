"""Load SEC Company Facts into the current schema with Snowpark."""
import json
import time

from ingestion_common import fetch, log, run_cli, validate


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

    # Replace the requested filing-year window so reruns don't duplicate facts.
    session.sql(
        "DELETE FROM sec_facts WHERE ticker = ? AND fiscal_year BETWEEN ? AND ?",
        params=[ticker, first_year, last_year + 1],
    ).collect()
    if rows:
        # Explicit types support batches where an entire column is NULL.
        from snowflake.snowpark.types import (
            DoubleType, LongType, StringType, StructField, StructType,
        )

        columns = [
            "TICKER", "CIK", "CONCEPT", "LABEL", "UNIT", "START_DATE", "END_DATE",
            "FACT_VALUE", "ACCESSION", "FORM", "FILED_DATE", "FISCAL_YEAR",
            "FISCAL_PERIOD", "FRAME",
        ]
        schema = StructType([
            StructField(
                name,
                DoubleType() if name == "FACT_VALUE"
                else LongType() if name == "FISCAL_YEAR"
                else StringType(),
            )
            for name in columns
        ])
        # ISO date strings are cast to the destination's DATE columns on insert.
        session.create_dataframe(rows, schema=schema).write.mode("append").save_as_table(
            "sec_facts", column_order="name",
        )
    log(session, ticker, None, "SEC_XBRL", facts_url, "SUCCESS", f"{len(rows)} facts loaded")
    return {"ticker": ticker, "cik": cik, "xbrl_fact_rows": len(rows)}


def main(session):
    """Notebook entry point; the caller owns and closes the session."""
    return ingest_sec_facts(session, "AAPL", 2023, 2023)


if __name__ == "__main__":
    run_cli(ingest_sec_facts)
