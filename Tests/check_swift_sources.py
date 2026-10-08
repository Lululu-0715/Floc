#!/usr/bin/env python3
"""Swift 源码静态一致性检查。

沙箱环境没有 Xcode，无法真正编译。这个脚本做力所能及的静态校验，
把「装到 Mac 上才发现」的问题尽量提前暴露：

  1. 括号 / 引号配平        —— 捕捉明显的语法截断
  2. 桥接头与 Go 导出对齐    —— 少一个声明就是链接错误
  3. 测试引用的类型确实存在  —— 避免 @testable import 后编译失败
  4. project.yml 源目录存在  —— XcodeGen 配错路径会静默漏文件
  5. 资源完整性              —— 图标 / plist / 三语言文案
  6. 系统设置跳转            —— 不许退回 canOpenURL 与老 scheme 写法
  7. 出包口味                —— 全功能版 + 仅内置代理版必须成对；补丁不许漂移
  8. 地图页全面屏            —— 地图层铺满，覆盖层守安全区
  9. 液态玻璃可用性          —— iOS 26 API 只能待在 GlassCard 的 #available 里

运行：python3 Tests/check_swift_sources.py
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAILURES: list[str] = []
WARNINGS: list[str] = []


def fail(message: str) -> None:
    FAILURES.append(message)


def warn(message: str) -> None:
    WARNINGS.append(message)


# ---------------------------------------------------------------------------
# 1. 括号与引号配平
# ---------------------------------------------------------------------------

def strip_strings_and_comments(source: str) -> str:
    """去掉字符串字面量与注释，避免其中的括号干扰配平判断。

    这是一个简化实现：处理 // 行注释、/* */ 块注释、双引号字符串（含转义），
    以及 Swift 的多行字符串 \"\"\"。足以应对本项目的代码风格。
    """
    out: list[str] = []
    i = 0
    n = len(source)

    while i < n:
        # 块注释
        if source.startswith("/*", i):
            depth = 1
            i += 2
            while i < n and depth > 0:
                if source.startswith("/*", i):
                    depth += 1
                    i += 2
                elif source.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue

        # 行注释
        if source.startswith("//", i):
            while i < n and source[i] != "\n":
                i += 1
            continue

        # 多行字符串
        if source.startswith('"""', i):
            i += 3
            while i < n and not source.startswith('"""', i):
                if source[i] == "\\":
                    i += 2
                else:
                    i += 1
            i += 3
            continue

        # 普通字符串
        if source[i] == '"':
            i += 1
            while i < n and source[i] != '"':
                if source[i] == "\\":
                    i += 2
                else:
                    i += 1
            i += 1
            continue

        out.append(source[i])
        i += 1

    return "".join(out)


def check_balance(path: Path, source: str) -> None:
    cleaned = strip_strings_and_comments(source)

    pairs = {"(": ")", "[": "]", "{": "}"}
    closers = {v: k for k, v in pairs.items()}
    stack: list[tuple[str, int]] = []

    line = 1
    for char in cleaned:
        if char == "\n":
            line += 1
        elif char in pairs:
            stack.append((char, line))
        elif char in closers:
            if not stack:
                fail(f"{path.relative_to(ROOT)}:{line} 出现多余的 '{char}'")
                return
            opener, open_line = stack.pop()
            if pairs[opener] != char:
                fail(
                    f"{path.relative_to(ROOT)}:{line} "
                    f"'{char}' 与第 {open_line} 行的 '{opener}' 不匹配"
                )
                return

    if stack:
        opener, open_line = stack[-1]
        fail(
            f"{path.relative_to(ROOT)}: 第 {open_line} 行的 '{opener}' 未闭合"
        )


# ---------------------------------------------------------------------------
# 2. 桥接头 vs Go 导出函数
# ---------------------------------------------------------------------------

def parse_go_exports(core_dir: Path) -> set[str]:
    exports: set[str] = set()
    for path in core_dir.glob("*.go"):
        for match in re.finditer(r"^//export\s+(\w+)", path.read_text(encoding="utf-8"), re.M):
            exports.add(match.group(1))
    return exports


