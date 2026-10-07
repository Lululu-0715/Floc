#!/usr/bin/env python3
"""出包后的产物校验：IPA 里的 App 到底长什么样。

`./build.sh --check` 那套静态检查看的是源码，看不出**打包结果**对不对。
有些问题只有拆开 IPA 才看得见，而且都很隐蔽：

  - **App 图标没进包**：产物 `Info.plist` 里既没有 `CFBundleIcons` 也没有
    `CFBundleIconName`，`Assets.car` 里只剩 `AppIconPreview`。装到手机上
    就是个白图标，用户每次自签安装还得自己补一张图。
    根因是 `project.yml` 没设 `ASSETCATALOG_COMPILER_APPICON_NAME`，
    XcodeGen 不会像 Xcode 模板那样自动补。
  - **显示名带了版本号**：历史上出现过一次，桌面图标名字变成
    「Floc 1.0.1」。显示名恒为 `Floc` 是硬约定。
  - 版本号没写进去 / 两个口味串了版本。

用法：
    python3 Scripts/verify-ipa.py --version 1.0.8 dist/Floc-1.0.8-unsigned.ipa ...
"""

from __future__ import annotations

import argparse
import plistlib
import sys
import zipfile
from pathlib import Path

APP_NAME = "Floc"
EXPECTED_BUNDLE_ID = "com.fff.loc"

FAILURES: list[str] = []


def fail(message: str) -> None:
    FAILURES.append(message)


def verify(ipa: Path, version: str) -> None:
    if not ipa.exists() or ipa.stat().st_size == 0:
        fail(f"{ipa.name} 不存在或为空")
        return

    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        plist_path = f"Payload/{APP_NAME}.app/Info.plist"

        if plist_path not in names:
            fail(f"{ipa.name} 里找不到 {plist_path}")
            return

        plist = plistlib.loads(archive.read(plist_path))
        bundle_files = {n.rsplit("/", 1)[-1] for n in names}

    display_name = plist.get("CFBundleDisplayName", "")
    if display_name != APP_NAME:
        fail(
            f"{ipa.name} 的显示名是「{display_name}」，应为「{APP_NAME}」"
            f"（版本号只出现在 IPA 文件名与 App 内「关于」页）"
        )

    bundle_id = plist.get("CFBundleIdentifier", "")
    if bundle_id != EXPECTED_BUNDLE_ID:
        fail(f"{ipa.name} 的 Bundle ID 是 {bundle_id}，应为 {EXPECTED_BUNDLE_ID}")

    short_version = plist.get("CFBundleShortVersionString", "")
    if short_version != version:
        fail(f"{ipa.name} 的版本号是 {short_version}，应为 {version}")

    icons = plist.get("CFBundleIcons")
    if not isinstance(icons, dict):
        fail(
            f"{ipa.name} 的 Info.plist 里没有 CFBundleIcons——"
            f"App 图标没被编译进去（检查 project.yml 的 "
            f"ASSETCATALOG_COMPILER_APPICON_NAME）"
        )
        return

    primary = icons.get("CFBundlePrimaryIcon")
    if not isinstance(primary, dict):
        fail(f"{ipa.name} 的 CFBundleIcons 里没有 CFBundlePrimaryIcon")
        return

    icon_files = primary.get("CFBundleIconFiles") or []
    if not icon_files:
        fail(f"{ipa.name} 的 CFBundlePrimaryIcon 没有列出任何图标文件")
        return

    # 图标条目必须真的落在包里，否则系统拿不到位图，照样显示白图标。
    present = []
    for entry in icon_files:
        for scale in ("@2x.png", "@3x.png", ".png"):
            if f"{entry}{scale}" in bundle_files:
                present.append(f"{entry}{scale}")
    if not present:
        fail(
            f"{ipa.name} 的 CFBundleIconFiles 声明了 {icon_files}，"
            f"但包里一个对应位图都没有"
        )
        return

    print(f"  {ipa.name}")
    print(f"    显示名 {display_name} · Bundle ID {bundle_id} · 版本 {short_version}")
    print(f"    图标 {', '.join(sorted(present))}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--version", required=True, help="期望的 MARKETING_VERSION")
    parser.add_argument("ipa", nargs="+", help="待校验的 IPA 路径")
    args = parser.parse_args(argv)

    print("IPA 产物校验")
    print("=" * 60)

    for item in args.ipa:
        verify(Path(item), args.version)

    print("=" * 60)
    if FAILURES:
        print(f"失败 {len(FAILURES)} 项：")
        for message in FAILURES:
            print(f"  ✗ {message}")
        return 1

    print("全部通过。")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
