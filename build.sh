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

构建未签名 IPA，输出到 dist/ 目录（同时生成带时间戳的副本）。

选项:
  --test    构建完成后运行 iOS 模拟器单元测试
  --check   只跑静态检查，不构建（Go 测试 + 脚本测试 + 源码一致性）
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
#   - 本地化条目对齐
#   - Swift 源码一致性（括号、桥接头、测试引用）
#   - 代理模块一致性（脚本 URL、路径、主机名）
#   - 品牌命名一致性（Bundle ID、显示名、证书主题）
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
  else
    echo "    跳过代理脚本测试（未安装 node）"
  fi

  python3 "$ROOT/Tests/check_localization.py" >/dev/null
  echo "    本地化校验通过"

  python3 "$ROOT/Tests/check_swift_sources.py" >/dev/null
  echo "    Swift 源码一致性通过"

  python3 "$ROOT/Tests/check_proxy_modules.py" >/dev/null
  echo "    代理模块一致性通过"

  python3 "$ROOT/Tests/check_branding.py" >/dev/null
  echo "    品牌命名一致性通过"
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

# --check 不构建，只跑检查，因此在沙箱 / CI 上也能执行
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

"$ROOT/Scripts/build-unsigned-ipa.sh"

IPA="$ROOT/dist/$APP_NAME-unsigned.ipa"
test -s "$IPA"
echo "未签名 IPA 已生成: $IPA"

if [ "$run_tests" -eq 1 ]; then
  run_simulator_tests
fi

echo
echo "下一步：使用 Impactor 或爱思助手签名后安装到 iPhone。"
