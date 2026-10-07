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
# 4. 脚本托管地址一致
# ---------------------------------------------------------------------------

# 脚本/配置的托管地址。生产**只认 jsDelivr**：
#
#   jsDelivr    https://cdn.jsdelivr.net/gh/<owner>/<repo>@<ref>/<path>
#   GitHub raw  https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>
#
# raw 国内基本不可用（DNS 污染），而模块与远端配置拉不到时的表现都是
# **静默失效**——开关看着是开的、日志里只有一行 debug。所以 raw 不是
# 「次优选择」，是明确的错误配置，这里直接拦掉而不是降级放行。
#
# 这段逻辑踩过一次坑：原来只写了 raw 的正则，换成 jsDelivr 之后匹配数变成 0，
# 检查照样「通过」，但「脚本 URL 指向了别的仓库」这条保护已经悄悄失效了。
# 所以下面除了比对坐标，还断言**每个模块文件恰好 2 条脚本 URL**——
# 让正则失配变成显式失败，而不是静默放行。
JSDELIVR_PATTERN = re.compile(
    r"https://cdn\.jsdelivr\.net/gh/"
    r"(?P<owner>[\w.\-]+)/(?P<repo>[\w.\-]+)@(?P<ref>[\w.\-]+)/"
)
RAW_PATTERN = re.compile(
    r"https://raw\.githubusercontent\.com/"
    r"(?P<owner>[\w.\-]+)/(?P<repo>[\w.\-]+)/(?P<ref>[\w.\-]+)/"
)

SCRIPT_URL_PATTERN = re.compile(r"https://[^\s,;'\"]+\.js(?![A-Za-z0-9])")

# 每个模块文件里应当出现的脚本 URL 条数（wloc.js + wloc-settings.js）。
EXPECTED_SCRIPTS_PER_MODULE = 2


def repo_coordinates(url: str) -> tuple[str, str, str] | None:
    """从 jsDelivr 地址取出 (owner, repo, ref)；其他主机的地址返回 None。"""
    match = JSDELIVR_PATTERN.match(url)
    if not match:
        return None
    return (match.group("owner"), match.group("repo"), match.group("ref"))


def hosted_url_problem(
    url: str, expected: tuple[str, str, str] | None, where: str
) -> str | None:
    """核对一条托管地址。没问题是 None，否则返回一句可读的原因。"""
    if RAW_PATTERN.match(url):
        return (
            f"{where} 用了 GitHub raw 地址，国内基本拉不到（表现是静默失效）：\n"
            f"      {url}\n"
            f"      请改用 https://cdn.jsdelivr.net/gh/<owner>/<repo>@<branch>/<path>"
        )
    match = JSDELIVR_PATTERN.match(url)
    if not match:
        return f"{where} 的地址不在已知托管主机上（既不是 jsDelivr 也不是 raw）：\n      {url}"
    if expected is None:
        return None
    coords = (match.group("owner"), match.group("repo"), match.group("ref"))
    if coords != expected:
        return (
            f"{where} 指向了其他仓库：\n"
            f"      {url}\n"
            f"      期望 {expected[0]}/{expected[1]}@{expected[2]}"
        )
    return None


def without_comment_lines(content: str) -> str:
    """去掉注释行。

    模块文件里到处是「对着旧写法讲道理」的注释，注释里出现地址很正常
    （比如 wloc.conf 头部就写着它自己的订阅地址）。不排除注释的话，
    这些字样会参与判定，改配置时容易被骗过去。
    注释前缀在这里统一处理：`;`（module/sgmodule/lpx/conf）、`#`、`//`。
    """
    kept = []
    for line in content.split("\n"):
        stripped = line.lstrip()
        if stripped.startswith((";", "#", "//")):
            continue
        kept.append(line)
    return "\n".join(kept)


def check_script_hosting() -> None:
    # 从 Swift 常量取期望仓库
    match = re.search(
        r"defaultModuleBaseURL\s*=\s*\n?\s*\"([^\"]+)\"",
        read("Shared/ThirdPartyProxyManager.swift"),
    )
    if not match:
        fail("无法从 ThirdPartyProxyManager.swift 读出 defaultModuleBaseURL")
        return

    base_url = match.group(1)
    problem = hosted_url_problem(base_url, None, "defaultModuleBaseURL")
    if problem:
        fail(problem)
        return

    expected = repo_coordinates(base_url)
    repo_label = f"{expected[0]}/{expected[1]}@{expected[2]}"
    print(f"  脚本仓库：{repo_label}")

    # 逐个模块核对脚本 URL
    modules_dir = ROOT / "ThirdParty" / "ProxyScripts" / "modules"
    checked = 0
    for path in sorted(modules_dir.iterdir()):
        if not path.is_file() or path.suffix == ".md":
            continue
        content = without_comment_lines(path.read_text(encoding="utf-8"))
        urls = SCRIPT_URL_PATTERN.findall(content)
        if len(urls) != EXPECTED_SCRIPTS_PER_MODULE:
            fail(
                f"{path.name} 里找到 {len(urls)} 条脚本 URL，"
                f"应为 {EXPECTED_SCRIPTS_PER_MODULE} 条"
                f"（正则失配会让「指向其他仓库 / 用错主机」被静默放过）"
            )
        for url in urls:
            checked += 1
            problem = hosted_url_problem(url, expected, f"{path.name} 的脚本 URL")
            if problem:
                fail(problem)
    print(f"  模块脚本地址：{checked} 条（{repo_label}）")

    # 远端配置地址
    match = re.search(
        r"defaultConfigurationURL\s*=\s*\n?\s*\"([^\"]+)\"",
        read("Shared/AppRemoteConfiguration.swift"),
    )
    if not match:
        fail("无法从 AppRemoteConfiguration.swift 读出 defaultConfigurationURL")
    else:
        config_url = match.group(1)
        problem = hosted_url_problem(config_url, expected, "远端配置 URL")
        if problem:
            fail(problem)
        for suffix in ("Resources/remote-config.json",):
            if config_url.endswith(suffix) and not (ROOT / suffix).exists():
                fail(f"远端配置指向 {suffix}，但仓库里没有这个文件")

    # 远端配置里的 moduleBaseURL 会覆盖应用内置值——它要是写回 raw，
    # 等于把用户又推回拉不到的地址上，所以这里一起核。
    remote = json.loads(read("Resources/remote-config.json"))
    remote_base = remote.get("moduleBaseURL")
    if remote_base:
        problem = hosted_url_problem(
            remote_base, expected, "Resources/remote-config.json 的 moduleBaseURL"
        )
        if problem:
            fail(problem)
    print(f"  远端配置地址：{repo_label}")


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
