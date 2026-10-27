import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("ci_version", Path(__file__).with_name("ci-version.py"))
versioning = importlib.util.module_from_spec(spec)
spec.loader.exec_module(versioning)


class VersionPolicy(unittest.TestCase):
    def test_every_run_has_a_new_version_and_retry_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "client").mkdir()
            (root / "client/pubspec.yaml").write_text("name: haven\nversion: 0.1.0+1\n")
            (root / "changelog.json").write_text(json.dumps({"schemaVersion": 1, "version": "0.1.0", "versionCode": 1, "changes": ["New media backup build"]}))
            self.assertEqual(versioning.prepare(root, "42"), ("0.1.42", 42))
            first = (root / "client/pubspec.yaml").read_text()
            self.assertEqual(versioning.prepare(root, "42"), ("0.1.42", 42))
            self.assertEqual(first, (root / "client/pubspec.yaml").read_text())
            self.assertEqual(versioning.prepare(root, "43"), ("0.1.43", 43))
            self.assertEqual(json.loads((root / "changelog.json").read_text())["versionCode"], 43)

    def test_invalid_codes_fail_before_writing(self):
        for value in ("", "0", "-1", "01", "1;echo", "2100000001"):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ValueError):
                    versioning.prepare(Path(directory), value)


if __name__ == "__main__":
    unittest.main()
