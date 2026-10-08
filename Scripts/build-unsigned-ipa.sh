#!/usr/bin/env bash
#
# 生成未签名 IPA。
#
# 默认出**两个**包（口味列表见 `FLAVORS`，默认 `standard localOnly`）：
#
#   Floc-<版本>-unsigned.ipa          标准版：全功能（第三方代理 + 应用内代理 + 卡密）
#   Floc-<版本>-仅内置-unsigned.ipa   仅内置代理版：只有应用内代理
#
# 另外两种口味默认不出，需要时用 `FLAVORS="standard pure"` 之类显式开启：
#
#   standard   全功能版
#   localOnly  仅内置代理版
#   pure       纯净版（PURE_BUILD，没有卡密那套）
#
# 「仅内置」不是编译条件，而是**在源码上临时应用一个补丁**
# （`Scripts/patches/local-proxy-only.patch`）：把第三方代理那条链路的代码
# 从工作区里摘掉，构建完再原样撤回。这样做的好处是主源码永远是全功能那一份，
# 不必在十几个文件里铺满 `#if`，以后改动也只有一处要维护。
#
# 补丁撤回失败会**直接报错终止**，不会留下一个半删状态的源码树。
#
# 纯净版裁掉什么、怎么裁，见 `Shared/BuildFlavor.swift`。
#
# 流程：编译 Go 静态库 → XcodeGen 生成工程 → 逐口味构建 → 打包 Payload
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Floc"

# 各口味文件名的后缀。build.sh 校验产物时也要用，所以走环境变量，默认值一致。
PURE_SUFFIX="${PURE_SUFFIX:-纯净}"
LOCAL_ONLY_SUFFIX="${LOCAL_ONLY_SUFFIX:-仅内置}"

# 要出哪些口味，空格分隔。
FLAVORS="${FLAVORS:-standard localOnly}"

# 「仅内置代理」补丁：把第三方代理那条链路的代码从工作区里摘掉。
LOCAL_ONLY_PATCH="$ROOT/Scripts/patches/local-proxy-only.patch"

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

# 「仅内置代理」补丁的应用 / 撤回。
#
# 撤回必须成功：失败要立刻报错，否则工作区会停在「第三方代码已摘掉」的
# 半截状态，下一次出包就会出错，而且很难看出原因。
PATCH_APPLIED=0
revert_local_only_patch() {
  if [ "$PATCH_APPLIED" -eq 1 ]; then
    echo "==> 撤回「仅内置代理」补丁"
    if git -C "$ROOT" apply -R "$LOCAL_ONLY_PATCH"; then
      PATCH_APPLIED=0
    else
      echo "补丁撤回失败！源码可能停在「仅内置」状态。" >&2
      echo "请手动执行: git -C \"$ROOT\" checkout -- App Shared Resources Tests" >&2
      exit 1
    fi
  fi
}
trap revert_local_only_patch EXIT

for flavor in $FLAVORS; do
  case "$flavor" in
    standard)
      # 全功能版：不追加任何编译条件，和改造前完全一致。
      build_flavor "标准版"
      pack_ipa ""
      ;;

    pure)
      # 纯净版：只多一个 PURE_BUILD。工程本身没设过
      # SWIFT_ACTIVE_COMPILATION_CONDITIONS，所以 "$(inherited)" 展开成空，
      # 实际生效的就是 PURE_BUILD。第二次构建时 Swift 会因为编译条件变化而
      # 整体重编，这是对的，别去"优化"掉。
      build_flavor "纯净版" SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PURE_BUILD'
      pack_ipa "-$PURE_SUFFIX"
      ;;

    localOnly)
      # 应用补丁前必须确认工作区干净：补丁是按全功能源码的上下文生成的，
      # 有未提交改动时要么 apply 失败，要么把别人的改动一起卷进去。
      if ! git -C "$ROOT" diff --quiet -- App Shared Resources Tests; then
        echo "App / Shared / Resources / Tests 下有未提交改动，" >&2
        echo "无法安全应用「仅内置代理」补丁。请先提交或暂存后再出包。" >&2
        exit 1
      fi
      echo "==> 应用「仅内置代理」补丁"
      git -C "$ROOT" apply "$LOCAL_ONLY_PATCH"
      PATCH_APPLIED=1
      # 补丁删掉了 ModeSelectionStep.swift，工程文件必须跟着重生成。
      xcodegen generate
      build_flavor "仅内置代理版"
      pack_ipa "-$LOCAL_ONLY_SUFFIX"
      revert_local_only_patch
      # 源码回来了，工程文件也要跟着回来。
      xcodegen generate
      ;;

    *)
      echo "未知口味: ${flavor}（可用: standard / pure / localOnly）" >&2
      exit 2
      ;;
  esac
done

trap - EXIT
