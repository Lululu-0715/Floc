#!/usr/bin/env python3
"""第三方代理模块一致性检查。

模块文件（`.module` / `.sgmodule` / `.conf` / `.lpx` / `.stoverride`）里写死了
一堆和代码强耦合的东西：

  - 脚本 URL（指向仓库 raw 地址）
  - 配置接口路径（`/wloc-settings/save`）
  - 拦截的主机名列表
  - 客户端种类数量

这些一旦和 Swift / JS 代码不一致，线上表现是「模块装了但定位不变」，
排查成本很高。这个脚本把这些约定固化下来。

运行：python3 Tests/check_proxy_modules.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULES = ROOT / "ThirdParty" / "ProxyScripts" / "modules"
SCRIPTS = ROOT / "ThirdParty" / "ProxyScripts"

FAILURES: list[str] = []
WARNINGS: list[str] = []

# 只有这些扩展名才是「给客户端导入的模块文件」。
# 目录里还放着 README.md（对照表）之类的说明文档，它们不该按模块规则校验——
# 否则文档里举例写的 `DOMAIN,...,DIRECT` 反例会被当成真的 DIRECT 规则报错。
MODULE_SUFFIXES = {".module", ".sgmodule", ".conf", ".lpx", ".stoverride"}


def is_module_file(path: Path) -> bool:
    return path.is_file() and path.suffix in MODULE_SUFFIXES


def fail(message: str) -> None:
    FAILURES.append(message)


def warn(message: str) -> None:
    WARNINGS.append(message)


# ---------------------------------------------------------------------------
# 期望值：从代码里读，而不是另抄一份
# ---------------------------------------------------------------------------

def expected_settings_path() -> str:
    source = (ROOT / "Shared" / "ThirdPartyProxyClient.swift").read_text(encoding="utf-8")
    match = re.search(r'static let settingsPath\s*=\s*"([^"]+)"', source)
    if not match:
        fail("无法从 ThirdPartyProxyClient.swift 读出 settingsPath")
        return "/wloc-settings/save"
    return match.group(1)


def expected_hosts() -> list[str]:
    source = (ROOT / "Shared" / "ThirdPartyProxyClient.swift").read_text(encoding="utf-8")
    block = re.search(
        r"static let interceptedHosts\s*=\s*\[(.*?)\]",
        source,
        re.S,
    )
    if not block:
        fail("无法从 ThirdPartyProxyClient.swift 读出 interceptedHosts")
        return []
    return re.findall(r'"([^"]+)"', block.group(1))


def expected_module_base_url() -> str:
    source = (ROOT / "Shared" / "ThirdPartyProxyManager.swift").read_text(encoding="utf-8")
    match = re.search(r'defaultModuleBaseURL\s*=\s*"([^"]+)"', source)
    if not match:
        fail("无法从 ThirdPartyProxyManager.swift 读出 defaultModuleBaseURL")
        return ""
    return match.group(1)


def expected_module_extensions() -> dict[str, str]:
    """从 Swift 代码读出「客户端 → 模块扩展名」的映射。"""
    source = (ROOT / "Shared" / "ThirdPartyProxyClient.swift").read_text(encoding="utf-8")
    block = re.search(
        r"var moduleFileExtension: String \{(.*?)\n    \}",
        source,
        re.S,
    )
    if not block:
        fail("无法解析 moduleFileExtension")
        return {}

    mapping: dict[str, str] = {}
    for line in block.group(1).splitlines():
        match = re.match(
            r"\s*case\s+([\w,\s.]+?)\s*:\s*return\s+\"([^\"]+)\"",
            line,
        )
        if match:
            clients, ext = match.group(1), match.group(2)
            for client in clients.split(","):
                client = client.strip().lstrip(".")
                if client:
                    mapping[client] = ext
        # `case .surge, .egern: return "sgmodule"` 这种合并在上一行已处理
    return mapping


def check_client_coverage() -> None:
    """逐个客户端核实：按扩展名拼出的模块文件确实存在。"""
    mapping = expected_module_extensions()
    if not mapping:
        return

    print(f"  客户端扩展名映射：{len(mapping)} 条")

    for client, ext in sorted(mapping.items()):
        filename = f"wloc.{ext}"
        if not (MODULES / filename).exists():
            fail(
                f"客户端 {client} 期望模块文件 {filename}，但该文件不存在"
                f"（用户导入时会 404）"
            )

    # 反向：目录里有没有用不上的模块文件
    # （说明文档如 README.md 不属于模块文件，跳过）
    used = {f"wloc.{ext}" for ext in mapping.values()}
    for path in MODULES.iterdir():
        if is_module_file(path) and path.name not in used:
            warn(f"模块文件 {path.name} 未被任何客户端引用")


# ---------------------------------------------------------------------------
# 检查
# ---------------------------------------------------------------------------

def check_module_files() -> None:
    if not MODULES.is_dir():
        fail(f"模块目录不存在: {MODULES.relative_to(ROOT)}")
        return

    files = sorted(p for p in MODULES.iterdir() if is_module_file(p))
    if not files:
        fail("模块目录为空")
        return

    settings_path = expected_settings_path()
    hosts = expected_hosts()
    base_url = expected_module_base_url()

    print(f"  配置接口路径：{settings_path}")
    print(f"  拦截主机：{len(hosts)} 个")
    print(f"  模块文件：{len(files)} 个")

    for path in files:
        content = path.read_text(encoding="utf-8")
        name = path.name

        # 1. 必须引用两个脚本，且指向同一个仓库路径
        for script in ("wloc.js", "wloc-settings.js"):
            if script not in content:
                fail(f"{name} 未引用脚本 {script}")

        # 2. 脚本 URL 必须落在约定的基地址下
        if base_url and "raw.githubusercontent.com" in content:
            urls = re.findall(r"https://raw\.githubusercontent\.com/\S+?\.js", content)
            for url in urls:
                if not url.startswith(base_url.replace("/modules", "").rstrip("/")):
                    # 只作提示：用户换成自己的仓库后这里的期望值会同步变化
                    warn(f"{name} 的脚本 URL 与默认基地址不一致：{url}")

        # 3. 配置接口路径必须与 Swift 常量一致。
        #    模块里通常写成正则转义形式（\/wloc-settings\/save），
        #    所以先把转义斜杠还原再比对。
        if "wloc-settings" in content:
            normalized = content.replace("\\/", "/")
            if settings_path not in normalized:
                fail(
                    f"{name} 里的配置接口路径与代码不一致"
                    f"（代码要求 {settings_path}）"
                )

        # 4. 拦截主机名必须覆盖全部约定主机
        for host in hosts:
            # 模块里可能用正则表达（如 gs-loc(-cn)?\.apple\.com），
            # 因此做宽松匹配：主机名的第一段出现即可
            key = host.split(".")[0]
            if key not in content:
                fail(f"{name} 缺少主机 {host}（或其正则形式）")

        # 5. 绝不允许 DIRECT 放行被拦截的主机
        if re.search(r"DIRECT", content, re.I):
            for line in content.splitlines():
                if "DIRECT" in line.upper() and not line.strip().startswith("#"):
                    for host in hosts:
                        if host in line:
                            fail(
                                f"{name} 给被拦截主机加了 DIRECT 规则：{line.strip()}\n"
                                f"      这会让流量绕过代理，改写规则永远不会触发"
                            )

    check_client_coverage()


def check_script_syntax() -> None:
    """粗查脚本里的括号配平，避免语法错误导致整个改写静默失效。"""
    for name in ("wloc.js", "wloc-settings.js"):
        path = SCRIPTS / name
        if not path.exists():
            fail(f"脚本不存在: {name}")
            continue
        content = path.read_text(encoding="utf-8")

        depth = 0
        in_string: str | None = None
        i = 0
        line = 1
        while i < len(content):
            char = content[i]
            if char == "\n":
                line += 1

            if in_string:
                if char == "\\":
                    i += 2
                    continue
                if char == in_string:
                    in_string = None
            elif char in "\"'`":
                in_string = char
            elif content.startswith("//", i):
                while i < len(content) and content[i] != "\n":
                    i += 1
                continue
            elif content.startswith("/*", i):
                end = content.find("*/", i)
                if end < 0:
                    fail(f"{name}:{line} 块注释未闭合")
                    break
                i = end + 2
                continue
            elif char in "{([":
                depth += 1
            elif char in "})]":
                depth -= 1
                if depth < 0:
                    fail(f"{name}:{line} 括号不匹配")
                    break
            i += 1

        if depth > 0:
            fail(f"{name} 括号未闭合（剩余深度 {depth}）")

    print(f"  脚本语法：已检查 2 个文件")


def check_settings_key_alignment() -> None:
    """两个脚本必须用同一个存储键，否则读写的不是同一份配置。"""
    keys: dict[str, str] = {}
    for name in ("wloc.js", "wloc-settings.js"):
        path = SCRIPTS / name
        if not path.exists():
            continue
        match = re.search(
            r"SETTINGS_KEY\s*=\s*'([^']+)'",
            path.read_text(encoding="utf-8"),
        )
        if match:
            keys[name] = match.group(1)

    if len(keys) == 2 and len(set(keys.values())) != 1:
        fail(
            f"两个脚本的存储键不一致，读写会落在不同位置：{keys}"
        )
    elif keys:
        print(f"  存储键：{list(keys.values())[0]}（两脚本一致）")


def main() -> int:
    print("第三方代理模块一致性检查")
    print("=" * 60)

    print("\n[1/3] 模块文件")
    check_module_files()

    print("\n[2/3] 脚本语法")
    check_script_syntax()

    print("\n[3/3] 脚本间约定")
    check_settings_key_alignment()

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
