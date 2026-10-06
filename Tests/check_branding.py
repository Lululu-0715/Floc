#!/usr/bin/env python3
"""品牌命名一致性检查。

改名是个跨 15+ 文件的活儿，漏改一处的后果往往很隐蔽：

  - Bundle ID 与 App Group 不一致 → App Group 拿不到，配置写不进去
  - entitlements 里的 group 与代码不一致 → 同上
  - 桥接头 / entitlements 文件名与 project.yml 不一致 → 构建直接失败
  - 模块里的脚本 URL 与常量不一致 → 用户导入后下载 404

这个脚本把「同一个值在多个地方出现」的约定全部核对一遍。

运行：python3 Tests/check_branding.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAILURES: list[str] = []
WARNINGS: list[str] = []


def fail(message: str) -> None:
    FAILURES.append(message)


def warn(message: str) -> None:
    WARNINGS.append(message)


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# 从「唯一真源」提取期望值
# ---------------------------------------------------------------------------

def expected_bundle_id() -> str:
    match = re.search(
        r"PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)",
        read("project.yml"),
    )
    if not match:
        fail("无法从 project.yml 读出 PRODUCT_BUNDLE_IDENTIFIER")
        return ""
    return match.group(1)


def expected_app_name() -> str:
    match = re.search(r"^name:\s*(\S+)", read("project.yml"), re.M)
    if not match:
        fail("无法从 project.yml 读出工程名")
        return ""
    return match.group(1)


# ---------------------------------------------------------------------------
# 1. Bundle ID 一致性
# ---------------------------------------------------------------------------

def check_bundle_id(bundle_id: str, app_name: str) -> None:
    if not bundle_id:
        return

    print(f"  Bundle ID：{bundle_id}")

    checks = [
        ("Core/bridge.go", r'const bundlePrefix\s*=\s*"([^"]+)"', "bundlePrefix"),
        ("Shared/AppGroup.swift", r'static let identifier\s*=\s*"group\.([^"]+)"', "App Group"),
        (
            "Shared/CertificateAuthorityStore.swift",
            r'static let serviceName\s*=\s*"([^"]+?)(?:\.ca)?"',
            "Keychain service",
        ),
    ]

    for path, pattern, label in checks:
        match = re.search(pattern, read(path))
        if not match:
            fail(f"无法从 {path} 读出 {label}")
            continue
        actual = match.group(1)
        if actual != bundle_id:
            fail(
                f"{label} 不一致：{path} 是 '{actual}'，"
                f"但 project.yml 要求 '{bundle_id}'"
            )

    # entitlements 里的 App Group
    entitlements = read("Resources/Floc.entitlements")
    groups = re.findall(r"<string>(group\.[^<]+)</string>", entitlements)
    for group in groups:
        expected_group = f"group.{bundle_id}"
        if group != expected_group:
            fail(
                f"entitlements 里的 App Group 不一致：'{group}'，"
                f"应为 '{expected_group}'"
            )

    # 测试里的断言
    test_files = list((ROOT / "Tests" / "FlocTests").glob("*.swift"))
    for path in test_files:
        content = path.read_text(encoding="utf-8")
        # 抓测试里硬编码的 group./com. 断言
        for match in re.finditer(r'"(group\.[\w.\-]+|com\.[\w.\-]+)"', content):
            value = match.group(1)
            expected = (
                f"group.{bundle_id}" if value.startswith("group.") else bundle_id
            )
            if value != expected:
                fail(
                    f"{path.name} 里断言了过时的标识：'{value}'，"
                    f"应为 '{expected}'"
                )


# ---------------------------------------------------------------------------
# 2. 文件名与 project.yml 引用一致
# ---------------------------------------------------------------------------

def check_file_references(app_name: str) -> None:
    project_yml = read("project.yml")

    # 桥接头
    headers = re.findall(r"SWIFT_OBJC_BRIDGING_HEADER:\s*(\S+)", project_yml)
    for header in set(headers):
        if not (ROOT / header).exists():
            fail(f"project.yml 引用的桥接头不存在: {header}")

    # entitlements
    entitlements = re.findall(r"CODE_SIGN_ENTITLEMENTS:\s*(\S+)", project_yml)
    for path in set(entitlements):
        if not (ROOT / path).exists():
            fail(f"project.yml 引用的 entitlements 不存在: {path}")

    # INFOPLIST
    plists = re.findall(r"INFOPLIST_FILE:\s*(\S+)", project_yml)
    for path in set(plists):
        if not (ROOT / path).exists():
            fail(f"project.yml 引用的 Info.plist 不存在: {path}")

    # 构建脚本里的 APP_NAME
    for script in ("build.sh", "Scripts/build-unsigned-ipa.sh"):
        match = re.search(r'APP_NAME\s*=\s*"([^"]+)"', read(script))
        if match and match.group(1) != app_name:
            fail(
                f"{script} 的 APP_NAME 是 '{match.group(1)}'，"
                f"与工程名 '{app_name}' 不一致"
            )

    # @testable import 必须指向工程名
    for path in (ROOT / "Tests" / "FlocTests").glob("*.swift"):
        for match in re.finditer(r"@testable import (\w+)", path.read_text(encoding="utf-8")):
            if match.group(1) != app_name:
                fail(
                    f"{path.name} 里 '@testable import {match.group(1)}' "
                    f"应为 '{app_name}'"
                )

    print(f"  工程名：{app_name}")


# ---------------------------------------------------------------------------
# 3. 显示名带版本号
# ---------------------------------------------------------------------------

def check_display_name(app_name: str) -> None:
    """显示名必须是「品牌名 + 版本号」，且版本号由构建时注入。

    自签安装的构建在桌面上长得一模一样，用户装了两版也分不出哪个新；
    所以显示名统一写成 `Floc $(MARKETING_VERSION)`，由 Xcode 在构建时
    替换成实际版本号。

    也正因为如此，三语言的 InfoPlist.strings **不允许**再定义
    CFBundleDisplayName——它会盖掉 Info.plist 里的动态值，版本号就没了。
    """
    expected = f"{app_name} $(MARKETING_VERSION)"

    plist = read("Resources/Info.plist")
    match = re.search(
        r"<key>CFBundleDisplayName</key>\s*<string>([^<]*)</string>",
        plist,
    )
    if not match:
        fail("Info.plist 缺少 CFBundleDisplayName")
    elif match.group(1) != expected:
        fail(
            f"Info.plist 的 CFBundleDisplayName 是 '{match.group(1)}'，"
            f"应为 '{expected}'"
        )

    for code in ("zh-Hans", "zh-Hant", "en"):
        path = ROOT / "Resources" / f"{code}.lproj" / "InfoPlist.strings"
        if not path.exists():
            fail(f"缺少 {path.relative_to(ROOT)}")
            continue
        content = path.read_text(encoding="utf-8")
        if re.search(r"CFBundleDisplayName\s*=", content):
            fail(
                f"{code}.lproj/InfoPlist.strings 不应定义 CFBundleDisplayName："
                f"它会把 Info.plist 里带版本号的显示名覆盖掉"
            )
        if not re.search(r'CFBundleName\s*=\s*"([^"]+)"', content):
            fail(f"{code}.lproj/InfoPlist.strings 缺少 CFBundleName")

    print(f"  显示名：{expected}（版本号由构建注入）")


# ---------------------------------------------------------------------------
# 4. 脚本托管地址一致
# ---------------------------------------------------------------------------

def check_script_hosting() -> None:
    # 从 Swift 常量取期望前缀
    match = re.search(
        r"defaultModuleBaseURL\s*=\s*\n?\s*\"([^\"]+)\"",
        read("Shared/ThirdPartyProxyManager.swift"),
    )
    if not match:
        fail("无法从 ThirdPartyProxyManager.swift 读出 defaultModuleBaseURL")
        return

    base_url = match.group(1)
    repo_prefix = base_url.split("/main/")[0]

    print(f"  脚本仓库：{repo_prefix}")

    # 逐个模块核对脚本 URL
    modules_dir = ROOT / "ThirdParty" / "ProxyScripts" / "modules"
    for path in sorted(modules_dir.iterdir()):
        if not path.is_file():
            continue
        content = path.read_text(encoding="utf-8")
        for match in re.finditer(r"https://raw\.githubusercontent\.com/\S+?\.js", content):
            url = match.group(0)
            if not url.startswith(repo_prefix):
                fail(
                    f"{path.name} 的脚本 URL 指向了其他仓库：\n"
                    f"      {url}\n"
                    f"      期望前缀 {repo_prefix}"
                )

    # 远端配置地址
    match = re.search(
        r"defaultConfigurationURL\s*=\s*\n?\s*\"([^\"]+)\"",
        read("Shared/AppRemoteConfiguration.swift"),
    )
    if match:
        config_url = match.group(1)
        if not config_url.startswith(repo_prefix):
            fail(
                f"远端配置 URL 与脚本仓库前缀不一致：\n"
                f"      {config_url}\n"
                f"      期望前缀 {repo_prefix}"
            )
        # 本地是否真的存在这个文件
        for suffix in ("Resources/remote-config.json",):
            if config_url.endswith(suffix) and not (ROOT / suffix).exists():
                fail(f"远端配置指向 {suffix}，但仓库里没有这个文件")


# ---------------------------------------------------------------------------
# 5. 证书主题
# ---------------------------------------------------------------------------

def check_certificate_subject(app_name: str) -> None:
    content = read("Core/proxy.go")

    for const, label in (
        ("caCommonName", "根证书 CN"),
        ("caOrganization", "根证书 O"),
        ("leafCommonName", "叶子证书 CN"),
    ):
        match = re.search(rf'{const}\s*=\s*"([^"]+)"', content)
        if not match:
            fail(f"Core/proxy.go 缺少 {const}")
            continue
        value = match.group(1)
        # 只要求包含品牌名，允许 "Floc Root CA" 这类后缀
        if app_name not in value:
            fail(
                f"{label}（{const}）是 '{value}'，"
                f"应包含品牌名 '{app_name}'"
            )

    print(f"  证书主题：包含 {app_name}")


# ---------------------------------------------------------------------------
# 6. 不该出现的旧名字
# ---------------------------------------------------------------------------

def check_no_stale_names() -> None:
    stale = ["LocationSpoofer", "location-spoofer", "com.example"]

    extensions = {
        ".swift", ".go", ".js", ".yml", ".yaml", ".sh", ".plist",
        ".entitlements", ".h", ".py", ".md", ".strings", ".json",
        ".module", ".sgmodule", ".conf", ".lpx", ".stoverride",
    }

    # 本脚本自身必然包含这些字符串（它们是检查目标），必须排除。
    self_path = Path(__file__).resolve()

    hits: list[str] = []
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        if path.resolve() == self_path:
            continue
        if any(part in {"node_modules", "build", "dist", ".git"} for part in path.parts):
            continue
        if path.suffix not in extensions:
            continue

        try:
            content = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue

        for name in stale:
            if name in content:
                rel = path.relative_to(ROOT)
                hits.append(f"{rel} 含 '{name}'")

    for hit in hits:
        fail(hit)

    print(f"  旧名称残留：{len(hits)} 处")


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def main() -> int:
    print("品牌命名一致性检查")
    print("=" * 60)

    bundle_id = expected_bundle_id()
    app_name = expected_app_name()

    print("\n[1/6] Bundle ID")
    check_bundle_id(bundle_id, app_name)

    print("\n[2/6] 文件引用")
    check_file_references(app_name)

    print("\n[3/6] 显示名")
    check_display_name(app_name)

    print("\n[4/6] 脚本托管地址")
    check_script_hosting()

    print("\n[5/6] 证书主题")
    check_certificate_subject(app_name)

    print("\n[6/6] 旧名称残留")
    check_no_stale_names()

    print("\n" + "=" * 60)

    if WARNINGS:
        print(f"警告 {len(WARNINGS)} 条：")
        for item in WARNINGS:
            print(f"  ! {item}")
        print()

    if FAILURES:
        print(f"失败 {len(FAILURES)} 项：")
        for item in FAILURES:
            print(f"  ✗ {item}")
        return 1

    print("全部通过。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
