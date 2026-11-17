#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Kodi 皮肤打包脚本（跨平台，Python 3.8+）。

把皮肤目录打包成 Kodi 可识别的 zip：压缩包内顶层是一个以插件 id 命名的目录，
id 与版本号均从 addon.xml 读取，避免手动维护出错。

用法：
    python tools/build.py                      # 打包到 dist/
    python tools/build.py --out D:/releases    # 指定输出目录
    python tools/build.py --check              # 只做检查，不打包
    python tools/build.py --print-version      # 只打印 addon.xml 里的版本号
    python tools/build.py --sync-kodi          # 打包后同步到本机 Kodi 插件目录
    python tools/build.py --sync-kodi --kodi-dir "D:/kodi/addons"

Kodi 打包规范：zip 内顶层目录 = addon id，即
    skin.arctic.zephyr.2.resurrection.mod-1.1.14.zip
      └── skin.arctic.zephyr.2.resurrection.mod/
          ├── addon.xml
          ├── 1080i/
          └── ...

排除项见 EXCLUDE_DIRS / EXCLUDE_FILES / EXCLUDE_SUFFIXES。
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

# ---------- 打包排除规则 ----------
# 这些目录不会被打进 zip
EXCLUDE_DIRS = {
    ".git", ".github", ".workbuddy-ai", "dist", "releases", "tools",
    "__pycache__", ".idea", ".vscode", "node_modules",
}
# 这些文件名（精确匹配）不会被打进 zip
EXCLUDE_FILES = {
    ".DS_Store", "Thumbs.db", "desktop.ini",
    ".gitattributes", ".gitignore",
}
# 这些后缀的文件不会被打进 zip
EXCLUDE_SUFFIXES = (".pyc", ".pyo", ".tmp", ".bak", ".orig", ".rej")

# Kodi 仓库里插件目录的常见位置（用于 --sync-kodi 自动探测）
KODI_ADDON_CANDIDATES = [
    Path(os.environ.get("APPDATA", "")) / "Kodi" / "addons",
    Path.home() / "AppData" / "Roaming" / "Kodi" / "addons",
    Path.home() / ".kodi" / "addons",
]

ADDON_ID_RE = re.compile(r"^[A-Za-z0-9_.-]+$")


def find_repo_root() -> Path:
    """向上查找包含 addon.xml 的目录作为仓库根目录。"""
    here = Path(__file__).resolve().parent
    for candidate in (here, *here.parents):
        if (candidate / "addon.xml").is_file():
            return candidate
    raise RuntimeError("找不到仓库根目录（未在上层找到 addon.xml）")


def read_addon_info(root: Path) -> tuple[str, str]:
    """从 addon.xml 读取 id 与 version。"""
    addon_xml = root / "addon.xml"
    if not addon_xml.is_file():
        raise RuntimeError(f"缺少 addon.xml: {addon_xml}")
    try:
        tree = ET.parse(addon_xml)
    except ET.ParseError as exc:
        raise RuntimeError(f"addon.xml 解析失败: {exc}") from exc
    addon = tree.getroot()
    addon_id = (addon.get("id") or "").strip()
    version = (addon.get("version") or "").strip()
    if not addon_id or not version:
        raise RuntimeError("addon.xml 缺少 id 或 version 属性")
    if not ADDON_ID_RE.match(addon_id):
        raise RuntimeError(f"非法的插件 id: {addon_id!r}")
    if not re.match(r"^\d+(\.\d+)*[A-Za-z0-9._-]*$", version):
        raise RuntimeError(f"异常的版本号: {version!r}")
    return addon_id, version


def should_exclude(rel: Path) -> bool:
    """判断相对路径是否应排除。"""
    parts = rel.parts
    if any(p in EXCLUDE_DIRS for p in parts[:-1]):
        return True
    name = rel.name
    if name in EXCLUDE_FILES:
        return True
    if name.endswith(EXCLUDE_SUFFIXES):
        return True
    return False


def collect_files(root: Path) -> list[Path]:
    """收集需要打包的文件，返回相对根目录的路径列表。"""
    files: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = Path(dirpath).relative_to(root)
        # 就地裁剪目录遍历，避免深入被排除的目录
        dirnames[:] = [
            d for d in dirnames
            if d not in EXCLUDE_DIRS and not should_exclude(rel_dir / d)
        ]
        for fname in filenames:
            rel = rel_dir / fname
            if not should_exclude(rel):
                files.append(rel)
    return sorted(files)


def check(root: Path, addon_id: str, version: str, files: list[Path]) -> list[str]:
    """打包前检查，返回警告列表。"""
    warnings: list[str] = []
    required = ["addon.xml", "1080i/Includes.xml", "resources"]
    for item in required:
        target = root / item
        if not target.exists():
            warnings.append(f"缺少预期内容: {item}")
    # 校验所有 XML 是否合法
    bad_xml: list[str] = []
    for rel in files:
        if rel.suffix.lower() == ".xml":
            try:
                ET.parse(root / rel)
            except ET.ParseError as exc:
                bad_xml.append(f"{rel.as_posix()}: {exc}")
    if bad_xml:
        warnings.append("XML 解析失败:\n    " + "\n    ".join(bad_xml))
    # 当前版本必须有对应的更新日志段落（fuse3 规范：缺日志不发版）
    if not extract_changelog(root, version):
        warnings.append(f"CHANGELOG.md 缺少版本 {version} 的段落或段落为空")
    # 顶层目录名不能与插件 id 冲突
    if addon_id in {p.parts[0] for p in files if len(p.parts) > 1}:
        warnings.append(f"发现与插件 id 同名的子目录 {addon_id}/，可能导致包结构异常")
    return warnings


