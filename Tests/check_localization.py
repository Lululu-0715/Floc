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
    """返回 (错误列表, 条目数)。"""
    errors = []
    try:
        text = open(path, encoding='utf-8').read()
    except Exception as exc:  # noqa: BLE001
        return [f'无法读取: {exc}'], 0

    # 逐条匹配 "key" = "value"; 允许 value 里出现转义引号
    pattern = re.compile(
        r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$'
    )

    entries = 0
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

        if not pattern.match(buffer):
            errors.append(f'{path}:{start_line} 语法错误: {buffer[:90]}')
        else:
            entries += 1
        buffer = ''

    if buffer:
        errors.append(f'{path}:{start_line} 末尾缺少分号: {buffer[:90]}')

    return errors, entries


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    files = sorted(glob.glob(os.path.join(root, 'Resources', '*.lproj', 'Localizable.strings')))

    if not files:
        print('未找到任何 Localizable.strings')
        return 1

    # 以简体中文为基准，检查各语言条目数是否一致
    baseline = None
    baseline_name = None
    all_errors = []
    summary = []

    for path in files:
        errors, entries = check_file(path)
        name = os.path.basename(os.path.dirname(path))
        summary.append((name, entries))
        all_errors.extend(errors)

        if baseline is None:
            baseline, baseline_name = entries, name

    for name, entries in summary:
        if entries != baseline:
            all_errors.append(
                f'{name} 条目数 {entries} 与基准语言 {baseline_name} 的 {baseline} 不一致'
            )

    if all_errors:
        print('文案校验失败:')
        for error in all_errors:
            print('  ' + error)
        return 1

    print(f'文案校验通过，共 {len(files)} 种语言，各 {baseline} 条')
    for name, entries in summary:
        print(f'  {name}: {entries}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
