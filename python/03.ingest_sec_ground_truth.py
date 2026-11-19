##objective: loading data from existing pipeline into the SQL sec table we just created in DDLs
##first specify service (create new on first day)
## the actual data from the sec; the correct extraction data

"""Load SEC Company Facts into the current schema with Snowpark."""
import json
import time

from datetime import date
from urllib.parse import urlparse

import requests

from lab_settings import read_ingest_settings
from sec_facts import merge_sec_facts

# The ticker and year range are NOT set here: they come from lab_settings,
# set once in python/00.set_session_variables.ipynb, so steps 02 and 03 always
# cover the same ticker-years.

# Set your contact address here before making SEC requests.
SEC_USER_AGENT = "FinancialDocumentsCourse zach@dataexpert.io"


def log(session, ticker, year, source, url, status, detail=""):
    session.sql(
        """INSERT INTO ingest_log
           (ticker, fiscal_year, source, source_url, status, detail)
           SELECT ?, ?, ?, ?, ?, ?""",
        params=[ticker, -1 if year is None else year, source, url, status, detail[:1000]],
    ).collect()


def fetch(url, allowed_hosts):
    """Download JSON with bounded retries; do not follow unverified redirects."""
    if urlparse(url).scheme != "https" or urlparse(url).hostname not in allowed_hosts:
        raise ValueError("URL must use HTTPS and an allowlisted host")
    for attempt in range(3):
        try:
            with requests.get(
                url, headers={"User-Agent": SEC_USER_AGENT,
                              "Accept": "application/json"},
                timeout=(12, 55), allow_redirects=False, stream=True,
            ) as response:
                if response.status_code in (301, 302, 303, 307, 308):
                    raise ValueError("Redirect not followed: verify the target host first")
                if response.status_code == 404:
                    return None
                if response.status_code in (429, 500, 502, 503, 504):
                    raise RuntimeError(f"Retryable HTTP {response.status_code}")
                response.raise_for_status()
                return b"".join(part for part in response.iter_content(128 * 1024) if part)
        except (requests.RequestException, RuntimeError):
            if attempt == 2:
                raise
            time.sleep(2 * (attempt + 1))
    return None


def validate(target_ticker, first_year, last_year):
    ticker = target_ticker.strip().upper()
    if not ticker or not ticker.isascii() or not ticker.replace("-", "").isalnum():
        raise ValueError("Invalid ticker")
    if not (2009 <= first_year <= last_year <= date.today().year):
        raise ValueError("Invalid year range")
    if last_year - first_year > 5:
        raise ValueError("Run in groups of at most six years")
    return ticker




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
    """Ingest the scope set in lab_settings; leave the session open."""
    ticker, first_year, last_year = read_ingest_settings(session)
    return ingest_sec_facts(session, ticker, first_year, last_year)


if __name__ == "__main__":
    from snowflake.snowpark.context import get_active_session
    session = get_active_session()
    session.sql("USE WAREHOUSE compute_wh").collect()
    session.sql("USE DATABASE bootcamp").collect()
    session.sql("USE SCHEMA atp524").collect()
    print(json.dumps(main(session), indent=2))
