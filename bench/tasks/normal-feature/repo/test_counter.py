import tempfile
import unittest
from pathlib import Path

import counter


class CollectTests(unittest.TestCase):
    def test_collect_counts_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "a.txt").write_text("one\ntwo\n")
            (root / "b.txt").write_text("three\n")
            stats = counter.collect(root)
            self.assertEqual(stats["files"], 2)
            self.assertEqual(stats["lines"], 3)

    def test_format_report_is_human_readable(self) -> None:
        report = counter.format_report({"files": 1, "lines": 2, "bytes": 3})
        self.assertIn("files: 1", report)


if __name__ == "__main__":
    unittest.main()
