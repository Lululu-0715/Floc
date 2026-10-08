#!/usr/bin/env bash
#
# 一键构建入口。
#
#   ./build.sh          构建未签名 IPA
#   ./build.sh --test   构建完成后额外跑 iOS 模拟器单元测试
#   ./build.sh --check  只跑静态检查（不构建，速度快）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP_NAME="Floc"

usage() {
  cat <<'USAGE'
用法: ./build.sh [--test|--check]

构建未签名 IPA，一次两个口味，输出到 dist/ 目录。

每次构建会把版本号末位 +1（1.0.0 → 1.0.1），共四个文件：

  dist/Floc-1.0.1-unsigned.ipa        标准版：带卡密 / 授权 / 推荐
  dist/Floc-1.0.1-纯净-unsigned.ipa   纯净版：没有卡密那套（PURE_BUILD）
  dist/Floc-unsigned.ipa              标准版的固定名字副本，供发布链接引用
  dist/Floc-纯净-unsigned.ipa         纯净版的固定名字副本

两个包是同一个 App（Bundle ID 与显示名都是 Floc），源码也只有一份，
区别只在编译条件里有没有 PURE_BUILD —— 详见 Shared/BuildFlavor.swift。
同一个 Bundle ID 只能装一个，装上会覆盖另一个。

版本号写进 IPA 文件名，并在 App 内的「设置 → 关于 → 应用版本」里显示。
桌面图标的显示名恒为 Floc，不随版本号变化——要区分多个自签构建，
看 IPA 文件名或 App 内版本号即可；纯净版的版本号后面会多一个「（纯净版）」。
构建失败会自动回退版本号。

选项:
  --test    构建完成后运行 iOS 模拟器单元测试
  --check   只跑静态检查，不构建（Go 测试 + 脚本测试 + 源码一致性）

环境变量:
  SKIP_MODULE_REACHABILITY=1   跳过打包前的模块联通性联网检查（离线时用）
  FULL_CLEAN=1                 连编译缓存一起清掉，强制全量重编
USAGE
}

require_command() {
  local name="$1" hint="$2"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "缺少命令: $name" >&2
    echo "$hint" >&2
    exit 1
  fi
}

run_simulator_tests() {
  local destination="${SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 16}"
  xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -destination "$destination" \
    test
}

# 构建前的静态检查。
# 这些检查都不需要 Xcode，能在构建前把明显问题拦下来：
#   - Go 核心单元测试
#   - 第三方代理脚本测试
#   - 授权服务端（Worker + D1）单元测试
#   - 本地化条目对齐
#   - Swift 源码一致性（括号、桥接头、测试引用）
#   - 代理模块一致性（脚本 URL、路径、主机名、QX 重写资源格式）
#   - 品牌命名一致性（Bundle ID、显示名、证书主题）
#   - 模块联通性（远端地址可达 + 与本地内容一致）
run_static_checks() {
  echo "==> 静态检查"

  if command -v go >/dev/null 2>&1; then
    ( cd "$ROOT/Core" && go test ./... >/dev/null )
    echo "    Go 核心测试通过"
  else
    echo "    跳过 Go 测试（未安装 go）"
  fi

  if command -v node >/dev/null 2>&1; then
    ( cd "$ROOT/ThirdParty/ProxyScripts" && node --test >/dev/null 2>&1 )
    echo "    代理脚本测试通过"

    # 授权服务端（Cloudflare Worker）单元测试。
    # 用的是 Node 22 内置的 node:sqlite，所以不需要 npm install，克隆下来就能跑。
    # Node < 22 没有这个模块，这时候跳过而不是报失败——只是少跑一层校验，
    # 不该拦住只做 iOS 构建的人。
    if node -e "require('node:sqlite')" >/dev/null 2>&1; then
      ( cd "$ROOT/Server/license-worker" && node --test 'test/**/*.test.mjs' >/dev/null 2>&1 )
      echo "    授权服务端测试通过"
    else
      echo "    跳过授权服务端测试（需要 Node 22+ 的 node:sqlite）"
    fi
  else
    echo "    跳过代理脚本测试（未安装 node）"
    echo "    跳过授权服务端测试（未安装 node）"
  fi

  python3 "$ROOT/Tests/check_localization.py" >/dev/null
  echo "    本地化校验通过"

  python3 "$ROOT/Tests/check_swift_sources.py" >/dev/null
  echo "    Swift 源码一致性通过"

  python3 "$ROOT/Tests/check_proxy_modules.py" >/dev/null
  echo "    代理模块一致性通过"

  python3 "$ROOT/Tests/check_branding.py" >/dev/null
  echo "    品牌命名一致性通过"

  # 模块联通性：确认用户设备上客户端会去拉的那几个地址真的能拉到东西。
  # 上面那几项都只看仓库内部自洽，查不出「地址 404」或「改了脚本忘了 push」——
  # 而那两种情况的线上表现都是「模块装了但定位不变」，几乎没法排查。
  # 需要离线构建时用 SKIP_MODULE_REACHABILITY=1 跳过。
  if [ "${SKIP_MODULE_REACHABILITY:-0}" = "1" ]; then
    echo "    跳过模块联通性检查（SKIP_MODULE_REACHABILITY=1）"
  elif python3 "$ROOT/Tests/check_module_reachability.py" >/dev/null 2>&1; then
    echo "    模块联通性检查通过"
  else
    echo "    模块联通性检查未通过：" >&2
    python3 "$ROOT/Tests/check_module_reachability.py" >&2 || true
    exit 1
  fi
}

