"""Render fictional earnings reports from structured records, locally or in Snowflake."""
import argparse
from copy import deepcopy
from datetime import date
from decimal import Decimal, ROUND_HALF_UP
import hashlib
import io
import json
from pathlib import Path

METRICS = {
    "revenue": ("Total net sales", 1),
    "gross_profit": ("Gross profit", 1),
    "operating_income": ("Operating income", 1),
    "net_income": ("Net income", 1),
    "eps_basic": ("Basic earnings per share", 1),
    "eps_diluted": ("Diluted earnings per share", 1),
    "assets": ("Total assets", 2),
    "liabilities": ("Total liabilities", 2),
    "equity": ("Total stockholders' equity", 2),
    "operating_cash_flow": ("Net cash provided by operating activities", 3),
}


def derive(record):
    """Inputs are USD millions and millions of shares; EPS is USD/share."""
    r = {k: Decimal(str(v)) if isinstance(v, (int, float)) else v
         for k, v in record.items()}
    r["revenue"] = r["products_revenue"] + r["services_revenue"]
    r["cost_of_sales"] = r["products_cost"] + r["services_cost"]
    r["gross_profit"] = r["revenue"] - r["cost_of_sales"]
    r["operating_expenses"] = r["research_development"] + r["selling_general_admin"]
    r["operating_income"] = r["gross_profit"] - r["operating_expenses"]
    r["pretax_income"] = r["operating_income"] + r["other_income"]
    r["net_income"] = r["pretax_income"] - r["income_tax"]
    for kind in ("basic", "diluted"):
        if r[f"shares_{kind}"] <= 0:
            raise ValueError("Share counts must be positive")
        r[f"eps_{kind}"] = (r["net_income"] / r[f"shares_{kind}"]).quantize(
            Decimal("0.01"), rounding=ROUND_HALF_UP)
    r["current_assets"] = sum(r[k] for k in (
        "cash", "marketable_securities_current", "receivables",
        "inventory", "other_current_assets"))
    r["assets"] = r["current_assets"] + sum(r[k] for k in (
        "marketable_securities_noncurrent", "property_equipment", "other_noncurrent_assets"))
    r["liabilities"] = r["current_liabilities"] + r["noncurrent_liabilities"]
    r["equity"] = r["assets"] - r["liabilities"]
    r["operating_cash_flow"] = sum(r[k] for k in (
        "net_income", "depreciation", "share_compensation", "working_capital_change"))
    r["investing_cash_flow"] = r["capital_expenditure"] + r["other_investing_cash_flow"]
    r["cash_change"] = sum(r[k] for k in (
        "operating_cash_flow", "investing_cash_flow", "financing_cash_flow"))
    if r["beginning_cash"] + r["cash_change"] != r["cash"]:
        raise ValueError(f"Cash flow does not reconcile for {record['fiscal_year']}")
    if date.fromisoformat(r["period_start"]) >= date.fromisoformat(r["period_end"]):
        raise ValueError("Invalid fiscal period")
    return r


def prepare(source):
    if source.get("synthetic") is not True:
        raise ValueError("Source must explicitly be marked synthetic")
    if source.get("currency") != "USD" or source.get("amount_scale") != 1000000:
        raise ValueError("This template requires USD millions")
    years = [derive(r) for r in source["years"]]
    if len(years) != 3 or any(
        years[i]["period_end"] <= years[i + 1]["period_end"] for i in range(2)
    ):
        raise ValueError("Provide three years, newest first")
    for current, prior in zip(years, years[1:]):
        if current["beginning_cash"] != prior["cash"]:
            raise ValueError("Comparative-year cash balances do not reconcile")
    return years


def number(value, eps=False):
    value = Decimal(value)
    text = f"{abs(value):,.2f}" if eps else f"{abs(value):,.0f}"
    return f"({text})" if value < 0 else text


