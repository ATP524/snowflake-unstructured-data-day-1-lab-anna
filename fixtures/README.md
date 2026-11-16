# Starter fixture provenance

Date: 2026-11-16  
POC: Course instructor  
TL;DR: The bundled Apple 2023 report and SEC Company Facts response let the first exercise run without live source downloads.

## Sources and identity

- PDF: https://www.annualreports.com/HostedData/AnnualReportArchive/a/NASDAQ_AAPL_2023.pdf
- SEC Company Facts: https://data.sec.gov/api/xbrl/companyfacts/CIK0000320193.json
- Filing: https://www.sec.gov/Archives/edgar/data/320193/000032019323000106/aapl-20230930.htm
- Entity: Apple Inc., CIK `0000320193`, ticker `AAPL`
- Form and accession: original 10-K, `0000320193-23-000106`
- Filing date: 2023-11-03
- Fiscal interval: 2022-09-25 through 2023-09-30
- Local download and verification date: 2026-11-16

The JSON is a full Company Facts response as retrieved, not a hand-written answer key. The loader selects matching concepts from the specific accession and dates. It preserves each selected observation's provenance.

## Integrity

| File | Bytes | SHA-256 |
| --- | --- | --- |
| `AAPL_2023.pdf` | 807316 | `068176ab665682096a79859d73b805c7b2fda05331e503f26d893b582353464e` |
| `AAPL_companyfacts.json` | 3859564 | `f085735b4d08fb116ade18d24247ffabe11df8eb52eae6556b165831f15ef1ad` |

`starter_manifest.json` pins these hashes. `load_starter.py` rejects changed artifacts before uploading or modifying tables.

## Review performed

The PDF has 80 pages. Local text inspection confirmed the cover identifies Apple's fiscal 2023 Form 10-K, the consolidated statement headers and scale notes, and these zero-based PDF page indexes:

| Index | Printed page | Content |
| --- | --- | --- |
| 30 | 28 | Consolidated statements of operations |
| 32 | 30 | Consolidated balance sheets |
| 34 | 32 | Consolidated statements of cash flows |
| 35 | 33 | Notes, including the 53-week fiscal calendar and revenue net of taxes |

The selected range is `[30, 36)`, including six pages. The starter deliberately includes the calendar note to support duration-date extraction and enough statements to expand to ten metrics.

Independent matching SEC observations from the pinned response are:

| Concept | Unit | Value |
| --- | --- | --- |
| `Assets` | USD | 352583000000 |
| `RevenueFromContractWithCustomerExcludingAssessedTax` | USD | 383285000000 |
| `EarningsPerShareDiluted` | USD/shares | 6.13 |

All three observations have the accession and end date above. The two duration facts start on 2022-09-25; assets has no start date. The PDF shows assets of 352,583 million, total net sales of 383,285 million, and diluted EPS of 6.13.

## Refresh policy

Keep these artifacts pinned for the course. A current SEC response may include new facts and a different hash; that does not mean this snapshot is damaged. The instructor guide explains intentional refreshes and review.

These source documents remain third-party materials. Review redistribution requirements before publishing them in a public course repository. Local artifact verification does not establish that hosted notebook uploads or Snowflake AI calls work; those need a classroom-runtime rehearsal.
