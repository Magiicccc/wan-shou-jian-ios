#!/usr/bin/env python3
"""Configure a workflow-produced unsigned IPA before signing it with Sideloadly.

The output contains a local device compatibility identifier. Sign the configured
IPA before installation; changing Info.plist invalidates any existing signature.
"""

import argparse
import copy
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import struct
import sys
import zipfile
import zlib


PLIST_PATH = "Payload/WanShouJian.app/Info.plist"
BUNDLE_ID = "com.magiicccc.wanshoujian"
MAX_PLIST_SIZE = 8 * 1024 * 1024
VISUAL_ASSET_NAMES = ("fox-open.png", "fox-closed.png")
VISUAL_ASSET_ROOT = "Payload/WanShouJian.app/PrivateVisuals/"
MAX_VISUAL_SIZE = 24 * 1024 * 1024
MAX_VISUAL_DIMENSION = 4096
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


class ConfigurationError(Exception):
    """A configuration error whose message is safe to display."""


def validate_hash(value):
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-fA-F]{64}", value) is None:
        raise ConfigurationError("设备摘要须为 64 位 ASCII 十六进制字符。")
    return value.upper()


def updated_plist(archive, device_hash):
    matches = [item for item in archive.infolist() if item.filename == PLIST_PATH]
    if len(matches) != 1:
        raise ConfigurationError("IPA 须包含唯一的 WanShouJian.app/Info.plist。")
    info = matches[0]
    if info.is_dir() or stat.S_ISLNK(info.external_attr >> 16):
        raise ConfigurationError("应用 Info.plist 须为普通文件。")
    if info.file_size > MAX_PLIST_SIZE:
        raise ConfigurationError("应用 Info.plist 超出大小上限。")
    try:
        with archive.open(info) as source:
            data = source.read(MAX_PLIST_SIZE + 1)
        if len(data) > MAX_PLIST_SIZE:
            raise ConfigurationError("应用 Info.plist 超出大小上限。")
        values = plistlib.loads(data)
        if not isinstance(values, dict) or values.get("CFBundleIdentifier") != BUNDLE_ID:
            raise ConfigurationError("IPA 的应用标识须为 com.magiicccc.wanshoujian。")
        values["KnownDeviceMACSHA256"] = device_hash
        return plistlib.dumps(values, fmt=plistlib.FMT_BINARY, sort_keys=False)
    except ConfigurationError:
        raise
    except Exception:
        raise ConfigurationError("应用 Info.plist 格式或内容校验失败。") from None


def remove_created_output(path, identity):
    try:
        current = path.lstat()
        if (current.st_dev, current.st_ino) == identity and not stat.S_ISLNK(current.st_mode):
            path.unlink()
    except FileNotFoundError:
        pass


def visual_assets(directory):
    if directory is None:
        return {}
    root = Path(directory).expanduser().resolve(strict=True)
    if not root.is_dir():
        raise ConfigurationError("私有素材位置须为包含两张 PNG 的文件夹。")
    result = {}
    for name in VISUAL_ASSET_NAMES:
        path = root / name
        if not path.exists():
            raise ConfigurationError("私有素材文件夹须同时包含 fox-open.png 与 fox-closed.png。")
        before = path.lstat()
        if not stat.S_ISREG(before.st_mode):
            raise ConfigurationError("私有 PNG 素材须为普通文件。")
        with path.open("rb") as handle:
            opened = os.fstat(handle.fileno())
            if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                raise ConfigurationError("私有素材已变化，请保持文件稳定后重试。")
            if opened.st_size >= MAX_VISUAL_SIZE:
                raise ConfigurationError("每张私有 PNG 须小于 24 MiB。")
            data = handle.read(MAX_VISUAL_SIZE)
        if len(data) >= MAX_VISUAL_SIZE:
            raise ConfigurationError("每张私有 PNG 须小于 24 MiB。")
        if len(data) < 33 or data[:8] != PNG_SIGNATURE or data[8:16] != b"\x00\x00\x00\x0dIHDR":
            raise ConfigurationError("私有素材须为具有完整 IHDR 的 PNG 图片。")
        width, height = struct.unpack(">II", data[16:24])
        header_crc = struct.unpack(">I", data[29:33])[0]
        if zlib.crc32(data[12:29]) & 0xFFFFFFFF != header_crc:
            raise ConfigurationError("私有 PNG 的 IHDR 校验失败，请重新导出素材。")
        if not (0 < width <= MAX_VISUAL_DIMENSION and 0 < height <= MAX_VISUAL_DIMENSION):
            raise ConfigurationError("私有 PNG 的宽和高须处于 1 至 4096 像素。")
        result[VISUAL_ASSET_ROOT + name] = data
    return result