def render_report(source):
    """Return (PDF bytes, manifest); no network or model calls."""
    from reportlab.lib import colors
    from reportlab.lib.enums import TA_RIGHT
    from reportlab.lib.pagesizes import letter
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
    from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak
    from xml.sax.saxutils import escape

    years = prepare(source)
    latest, prior = years[:2]
    buf = io.BytesIO()
    styles = getSampleStyleSheet()
    styles.add(ParagraphStyle("Financial", fontName="Helvetica", fontSize=9, leading=12))
    styles.add(ParagraphStyle("Numeric", parent=styles["Financial"], alignment=TA_RIGHT))
    story = []
    company = escape(source["company"])
    title = f"{company} | Fiscal {int(latest['fiscal_year'])} earnings report"

    def para(text, style="BodyText"):
        story.append(Paragraph(text, styles[style]))
        story.append(Spacer(1, 10))

    def heading(text):
        para(text, "Heading1")

    def table(rows, instant=False):
        label = "As of" if instant else "Year ended"
        data = [[Paragraph(label, styles["Financial"])] + [
            Paragraph(r["period_end"], styles["Numeric"]) for r in years]]
        for key, caption in rows:
            data.append([Paragraph(escape(caption), styles["Financial"])] + [
                Paragraph(number(r[key], key.startswith("eps_")), styles["Numeric"])
                for r in years])
        t = Table(data, colWidths=[285, 77, 77, 77], repeatRows=1, hAlign="LEFT")
        commands = [
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#edf1f5")),
            ("LINEBELOW", (0, 0), (-1, 0), 0.7, colors.HexColor("#1f344a")),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("TOPPADDING", (0, 0), (-1, -1), 7),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
            ("LINEABOVE", (0, -1), (-1, -1), 0.7, colors.HexColor("#1f344a")),
        ]
        t.setStyle(TableStyle(commands))
        story.append(t)

    heading(title)
    para("SYNTHETIC EVALUATION DOCUMENT", "Heading2")
    para(f"{company} is fictional. All amounts, securities identifiers, "
         "and financial statements in this report are invented for extraction testing. "
         "This report is unaudited, is not an SEC filing, and is not affiliated with Apple Inc.")
    heading("Full-year results")
    growth = (latest["revenue"] / prior["revenue"] - 1) * 100
    para(f"For the fiscal year ended {latest['period_end']}, {company} reported "
         f"net sales of ${latest['revenue'] / 1000:,.2f} billion, compared with "
         f"${prior['revenue'] / 1000:,.2f} billion in the preceding year "
         f"({growth:+.1f}%). Net income was ${latest['net_income'] / 1000:,.2f} billion "
         f"and diluted earnings per share were ${latest['eps_diluted']:.2f}.")
    para(f"Products generated ${latest['products_revenue'] / 1000:,.2f} billion "
         f"of net sales. Services generated ${latest['services_revenue'] / 1000:,.2f} billion. "
         "The statements that follow contain the full-year consolidated amounts; "
         "summary figures on this page are rounded.")
    para("Reporting basis", "Heading2")
    para("The statements use a simplified U.S. GAAP presentation for a fictional "
         "single-parent company with no noncontrolling interests. They are teaching "
         "fixtures, not a complete set of GAAP financial statements.")
    para("Contents: consolidated statements of operations (page 2), balance sheets "
         "(page 3), cash flows (page 4), and fiscal-calendar and accounting notes (page 5).")
    story.append(PageBreak())

    heading("Consolidated statements of operations")
    para("USD in millions, except per-share amounts. Shares in millions.")
    table([(k, caption) for k, caption in [
        ("products_revenue", "Net sales: Products"), ("services_revenue", "Net sales: Services"),
        ("revenue", "Total net sales"), ("products_cost", "Cost of sales: Products"),
        ("services_cost", "Cost of sales: Services"), ("cost_of_sales", "Total cost of sales"),
        ("gross_profit", "Gross profit"), ("research_development", "Research and development"),
        ("selling_general_admin", "Selling, general and administrative"),
        ("operating_expenses", "Total operating expenses"), ("operating_income", "Operating income"),
        ("other_income", "Other income / (expense), net"), ("pretax_income", "Income before taxes"),
        ("income_tax", "Provision for income taxes"), ("net_income", "Net income"),
        ("eps_basic", "Basic earnings per share"), ("eps_diluted", "Diluted earnings per share"),
        ("shares_basic", "Weighted-average shares: Basic"),
        ("shares_diluted", "Weighted-average shares: Diluted")]])
    story.append(PageBreak())

    heading("Consolidated balance sheets")
    para("USD in millions. Balances are at each fiscal year-end.")
    table([
        ("cash", "Cash and cash equivalents"),
        ("marketable_securities_current", "Current marketable securities"),
        ("receivables", "Accounts receivable, net"), ("inventory", "Inventories"),
        ("other_current_assets", "Other current assets"), ("current_assets", "Total current assets"),
        ("marketable_securities_noncurrent", "Noncurrent marketable securities"),
        ("property_equipment", "Property and equipment, net"),
        ("other_noncurrent_assets", "Other noncurrent assets"), ("assets", "Total assets"),
        ("current_liabilities", "Total current liabilities"),
        ("noncurrent_liabilities", "Total noncurrent liabilities"),
        ("liabilities", "Total liabilities"), ("equity", "Total stockholders' equity"),
        ("assets", "Total liabilities and stockholders' equity")], instant=True)
    story.append(PageBreak())

    heading("Consolidated statements of cash flows")
    para("USD in millions. Parentheses denote cash outflows or negative adjustments.")
    table([
        ("net_income", "Net income"), ("depreciation", "Depreciation and amortization"),
        ("share_compensation", "Share-based compensation"),
        ("working_capital_change", "Changes in operating assets and liabilities, net"),
        ("operating_cash_flow", "Net cash provided by operating activities"),
        ("capital_expenditure", "Purchases of property and equipment"),
        ("other_investing_cash_flow", "Other investing activities, net"),
        ("investing_cash_flow", "Net cash used in investing activities"),
        ("financing_cash_flow", "Net cash used in financing activities"),
        ("cash_change", "Increase / (decrease) in cash and cash equivalents"),
        ("beginning_cash", "Cash and cash equivalents, beginning of year"),
        ("cash", "Cash and cash equivalents, end of year")])
    story.append(PageBreak())

    heading("Notes to the consolidated statements")
    para("1. Fiscal calendar", "Heading2")
    for r in years:
        start, end = date.fromisoformat(r["period_start"]), date.fromisoformat(r["period_end"])
        weeks = ((end - start).days + 1) // 7
        para(f"Fiscal {int(r['fiscal_year'])} began {start.isoformat()} and ended "
             f"{end.isoformat()} and comprised {weeks} weeks.")
    para("2. Presentation and units", "Heading2")
    para("All statement amounts are in millions of U.S. dollars, except earnings per share. "
         "Multiply monetary statement amounts by 1,000,000 to obtain U.S. dollars. "
         "Basic and diluted earnings per share are U.S. dollars per share and use no multiplier. "
         "Net income is attributable entirely to the parent company's common shareholders.")
    para("3. Earnings per share", "Heading2")
    para("Basic and diluted earnings per share equal net income divided by the respective "
         "weighted-average shares and are rounded to the nearest cent. No adjusted or non-GAAP "
         "earnings figures are presented.")
    para("4. Evaluation provenance", "Heading2")
    para("The PDF is rendered from structured fictional records. The separate ground-truth "
         "artifact records the exact printed values, unit multipliers, and fiscal periods. "
         "It is not derived by extracting this PDF.")

    def footer(canvas, doc):
        canvas.saveState()
        canvas.setFont("Helvetica", 8)
        canvas.setFillColor(colors.HexColor("#536374"))
        canvas.drawString(48, 28, f"SYNTHETIC | {source['ticker']} | Not an SEC filing")
        canvas.drawRightString(564, 28, f"{doc.page}")
        canvas.restoreState()

    doc = SimpleDocTemplate(buf, pagesize=letter, rightMargin=48, leftMargin=48,
                            topMargin=40, bottomMargin=45, title=source["company"] + " synthetic earnings")
    doc.build(story, onFirstPage=footer, onLaterPages=footer)
    pdf = buf.getvalue()
    expected = {}
    for metric, (label, page) in METRICS.items():
        eps = metric.startswith("eps_")
        scale = 1 if eps else 1000000
        expected[metric] = {
            "raw_value": str(latest[metric]), "scale": scale,
            "value": float(latest[metric] * scale),
            "unit": "USD/shares" if eps else "USD",
            "start": None if metric in {"assets", "liabilities", "equity"} else latest["period_start"],
            "end": latest["period_end"], "label": label, "page_index": page,
        }
    manifest = {
        "synthetic": True, "reference_source": "STRUCTURED_SYNTHETIC",
        "ticker": source["ticker"], "report_year": int(latest["fiscal_year"]),
        "relative_path": f"synthetic/{source['ticker']}/{int(latest['fiscal_year'])}.pdf",
        "period_start": latest["period_start"], "period_end": latest["period_end"],
        "template_version": source["template_version"],
        "source_sha256": hashlib.sha256(json.dumps(source, sort_keys=True).encode()).hexdigest(),
        "pdf_sha256": hashlib.sha256(pdf).hexdigest(),
        "page_ranges": [{"start": 1, "end": 5}], "expected": expected,
    }
    return pdf, manifest


