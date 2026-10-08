#!/usr/bin/env python3
"""品牌命名一致性检查。

改名是个跨 15+ 文件的活儿，漏改一处的后果往往很隐蔽：

  - Bundle ID 与 App Group 不一致 → App Group 拿不到，配置写不进去
  - entitlements 里的 group 与代码不一致 → 同上
  - 桥接头 / entitlements 文件名与 project.yml 不一致 → 构建直接失败
  - 远端配置指向已被删掉的模块目录 → 客户端去拉 404，静默失效

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
# 3. 显示名必须为纯品牌名（不带版本号）
# ---------------------------------------------------------------------------

def check_display_name(app_name: str) -> None:
    """显示名必须是纯品牌名，**不带版本号**。

    版本号只出现在两个地方：

      - App 内部：设置 → 关于 → 应用版本（读 `CFBundleShortVersionString`）
      - IPA 文件名：`build.sh` 按 `MARKETING_VERSION` 命名

    早期版本把版本号拼进了显示名（`Floc 1.0.1`），想的是「桌面上能区分
    多个自签构建」，但那等于让**应用名称**跟着版本号走，不是要的效果。
    现在显示名固定为品牌名。

    三语言 `InfoPlist.strings` 依然**不允许**定义 `CFBundleDisplayName`，
    保证品牌名在任何语言下都一致。
    """
    expected = app_name

    plist = read("Resources/Info.plist")
    match = re.search(
        r"<key>CFBundleDisplayName</key>\s*<string>([^<]*)</string>",
        plist,
    )
    if not match:
        fail("Info.plist 缺少 CFBundleDisplayName")
    elif match.group(1) != expected:
        extra = ""
        if "MARKETING_VERSION" in match.group(1):
            extra = "（显示名不应带版本号，版本号放在 App 内部和 IPA 文件名里）"
        fail(
            f"Info.plist 的 CFBundleDisplayName 是 '{match.group(1)}'，"
            f"应为 '{expected}'{extra}"
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
                f"它会让品牌名随语言变化"
            )
        if not re.search(r'CFBundleName\s*=\s*"([^"]+)"', content):
            fail(f"{code}.lproj/InfoPlist.strings 缺少 CFBundleName")

    print(f"  显示名：{expected}（不带版本号）")
    print("  版本号：仅出现在 App 内部与 IPA 文件名")


# ---------------------------------------------------------------------------
# 4. 远端配置地址
# ---------------------------------------------------------------------------

# 1.0.8 起只剩应用内代理，脚本与模块文件全部删除，托管地址检查收敛成
# **只剩 `AppRemoteConfiguration` 的远端配置地址**。
#
# 检查规则：
#   - 必须是 https
#   - **不许用 GitHub raw**：国内基本拉不到（DNS 污染），而远端配置拉不到
#     的表现是静默降级——公告不弹、失效警示不显示，日志里只有一行 debug。
#     曾经踩过一次：模块与配置都写着 raw，检查照样「通过」，直到用户报
#     「切出去一分钟就恢复真实位置」才查出来。
#   - 指向本仓库的文件时，本地必须真的存在
#   - `remote-config.json` 里**不许再出现 `moduleBaseURL`**：那是指向已删除
#     的模块目录的字段，留着会让旧版客户端去拉不存在的地址。
RAW_PATTERN = re.compile(
    r"https://raw\.githubusercontent\.com/"
    r"(?P<owner>[\w.\-]+)/(?P<repo>[\w.\-]+)/(?P<ref>[\w.\-]+)/"
)

JSDELIVR_PATTERN = re.compile(
    r"https://cdn\.jsdelivr\.net/gh/"
    r"(?P<owner>[\w.\-]+)/(?P<repo>[\w.\-]+)@(?P<ref>[\w.\-]+)/"
)

# 仓库里实际存在的、会被远端配置引用的文件。
REMOTE_CONFIG_PATH = "Resources/remote-config.json"


def check_script_hosting() -> None:
    """核对远端配置地址。

    历史名字保留（`check_script_hosting`），因为它干的就是「看那些**用户
    设备会去拉的东西**是不是指对了地方」；现在只剩配置这一条。
    """
    match = re.search(
        r"defaultConfigurationURL\s*=\s*\n?\s*\"([^\"]+)\"",
        read("Shared/AppRemoteConfiguration.swift"),
    )
    if not match:
        fail("无法从 AppRemoteConfiguration.swift 读出 defaultConfigurationURL")
        return

    url = match.group(1)

    if not url.startswith("https://"):
        fail(f"远端配置地址不是 https：\n      {url}")

    if RAW_PATTERN.match(url):
        fail(
            f"远端配置用了 GitHub raw 地址，国内基本拉不到（表现是静默降级）：\n"
            f"      {url}\n"
            f"      请改用 https://cdn.jsdelivr.net/gh/<owner>/<repo>@<branch>/<path>"
            f"，或你自己的域名"
        )

    if JSDELIVR_PATTERN.match(url):
        print("  远端配置托管：jsDelivr")
    else:
        print("  远端配置托管：自有/其他主机")

    if url.endswith(REMOTE_CONFIG_PATH) and not (ROOT / REMOTE_CONFIG_PATH).exists():
        fail(f"远端配置指向 {REMOTE_CONFIG_PATH}，但仓库里没有这个文件")

    # 配置内容本身：不许再留指向已删除模块的字段。
    remote = json.loads(read(REMOTE_CONFIG_PATH))
    if "moduleBaseURL" in remote:
        fail(
            f"{REMOTE_CONFIG_PATH} 里还有 moduleBaseURL，"
            f"但第三方模块已于 1.0.8 删除，这个字段只会把客户端指向 404"
        )
    print(f"  远端配置字段：{', '.join(sorted(remote)) or '(空)'}")


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

    print("\n[4/6] 远端配置地址")
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
