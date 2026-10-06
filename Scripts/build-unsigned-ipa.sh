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

# 打包目录每次都要重建，否则旧的 Payload 会和新产物混在一起。
rm -rf build/UnsignedIPA

# DerivedData 特意保留：Release 产物是覆盖写入的，留着编译缓存只会更快，
# 不会拿到上一版的包。确实需要全量重编时用 FULL_CLEAN=1 ./build.sh。
if [ "${FULL_CLEAN:-0}" = "1" ]; then
  echo "==> 全量清理编译缓存（FULL_CLEAN=1）"
  rm -rf build/DerivedData
fi

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

# 版本号由 build.sh 维护（每次出包末位 +1），这里读出来给产物命名。
# 不带版本号的话，dist/ 里只剩一个固定名字，分不清哪次构建对应哪一版；
# 光用时间戳也不行——手机上装的是哪个版本仍然看不出来。
VERSION="${VERSION:-$(python3 "$ROOT/Scripts/bump-version.py")}"

STABLE_IPA="$ROOT/dist/$APP_NAME-unsigned.ipa"
VERSIONED_IPA="$ROOT/dist/$APP_NAME-${VERSION}-unsigned.ipa"

rm -f "$STABLE_IPA"
cd build/UnsignedIPA
zip -qry "$STABLE_IPA" Payload
cp "$STABLE_IPA" "$VERSIONED_IPA"

echo "输出: $VERSIONED_IPA"
echo "固定名副本: $STABLE_IPA"