def generate_in_snowflake(session, source):
    """Use the active student schema and existing annual_report_pdfs stage."""
    pdf, manifest = render_report(deepcopy(source))
    path = manifest["relative_path"]
    session.file.put_stream(io.BytesIO(pdf), "@annual_report_pdfs/" + path,
                            auto_compress=False, overwrite=True)
    session.file.put_stream(
        io.BytesIO(json.dumps(manifest, indent=2).encode()),
        "@annual_report_pdfs/" + path.removesuffix(".pdf") + ".ground_truth.json",
        auto_compress=False, overwrite=True)
    session.sql("ALTER STAGE annual_report_pdfs REFRESH").collect()
    return manifest


def build_batch_sources(source):
    """Five deterministic financial scenarios; preserve accounting identities."""
    companies = [
        ("SYN_ORCH", "Orchard Devices, Inc."),
        ("SYN_CEDAR", "Cedar Systems, Inc."),
        ("SYN_MAPLE", "Maple Computing, Inc."),
        ("SYN_BIRCH", "Birch Electronics, Inc."),
        ("SYN_ELM", "Elm Technologies, Inc."),
    ]
    sources = []
    for factor, (ticker, company) in enumerate(companies, start=1):
        item = deepcopy(source)
        item.update(ticker=ticker, company=company)
        for record in item["years"]:
            for key, value in record.items():
                if isinstance(value, (int, float)) and key not in {
                    "fiscal_year", "shares_basic", "shares_diluted"
                }:
                    record[key] = value * factor
        prepare(item)
        sources.append(item)
    return sources