def parse_bridging_header(path: Path) -> set[str]:
    if not path.exists():
        fail(f"桥接头不存在: {path.relative_to(ROOT)}")
        return set()

    text = path.read_text(encoding="utf-8")

    # 桥接头可以直接 #import cgo 生成的 Core/locationcore.h（推荐做法：声明不可能
    # 与 Go 侧漂移）。这种情况下真正的声明来自生成的头文件，就该拿它来比对——
    # 顺带还能查出「改了 bridge.go 却忘了重跑 build-core.sh」。
    if re.search(r'#\s*import\s+"locationcore\.h"', text):
        generated = ROOT / "Core" / "locationcore.h"
        if not generated.exists():
            fail(
                "桥接头 #import 了 Core/locationcore.h，但该文件不存在；"
                "请先执行 Scripts/build-core.sh 生成它"
            )
            return set()
        text = generated.read_text(encoding="utf-8")

    # 只认函数形态的声明（名字后面跟 '('）。cgo 生成的头文件里还会出现
    # `struct locationcore_generateca_return` 这类派生类型名，
    # 它们不是函数，不该被当成「已废弃的声明」。
    return set(re.findall(r"\b(locationcore_\w+)\s*\(", text))


def check_bridging_header() -> None:
    exports = parse_go_exports(ROOT / "Core")
    declared = parse_bridging_header(ROOT / "App" / "Floc-Bridging-Header.h")

    if not exports:
        fail("Core 目录下未找到任何 //export 声明，脚本可能读错了路径")
        return

    missing = exports - declared
    if missing:
        fail(
            "桥接头缺少以下 Go 导出函数的声明（会导致链接/编译失败）："
            + "".join(f"\n    - {name}" for name in sorted(missing))
        )

    extra = declared - exports
    if extra:
        warn(
            "桥接头声明了 Core 未导出的函数（可能已废弃）："
            + "".join(f"\n    - {name}" for name in sorted(extra))
        )

    print(f"  桥接头：{len(declared)} 个声明 / Core 导出 {len(exports)} 个")


# ---------------------------------------------------------------------------
# 3. 测试引用的符号
# ---------------------------------------------------------------------------

SWIFT_TYPE_PATTERN = re.compile(
    r"^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+)*"
    r"(?:final\s+)?"
    r"(?:class|struct|enum|protocol)\s+(\w+)",
    re.M,
)

# 从测试文件里抓「裸名字引用」：XCTAssert...(.xxx) 或 .case 这类枚举成员
# 不好静态判定，这里只检查类型级引用，误报率最低。
TEST_TYPE_REFERENCE = re.compile(r"\b([A-Z]\w{2,})\b")


def collect_declared_types() -> set[str]:
    """收集项目内声明的类型。

    用 `rglob` 而不是 `glob`：`Shared/License/` 这类子目录同样参与编译，
    早先用 `glob("*.swift")` 只扫顶层，导致 `LicenseManager` 这些
    「确实存在却报未声明」的假失败。
    """
    declared: set[str] = set()
    for folder in ("App", "Shared"):
        for path in (ROOT / folder).rglob("*.swift"):
            declared.update(SWIFT_TYPE_PATTERN.findall(path.read_text(encoding="utf-8")))
    return declared


