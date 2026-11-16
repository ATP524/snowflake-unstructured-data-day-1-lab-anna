"""Download AnnualReports.com PDFs and upload them through Snowpark."""
import io
import json
import time

from ingestion_common import fetch, log, run_cli, validate


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
                pdf = fetch(url, allowed_pdf, binary=True)
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
    """Notebook entry point; the caller owns and closes the session."""
    return ingest_annual_report_pdfs(session, "AAPL", 2023, 2023)


# Schema that holds the lab tables and stage (see sql/ddls.sql) when run in a Workspace.
WORKSPACE_DATABASE = "BOOTCAMP"
WORKSPACE_SCHEMA = "PUBLIC"


def _active_session():
    """Return the Workspace kernel's session, or None when run from a CLI."""
    try:
        from snowflake.snowpark.context import get_active_session
        return get_active_session()
    except Exception:
        return None


if __name__ == "__main__":
    active = _active_session()
    if active is not None:
        active.use_database(WORKSPACE_DATABASE)
        active.use_schema(WORKSPACE_SCHEMA)
        print(json.dumps(main(active), indent=2))
    else:
        run_cli(ingest_annual_report_pdfs)
