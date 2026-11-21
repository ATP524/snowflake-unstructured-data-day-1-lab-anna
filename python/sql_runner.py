"""Run the lab's SQL step files (and notebook SQL cells) from Python, in order.

Used by python/00.run_pipeline.ipynb so every step runs from the .sql file itself
(one source of truth), and by python/export_notebook_sql.py to turn a notebook's
SQL cells into a .sql file.

    from sql_runner import run_sql_file
    results = run_sql_file(session, "sql/04.prepare_manifest.sql")
"""
import hashlib
import io
import json
import re
from pathlib import Path


def find_project_root(start=None):
    """Return the folder that contains both sql/ and python/ (works from any subfolder)."""
    here = Path(start or Path.cwd()).resolve()
    for folder in (here, *here.parents):
        if (folder / "sql").is_dir() and (folder / "python").is_dir():
            return folder
    raise FileNotFoundError("Could not find the project root (a folder with sql/ and python/)")


def split_sql(text):
    """Split SQL text into executable statements, dropping comment-only pieces.

    Uses the Snowflake connector's splitter when available (it understands $$ blocks,
    quotes and comments); otherwise falls back to a splitter with the same rules.
    """
    try:
        from snowflake.connector.util_text import split_statements
        pieces = [s for s, _ in split_statements(io.StringIO(text), remove_comments=True)]
    except ImportError:
        pieces = _split_sql_fallback(text)
    return [p.strip() for p in pieces if p.strip().rstrip(";").strip()]


def _split_sql_fallback(text):
    statements, current, i, n = [], [], 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "--" or two == "//":
            end = text.find("\n", i)
            i = n if end == -1 else end
        elif two == "/*":
            end = text.find("*/", i + 2)
            i = n if end == -1 else end + 2
        elif two == "$$":
            end = text.find("$$", i + 2)
            end = n if end == -1 else end + 2
            current.append(text[i:end])
            i = end
        elif text[i] == "'":
            j = i + 1
            while j < n and not (text[j] == "'" and text[j + 1:j + 2] != "'"):
                j += 2 if text[j:j + 2] in ("''", "\\'") else 1
            current.append(text[i:j + 1])
            i = j + 1
        elif text[i] == ";":
            statements.append("".join(current))
            current, i = [], i + 1
        else:
            current.append(text[i])
            i += 1
    statements.append("".join(current))
    return statements


def notebook_sql_cells(notebook_path):
    """Return the SQL source of each SQL cell in a notebook, in order."""
    notebook = json.loads(Path(notebook_path).read_text())
    cells = []
    for cell in notebook.get("cells", []):
        if cell.get("cell_type") != "code":
            continue
        source = "".join(cell.get("source", []))
        language = cell.get("metadata", {}).get("language", "")
        lines = source.splitlines()
        if lines and lines[0].startswith("%%sql"):
            source, language = "\n".join(lines[1:]), "sql"
        if language == "sql":
            title = cell.get("metadata", {}).get("title", "")
            cells.append((title, source.strip()))
    return cells


def notebook_sql_text(notebook_path):
    """All SQL cells of a notebook joined into one script, titled by cell."""
    parts = []
    for title, source in notebook_sql_cells(notebook_path):
        header = f"-- [cell] {title}\n" if title else ""
        parts.append(header + source.rstrip().rstrip(";") + ";")
    return "\n\n".join(parts) + "\n"


def _set_query_tag(session, tag):
    """Set QUERY_TAG and return the previous value ('' if none), so it can be restored."""
    previous = ""
    try:
        rows = session.sql("SHOW PARAMETERS LIKE 'QUERY_TAG' IN SESSION").collect()
        if rows:
            row = rows[0].as_dict() if hasattr(rows[0], "as_dict") else dict(rows[0])
            previous = str(row.get("value") or row.get("VALUE") or "")
    except Exception:
        pass
    session.sql("ALTER SESSION SET QUERY_TAG = '%s'" % tag.replace("'", "")).collect()
    return previous


