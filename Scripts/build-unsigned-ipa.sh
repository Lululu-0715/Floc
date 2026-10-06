#!/usr/bin/env bash
#
# 生成未签名 IPA。
#
# 流程：编译 Go 静态库 → XcodeGen 生成工程 → xcodebuild 构建 → 打包 Payload → 压缩为 IPA
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Floc"

"$ROOT/Scripts/build-core.sh"

command -v xcodegen >/dev/null 2>&1 || {
  echo "缺少 xcodegen，请先执行: brew install xcodegen" >&2
  exit 1
}

echo "==> 生成 Xcode 工程"
xcodegen generate

echo "==> 清理旧的构建产物"
rm -rf build/UnsignedIPA build/DerivedData

echo "==> 构建 Release 版本"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

APP_BUNDLE="build/DerivedData/Build/Products/Release-iphoneos/$APP_NAME.app"
if [ ! -d "$APP_BUNDLE" ]; then
  echo "未找到 App 产物: $APP_BUNDLE" >&2
  exit 1
fi

echo "==> 打包 IPA"
mkdir -p build/UnsignedIPA/Payload dist
cp -R "$APP_BUNDLE" "build/UnsignedIPA/Payload/$APP_NAME.app"

BUILD_TIMESTAMP="${BUILD_TIMESTAMP:-$(date '+%Y%m%d-%H%M%S')}"
case "$BUILD_TIMESTAMP" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) echo "BUILD_TIMESTAMP 必须形如 yyyyMMdd-HHmmss" >&2; exit 2 ;;
esac

IPA="$ROOT/dist/$APP_NAME-unsigned.ipa"
TIMESTAMPED_IPA="$ROOT/dist/$APP_NAME-${BUILD_TIMESTAMP}-unsigned.ipa"

rm -f "$IPA"
cd build/UnsignedIPA
zip -qry "$IPA" Payload
cp "$IPA" "$TIMESTAMPED_IPA"

echo "输出: $IPA"
echo "带时间戳输出: $TIMESTAMPED_IPA"
