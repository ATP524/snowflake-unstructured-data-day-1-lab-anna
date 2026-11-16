"""Upsert SEC observations into the current session's student schema."""
import json


COLUMNS = (
    "ticker", "cik", "concept", "label", "unit", "start_date", "end_date",
    "fact_value", "accession", "form", "filed_date", "fiscal_year",
    "fiscal_period", "frame",
)
KEY_COLUMNS = (
    "ticker", "accession", "concept", "unit", "start_date", "end_date",
    "form", "fiscal_year", "fiscal_period", "frame",
)


def merge_sec_facts(session, rows):
    """Merge observations without removing facts absent from this batch."""
    unique = {}
    for row in rows:
        if len(row) != len(COLUMNS):
            raise ValueError("SEC fact row must contain 14 fields")
        row = tuple(row)
        key = tuple(row[COLUMNS.index(column)] for column in KEY_COLUMNS)
        if key in unique and unique[key] != row:
            raise ValueError("Conflicting SEC observations for the same fact key")
        unique[key] = row
    if not unique:
        return 0

    types = {
        "start_date": "DATE", "end_date": "DATE", "filed_date": "DATE",
        "fact_value": "FLOAT", "fiscal_year": "INT",
    }
    projection = ", ".join(
        f"NULLIF(value[{index}], PARSE_JSON('null'))::{types.get(column, 'STRING')} AS {column}"
        for index, column in enumerate(COLUMNS)
    )
    condition = " AND ".join(
        f"EQUAL_NULL(t.{column}, s.{column})" for column in KEY_COLUMNS
    )
    updates = ", ".join(f"{column}=s.{column}" for column in COLUMNS)
    session.sql(
        f"""MERGE INTO sec_facts t
        USING (
            SELECT {projection}
            FROM TABLE(FLATTEN(INPUT => PARSE_JSON(?)))
        ) s ON {condition}
        WHEN MATCHED THEN UPDATE SET {updates}, loaded_at=CURRENT_TIMESTAMP()
        WHEN NOT MATCHED THEN INSERT ({', '.join(COLUMNS)})
        VALUES ({', '.join('s.' + column for column in COLUMNS)})""",
        params=[json.dumps(list(unique.values()), allow_nan=False)],
    ).collect()
    return len(unique)
