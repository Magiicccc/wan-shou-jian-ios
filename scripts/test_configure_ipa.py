import contextlib
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import stat
import struct
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile
import zlib


SCRIPT = Path(__file__).with_name("configure-ipa.py")
SPEC = importlib.util.spec_from_file_location("configure_ipa", SCRIPT)
configure = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(configure)
SYNTHETIC_HASH = "0123456789abcdef" * 4


def png_bytes(width=1, height=1):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    pixels = (b"\x00" + b"\x00\x00\x00\xff" * width) * height
    return configure.PNG_SIGNATURE + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")


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

    def test_optional_model_is_preserved(self):
        self.make_ipa()
        model = self.folder / "fox.usdz"
        with zipfile.ZipFile(model, "w") as archive:
            archive.writestr("fox.usda", "#usda 1.0\n")
        configure.configure_ipa(self.source, self.output, SYNTHETIC_HASH, model_path=model)
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(archive.read(configure.VISUAL_ASSET_ROOT + "fox.usdz"), model.read_bytes())

    def test_model_rejects_parent_traversal(self):
        self.make_ipa()
        model = self.folder / "fox.usdz"
        with zipfile.ZipFile(model, "w") as archive:
            archive.writestr("../fox.usda", "#usda 1.0\n")
        with self.assertRaises(configure.ConfigurationError):
            configure.configure_ipa(self.source, self.output, SYNTHETIC_HASH, model_path=model)
        self.assertFalse(self.output.exists())

    def make_visuals(self):
        folder = self.folder / "private-images"
        folder.mkdir(exist_ok=True)
        for name in configure.VISUAL_ASSET_NAMES:
            (folder / name).write_bytes(png_bytes())
        return folder

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

    def test_visual_assets_are_injected_with_input_and_metadata_preserved(self):
        self.make_ipa()
        folder = self.make_visuals()
        (folder / "private-unused.txt").write_text("synthetic unused content", encoding="utf-8")
        before = self.source_hash()
        configure.configure_ipa(self.source, self.output, SYNTHETIC_HASH, folder)
        self.assertEqual(before, self.source_hash())
        with zipfile.ZipFile(self.source) as original, zipfile.ZipFile(self.output) as output:
            self.assertEqual(output.namelist(), original.namelist() + [configure.VISUAL_ASSET_ROOT + name for name in configure.VISUAL_ASSET_NAMES])
            self.assertEqual(original.comment, output.comment)
            self.assertIsNone(output.testzip())
            for item in original.infolist():
                saved = output.getinfo(item.filename)
                for field in ["date_time", "compress_type", "create_system", "external_attr", "internal_attr", "comment", "extra"]:
                    self.assertEqual(getattr(item, field), getattr(saved, field), field)
                if item.filename != configure.PLIST_PATH:
                    self.assertEqual(original.read(item), output.read(item.filename))
            for name in configure.VISUAL_ASSET_NAMES:
                entry = output.getinfo(configure.VISUAL_ASSET_ROOT + name)
                self.assertEqual(output.read(entry), (folder / name).read_bytes())
                self.assertEqual(entry.external_attr >> 16, stat.S_IFREG | 0o644)
                self.assertEqual(entry.compress_type, zipfile.ZIP_DEFLATED)

    def test_visual_assets_require_both_files(self):
        self.make_ipa()
        folder = self.make_visuals()
        (folder / "fox-closed.png").unlink()
        with self.assertRaisesRegex(configure.ConfigurationError, "同时包含"):
            configure.configure_ipa(self.source, self.output, SYNTHETIC_HASH, folder)
        self.assertFalse(self.output.exists())

    def test_visual_assets_require_regular_files(self):
        self.make_ipa()
        folder = self.make_visuals()
        target = folder / "fox-open.png"
        target.unlink()
        target.mkdir()
        with self.assertRaisesRegex(configure.ConfigurationError, "普通文件"):
            configure.configure_ipa(self.source, self.output, SYNTHETIC_HASH, folder)
        self.assertFalse(self.output.exists())

    def test_visual_assets_reject_symlink_metadata_before_opening(self):
        folder = self.make_visuals()
        original_lstat = Path.lstat

        def lstat(path):
            value = original_lstat(path)
            if path.name == "fox-open.png":
                return mock.Mock(st_mode=stat.S_IFLNK | 0o777)
            return value

        with mock.patch.object(Path, "lstat", lstat), self.assertRaisesRegex(configure.ConfigurationError, "普通文件"):
            configure.visual_assets(folder)

    def test_visual_assets_validate_png_signature_ihdr_and_crc(self):
        self.make_ipa()
        folder = self.make_visuals()
        valid = png_bytes()
        examples = [b"synthetic jpeg", valid[:32], b"wrongPNG" + valid[8:], valid[:8] + b"\x00\x00\x00\x0c" + valid[12:], valid[:12] + b"DATA" + valid[16:], valid[:29] + b"\x00\x00\x00\x00" + valid[33:]]
        for data in examples:
            with self.subTest(length=len(data)):
                (folder / "fox-open.png").write_bytes(data)
                with self.assertRaisesRegex(configure.ConfigurationError, "PNG"):
                    configure.configure_ipa(self.source, self.output, SYNTHETIC_HASH, folder)
                self.assertFalse(self.output.exists())

    def test_visual_assets_dimension_limits_are_inclusive(self):
        folder = self.make_visuals()
        for width, height in [(0, 1), (1, 0), (4097, 1), (1, 4097)]:
            with self.subTest(width=width, height=height):
                (folder / "fox-open.png").write_bytes(png_bytes(width, height))
                with self.assertRaisesRegex(configure.ConfigurationError, "4096"):
                    configure.visual_assets(folder)
        for width, height in [(4096, 1), (1, 4096)]:
            with self.subTest(width=width, height=height):
                value = png_bytes(width, height)
                (folder / "fox-open.png").write_bytes(value)
                self.assertEqual(configure.visual_assets(folder)[configure.VISUAL_ASSET_ROOT + "fox-open.png"], value)

    def test_visual_assets_size_must_be_strictly_below_limit(self):
        self.make_ipa()
        folder = self.make_visuals()
        for size in [configure.MAX_VISUAL_SIZE, configure.MAX_VISUAL_SIZE + 1]:
            with self.subTest(size=size):
                with (folder / "fox-open.png").open("wb") as handle:
                    handle.write(png_bytes())
                    handle.truncate(size)
                with self.assertRaisesRegex(configure.ConfigurationError, "24 MiB"):
                    configure.configure_ipa(self.source, self.output, SYNTHETIC_HASH, folder)
                self.assertFalse(self.output.exists())

    def test_existing_visual_entries_are_rejected_before_output_creation(self):
        folder = self.make_visuals()
        for name in [configure.VISUAL_ASSET_ROOT + "fox-open.png", (configure.VISUAL_ASSET_ROOT + "fox-closed.png").upper()]:
            with self.subTest(name=name):
                self.make_ipa()
                with zipfile.ZipFile(self.source, "a") as archive:
                    archive.writestr(name, b"synthetic existing content")
                before = self.source_hash()
                with self.assertRaisesRegex(configure.ConfigurationError, "同名"):
                    configure.configure_ipa(self.source, self.output, SYNTHETIC_HASH, folder)
                self.assertFalse(self.output.exists())
                self.assertEqual(before, self.source_hash())

    def test_visual_write_failure_cleans_partial_output(self):
        self.make_ipa()
        folder = self.make_visuals()
        before = self.source_hash()
        original_write = zipfile.ZipFile.writestr

        def write(archive, item, data, *args, **kwargs):
            if item.filename.endswith("fox-closed.png"):
                raise OSError("synthetic private image write failure")
            return original_write(archive, item, data, *args, **kwargs)

        with mock.patch.object(zipfile.ZipFile, "writestr", write):
            with self.assertRaises(configure.ConfigurationError):
                configure.configure_ipa(self.source, self.output, SYNTHETIC_HASH, folder)
        self.assertFalse(self.output.exists())
        self.assertEqual(before, self.source_hash())

    def test_cli_visual_assets_logs_only_the_configured_path(self):
        self.make_ipa()
        folder = self.make_visuals()
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, {"LIGHTSTICK_MAC_SHA256": SYNTHETIC_HASH}), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = configure.main(["--input", str(self.source), "--output", str(self.output), "--visual-assets", str(folder)])
        self.assertEqual(result, 0)
        self.assertEqual(stdout.getvalue().strip(), str(self.output.resolve()))
        self.assertEqual(stderr.getvalue(), "")
        with zipfile.ZipFile(self.output) as output:
            self.assertIn(configure.VISUAL_ASSET_ROOT + "fox-open.png", output.namelist())


if __name__ == "__main__":
    unittest.main()
