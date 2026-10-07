#!/usr/bin/env python3
"""校验 Localizable.strings 的语法。

strings 文件本质是 plist，格式错误会导致整份文案静默失效，
因此构建前必须先验证。这里不依赖 plutil，做一份轻量检查。
"""
import re
import sys
import glob
import os

FORBIDDEN_UNESCAPED = re.compile(r'(?<!\\)"')


def check_file(path):
    """返回 (错误列表, 条目数, key 集合)。"""
    errors = []
    try:
        text = open(path, encoding='utf-8').read()
    except Exception as exc:  # noqa: BLE001
        return [f'无法读取: {exc}'], 0, set()

    # 逐条匹配 "key" = "value"; 允许 value 里出现转义引号
    pattern = re.compile(
        r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$'
    )

    entries = 0
    keys = set()
    duplicates = []
    buffer = ''
    start_line = 0

    for lineno, raw in enumerate(text.split('\n'), 1):
        line = raw.strip()
        if not line or line.startswith('//'):
            continue

        if not buffer:
            start_line = lineno
        buffer = f'{buffer} {line}'.strip()

        # 一条记录必须以分号结尾才算完整
        if not buffer.endswith(';'):
            continue

        match = pattern.match(buffer)
        if not match:
            errors.append(f'{path}:{start_line} 语法错误: {buffer[:90]}')
        else:
            entries += 1
            key = match.group(1)
            # 重复 key 是个静默陷阱：plist 解析时后写的覆盖先写的，
            # 两边值不一样就会「明明改了却没生效」。之前 zh-Hant 里
            # 「已复制」同时存在「已復製」和「已複製」就是这么来的。
            if key in keys:
                duplicates.append(f'{path}:{start_line} 重复定义 key: {key}')
            keys.add(key)
        buffer = ''

    if buffer:
        errors.append(f'{path}:{start_line} 末尾缺少分号: {buffer[:90]}')

    errors.extend(duplicates)
    return errors, entries, keys


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    files = sorted(glob.glob(os.path.join(root, 'Resources', '*.lproj', 'Localizable.strings')))

    if not files:
        print('未找到任何 Localizable.strings')
        return 1

    # 以简体中文为基准，检查各语言的条目数与 **key 集合** 是否一致。
    #
    # 只比对条目数是不够的：繁体和英文目前是人工维护的（生成脚本的
    # 简→繁字符表覆盖不全，跑一遍反而会把已经写好的繁体打回简体，
    # 所以 zh-Hant 不能靠自动生成）。这种情况下「条数一样但换了个 key」
    # 会静默漏过，用户看到的是某一条文案突然变回 key 原文。
    baseline = None
    baseline_name = None
    baseline_keys = set()
    all_errors = []
    summary = []
    parsed = []

    for path in files:
        errors, entries, keys = check_file(path)
        name = os.path.basename(os.path.dirname(path))
        summary.append((name, entries))
        parsed.append((name, keys))
        all_errors.extend(errors)

        if baseline is None:
            baseline, baseline_name, baseline_keys = entries, name, keys

    for name, entries in summary:
        if entries != baseline:
            all_errors.append(
                f'{name} 条目数 {entries} 与基准语言 {baseline_name} 的 {baseline} 不一致'
            )

    # key 集合必须与基准语言完全一致
    for name, keys in parsed:
        missing = sorted(baseline_keys - keys)
        extra = sorted(keys - baseline_keys)
        if missing:
            all_errors.append(
                f'{name} 缺少 {len(missing)} 个 key（未翻译）：'
                + '、'.join(missing[:5])
                + ('…' if len(missing) > 5 else '')
            )
        if extra:
            all_errors.append(
                f'{name} 多出 {len(extra)} 个基准语言没有的 key：'
                + '、'.join(extra[:5])
                + ('…' if len(extra) > 5 else '')
            )

    if all_errors:
        print('文案校验失败:')
        for error in all_errors:
            print('  ' + error)
        return 1

    print(f'文案校验通过，共 {len(files)} 种语言，各 {baseline} 条，key 完全一致')
    for name, entries in summary:
        print(f'  {name}: {entries}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