def check_test_references() -> None:
    declared = collect_declared_types()
    test_dir = ROOT / "Tests" / "FlocTests"
    if not test_dir.exists():
        fail("测试目录不存在: Tests/FlocTests")
        return

    # 系统 / XCTest / CoreLocation 提供的类型，不在项目内声明
    known_external = {
        "XCTest", "XCTestCase", "XCTAssert", "XCTAssertEqual", "XCTAssertTrue",
        "XCTAssertFalse", "XCTAssertNil", "XCTAssertNotNil", "XCTAssertGreaterThan",
        "XCTAssertLessThan", "XCTAssertGreaterThanOrEqual", "XCTFail",
        "XCTAssertNotEqual", "XCTAssertLessThanOrEqual", "XCTAssertIdentical",
        "XCTUnwrap", "XCTAssertNoThrow", "XCTAssertThrowsError",
        "Foundation", "CoreLocation", "CLLocation", "CLLocationCoordinate2D",
        "CLLocationDistance", "URL", "UUID", "Data", "Date", "JSONEncoder",
        "JSONDecoder", "UserDefaults", "Set", "String", "Double", "Int",
        "Bool", "Array", "Dictionary", "NSRange", "CharacterSet", "Locale",
        "FileManager", "Character", "Void", "UnsafeMutablePointer", "CDouble",
        "CInt", "MainActor", "Published", "Self", "AppLocalization",
        "CVarArg", "Notification", "Bundle", "Result", "Error",
    }

    # 只关心「测试显式声称要测的项目内类型」——即 @testable 导入后
    # 直接以类型名出现在断言或构造里的标识符。为避免把英文单词误判成
    # 类型，只在名字确实像类型（含大写且长度 >= 4）时纳入检查，
    # 并且必须以「被项目声明过」的白名单方式判定，不做反向推断。
    #
    # 做法：收集测试文件里所有「形如 Type.member」或「Type(」的引用。
    type_reference = re.compile(r"\b([A-Z]\w{3,})\s*(?:\.\w|\()")

    known_all = declared | known_external
    checked = 0
    for path in sorted(test_dir.glob("*.swift")):
        raw = path.read_text(encoding="utf-8")
        # 先把字符串字面量与注释摘掉再找类型名：注释里提到类型名、
        # 或者字符串里出现形如 `XXX.workers.dev` 的域名，都会被误判成
        # 「引用了未声明的类型」。单行字符串不会吃掉换行，行号仍然准。
        source = strip_strings_and_comments(raw)
        own_types = set(SWIFT_TYPE_PATTERN.findall(source))

        for match in type_reference.finditer(source):
            name = match.group(1)
            checked += 1
            if name in known_all or name in own_types:
                continue
            # 项目里没有、外部白名单里也没有 —— 很可能是拼写错误或漏了实现
            line = source[: match.start()].count("\n") + 1
            fail(
                f"{path.name}:{line} 引用了未声明的类型 '{name}'"
                f"（项目内无此声明，也不在已知系统类型中）"
            )

    print(f"  项目内声明类型 {len(declared)} 个，检查 {checked} 处类型引用")


# ---------------------------------------------------------------------------
# 4. project.yml 源目录
# ---------------------------------------------------------------------------

def check_project_sources() -> None:
    project_yml = ROOT / "project.yml"
    if not project_yml.exists():
        fail("project.yml 不存在")
        return

    content = project_yml.read_text(encoding="utf-8")
    paths = re.findall(r"^\s*-\s*path:\s*(\S+)\s*$", content, re.M)

    if not paths:
        fail("project.yml 中未找到任何 sources 路径")
        return

    # 这些目录承载非 Swift 资源（本地化、图标、plist），不含 .swift 是正常的
    resource_dirs = {"Resources"}

    for rel in paths:
        target = ROOT / rel
        if not target.exists():
            fail(f"project.yml 引用的路径不存在: {rel}")
        elif target.is_dir() and rel not in resource_dirs:
            if not any(target.rglob("*.swift")):
                warn(f"project.yml 引用的源码目录里没有 Swift 文件: {rel}")

    print(f"  project.yml 源路径：{len(paths)} 个")


# ---------------------------------------------------------------------------
# 5. 资源完整性
# ---------------------------------------------------------------------------

def check_resources() -> None:
    resources = ROOT / "Resources"

    for path in (
        resources / "Info.plist",
        resources / "Floc.entitlements",
        resources / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png",
    ):
        if not path.exists():
            fail(f"缺少资源文件: {path.relative_to(ROOT)}")

    # 三语言目录
    for code in ("zh-Hans", "zh-Hant", "en"):
        lproj = resources / f"{code}.lproj"
        if not lproj.is_dir():
            fail(f"缺少语言目录: Resources/{code}.lproj")
            continue
        for name in ("Localizable.strings", "InfoPlist.strings"):
            if not (lproj / name).exists():
                fail(f"缺少文案文件: Resources/{code}.lproj/{name}")


# ---------------------------------------------------------------------------
# 6. 系统设置跳转
# ---------------------------------------------------------------------------

