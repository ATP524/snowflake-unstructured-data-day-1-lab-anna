"""Offline checks for the shared SEC fact MERGE."""
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import MagicMock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
from sec_facts import COLUMNS, KEY_COLUMNS, merge_sec_facts


class SecFactMergeTests(unittest.TestCase):
    def setUp(self):
        self.row = [
            "AAPL", "0000320193", "Assets", "Assets", "USD", None,
            "2023-09-30", 100.0, "original", "10-K", "2023-11-01",
            2023, "FY", None,
        ]

    def test_merge_has_typed_source_null_safe_keys_and_upsert_branches(self):
        session = MagicMock()
        self.assertEqual(merge_sec_facts(session, [self.row]), 1)
        session.sql.assert_called_once()
        call = session.sql.call_args
        sql = call.args[0]
        self.assertIn("MERGE INTO sec_facts", sql)
        self.assertIn("WHEN MATCHED THEN UPDATE", sql)
        self.assertIn("WHEN NOT MATCHED THEN INSERT", sql)
        self.assertIn("NULLIF(value[5], PARSE_JSON('null'))::DATE", sql)
        self.assertIn("::FLOAT AS fact_value", sql)
        for column in KEY_COLUMNS:
            self.assertIn(f"EQUAL_NULL(t.{column}, s.{column})", sql)
        for column in COLUMNS:
            self.assertIn(f"{column}=s.{column}", sql)
        self.assertNotIn("DELETE", sql)
        self.assertEqual(json.loads(call.kwargs["params"][0]), [self.row])
        session.sql.return_value.collect.assert_called_once()

    def test_identical_source_duplicates_are_collapsed(self):
        session = MagicMock()
        self.assertEqual(merge_sec_facts(session, [self.row, tuple(self.row)]), 1)
        self.assertEqual(
            len(json.loads(session.sql.call_args.kwargs["params"][0])), 1
        )

    def test_distinct_filings_periods_and_frames_are_preserved(self):
        rows = [self.row]
        for index, value in (
            (8, "later-comparative"), (5, "2022-10-01"),
            (11, 2024), (13, "CY2023Q3I"),
        ):
            row = list(self.row)
            row[index] = value
            rows.append(row)
        session = MagicMock()
        self.assertEqual(merge_sec_facts(session, rows), 5)

    def test_conflicting_source_values_fail_before_writing(self):
        conflicting = list(self.row)
        conflicting[7] = 200.0
        session = MagicMock()
        with self.assertRaisesRegex(ValueError, "Conflicting"):
            merge_sec_facts(session, [self.row, conflicting])
        session.sql.assert_not_called()

    def test_empty_batch_does_not_write(self):
        session = MagicMock()
        self.assertEqual(merge_sec_facts(session, []), 0)
        session.sql.assert_not_called()

    def test_bad_row_fails_before_writing(self):
        session = MagicMock()
        with self.assertRaisesRegex(ValueError, "14 fields"):
            merge_sec_facts(session, self.row[:2])
        session.sql.assert_not_called()


if __name__ == "__main__":
    unittest.main()
