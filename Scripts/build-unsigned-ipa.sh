#!/usr/bin/env bash
#
# 生成未签名 IPA。
#
# 一次出**两个**包，同一个 target、同一份源码，只差一个编译条件：
#
#   Floc-<版本>-unsigned.ipa        标准版（带卡密 / 授权 / 推荐）
#   Floc-<版本>-纯净-unsigned.ipa   纯净版（PURE_BUILD，没有卡密那套）
#
# 纯净版裁掉什么、怎么裁，见 `Shared/BuildFlavor.swift`。
#
# 流程：编译 Go 静态库 → XcodeGen 生成工程 → 分别构建两个口味 → 打包 Payload
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Floc"

# 纯净版文件名的后缀。build.sh 校验产物时也要用，所以走环境变量，默认值一致。
PURE_SUFFIX="${PURE_SUFFIX:-纯净}"

"$ROOT/Scripts/build-core.sh"

command -v xcodegen >/dev/null 2>&1 || {
  echo "缺少 xcodegen，请先执行: brew install xcodegen" >&2
  exit 1
}

echo "==> 生成 Xcode 工程"
xcodegen generate

# 打包目录每次都要重建，否则旧的 Payload 会和新产物混在一起。
rm -rf build/UnsignedIPA

# DerivedData 特意保留：Release 产物是覆盖写入的，留着编译缓存只会更快，
# 不会拿到上一版的包。确实需要全量重编时用 FULL_CLEAN=1 ./build.sh。
if [ "${FULL_CLEAN:-0}" = "1" ]; then
  echo "==> 全量清理编译缓存（FULL_CLEAN=1）"
  rm -rf build/DerivedData
fi

# 版本号由 build.sh 维护（每次出包末位 +1），这里读出来给产物命名。
# 不带版本号的话，dist/ 里只剩一个固定名字，分不清哪次构建对应哪一版；
# 光用时间戳也不行——手机上装的是哪个版本仍然看不出来。
VERSION="${VERSION:-$(python3 "$ROOT/Scripts/bump-version.py")}"

APP_BUNDLE="build/DerivedData/Build/Products/Release-iphoneos/$APP_NAME.app"

build_flavor() {
  local label="$1"
  shift

  echo "==> 构建 Release（${label}）"
  # "$@" 在没有任何额外参数时展开为空；bash 对 "$@" 有特判，不会触发 set -u。
  xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -sdk iphoneos \
    -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    "$@" \
    build
}

pack_ipa() {
  local suffix="$1"

  if [ ! -d "$APP_BUNDLE" ]; then
    echo "未找到 App 产物: $APP_BUNDLE" >&2
    exit 1
  fi

  echo "==> 打包 IPA（${suffix:-标准版}）"
  rm -rf build/UnsignedIPA/Payload
  mkdir -p build/UnsignedIPA/Payload dist
  cp -R "$APP_BUNDLE" "build/UnsignedIPA/Payload/$APP_NAME.app"

  local stable="$ROOT/dist/$APP_NAME${suffix}-unsigned.ipa"
  local versioned="$ROOT/dist/$APP_NAME-${VERSION}${suffix}-unsigned.ipa"

  rm -f "$stable"
  ( cd build/UnsignedIPA && zip -qry "$stable" Payload )
  cp "$stable" "$versioned"

  echo "输出: $versioned"
  echo "固定名副本: $stable"
}

# 标准版：不追加任何编译条件，和改造前完全一致。
build_flavor "标准版"
pack_ipa ""

# 纯净版：只多一个 PURE_BUILD。工程本身没设过 SWIFT_ACTIVE_COMPILATION_CONDITIONS，
# 所以 "$(inherited)" 展开成空，实际生效的就是 PURE_BUILD。
# 第二次构建时 Swift 会因为编译条件变化而整体重编，这是对的，别去"优化"掉。
build_flavor "纯净版" SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PURE_BUILD'
pack_ipa "-$PURE_SUFFIX"