def generate_batch_in_snowflake(session, source):
    """Upload five PDFs plus ground truth, then publish the batch manifest last.

    Generation makes no AI calls. Run evaluate_synthetic.sql separately.
    """
    sources = build_batch_sources(source)
    # Validate/render every report before beginning uploads.
    reports = [render_report(item) for item in sources]
    manifests = []
    for pdf, manifest in reports:
        manifest["relative_path"] = manifest["relative_path"].replace(
            "synthetic/", "synthetic/batch/", 1)
        path = manifest["relative_path"]
        for data, target in (
            (pdf, path),
            (json.dumps(manifest, indent=2).encode(),
             path.removesuffix(".pdf") + ".ground_truth.json"),
        ):
            session.file.put_stream(
                io.BytesIO(data), "@annual_report_pdfs/" + target,
                auto_compress=False, overwrite=True)
        manifests.append(manifest)
    batch = {"synthetic": True, "report_count": 5, "reports": manifests}
    session.file.put_stream(
        io.BytesIO(json.dumps(batch, indent=2).encode()),
        "@annual_report_pdfs/synthetic/batch/manifest.json",
        auto_compress=False, overwrite=True)
    session.sql("ALTER STAGE annual_report_pdfs REFRESH").collect()
    save_batch_ground_truth(session, batch)
    return batch


def save_batch_ground_truth(session, batch):
    """Materialize structured expected answers, without reading PDFs or calling AI.

    Replaces this workflow's ground-truth table in the active student schema.
    """
    session.sql(
        """CREATE OR REPLACE TABLE synthetic_ground_truth AS
        WITH batch AS (SELECT PARSE_JSON(?) AS payload)
        SELECT r.value:relative_path::STRING AS relative_path,
               r.value:ticker::STRING AS ticker,
               r.value:report_year::INT AS report_year,
               m.key::STRING AS metric_id,
               m.value:label::STRING AS metric_label,
               m.value:raw_value::NUMBER(38, 2) AS expected_printed_value,
               m.value:scale::NUMBER(38, 0) AS expected_scale,
               m.value:value::NUMBER(38, 2) AS expected_value,
               m.value:unit::STRING AS expected_unit,
               TRY_TO_DATE(m.value:start::STRING) AS period_start,
               m.value:end::DATE AS period_end,
               m.value:page_index::INT AS page_index,
               r.value:source_sha256::STRING AS source_sha256,
               r.value:pdf_sha256::STRING AS pdf_sha256,
               'STRUCTURED_SYNTHETIC' AS reference_source
        FROM batch,
             LATERAL FLATTEN(INPUT => payload:reports) r,
             LATERAL FLATTEN(INPUT => r.value:expected) m""",
        params=[json.dumps(batch)],
    ).collect()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1] /
                        "fixtures/synthetic_earnings_source.json")
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).resolve().parents[1] / "fixtures")
    parser.add_argument("--batch", action="store_true", help="Generate five distinct reports")
    args = parser.parse_args()
    source = json.loads(args.source.read_text())
    if args.batch:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        manifests = []
        for item in build_batch_sources(source):
            pdf, manifest = render_report(item)
            manifest["relative_path"] = manifest["relative_path"].replace(
                "synthetic/", "synthetic/batch/", 1)
            stem = f"{manifest['ticker']}_{manifest['report_year']}"
            (args.output_dir / f"{stem}.pdf").write_bytes(pdf)
            (args.output_dir / f"{stem}.ground_truth.json").write_text(
                json.dumps(manifest, indent=2) + "\n")
            manifests.append(manifest)
        (args.output_dir / "manifest.json").write_text(json.dumps(
            {"synthetic": True, "report_count": 5, "reports": manifests}, indent=2) + "\n")
        (args.output_dir / "sources.json").write_text(
            json.dumps(build_batch_sources(source), indent=2) + "\n")
        print(json.dumps({"reports": len(manifests), "output_dir": str(args.output_dir)}))
        return
    pdf, manifest = render_report(source)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    stem = f"{manifest['ticker']}_{manifest['report_year']}"
    (args.output_dir / f"{stem}.pdf").write_bytes(pdf)
    (args.output_dir / f"{stem}.ground_truth.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"pdf": str(args.output_dir / f"{stem}.pdf"), "metrics": len(manifest["expected"])}))


if __name__ == "__main__":
    main()