def build_zip(root: Path, addon_id: str, version: str, files: list[Path], out_dir: Path) -> Path:
    """生成 zip，返回产物路径。"""
    out_dir.mkdir(parents=True, exist_ok=True)
    zip_path = out_dir / f"{addon_id}-{version}.zip"
    tmp_path = zip_path.with_suffix(".zip.tmp")
    if tmp_path.exists():
        tmp_path.unlink()

    count = 0
    with zipfile.ZipFile(tmp_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for rel in files:
            src = root / rel
            arcname = f"{addon_id}/{rel.as_posix()}"
            zf.write(src, arcname)
            count += 1
    tmp_path.replace(zip_path)

    size_mb = zip_path.stat().st_size / 1024 / 1024
    print(f"[OK] 打包完成: {zip_path}")
    print(f"     文件数: {count}  大小: {size_mb:.2f} MB  顶层目录: {addon_id}/")
    return zip_path


def verify_zip(zip_path: Path, addon_id: str) -> None:
    """校验 zip 结构：所有条目都在 addon_id/ 下，且 addon.xml 存在。"""
    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()
        bad = [n for n in names if not n.startswith(addon_id + "/")]
        if bad:
            raise RuntimeError(f"zip 中存在顶层目录外的条目: {bad[:5]}")
        if f"{addon_id}/addon.xml" not in names:
            raise RuntimeError("zip 中缺少 addon.xml")
    print(f"[OK] 包结构校验通过（顶层目录 {addon_id}/）")


def sync_to_kodi(root: Path, kodi_dir: Path) -> None:
    """把工作区文件同步到 Kodi 插件目录（排除开发文件，不删除多余文件）。"""
    if not kodi_dir.exists():
        raise RuntimeError(f"Kodi 插件目录不存在: {kodi_dir}")
    files = collect_files(root)
    copied = 0
    for rel in files:
        src = root / rel
        dst = kodi_dir / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        copied += 1
    print(f"[OK] 已同步 {copied} 个文件到 {kodi_dir}")


def detect_kodi_dir(addon_id: str) -> Path | None:
    for base in KODI_ADDON_CANDIDATES:
        candidate = base / addon_id
        if candidate.is_dir():
            return candidate
    return None


def extract_changelog(root: Path, version: str) -> str:
    """从 CHANGELOG.md 抽取指定版本的段落（fuse3 格式：## <版本> (日期)）。

    找不到版本、或段落为空时返回空字符串，由调用方判定为失败。
    """
    changelog = root / "CHANGELOG.md"
    if not changelog.is_file():
        return ""
    text = changelog.read_text(encoding="utf-8")
    lines = text.splitlines()
    heading_re = re.compile(r"^##\s+(\S+)(?:\s|$|\()")
    start = None
    for i, line in enumerate(lines):
        m = heading_re.match(line)
        if m and m.group(1) == version:
            start = i + 1
            break
    if start is None:
        return ""
    body: list[str] = []
    for line in lines[start:]:
        if line.startswith("## "):
            break
        body.append(line)
    # 去掉首尾空行
    while body and not body[0].strip():
        body.pop(0)
    while body and not body[-1].strip():
        body.pop()
    return "\n".join(body)


def main() -> int:
    parser = argparse.ArgumentParser(description="Kodi 皮肤打包脚本")
    parser.add_argument("--out", type=Path, help="zip 输出目录（默认 dist/）")
    parser.add_argument("--check", action="store_true", help="只检查不打包")
    parser.add_argument("--print-version", action="store_true", help="只打印版本号")
    parser.add_argument("--changelog", metavar="VERSION",
                        help="从 CHANGELOG.md 抽取指定版本的更新日志段落")
    parser.add_argument("--sync-kodi", action="store_true", help="打包后同步到本机 Kodi")
    parser.add_argument("--kodi-dir", type=Path, help="Kodi 插件目录（配合 --sync-kodi）")
    args = parser.parse_args()

    try:
        root = find_repo_root()
        addon_id, version = read_addon_info(root)

        if args.print_version:
            print(version)
            return 0

        if args.changelog is not None:
            section = extract_changelog(root, args.changelog)
            if not section:
                print(
                    f"[错误] CHANGELOG.md 中找不到版本 {args.changelog} 的段落或段落为空",
                    file=sys.stderr,
                )
                return 1
            print(section)
            return 0

        print(f"插件 id : {addon_id}")
        print(f"版本    : {version}")
        print(f"根目录  : {root}")

        files = collect_files(root)
        print(f"待打包  : {len(files)} 个文件")

        warnings = check(root, addon_id, version, files)
        if warnings:
            print("\n[警告] 发现以下问题：", file=sys.stderr)
            for w in warnings:
                print(f"  - {w}", file=sys.stderr)
            # 致命问题：XML 解析失败或缺更新日志，拒绝打包/发布
            fatal = [w for w in warnings if "XML 解析失败" in w or "CHANGELOG.md 缺少版本" in w]
            if fatal:
                print("\n[错误] 存在致命问题，已中止：", file=sys.stderr)
                for w in fatal:
                    print(f"  - {w}", file=sys.stderr)
                return 1

        if args.check:
            print("[OK] 检查完成")
            return 0

        out_dir = args.out or (root / "dist")
        zip_path = build_zip(root, addon_id, version, files, out_dir)
        verify_zip(zip_path, addon_id)

        if args.sync_kodi:
            kodi_dir = args.kodi_dir
            if kodi_dir is None:
                detected = detect_kodi_dir(addon_id)
                if detected is None:
                    raise RuntimeError(
                        "未能自动定位 Kodi 插件目录，请用 --kodi-dir 明确指定"
                    )
                kodi_dir = detected
            sync_to_kodi(root, kodi_dir)

        return 0
    except Exception as exc:  # noqa: BLE001 - 脚本顶层统一报错
        print(f"[错误] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