def check_settings_navigator() -> None:
    """锁死系统设置跳转上踩过的两个坑。

    1. **`canOpenURL` 不能当闸门。** iOS 18 起它对 `App-Prefs` 一律返回 false，
       但直接 `open` 仍然能跳到目标页；拿它做判断会把「能用」当成「不支持」，
       静默退到本应用设置页——用户看到的正是「点定位服务，结果进了 Floc 那一屏」。
       `CertificateTrustVerifier` 里就藏着这么一份，直到 1.0.6 才合并掉。
    2. **iOS 26 的 `settings-navigation://` 路线不能丢。** 新系统上老 scheme 会被
       系统兜底成「打开发起方自己的设置页」，少一条新路线整条链就落空。

    候选顺序（新在前）由 iOS 单测 `SystemSettingsNavigatorTests` 负责，
    这里只做「不许退回旧写法」的静态兜底。
    """
    navigator = ROOT / "Shared" / "SystemSettingsNavigator.swift"
    if not navigator.exists():
        fail("缺少 Shared/SystemSettingsNavigator.swift")
        return

    source = navigator.read_text(encoding="utf-8")

    # 去掉注释与字符串再查，注释里讲这条规则不算违规。
    if "canOpenURL" in strip_strings_and_comments(source):
        fail(
            "SystemSettingsNavigator 不得使用 canOpenURL 当闸门"
            "（iOS 18 起对 App-Prefs 恒返回 false，会静默退到本应用设置页）"
        )

    required = {
        "定位服务": "settings-navigation://com.apple.Settings.PrivacyAndSecurity/LOCATION",
        "无线局域网": "settings-navigation://com.apple.Settings.WiFi",
        "证书信任设置": "settings-navigation://com.apple.Settings.General/About/CERT_TRUST_SETTINGS",
        "设置首页": "settings-navigation://com.apple.Settings",
    }
    for label, url in required.items():
        # 带引号匹配：`com.apple.Settings` 是其它几条的前缀，不锚定会漏判。
        if f'"{url}"' not in source:
            fail(f"SystemSettingsNavigator 缺少「{label}」的 iOS 26 候选：{url}")

    # 证书信任那条曾经写成页面标题而不是 specifier 名，断言一下省得改回去。
    if "path=About/CertificateTrustSettings" in source:
        fail("证书信任设置应使用 specifier 名 About/CERT_TRUST_SETTINGS，而不是页面标题")


# ---------------------------------------------------------------------------
# 7. 出包口味
# ---------------------------------------------------------------------------