run_tests=0
check_only=0
case "${1:-}" in
  '') ;;
  --test) run_tests=1 ;;
  --check) check_only=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi

# --check 不构建，只跑检查。
# 注意其中「模块联通性」这一项要联网，纯离线环境下用
# SKIP_MODULE_REACHABILITY=1 ./build.sh --check 跳过。
if [ "$check_only" -eq 1 ]; then
  run_static_checks
  echo
  echo "静态检查全部通过。"
  exit 0
fi

require_command xcrun "请安装 Xcode 及其命令行工具。"
require_command xcodebuild "请安装 Xcode 并用 xcode-select 指向它。"
require_command xcodegen "请执行: brew install xcodegen"
require_command go "请安装 Go 1.23 或更高版本。"

run_static_checks
echo

# 版本号自增：1.0.0 → 1.0.1。
#
# 版本号进 IPA 文件名和 App 内「关于」页，用来区分多次构建。
# 桌面图标的显示名恒为 Floc，不带版本号。
# 构建失败要回退——否则会出现「版本号涨了但没有对应产物」，
# 下次再构建就凭空跳过了一个版本。
# CURRENT_PROJECT_VERSION（Xcode build 号）也会被一起自增，所以回退时两个都得还回去，
# 不然失败一次就白白吃掉一个 build 号。
PREVIOUS_VERSION="$(python3 "$ROOT/Scripts/bump-version.py")"
PREVIOUS_BUILD="$(python3 "$ROOT/Scripts/bump-version.py" --show-build)"
VERSION="$(python3 "$ROOT/Scripts/bump-version.py" --bump)"
echo "==> 版本号 $PREVIOUS_VERSION → $VERSION"

BUILD_SUCCEEDED=0
restore_version_on_failure() {
  if [ "$BUILD_SUCCEEDED" -ne 1 ]; then
    python3 "$ROOT/Scripts/bump-version.py" --set "$PREVIOUS_VERSION" >/dev/null
    python3 "$ROOT/Scripts/bump-version.py" --set-build "$PREVIOUS_BUILD" >/dev/null
    echo "构建未完成，版本号已回退到 $PREVIOUS_VERSION" >&2
  fi
}
trap restore_version_on_failure EXIT

VERSION="$VERSION" "$ROOT/Scripts/build-unsigned-ipa.sh"

# 各口味文件名的后缀。默认值与 Scripts/build-unsigned-ipa.sh 里的一致——
# 两边都只是字面量，改名时记得一起动。
PURE_SUFFIX="${PURE_SUFFIX:-纯净}"
LOCAL_ONLY_SUFFIX="${LOCAL_ONLY_SUFFIX:-仅内置}"

STANDARD_IPA="$ROOT/dist/$APP_NAME-$VERSION-unsigned.ipa"
STANDARD_STABLE_IPA="$ROOT/dist/$APP_NAME-unsigned.ipa"
LOCAL_ONLY_IPA="$ROOT/dist/$APP_NAME-$VERSION-$LOCAL_ONLY_SUFFIX-unsigned.ipa"
LOCAL_ONLY_STABLE_IPA="$ROOT/dist/$APP_NAME-$LOCAL_ONLY_SUFFIX-unsigned.ipa"

test -s "$STANDARD_IPA"
test -s "$STANDARD_STABLE_IPA"
test -s "$LOCAL_ONLY_IPA"
test -s "$LOCAL_ONLY_STABLE_IPA"

# 静态检查看源码，看不出打包结果对不对——图标没进包、显示名带版本号
# 这类问题只有拆开 IPA 才看得见。见 Scripts/verify-ipa.py。
echo
python3 "$ROOT/Scripts/verify-ipa.py" --version "$VERSION" \
  "$STANDARD_IPA" "$LOCAL_ONLY_IPA"

# 出包之后往桌面放一份。用户要求每版都留档，并按版本类型分文件夹，
# 免得 dist/ 里几个包反复互相覆盖、事后分不清哪个是哪个。
# 路径可用 FLOC_ARCHIVE_DIR 覆盖（比如换个盘）。
ARCHIVE_ROOT="${FLOC_ARCHIVE_DIR:-$HOME/Desktop/Floc 发布包}"

archive_ipa() {
  local src="$1"
  local folder="$2"

  [ -f "$src" ] || return 0
  mkdir -p "$ARCHIVE_ROOT/$folder"
  cp -f "$src" "$ARCHIVE_ROOT/$folder/"
  echo "    $ARCHIVE_ROOT/$folder/$(basename "$src")"
}

BUILD_SUCCEEDED=1

echo "未签名 IPA 已生成:"
echo "  全功能版（第三方代理 + 应用内代理 + 卡密）"
echo "    $STANDARD_IPA"
echo "    $STANDARD_STABLE_IPA"
echo "  仅内置代理版（只有应用内代理）"
echo "    $LOCAL_ONLY_IPA"
echo "    $LOCAL_ONLY_STABLE_IPA"

echo
echo "已归档到桌面:"
archive_ipa "$STANDARD_IPA" "全功能版"
archive_ipa "$LOCAL_ONLY_IPA" "仅内置代理版"
# 纯净版默认不出；真要出时（FLAVORS 里带上 pure）也一并归档。
archive_ipa "$ROOT/dist/$APP_NAME-$VERSION-$PURE_SUFFIX-unsigned.ipa" "纯净版"

if [ "$run_tests" -eq 1 ]; then
  run_simulator_tests
fi

echo
echo "下一步：使用 Impactor 或爱思助手签名后安装到 iPhone。"
