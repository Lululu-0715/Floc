#!/usr/bin/env python3
"""第三方模块联通性检查（打包前必跑）。

`check_proxy_modules.py` 只看仓库内部自洽——文件在不在、URL 写法对不对。
它**不会**告诉你远端到底能不能拉到东西。而这个差别正是最坑的地方：

  用户装好 App，App 让客户端去拉 `.../wloc.js`。如果那个地址 404、
  仓库被改成私有、或者本地改了脚本忘了 push，客户端拿到的是旧内容甚至
  什么都没有。屏幕上只表现成「模块装了但定位不变」，几乎没法排查。

所以这个脚本在打包前把「手机将要访问的那个 URL」真拉到本地比一遍：

  本地检查（离线也能跑）
    - 7 个文件（5 个模块 + 2 个脚本）都在
    - 模块里引用的每个 raw URL 都能对应到仓库里真实存在的文件
    - URL 指向的仓库与 `git remote origin` 一致（fork 后忘改地址会在此暴露）
    - 远端配置地址同源

  联网检查
    - 7 个 URL 逐个请求，必须 200 且内容非空
    - 远端内容与本地文件逐字节比对（不一致 = 忘了 push，客户端会拿到旧代码）
    - raw 被墙时回落到 GitHub contents API，用来区分「网络不通」和「文件没了」

用法：
    python3 Tests/check_module_reachability.py            本地 + 联网
    python3 Tests/check_module_reachability.py --offline  只跑本地检查
    python3 Tests/check_module_reachability.py --allow-drift
                                                          远端与本地不一致只警告不报错
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULES = ROOT / "ThirdParty" / "ProxyScripts" / "modules"
SCRIPTS = ROOT / "ThirdParty" / "ProxyScripts"

FAILURES: list[str] = []
WARNINGS: list[str] = []

REQUEST_TIMEOUT = 20
# 走代理时 raw 偶发 TLS 中断，单次失败就拦下整轮打包太亏，重试几次再判。
REQUEST_ATTEMPTS = 3
RETRY_DELAY = 1.5
USER_AGENT = "Floc-Module-Reachability-Check"

# 与 check_proxy_modules.py 保持一致的模块扩展名
MODULE_SUFFIXES = [".module", ".sgmodule", ".conf", ".lpx", ".stoverride"]

# 同一份文件有两条公开地址，检查脚本必须都认识：
#
#   raw      https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>
#   jsDelivr https://cdn.jsdelivr.net/gh/<owner>/<repo>@<branch>/<path>
#
# 手机上真正去拉的是 jsDelivr（国内可达），但**权威内容以 raw 为准**——
# jsDelivr 对分支有最长 12 小时的缓存，刚 push 完它可能还是旧内容。
# 所以 raw 那条要求逐字节一致（用来抓「改了没 push」），
# jsDelivr 只要求「拉得到且是同一份脚本」，内容暂时滞后只警告不报错。
RAW_PATTERN = re.compile(
    r"^https://raw\.githubusercontent\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+)/"
    r"(?P<branch>[^/]+)/(?P<path>.+)$"
)
JSDELIVR_PATTERN = re.compile(
    r"^https://(?:cdn|fastly|gcore)\.jsdelivr\.net/gh/(?P<owner>[^/]+)/(?P<repo>[^/]+)"
    r"@(?P<branch>[^/]+)/(?P<path>.+)$"
)


def parse_repo_url(url: str) -> tuple[str, str, str, str] | None:
    """把 raw / jsDelivr 两种地址都解析成 (owner, repo, branch, path)。"""
    for pattern in (RAW_PATTERN, JSDELIVR_PATTERN):
        match = pattern.match(url)
        if match:
            return (
                match.group("owner"),
                match.group("repo"),
                match.group("branch"),
                match.group("path"),
            )
    return None


def mirror_raw(url: str) -> str | None:
    """把 jsDelivr 地址换成同一份文件的 raw 地址，用于兜底。"""
    parsed = parse_repo_url(url)
    if not parsed:
        return None
    owner, repo, branch, path = parsed
    return f"https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{path}"



def fail(message: str) -> None:
    FAILURES.append(message)


def warn(message: str) -> None:
    WARNINGS.append(message)


# ---------------------------------------------------------------------------
# 期望值：从代码里读
# ---------------------------------------------------------------------------

def module_base_url() -> str:
    source = (ROOT / "Shared" / "ThirdPartyProxyManager.swift").read_text(encoding="utf-8")
    match = re.search(r'defaultModuleBaseURL\s*=\s*\n?\s*"([^"]+)"', source)
    if not match:
        fail("无法从 ThirdPartyProxyManager.swift 读出 defaultModuleBaseURL")
        return ""
    return match.group(1).rstrip("/")


def raw_module_base_url() -> str:
    """同一份模块文件的 raw 地址，用来在 CDN 缓存滞后时判断到底推没推。"""
    source = (ROOT / "Shared" / "ThirdPartyProxyManager.swift").read_text(encoding="utf-8")
    match = re.search(r'rawScriptPrefix\s*=\s*\n?\s*"([^"]+)"', source)
    if not match:
        return ""
    return f"{match.group(1).rstrip('/')}/modules"


def configuration_url() -> str:
    source = (ROOT / "Shared" / "AppRemoteConfiguration.swift").read_text(encoding="utf-8")
    match = re.search(r'defaultConfigurationURL\s*=\s*\n?\s*"([^"]+)"', source)
    return match.group(1).rstrip("/") if match else ""


def origin_repository() -> str:
    """把 `git remote get-url origin` 归一成 `owner/repo`。取不到返回空串。"""
    try:
        out = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return ""

    url = out.stdout.strip()
    if not url:
        return ""

    match = re.search(r"github\.com[:/]+([^/]+)/([^/\s]+?)(?:\.git)?$", url)
    return f"{match.group(1)}/{match.group(2)}" if match else ""


# ---------------------------------------------------------------------------
# 待检查清单
# ---------------------------------------------------------------------------

def build_targets() -> list[tuple[str, Path]]:
    """返回 [(URL, 本地文件路径)]。

    只检查**手机上真正去拉的那条地址**（默认是 jsDelivr，见
    `ThirdPartyProxyManager.defaultModuleBaseURL`）。`raw` 那条留到
    内容对不上时作兜底比对，不在这里重复请求——多 7 个请求要多等好几分钟。
    """
    base = module_base_url()
    if not base:
        return []

    scripts_base = base.rsplit("/modules", 1)[0]
    targets: list[tuple[str, Path]] = []

    for suffix in MODULE_SUFFIXES:
        targets.append((f"{base}/wloc{suffix}", MODULES / f"wloc{suffix}"))

    for script in ("wloc.js", "wloc-settings.js"):
        targets.append((f"{scripts_base}/{script}", SCRIPTS / script))

    return targets


def git(*args: str) -> str:
    """跑一条 git 命令，失败返回空串。"""
    try:
        out = subprocess.run(
            ["git", *args], cwd=ROOT, capture_output=True, text=True, timeout=20
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def check_git_state(offline: bool = False) -> None:
    """确认这些文件**真的推到 GitHub 了**。

    这是用户最直接的那个疑问（「是不是没上传 GitHub」）的机器答案。
    以前只能靠联网拉远端来推断，现在本地两条 git 事实就够了，而且更快更准：

      1. 工作区有没有未提交的改动 —— 有就是「改了没提交」；
      2. 本地 HEAD 在不在 `origin/main` 上 —— 不在就是「提交了没 push」。

    第 2 条只花一次 `git ls-remote`（一次握手），比逐文件拉内容便宜得多；
    拿不到远端时跳过，不据此判失败（离线环境很常见）。
    """
    dirty = git("status", "--porcelain", "--", "ThirdParty")
    if dirty:
        files = [line.split(maxsplit=1)[-1] for line in dirty.splitlines()]
        fail(
            "这些第三方文件有未提交的改动，手机上拉到的仍是旧版本：\n"
            + "\n".join(f"      {name}" for name in files)
            + "\n      —— 先提交并 push，再出包"
        )

    head = git("rev-parse", "HEAD")
    if not head:
        return

    if offline:
        print("  已按 --offline 跳过「是否已 push」检查")
        return

    remote = git("ls-remote", "origin", "refs/heads/main")
    if not remote:
        print("  远端不可达，跳过「是否已 push」检查")
        return

    if head not in remote:
        fail(
            "本地 HEAD 不在 origin/main 上——**提交了但没 push**，"
            "手机拉不到这次改动\n"
            f"      HEAD={head[:8]}，origin/main={remote.split()[0][:8]}"
        )
    else:
        print("  代码已推送：HEAD 与 origin/main 一致")


def check_local(targets: list[tuple[str, Path]], offline: bool = False) -> None:
    print("[1/2] 本地检查")

    if not targets:
        return

    # 1. 文件都在
    for url, path in targets:
        if not path.exists():
            fail(f"URL 指向的文件在仓库里不存在：{path.relative_to(ROOT)}（{url}）")

    # 2. 地址与 git remote 同源（raw / jsDelivr 两种形式都要认）
    origin = origin_repository()
    parsed = parse_repo_url(targets[0][0])
    if origin and parsed:
        url_repo = f"{parsed[0]}/{parsed[1]}"
        if url_repo != origin:
            fail(
                f"模块地址指向的仓库与 git origin 不一致：\n"
                f"      URL 里是 {url_repo}，origin 是 {origin}\n"
                f"      fork 之后必须同步替换（见 docs/BUILD.md 第 7 节）"
            )
        else:
            print(f"  仓库同源：{origin}")
    elif origin:
        fail(f"认不出模块地址的仓库：{targets[0][0]}")

    # 3. 模块文件里引用的每个脚本地址，都要能在仓库里找到对应文件
    for suffix in MODULE_SUFFIXES:
        path = MODULES / f"wloc{suffix}"
        if not path.exists():
            continue
        content = path.read_text(encoding="utf-8")
        # 两个坑都踩过：
        #   - 写成 `\S+?\.js`（非贪婪）会停在 `https://cdn.js` 上，
        #     因为 jsDelivr 的主机名本身就以 `.js` 开头；
        #   - 只写 `\.js` 也不行，注释里那条 `.../wloc.conf` 的地址会被
        #     回溯匹配成 `https://cdn.js`。
        # 所以既要贪婪，又要求 `.js` 后面确实不是字母数字（真到结尾了）。
        for url in re.findall(r"https://[^\s,;'\"]+\.js(?![A-Za-z0-9])", content):
            parsed = parse_repo_url(url)
            if not parsed:
                fail(
                    f"{path.name} 里的脚本地址既不是 raw 也不是 jsDelivr 形式，"
                    f"检查脚本认不出来：{url}"
                )
                continue
            relative = parsed[3]
            if not (ROOT / relative).exists():
                fail(f"{path.name} 引用了仓库里不存在的脚本：{url}")

    config = configuration_url()
    if config and origin and origin not in config:
        warn(f"远端配置地址不属于当前仓库：{config}")

    check_git_state(offline)

    print(f"  待检查条目：{len(targets)} 个（5 个模块 + 2 个脚本）")


# ---------------------------------------------------------------------------
# 联网检查
# ---------------------------------------------------------------------------

def http_get(url: str) -> tuple[int, bytes]:
    """返回 (状态码, 内容)。网络层失败抛 OSError。

    **为什么带重试**：走代理时 `raw.githubusercontent.com` 会偶发 TLS 中断
    （`UNEXPECTED_EOF_WHILE_READING`、`connection reset`），单次失败就把整轮
    打包拦下来，然后重跑一次又是 7/7 —— 纯属白等一轮。同一秒里换个连接就通，
    所以固定重试几次再判失败。

    只对网络层（`OSError`）重试；`HTTPError` 是确定性的状态码，不重试。
    """
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    last_error: OSError | None = None

    for attempt in range(REQUEST_ATTEMPTS):
        if attempt:
            time.sleep(RETRY_DELAY * attempt)
        try:
            with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as exc:
            return exc.code, b""
        except OSError as exc:
            last_error = exc

    assert last_error is not None
    raise last_error


def fetch_via_api(url: str) -> tuple[int, bytes] | None:
    """拉不动时用 GitHub contents API 兜底，用来区分「被墙」和「404」。

    返回 None 表示这个 URL 没法用 API 表达（例如不是本仓库的地址）。
    """
    parsed = parse_repo_url(url)
    if not parsed:
        return None

    owner, repo, branch, path = parsed
    api = f"https://api.github.com/repos/{owner}/{repo}/contents/{path}?ref={branch}"
    request = urllib.request.Request(
        api,
        headers={"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        return exc.code, b""
    except (OSError, json.JSONDecodeError):
        return None

    if payload.get("encoding") == "base64":
        import base64

        return 200, base64.b64decode(payload["content"])
    return None


def fetch_bytes(url: str) -> bytes | None:
    """尽力取一份内容：直连失败就走 raw 镜像、再走 GitHub API。取不到返回 None。"""
    candidates = [url]
    mirrored = mirror_raw(url)
    if mirrored and mirrored != url:
        candidates.append(mirrored)

    for candidate in candidates:
        try:
            status, body = http_get(candidate)
        except OSError:
            status, body = 0, b""
        if status == 200 and body:
            return body

        fallback = fetch_via_api(candidate)
        if fallback and fallback[0] == 200 and fallback[1]:
            return fallback[1]

    return None


def check_network(targets: list[tuple[str, Path]], allow_drift: bool) -> None:
    print("\n[2/2] 联网检查")

    if not targets:
        return

    reachable = 0
    drifted: list[str] = []
    blocked = 0

    for url, path in targets:
        name = path.name

        try:
            status, body = http_get(url)
        except OSError as exc:
            # 网络层就失败了。有可能是沙箱/防火墙拦了 raw，
            # 用 API 再确认一次，避免把「文件不存在」误判成「网络不通」。
            fallback = fetch_via_api(url)
            if fallback and fallback[0] == 200:
                status, body = fallback
                blocked += 1
            else:
                hint = f"（API 兜底也失败：{fallback[0] if fallback else '不可用'}）"
                fail(f"{name} 无法访问：{exc}{hint}\n      {url}")
                continue

        if status != 200:
            fail(f"{name} 返回 HTTP {status}（客户端会 404 或空内容）\n      {url}")
            continue

        if not body:
            fail(f"{name} 返回 200 但内容为空\n      {url}")
            continue

        reachable += 1

        # 远端内容必须与本地一致，否则客户端跑的是旧脚本。
        #
        # 注意这里拉的是 jsDelivr，它对分支有最长 12 小时的缓存，所以
        # 「内容不一致」有两种可能，必须分清，否则刚 push 完就会被误判成
        # 「改了没 push」而拦住出包：
        #   1. 仓库里是对的，只是 CDN 还在发旧副本 → 警告；
        #   2. 仓库里也是旧的 → 真的没 push → 失败。
        # 判据就是 raw（直读仓库）跟本地是否一致。
        if path.exists():
            local = path.read_bytes()
            if local != body:
                mirrored_url = mirror_raw(url) or url
                if fetch_bytes(mirrored_url) == local:
                    warn(
                        f"{name} 的 CDN 副本仍是旧内容（jsDelivr 分支缓存最长 12 小时），"
                        f"仓库里已经是本地这一版。急着验证就把模块基地址换成 raw 地址"
                    )
                else:
                    drifted.append(name)
                    message = (
                        f"{name} 远端内容与本地不一致——改了没 push，"
                        f"客户端会拿到旧代码\n      {url}"
                    )
                    if allow_drift:
                        warn(message)
                    else:
                        fail(message)

    summary = f"  可访问：{reachable}/{len(targets)}"
    if blocked:
        summary += f"（其中 {blocked} 个走 API 兜底）"
    print(summary)

    if drifted:
        print(f"  内容漂移：{', '.join(drifted)}")
    else:
        print("  内容漂移：无（远端与本地逐字节一致）")


# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--offline", action="store_true", help="只跑本地检查，不联网")
    parser.add_argument(
        "--allow-drift",
        action="store_true",
        help="远端与本地内容不一致时只警告，不作为失败",
    )
    args = parser.parse_args()

    print("第三方模块联通性检查")
    print("=" * 60)

    targets = build_targets()
    if not targets:
        print("\n无法确定模块地址，跳过。")
        return 1

    check_local(targets, args.offline)

    if args.offline:
        print("\n[2/2] 联网检查（已按 --offline 跳过）")
    else:
        check_network(targets, args.allow_drift)

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
        print()
        print("提示：这些地址就是用户设备上客户端会去拉的地方，")
        print("      修好之前不要出包——装了也不会生效。")
        return 1

    print("全部通过。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
