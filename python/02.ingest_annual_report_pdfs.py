## puts PDF documents by getting PDFs
# this data is a PDF we can go and read online (i.e. the annual report 2025 report which has things we need and things we do not)

"""Download AnnualReports.com PDFs and upload them through Snowpark."""
import io
import json
import time

from datetime import date
from urllib.parse import urlparse

import requests

from lab_settings import read_ingest_settings

# The ticker and year range are NOT set here: they come from lab_settings,
# set once in python/00.set_session_variables.ipynb, so steps 02 and 03 always
# cover the same ticker-years.

SEC_USER_AGENT = "FinancialDocumentsCourse zach@dataexpert.io"
MAX_PDF_BYTES = 30 * 1024 * 1024


def log(session, ticker, year, source, url, status, detail=""):
    session.sql(
        """INSERT INTO ingest_log
           (ticker, fiscal_year, source, source_url, status, detail)
           SELECT ?, ?, ?, ?, ?, ?""",
        params=[ticker, -1 if year is None else year, source, url, status, detail[:1000]],
    ).collect()


def fetch(url, allowed_hosts):
    """Download a PDF with bounded retries and a 30 MB safety cap."""
    if urlparse(url).scheme != "https" or urlparse(url).hostname not in allowed_hosts:
        raise ValueError("URL must use HTTPS and an allowlisted host")
    for attempt in range(3):
        try:
            with requests.get(
                url, headers={"User-Agent": SEC_USER_AGENT,
                              "Accept": "application/pdf"},
                timeout=(12, 55), allow_redirects=False, stream=True,
            ) as response:
                if response.status_code in (301, 302, 303, 307, 308):
                    raise ValueError("Redirect not followed: verify the target host first")
                if response.status_code == 404:
                    return None
                if response.status_code in (429, 500, 502, 503, 504):
                    raise RuntimeError(f"Retryable HTTP {response.status_code}")
                response.raise_for_status()
                parts, byte_count = [], 0
                for part in response.iter_content(chunk_size=128 * 1024):
                    if not part:
                        continue
                    byte_count += len(part)
                    if byte_count > MAX_PDF_BYTES:
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


def pdf_candidates(ticker, year):
    # These historical patterns are candidates, not guaranteed URLs.
    for exchange in ("NASDAQ", "NYSE"):
        basename = f"{exchange}_{ticker}_{year}.pdf"
        yield f"https://www.annualreports.com/HostedData/AnnualReports/PDF/{basename}"
        yield (
            "https://www.annualreports.com/HostedData/AnnualReportArchive/"
            f"{ticker[0].lower()}/{basename}"
        )


def ingest_annual_report_pdfs(session, target_ticker, first_year, last_year):
    """Download up to six report years into the current schema's PDF stage."""
    ticker = validate(target_ticker, first_year, last_year)
    allowed_pdf = {"www.annualreports.com", "annualreports.com"}
    successes, failures = [], []
    for year in range(first_year, last_year + 1):
        found = False
        for url in pdf_candidates(ticker, year):
            try:
                pdf = fetch(url, allowed_pdf)
                if pdf is None:
                    continue
                if not pdf.startswith(b"%PDF-"):
                    log(session, ticker, year, "PDF", url, "ERROR", "Response is not a PDF")
                    continue
                session.file.put_stream(
                    io.BytesIO(pdf), f"@annual_report_pdfs/{ticker}/{year}.pdf",
                    auto_compress=False, overwrite=True,
                )
                log(session, ticker, year, "PDF", url, "SUCCESS", f"{len(pdf)} bytes")
                successes.append(year)
                found = True
                break
            except Exception as exc:
                log(session, ticker, year, "PDF", url, "ERROR", str(exc))
            finally:
                time.sleep(0.5)
        if not found:
            log(session, ticker, year, "PDF", "", "MISSING", "No valid PDF found at tested URLs")
            failures.append(year)
        time.sleep(1)
    if successes:
        session.sql("ALTER STAGE annual_report_pdfs REFRESH").collect()
    return {"ticker": ticker, "pdf_years_downloaded": successes, "pdf_years_missing": failures}


def main(session):
    """Ingest the scope set in lab_settings; leave the session open."""
    ticker, first_year, last_year = read_ingest_settings(session)
    return ingest_annual_report_pdfs(session, ticker, first_year, last_year)


if __name__ == "__main__":
    from snowflake.snowpark.context import get_active_session
    session = get_active_session()
    session.sql("USE WAREHOUSE compute_wh").collect()
    session.sql("USE DATABASE bootcamp").collect()
    session.sql("USE SCHEMA atp524").collect()
    print(json.dumps(main(session), indent=2))
