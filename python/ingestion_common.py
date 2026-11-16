"""Shared helpers for the Snowpark ingestion scripts."""
import argparse
from datetime import date
import json
import time
from urllib.parse import urlparse

import requests

SEC_USER_AGENT = "FinancialDocumentsCourse zach@dataexpert.io"
MAX_PDF_BYTES = 30 * 1024 * 1024


def log(session, ticker, year, source, url, status, detail=""):
    session.sql(
        """INSERT INTO ingest_log
           (ticker, fiscal_year, source, source_url, status, detail)
           SELECT ?, ?, ?, ?, ?, ?""",
        params=[ticker, -1 if year is None else year, source, url, status, detail[:1000]],
    ).collect()


def fetch(url, allowed_hosts, binary=False):
    # Check before issuing the request and never follow redirects.
    if urlparse(url).scheme != "https" or urlparse(url).hostname not in allowed_hosts:
        raise ValueError("URL must use HTTPS and an allowlisted host")
    headers = {
        "User-Agent": SEC_USER_AGENT,
        "Accept": "application/json,application/pdf,*/*",
    }
    for attempt in range(3):
        try:
            with requests.get(
                url, headers=headers, timeout=(12, 55),
                allow_redirects=False, stream=True,
            ) as response:
                if response.status_code in (301, 302, 303, 307, 308):
                    raise ValueError("Redirect not followed: verify the target host first")
                if response.status_code == 404:
                    return None
                if response.status_code in (429, 500, 502, 503, 504):
                    raise RuntimeError(f"Retryable HTTP {response.status_code}")
                response.raise_for_status()
                parts = []
                byte_count = 0
                for part in response.iter_content(chunk_size=128 * 1024):
                    if not part:
                        continue
                    byte_count += len(part)
                    if binary and byte_count > MAX_PDF_BYTES:
                        raise ValueError("PDF exceeds 30 MB safety cap")
                    parts.append(part)
                return b"".join(parts)
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


def run_cli(job):
    """Open a named Snowflake connection only when a script is executed."""
    parser = argparse.ArgumentParser(description=job.__doc__)
    parser.add_argument("--connection", required=True, help="Named Snowflake connection")
    parser.add_argument("--ticker", default="AAPL")
    parser.add_argument("--first-year", type=int, default=2021)
    parser.add_argument("--last-year", type=int, default=2025)
    args = parser.parse_args()
    validate(args.ticker, args.first_year, args.last_year)

    # Imports stay local so tests and module imports do not need Snowpark.
    from snowflake.snowpark import Session

    session = Session.builder.config("connection_name", args.connection).create()
    try:
        print(json.dumps(job(session, args.ticker, args.first_year, args.last_year), indent=2))
    finally:
        session.close()
