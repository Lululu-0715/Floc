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

        # 2. 脚本 URL 必须能算出仓库里的相对路径。
        #    两种地址形式都合法：cdn.jsdelivr.net/gh/<owner>/<repo>@main/<path>
        #    与 raw.githubusercontent.com/<owner>/<repo>/main/<path>。
        #    手机实际拉的是 jsDelivr（国内可达），raw 留作对照。
        for url in re.findall(r"https://[^\s,;'\"]+\.js(?![A-Za-z0-9])", content):
            if "jsdelivr.net/gh/" in url:
                repo_path = url.split("@main/", 1)
                if len(repo_path) == 1:
                    fail(f"{name} 的 jsDelivr 地址缺少 @main/ 分支标记：{url}")
            elif "raw.githubusercontent.com" in url:
                repo_path = url.split("/main/", 1)
                if len(repo_path) == 1:
                    fail(f"{name} 的 raw 地址缺少 /main/ 分支标记：{url}")
            else:
                fail(
                    f"{name} 的脚本地址既不是 jsDelivr 也不是 raw 形式，"
                    f"客户端可能拉不到：{url}"
                )

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


def check_quantumultx_format() -> None:
    """Quantumult X 的远程重写资源必须是「裸列表」，不能带段名。

    QX 有两种长得很像的格式，极易混淆：

      1. 主配置（.conf 导入 App 里手动粘贴）—— 有 `[rewrite_local]` /
         `[mitm]` 段名；
      2. **远程重写资源**（设置 → 重写 → 引用添加的 URL）—— 官方示例
         `sample-import-rewrite.snippet` 里是**没有段名**的，只有一行可选的
         `hostname = ...` 加上若干条重写规则。

    我们的 wloc.conf 是给第 2 种用的。早期版本写成了第 1 种的样子，
    结果 QX 导入直接报「配置失败、未生效」——模块装了但规则一条没跑。
    这条检查就是防止它再被改回去。
    """
    path = MODULES / "wloc.conf"
    if not path.exists():
        fail("缺少 wloc.conf")
        return

    content = path.read_text(encoding="utf-8")

    section = re.search(r"^\s*\[[^\]]+\]", content, re.M)
    if section:
        fail(
            f"wloc.conf 出现了段名 {section.group(0).strip()}："
            f"Quantumult X 的远程重写资源不支持 [rewrite_local] / [mitm] 段名，"
            f"会导致导入报「配置失败」而完全不生效。\n"
            f"      应改为「hostname = ... 一行 + 裸重写规则」的格式，"
            f"参考官方 sample-import-rewrite.snippet"
        )

    if not re.search(r"^\s*hostname\s*=", content, re.M):
        fail("wloc.conf 缺少 `hostname = ...` 行，Quantumult X 不会对定位主机做 MITM")

    # 注释必须是分号开头。井号在 .conf 主配置里能用，但在重写资源里
    # 不属于官方示例的写法，容易被解析成规则行。
    for number, line in enumerate(content.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("#"):
            fail(
                f"wloc.conf:{number} 用了 `#` 注释；Quantumult X 重写资源"
                f"统一用分号 `;` 开头"
            )

    rules = [
        line for line in content.splitlines()
        if line.strip() and not line.strip().startswith(";")
        and not re.match(r"^\s*hostname\s*=", line)
    ]
    if len(rules) != 2:
        fail(f"wloc.conf 期望 2 条重写规则，实际 {len(rules)} 条")

    print(f"  Quantumult X 重写资源：{len(rules)} 条规则，无段名")


def effective_lines(content: str, comment_prefix: str = "#") -> str:
    """去掉注释行后的配置正文。

    判据必须只看真正的配置行：这些文件里到处是对着旧写法讲道理的注释
    （「不能写成 xxx」），拿整份文件做子串匹配会被注释里的字样骗过去——
    反向验证时就踩过一次：把 `binary-body-mode=1` 从脚本行删掉，
    检查却因为注释里还有这几个字而放行。
    """
    return "\n".join(
        line for line in content.splitlines()
        if not line.strip().startswith(comment_prefix)
    )


def check_client_module_syntax() -> None:
    """小火箭的段名，以及各家「二进制响应体」开关。

    这两件事都属于「写错了不报错、只是静默失效」那一类——用户在客户端里
    看到模块装好了、开关也开着，定位就是不变，几乎无从排查。所以必须拦住。

    **1）Shadowrocket 的段名**

    Shadowrocket 模块只提供这些段：`[General]` `[Rule]` `[Host]`
    `[URL Rewrite]` `[Header Rewrite]` `[Body Rewrite]` `[Map Local]`
    `[Script]` `[MITM]`，脚本一律走 `[Script]` 段。

    1.0.7 及以前的 `wloc.module` 写的是 `[Rewrite]` 段配
    `url script-response-body`（那是 Quantumult X 的写法），小火箭读不懂，
    导入后模块根本不起作用——用户反馈就是「小火箭模块都不识别了」。

    **2）二进制响应体**

    定位响应是 protobuf 二进制。客户端不开 `binary-body-mode` 时，会先按
    UTF-8 解码再把 body 交给脚本，0x80 以上的字节被替换成 U+FFFD；
    脚本 `charCodeAt(i) & 0xff` 拼回去的字节流已经坏了，系统解析失败后
    直接丢弃这个响应——表现就是「模块在跑、状态显示已连接、定位纹丝不动」。
    所以每个带 `wloc.js` 改写的模块文件都必须显式打开二进制体模式。
    """
    module = MODULES / "wloc.module"
    if module.exists():
        # 注释里会提到旧的错误写法（正是为了讲清楚为什么不能这么写），
        # 所以判据只看真正的配置行。
        effective = effective_lines(module.read_text(encoding="utf-8"))

        if re.search(r"^\s*\[Rewrite\]\s*$", effective, re.M):
            fail(
                "wloc.module 用了 `[Rewrite]` 段——Shadowrocket 的模块没有这个段名"
                "（URL 重写是 `[URL Rewrite]`，脚本是 `[Script]`），"
                "导入后模块不会生效。"
            )
        for legacy in ("url script-response-body", "url script-echo-response"):
            if legacy in effective:
                fail(
                    f"wloc.module 里出现了 `{legacy}`：那是 Quantumult X 的重写语法，"
                    f"Shadowrocket 读不懂。小火箭的脚本要写在 [Script] 段里。"
                )
        if "[Script]" not in effective:
            fail("wloc.module 缺少 [Script] 段")

    binary_flags = {
        "wloc.module": "binary-body-mode=1",
        "wloc.sgmodule": "binary-body-mode=1",
        "wloc.lpx": "binary-body-mode=true",
        "wloc.stoverride": "binary-body-mode: true",
    }
    for name, flag in binary_flags.items():
        path = MODULES / name
        if not path.exists():
            continue
        # Stash 的 override 是 YAML，注释用 #，判据同上。
        effective = effective_lines(path.read_text(encoding="utf-8"))
        if "wloc.js" not in effective:
            continue
        if flag not in effective:
            fail(
                f"{name} 没打开二进制体模式（期望 `{flag}`）：定位响应是 protobuf 二进制，"
                f"客户端会先按 UTF-8 解码，高位字节被替换后脚本还原出的字节流已损坏，"
                f"表现为「模块在跑但定位不变」。"
            )

    print("  客户端语法：小火箭段名 + 二进制体模式")


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

    print("\n[1/5] 模块文件")
    check_module_files()

    print("\n[2/5] Quantumult X 重写资源格式")
    check_quantumultx_format()

    print("\n[3/5] 客户端语法（小火箭段名 / 二进制体模式）")
    check_client_module_syntax()

    print("\n[4/5] 脚本语法")
    check_script_syntax()

    print("\n[5/5] 脚本间约定")
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