def configure_ipa(input_path, output_path, mac_sha256, visual_assets_path=None):
    device_hash = validate_hash(mac_sha256)
    created_identity = None
    output = None
    try:
        source = Path(input_path).expanduser().resolve(strict=True)
        requested_output = Path(output_path).expanduser()
        output = requested_output.resolve(strict=False)
        if source == output:
            raise ConfigurationError("输入与输出须使用不同的绝对路径。")
        if os.path.lexists(requested_output) or os.path.lexists(output):
            raise ConfigurationError("输出文件已存在，请指定新的文件名。")
        if not source.is_file():
            raise ConfigurationError("输入须为无签名 IPA 文件。")
        if not output.parent.is_dir():
            raise ConfigurationError("请先创建输出文件的父目录。")

        private_images = visual_assets(visual_assets_path)
        with zipfile.ZipFile(source, "r") as original:
            replacement = updated_plist(original, device_hash)
            reserved = {name.casefold() for name in private_images}
            if any(item.filename.replace("\\", "/").rstrip("/").casefold() in reserved for item in original.infolist()):
                raise ConfigurationError("输入 IPA 已含同名私有素材，请选用原始通用 IPA。")
            with output.open("xb") as handle:
                owned = os.fstat(handle.fileno())
                created_identity = (owned.st_dev, owned.st_ino)
                with zipfile.ZipFile(handle, "w", allowZip64=True) as configured:
                    configured.comment = original.comment
                    for item in original.infolist():
                        # Preserve entry metadata; ZIP offsets, sizes and CRCs are rebuilt.
                        cloned = copy.copy(item)
                        if item.filename == PLIST_PATH:
                            cloned.file_size = len(replacement)
                        with configured.open(cloned, "w", force_zip64=cloned.file_size > zipfile.ZIP64_LIMIT) as destination:
                            if item.filename == PLIST_PATH:
                                destination.write(replacement)
                            else:
                                with original.open(item, "r") as content:
                                    shutil.copyfileobj(content, destination, length=1024 * 1024)
                        # ZipFile supplies default permissions when this field is zero.
                        cloned.external_attr = item.external_attr
                    for name, data in private_images.items():
                        entry = zipfile.ZipInfo(name)
                        entry.compress_type = zipfile.ZIP_DEFLATED
                        entry.create_system = 3
                        entry.external_attr = (stat.S_IFREG | 0o644) << 16
                        configured.writestr(entry, data)
        return output
    except BaseException as error:
        if created_identity is not None and output is not None:
            try:
                remove_created_output(output, created_identity)
            except OSError:
                raise ConfigurationError("处理已中止，输出文件清理失败，请检查文件占用。") from None
        if isinstance(error, ConfigurationError):
            raise
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        raise ConfigurationError("IPA 处理失败，请检查文件格式、路径与写入权限。") from None


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(2, "命令参数有误，请使用 --help 查看说明。\n")


def main(argv=None):
    parser = SafeArgumentParser(description="为无签名 IPA 配置本机设备兼容性标识，随后由 Sideloadly 签名安装。")
    parser.add_argument("--input", required=True, help="原始无签名 IPA")
    parser.add_argument("--output", required=True, help="新的输出 IPA，父目录须已存在")
    parser.add_argument("--mac-sha256", help="64 位 ASCII 十六进制摘要；省略时读取 LIGHTSTICK_MAC_SHA256")
    parser.add_argument("--visual-assets", help="可选私有素材文件夹，读取 fox-open.png 与 fox-closed.png")
    arguments = parser.parse_args(argv)
    digest = arguments.mac_sha256 if arguments.mac_sha256 is not None else os.environ.get("LIGHTSTICK_MAC_SHA256", "")
    try:
        output = configure_ipa(arguments.input, arguments.output, digest, arguments.visual_assets)
    except ConfigurationError as error:
        print(str(error), file=sys.stderr)
        return 2
    print(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