def check_build_flavors() -> None:
    """每次出包必须成对：全功能版 + 仅内置代理版。

    用户的要求是「以后专门就做第一个版本全功能的带第三方和内置带授权卡密的，
    第三个版本就是只有应用内代理」，纯净版暂时按需。

    「仅内置代理版」不是在源码里铺 `#if`，而是出包时**临时应用一个补丁**
    （`Scripts/patches/local-proxy-only.patch`）把第三方那条链路摘掉，构完撤回。
    这样做的软肋是补丁会随主源码漂移——所以这里直接试跑一次
    `git apply --check`，漂移了当场报出来，而不是等出包失败才发现。
    """
    flavor = ROOT / "Shared" / "BuildFlavor.swift"
    if not flavor.exists():
        fail("缺少 Shared/BuildFlavor.swift（纯净版的编译条件开关）")
    elif "#if PURE_BUILD" not in flavor.read_text(encoding="utf-8"):
        fail("BuildFlavor.swift 里没有 #if PURE_BUILD 分支")

    ipa_script = ROOT / "Scripts" / "build-unsigned-ipa.sh"
    if not ipa_script.exists():
        fail("缺少 Scripts/build-unsigned-ipa.sh")
        return

    script = ipa_script.read_text(encoding="utf-8")
    if "PURE_BUILD" not in script:
        fail("打包脚本没有用 PURE_BUILD 构建纯净版")
    # 1 次函数定义 + 至少 2 次调用（默认的全功能版、仅内置代理版）
    if script.count("pack_ipa") < 3:
        fail("打包脚本似乎只打了一个包：pack_ipa 调用不足两次")

    # 默认口味必须是「全功能版 + 仅内置代理版」这两个。
    if 'FLAVORS="${FLAVORS:-standard localOnly}"' not in script:
        fail("打包脚本的默认口味不再是「全功能版 + 仅内置代理版」")
    if "仅内置" not in script:
        fail("打包脚本里找不到「仅内置代理版」这个口味")

    # 「仅内置代理」靠补丁实现：补丁要在，且**此刻就能干净应用**。
    # 这条是整套做法的命门——主源码一改，补丁就可能对不上，
    # 那时候出包会直接失败，不如在这里先拦下来。
    patch = ROOT / "Scripts" / "patches" / "local-proxy-only.patch"
    if not patch.exists():
        fail("缺少 Scripts/patches/local-proxy-only.patch（仅内置代理版靠它生成）")
    else:
        touched = ["App", "Shared", "Resources", "Tests"]
        dirty = subprocess.run(
            ["git", "diff", "--quiet", "--", *touched],
            cwd=ROOT,
            capture_output=True,
        ).returncode != 0
        if dirty:
            warn("工作区有未提交改动，「仅内置代理」补丁的可用性这轮没能验证")
        else:
            probe = subprocess.run(
                ["git", "apply", "--check", str(patch)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            if probe.returncode != 0:
                fail(
                    "「仅内置代理」补丁已经不能干净应用"
                    "（多半是主源码改过、补丁漂移了）："
                    + probe.stderr.strip()
                )

    if 'apply -R "$LOCAL_ONLY_PATCH"' not in script:
        fail("打包脚本应用了「仅内置代理」补丁，却看不到撤回动作")

    # 脚本里 `$VAR` 后面紧跟着中文字符时，bash 在部分 locale 下会把多字节字符
    # 的首字节当成变量名的一部分（报 `label?: unbound variable`，报错位置还很难认）。
    # 中文提示语在这套脚本里到处都是，所以这里统一要求加花括号。
    for sh in sorted([ROOT / "build.sh"] + list((ROOT / "Scripts").glob("*.sh"))):
        for lineno, line in enumerate(sh.read_text(encoding="utf-8").split("\n"), 1):
            for match in re.finditer(r"\$(?!\{)([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7f])", line):
                fail(
                    f"{sh.relative_to(ROOT)}:{lineno} 变量 {match.group(0)} 后面紧跟中文字符，"
                    f"必须写成 ${{{match.group(1)}}}（否则 bash 会把中文首字节吃进变量名）"
                )

    # 卡密相关的东西必须真的待在 #if !PURE_BUILD 里，
    # 否则「纯净版」只是把界面藏起来，接口和地址照样在包里。
    for rel in (
        "Shared/License/LicenseAPI.swift",
        "Shared/License/LicenseViews.swift",
    ):
        path = ROOT / rel
        if not path.exists():
            fail(f"缺少 {rel}")
        elif "#if !PURE_BUILD" not in path.read_text(encoding="utf-8"):
            fail(f"{rel} 没包 #if !PURE_BUILD，纯净版会连卡密功能一起带上")


# ---------------------------------------------------------------------------
# 8. 地图页全面屏
# ---------------------------------------------------------------------------

def swift_block(source: str, declaration: str) -> str:
    """取出 `declaration` 声明的那个花括号块（配对到底）。

    只按花括号配平找结尾，不依赖缩进——这个项目里嵌套层级不浅，
    数空格一定会数错。
    """
    start = source.find(declaration)
    if start == -1:
        return ""

    brace = source.find("{", start + len(declaration))
    if brace == -1:
        return ""

    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace : index + 1]
    return ""


def check_full_bleed_map() -> None:
    """地图页必须是全面屏。

    1.0.7 及以前地图层写的是 `.ignoresSafeArea(edges: .bottom)`，顶上那条
    安全区就空着，露出的是窗口底色——浅色模式下状态栏底下就是一整条白带，
    和下面的地图断开。用户要求「状态栏那里不要白色了，全面屏」。

    两条约束必须同时成立：
      A. 地图层忽略**全部**边（不能只写 `.bottom`）；
      B. 覆盖层不许忽略安全区。

    B 是 A 的前提：地图层放开之后，搜索框会不会顶到状态栏下面、底部面板
    会不会压住 Home 指示条，全看覆盖层有没有守住安全区。只查 A 会漏掉
    另一半——把搜索框顶上去，用户看到的还是坏的。
    """
    path = ROOT / "App" / "MapHomeView.swift"
    if not path.exists():
        fail("缺少 App/MapHomeView.swift")
        return

    source = strip_strings_and_comments(path.read_text(encoding="utf-8"))

    map_layer = swift_block(source, "private var mapLayer: some View")
    if not map_layer:
        fail("MapHomeView 里找不到 mapLayer：检查脚本的定位字串已失效")
    elif ".ignoresSafeArea()" not in map_layer:
        detail = (
            "只忽略了部分边"
            if ".ignoresSafeArea(edges:" in map_layer
            else "完全没有 ignoresSafeArea"
        )
        fail(
            f"mapLayer 没有铺满整块屏幕（{detail}），状态栏底下会露出一条白带：\n"
            "      期望 .ignoresSafeArea()"
        )

    overlay = swift_block(source, "private var overlayLayer: some View")
    if not overlay:
        fail("MapHomeView 里找不到 overlayLayer：检查脚本的定位字串已失效")
    elif ".ignoresSafeArea" in overlay:
        fail(
            "overlayLayer 忽略了安全区，搜索框/底部面板会顶到状态栏或 Home 指示条下面"
        )


# ---------------------------------------------------------------------------
# 9. 液态玻璃可用性
# ---------------------------------------------------------------------------

# iOS 26 才有的液态玻璃 API。
# `Glass.` 后面必须跟成员名，否则会把 `GlassMetrics` 一起匹配进来。
GLASS_API_PATTERNS = (
    r"\bglassEffect\s*\(",
    r"\bglassEffectTransition\s*\(",
    r"\bGlassEffectContainer\b",
    r"\bGlassButtonStyle\b",
    r"\bGlassProminentButtonStyle\b",
    r"\bGlass\.(?:regular|clear|identity)\b",
    r"buttonStyle\s*\(\s*\.glass",
)

GLASS_API_RE = re.compile("|".join(GLASS_API_PATTERNS))

# 唯一允许出现这些 API 的文件。
GLASS_ENTRY_FILE = "Shared/GlassCard.swift"

IOS_26_GUARD_RE = re.compile(r"if\s+#available\s*\(\s*iOS\s+26")


def line_brace_depths(source: str) -> list[int]:
    """逐行的「行首花括号深度」。

    `if #available(iOS 26, *) {` 自己也会开一层花括号，所以块内语句的
    行首深度一定比那行 `if` 大 1。用这个差值反查「这一句是不是在这个
    守卫里面」，比数缩进可靠（这个项目的缩进层级不浅，而且 ViewBuilder
    里 `if` 不产生缩进之外的额外结构）。
    """
    depths: list[int] = []
    depth = 0
    for line in source.splitlines():
        depths.append(depth)
        depth += line.count("{") - line.count("}")
    return depths


def check_liquid_glass() -> None:
    """液态玻璃只能待在 GlassCard.swift 的 `if #available(iOS 26, *)` 里。

    1.0.10 起用 iOS 26 SDK 编译，同一个二进制在 iOS 26+ 换皮、在 15~18
    保持原样。这个分叉有两处极容易写坏：

      A. 顺手把 `deploymentTarget` 提到 26 —— 老设备直接装不上，
         而本地测试（模拟器都是 iOS 18 / 26）完全看不出来；
      B. 在别处直接写 `glassEffect(...)` —— 编译能过（编译器只按 SDK
         判定可用性），但一跑到 iOS 18 就是 `dyld` 符号缺失级别的崩溃，
         而且是运行时才炸。

    所以这里锁三件事：
      1. `project.yml` 的最低版本仍是 iOS 15.0；
      2. 玻璃 API 只出现在 `Shared/GlassCard.swift`；
      3. 该文件里每一处调用都落在 `if #available(iOS 26, ...)` 块内，
         并且每个这样的守卫块里至少有一处调用（防止守卫变成死分支）。
    """
    # 1. 最低支持版本
    project_path = ROOT / "project.yml"
    if not project_path.exists():
        fail("缺少 project.yml")
    else:
        project = project_path.read_text(encoding="utf-8")
        match = re.search(
            r"deploymentTarget:\s*\n\s*iOS:\s*\"([^\"]+)\"", project
        )
        if not match:
            fail("project.yml 里找不到 options.deploymentTarget.iOS：检查脚本的定位字串已失效")
        elif match.group(1) != "15.0":
            fail(
                f"最低支持版本被改成了 iOS {match.group(1)}，"
                "液态玻璃「新系统换皮、老系统不变」的前提是本包仍然支持 iOS 15.0"
            )

    # 2. 玻璃 API 不许散到别的文件
    swift_files = sorted(
        list((ROOT / "App").glob("*.swift"))
        + list((ROOT / "Shared").rglob("*.swift"))
        + list((ROOT / "Tests").rglob("*.swift"))
    )
    for path in swift_files:
        rel = path.relative_to(ROOT).as_posix()
        if rel == GLASS_ENTRY_FILE:
            continue
        stripped = strip_strings_and_comments(path.read_text(encoding="utf-8"))
        hit = GLASS_API_RE.search(stripped)
        if hit:
            fail(
                f"{rel} 直接用了 iOS 26 的玻璃 API（{hit.group(0)}）："
                f"改成走 {GLASS_ENTRY_FILE} 里的 glassCard()/mapGlassSurface()/mapGlassCapsule()"
            )

    # 3. 入口文件内部必须逐处守在可用性守卫里
    entry = ROOT / GLASS_ENTRY_FILE
    if not entry.exists():
        fail(f"缺少 {GLASS_ENTRY_FILE}")
        return

    lines = strip_strings_and_comments(entry.read_text(encoding="utf-8")).splitlines()
    depths = line_brace_depths("\n".join(lines))

    def scope_end(start: int) -> int:
        """`if #available(iOS 26, ...)` 那一行所在的块在哪里结束（行号，不含）。

        守卫行自己的行首深度是 `depths[start]`；它那个 `}` 收尾之后深度会
        回到同一个值，所以「第一个行首深度 <= depths[start] 的后继行」
        就是块的边界。
        """
        base = depths[start]
        for index in range(start + 1, len(lines)):
            if depths[index] <= base:
                return index
        return len(lines)

    guard_ranges = [
        (index, scope_end(index))
        for index, line in enumerate(lines)
        if IOS_26_GUARD_RE.search(line)
    ]

    guarded_calls = 0
    for index, line in enumerate(lines):
        if not GLASS_API_RE.search(line):
            continue
        if any(start < index < end for start, end in guard_ranges):
            guarded_calls += 1
            continue
        fail(
            f"{GLASS_ENTRY_FILE}:{index + 1} 的玻璃 API 不在 "
            f"`if #available(iOS 26, *)` 里，iOS 18 上会直接崩：\n"
            f"      {line.strip()}"
        )

    for start, end in guard_ranges:
        if not any(GLASS_API_RE.search(l) for l in lines[start:end]):
            fail(
                f"{GLASS_ENTRY_FILE}:{start + 1} 的 `if #available(iOS 26, *)` "
                "块里没有任何玻璃 API，守卫成了死分支"
            )

    if guarded_calls == 0:
        fail(f"{GLASS_ENTRY_FILE} 里找不到任何玻璃 API：检查脚本的定位字串已失效")


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def main() -> int:
    print("Swift 源码静态检查")
    print("=" * 60)

    swift_files = sorted(
        list((ROOT / "App").glob("*.swift"))
        + list((ROOT / "Shared").glob("*.swift"))
        + list((ROOT / "Tests").rglob("*.swift"))
    )

    print(f"\n[1/9] 括号配平（{len(swift_files)} 个 Swift 文件）")
    for path in swift_files:
        check_balance(path, path.read_text(encoding="utf-8"))
    print(f"      已检查 {len(swift_files)} 个文件")

    print("\n[2/9] 桥接头与 Go 导出对齐")
    check_bridging_header()

    print("\n[3/9] 测试类型引用")
    check_test_references()

    print("\n[4/9] project.yml 源路径")
    check_project_sources()

    print("\n[5/9] 资源完整性")
    check_resources()

    print("\n[6/9] 系统设置跳转")
    check_settings_navigator()

    print("\n[7/9] 出包口味")
    check_build_flavors()

    print("\n[8/9] 地图页全面屏")
    check_full_bleed_map()

    print("\n[9/9] 液态玻璃可用性")
    check_liquid_glass()

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
