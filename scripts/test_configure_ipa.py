import contextlib
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile


SCRIPT = Path(__file__).with_name("configure-ipa.py")
SPEC = importlib.util.spec_from_file_location("configure_ipa", SCRIPT)
configure = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(configure)
SYNTHETIC_HASH = "0123456789abcdef" * 4


class ConfigureIPATests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.source = self.folder / "unsigned.ipa"
        self.output = self.folder / "configured.ipa"

    def make_ipa(self, bundle=configure.BUNDLE_ID, plist_path=configure.PLIST_PATH, duplicate=False):
        values = {"CFBundleIdentifier": bundle, "KnownDeviceMACSHA256": "", "Nested": {"enabled": True}}
        with zipfile.ZipFile(self.source, "w") as archive:
            archive.comment = b"synthetic fixture"
            for name, data, mode in [
                ("Payload/", b"", stat.S_IFDIR | 0o755),
                (plist_path, plistlib.dumps(values), stat.S_IFREG | 0o644),
                ("Payload/WanShouJian.app/WanShouJian", b"synthetic executable" * 80000, stat.S_IFREG | 0o755),
            ]:
                entry = zipfile.ZipInfo(name, date_time=(2025, 1, 2, 3, 4, 6))
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.create_system = 3
                entry.external_attr = mode << 16
                entry.internal_attr = 1
                entry.comment = b"entry metadata"
                entry.extra = b"\xfe\xca\x02\x00ok"
                archive.writestr(entry, data)
            if duplicate:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    archive.writestr(plist_path, plistlib.dumps(values))

    def source_hash(self):
        return hashlib.sha256(self.source.read_bytes()).digest()

    def test_success_preserves_input_metadata_and_other_entries(self):
        self.make_ipa()
        before = self.source_hash()
        result = configure.configure_ipa(self.source, self.output, SYNTHETIC_HASH)
        self.assertEqual(result, self.output.resolve())
        self.assertEqual(before, self.source_hash())
        with zipfile.ZipFile(self.source) as original, zipfile.ZipFile(self.output) as output:
            self.assertEqual(original.namelist(), output.namelist())
            self.assertEqual(original.comment, output.comment)
            self.assertIsNone(output.testzip())
            for old, new in zip(original.infolist(), output.infolist()):
                for field in ["date_time", "compress_type", "create_system", "external_attr", "internal_attr", "comment", "extra"]:
                    self.assertEqual(getattr(old, field), getattr(new, field), field)
                if old.filename != configure.PLIST_PATH:
                    self.assertEqual(original.read(old), output.read(new))
            data = output.read(configure.PLIST_PATH)
            self.assertTrue(data.startswith(b"bplist00"))
            values = plistlib.loads(data)
            self.assertEqual(values["KnownDeviceMACSHA256"], SYNTHETIC_HASH.upper())
            self.assertEqual(values["Nested"], {"enabled": True})

    def test_invalid_hashes_are_rejected_without_creating_output(self):
        self.make_ipa()
        before = self.source_hash()
        for digest in ["", "a" * 63, "a" * 65, "g" * 64, "Ｆ" * 64, "a" * 63 + "\n", None]:
            with self.subTest(digest_type=type(digest).__name__):
                with self.assertRaises(configure.ConfigurationError):
                    configure.configure_ipa(self.source, self.output, digest)
                self.assertFalse(self.output.exists())
        self.assertEqual(before, self.source_hash())

    def test_wrong_bundle_is_rejected(self):
        self.make_ipa(bundle="com.example.synthetic")
        with self.assertRaisesRegex(configure.ConfigurationError, "应用标识"):
            configure.configure_ipa(self.source, self.output, SYNTHETIC_HASH)
        self.assertFalse(self.output.exists())

    def test_expected_plist_is_required_and_unique(self):
        for options in [{"plist_path": "Payload/Other.app/Info.plist"}, {"duplicate": True}]:
            self.make_ipa(**options)
            with self.assertRaisesRegex(configure.ConfigurationError, "唯一"):
                configure.configure_ipa(self.source, self.output, SYNTHETIC_HASH)
            self.assertFalse(self.output.exists())

    def test_resolved_same_path_is_rejected(self):
        self.make_ipa()
        before = self.source_hash()
        alias = self.folder / "unused" / ".." / self.source.name
        with self.assertRaisesRegex(configure.ConfigurationError, "不同"):
            configure.configure_ipa(self.source, alias, SYNTHETIC_HASH)
        self.assertEqual(before, self.source_hash())

    def test_existing_output_is_preserved(self):
        self.make_ipa()
        self.output.write_bytes(b"existing user output")
        with self.assertRaisesRegex(configure.ConfigurationError, "已存在"):
            configure.configure_ipa(self.source, self.output, SYNTHETIC_HASH)
        self.assertEqual(self.output.read_bytes(), b"existing user output")

    def test_missing_output_directory_creates_nothing(self):
        self.make_ipa()
        output = self.folder / "missing" / "configured.ipa"
        with self.assertRaisesRegex(configure.ConfigurationError, "父目录"):
            configure.configure_ipa(self.source, output, SYNTHETIC_HASH)
        self.assertFalse(output.parent.exists())

    def test_streaming_failure_removes_own_partial_output(self):
        self.make_ipa()
        before = self.source_hash()
        with mock.patch.object(configure.shutil, "copyfileobj", side_effect=OSError("synthetic write failure")):
            with self.assertRaises(configure.ConfigurationError):
                configure.configure_ipa(self.source, self.output, SYNTHETIC_HASH)
        self.assertFalse(self.output.exists())
        self.assertEqual(before, self.source_hash())

    def test_cli_environment_fallback_logs_only_output_path(self):
        self.make_ipa()
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, {"LIGHTSTICK_MAC_SHA256": SYNTHETIC_HASH}), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = configure.main(["--input", str(self.source), "--output", str(self.output)])
        self.assertEqual(result, 0)
        self.assertEqual(stdout.getvalue().strip(), str(self.output.resolve()))
        self.assertEqual(stderr.getvalue(), "")
        self.assertNotIn(SYNTHETIC_HASH, stdout.getvalue())

    def test_cli_explicit_hash_takes_precedence_and_invalid_value_is_private(self):
        self.make_ipa()
        stdout, stderr = io.StringIO(), io.StringIO()
        invalid = "synthetic-invalid-digest"
        with mock.patch.dict(os.environ, {"LIGHTSTICK_MAC_SHA256": SYNTHETIC_HASH}), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = configure.main(["--input", str(self.source), "--output", str(self.output), "--mac-sha256", invalid])
        self.assertEqual(result, 2)
        self.assertNotIn(invalid, stderr.getvalue())
        self.assertNotIn(SYNTHETIC_HASH, stderr.getvalue())
        self.assertFalse(self.output.exists())

    def test_cli_missing_hash_is_rejected(self):
        self.make_ipa()
        with mock.patch.dict(os.environ, {}, clear=True), contextlib.redirect_stderr(io.StringIO()):
            result = configure.main(["--input", str(self.source), "--output", str(self.output)])
        self.assertEqual(result, 2)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