def run_sql_text(session, text, label="", show=True, query_tag=None):
    """Execute every statement in `text` in order; return [(statement, rows)].

    Stops at the first failing statement and re-raises with the step label and the
    statement, so a failure is never silent. With `query_tag`, every statement is
    tagged (Snowflake QUERY_TAG) for cost and history reports; the session's previous
    tag is restored afterwards.
    """
    previous_tag = _set_query_tag(session, query_tag) if query_tag else None
    results = []
    try:
        for statement in split_sql(text):
            try:
                rows = session.sql(statement).collect()
            except Exception as exc:
                raise RuntimeError(f"{label}: failed on statement:\n{statement[:500]}\n{exc}") from exc
            results.append((statement, rows))
            if show:
                first_line = " ".join(statement.split())[:90]
                print(f"  ok  {first_line}  -> {len(rows)} row(s)")
    finally:
        if query_tag:
            session.sql("ALTER SESSION SET QUERY_TAG = '%s'" % previous_tag.replace("'", "")).collect()
    return results


def run_sql_file(session, path, show=True, tag=True):
    """Run a .sql file (or the SQL cells of a .ipynb) from the project root.

    Each statement is tagged 'lab:<file name>' (e.g. lab:08.extract_reports.ipynb), so
    QUERY_HISTORY and AI-cost views can be grouped by pipeline step.
    """
    path = Path(path)
    if not path.is_absolute():
        path = find_project_root() / path
    text = notebook_sql_text(path) if path.suffix == ".ipynb" else path.read_text()
    print(f"== {path.name}")
    return run_sql_text(session, text, label=path.name, show=show,
                        query_tag=f"lab:{path.name}" if tag else None)


# ---------------------------------------------------------------------------------
# DDL skip check (used by the runner for 01.ddls.sql). 01 is safe to re-run but slow;
# the runner skips it only when it provably has nothing to do.
# ---------------------------------------------------------------------------------
_DDL_OBJECT = re.compile(
    r"^\s*CREATE\s+(?:OR\s+REPLACE\s+)?(TABLE|FUNCTION)\s+(?:IF\s+NOT\s+EXISTS\s+)?([A-Za-z_][A-Za-z0-9_]*)",
    re.IGNORECASE | re.MULTILINE)


def ddl_objects(text):
    """Tables and functions a DDL file creates: {'TABLE': {...}, 'FUNCTION': {...}} (upper case)."""
    found = {"TABLE": set(), "FUNCTION": set()}
    for kind, name in _DDL_OBJECT.findall(text):
        found[kind.upper()].add(name.upper())
    return found


def file_sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def ddl_status(session, path):
    """Return (up_to_date, reason) for a DDL file in the current schema.

    Up to date only when ddl_applied holds this file's current SHA-256 AND every table
    and function the file creates exists. Anything else (first run, an edited file, a
    dropped object, or the check itself failing) means "run it".
    """
    path = Path(path)
    sha = file_sha256(path)
    try:
        rows = session.sql("SELECT sha256, applied_at FROM ddl_applied WHERE file_name = ?",
                           params=[path.name]).collect()
    except Exception:
        return False, "no ddl_applied record yet (new schema or first run)"
    if not rows:
        return False, f"{path.name} has never been applied by the runner"
    if rows[0][0] != sha:
        return False, f"{path.name} changed since it was last applied ({rows[0][1]:%Y-%m-%d %H:%M})"
    wanted = ddl_objects(path.read_text())
    existing = {
        "TABLE": {r[0].upper() for r in session.sql(
            "SELECT table_name FROM information_schema.tables "
            "WHERE table_schema = CURRENT_SCHEMA() AND table_type = 'BASE TABLE'").collect()},
        "FUNCTION": {r[0].upper() for r in session.sql(
            "SELECT function_name FROM information_schema.functions "
            "WHERE function_schema = CURRENT_SCHEMA()").collect()},
    }
    missing = sorted(f"{kind.lower()} {name}" for kind in wanted for name in wanted[kind] - existing[kind])
    if missing:
        return False, "missing: " + ", ".join(missing)
    count = sum(len(v) for v in wanted.values())
    return True, f"unchanged since {rows[0][1]:%Y-%m-%d %H:%M}; all {count} tables and functions exist"


def record_ddl_applied(session, path):
    """Record that `path` ran without error (call only after a successful run)."""
    path = Path(path)
    session.sql(
        "MERGE INTO ddl_applied t USING (SELECT ? AS file_name, ? AS sha256) s "
        "ON t.file_name = s.file_name "
        "WHEN MATCHED THEN UPDATE SET sha256 = s.sha256, applied_at = CURRENT_TIMESTAMP() "
        "WHEN NOT MATCHED THEN INSERT (file_name, sha256) VALUES (s.file_name, s.sha256)",
        params=[path.name, file_sha256(path)]).collect()
