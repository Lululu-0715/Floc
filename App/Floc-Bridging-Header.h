#import <Foundation/Foundation.h>

// Go Core 导出的 C 接口。
//
// 这里直接引入 cgo 生成的 Core/locationcore.h，而不是手抄一份声明。
// 手抄版本曾经和 bridge.go 漂移过：locationcore_generateca 从「两个出参」
// 改成了「返回结构体」，Swift 侧已按新 ABI 调用，头文件却没跟上——
// 这不仅是编译报错，就算硬改签名也会在运行期按错误的调用约定取返回值。
//
// 唯一的事实来源是 Core/bridge.go 里的 `//export` 注释。
// 改了 bridge.go 之后依次执行：
//   1. Scripts/build-core.sh    # 重新生成 Core/locationcore.h
//   2. xcodegen generate        # 刷新工程（Core 已在 HEADER_SEARCH_PATHS 中）
// 本文件无需任何改动。

#ifndef LOCATION_SPOOFER_BRIDGE_H
#define LOCATION_SPOOFER_BRIDGE_H

#import "locationcore.h"

#endif /* LOCATION_SPOOFER_BRIDGE_H */
