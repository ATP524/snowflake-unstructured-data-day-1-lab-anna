"""Read the lab scope (ticker + year range) from the lab_settings table.

The scope is set once in python/00.set_session_variables.ipynb. Every step that
ingests or processes reports reads it from here, so the PDF download (02), the
SEC facts load (03) and all SQL steps cover exactly the same ticker-years.
"""


def read_ingest_settings(session):
    """Return (ticker, first_year, last_year); raise if the scope is not set."""
    rows = session.sql(
        "SELECT ticker, first_year, last_year FROM lab_settings"
    ).collect()
    if len(rows) != 1:
        raise ValueError(
            "lab_settings must contain exactly one row; set the scope in "
            "python/00.set_session_variables.ipynb (found %d rows)" % len(rows)
        )
    row = rows[0]
    ticker, first_year, last_year = row["TICKER"], row["FIRST_YEAR"], row["LAST_YEAR"]
    if not ticker or first_year is None or last_year is None:
        raise ValueError("lab_settings has an empty ticker or year; set the scope in 00")
    return str(ticker), int(first_year), int(last_year)
