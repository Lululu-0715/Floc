#!/usr/bin/env python3
"""从简体中文文案生成英文与繁体中文文案。

繁体部分做字符级转换（简→繁），英文部分使用显式映射表。
好处是能严格保证三种语言的 key 集合完全一致，避免漏翻。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(ROOT, 'Resources')

ENTRY_RE = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')


def parse(path):
    """解析 strings 文件，返回有序的 (key, value) 列表。"""
    entries = []
    buffer = ''
    for raw in open(path, encoding='utf-8').read().split('\n'):
        line = raw.strip()
        if not line or line.startswith('//'):
            continue
        buffer = f'{buffer} {line}'.strip()
        if not buffer.endswith(';'):
            continue
        match = ENTRY_RE.match(buffer)
        if match:
            entries.append((match.group(1), match.group(2)))
        buffer = ''
    return entries


def unescape(text):
    return text.replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')


def escape(text):
    return text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')


# 简 → 繁 字符映射。只覆盖文案里实际出现的字，避免引入过度转换。
S2T = {
    '应': '應', '内': '內', '运': '運', '行': '行', '模': '模', '式': '式', '代': '代', '理': '理',
    '设': '設', '备': '備', '覆': '覆', '盖': '蓋', '当': '當', '前': '前', '需': '需', '要': '要',
    '安': '安', '装': '裝', '并': '並', '信': '信', '任': '任', '证': '證', '书': '書',
    '由': '由', '你': '你', '自': '自', '己': '己', '的': '的', '客': '客', '户': '戶', '端': '端',
    '执': '執', '可': '可', '蜂': '蜂', '窝': '窩', '网': '網', '络': '絡', '无': '無',
    '切': '切', '换': '換', '后': '後', '会': '會', '重': '重', '新': '新', '进': '進',
    '入': '入', '配': '配', '置': '置', '引': '引', '导': '導', '两': '兩', '种': '種',
    '互': '互', '不': '不', '影': '影', '响': '響',
    '选': '選', '择': '擇', '授': '授', '予': '予', '必': '必', '执': '執',
    '先': '先', '确': '確', '定': '定', '拦': '攔', '截': '截', '在': '在', '哪': '哪', '里': '裡',
    '这': '這', '一': '一', '步': '步', '之': '之', '仍': '仍', '随': '隨', '时': '時',
    '地': '地', '图': '圖', '显': '顯', '示': '示', '与': '與', '名': '名', '称': '稱',
    '读': '讀', '取': '取', '定': '定', '位': '位', '权': '權', '限': '限',
    '本': '本', '用': '用', '上': '上', '传': '傳', '任': '任', '何': '何', '数': '數', '据': '據',
    '把': '把', '指': '指', '向': '向', '在': '在', '你': '你', '中': '中', '导': '導',
    '对': '對', '解': '解', '密': '密', '完': '完', '整': '整', '检': '檢', '测': '測',
    '认': '認', '每': '每', '个': '個', '环': '環', '节': '節', '都': '都', '通': '通',
    '了': '了', '再': '再', '开': '開', '始': '始', '使': '使',
    '过': '過', '删': '刪', '除': '除', '清': '清', '空': '空', '保': '保', '存': '存',
    '关': '關', '闭': '閉', '校': '校', '验': '驗', '失': '失', '败': '敗',
    '获': '獲', '得': '得', '环': '環', '境': '境', '检': '檢', '查': '查',
    '报': '報', '告': '告', '预': '預', '览': '覽', '复': '複', '制': '製',
    '已': '已', '经': '經', '还': '還', '没': '沒', '有': '有', '结': '結', '果': '果',
    '点': '點', '击': '擊', '下': '下', '方': '方', '按': '按', '钮': '鈕',
    '逐': '逐', '项': '項', '链': '鏈', '路': '路', '与': '與', '改': '改', '写': '寫',
    '系': '係', '统': '統', '够': '夠', '从': '從', '来': '來', '调': '調', '试': '試',
    '研': '研', '究': '究', '请': '請', '仅': '僅', '拥': '擁', '或': '或',
    '网': '網', '设': '設', '置': '置', '页': '頁', '面': '面', '语': '語', '言': '言',
    '部': '部', '分': '分', '需': '需', '效': '效', '支': '支', '持': '持',
    '诊': '診', '断': '斷', '筛': '篩', '级': '級', '条': '條', '志': '誌',
    '别': '別', '自': '自', '动': '動', '刷': '刷', '新': '新', '全': '全',
    '题': '題', '描': '描', '述': '述', '说': '說', '明': '明', '遇': '遇', '到': '到',
    '例': '例', '如': '如', '仍': '仍', '真': '真', '实': '實', '稳': '穩',
    '附': '附', '带': '帶', '先': '先', '做': '做', '脱': '脫', '敏': '敏', '处': '處',
    '理': '理', '去': '去', '令': '令', '牌': '牌', '等': '等', '感': '感', '内': '內',
    '容': '容', '生': '生', '成': '成', '认': '認', '希': '希', '望': '望', '公': '公',
    '信': '信', '息': '息', '提': '提', '交': '交', '型': '型', '号': '號',
    '状': '狀', '态': '態', '网': '網', '络': '絡', '共': '共', '享': '享',
    '启': '啟', '可': '可', '版': '版', '构': '構', '建': '建', '核': '核', '心': '心',
    '当': '當', '可': '可', '能': '能', '受': '受',
    '开': '開', '启': '啟', '前': '前', '确': '確', '认': '認',
    '如': '如', '何': '何', '彻': '徹', '底': '底', '恢': '恢', '复': '復',
    '后': '後', '被': '被', '改': '改', '部': '部', '分': '分', '应': '應',
    '独': '獨', '立': '立', '的': '的', '缓': '緩', '存': '存', '或': '或',
    '策': '策', '略': '略', '可': '可', '能': '能', '待': '待', '刷': '刷',
    '启': '啟', '动': '動', '目': '目', '标': '標', '停': '停', '止': '止',
    '还': '還', '手': '手', '关': '關', '旧': '舊', '必': '必',
    '规': '規', '则': '則', '由': '由', '客': '客', '户': '戶', '端': '端',
    '里': '裡', '继': '繼', '续': '續', '描': '描', '述': '述', '安': '安',
    '装': '裝', '描': '描', '述': '述', '文': '文', '件': '件',
    '手': '手', '动': '動', '否': '否', '则': '則', '拦': '攔', '截': '截',
    '不': '不', '效': '效', '无': '無', '法': '法', '错': '錯', '误': '誤',
    '钥': '鑰', '匙': '匙', '串': '串', '编': '編', '码': '碼', '拒': '拒',
    '绝': '絕', '构': '構', '造': '造', '询': '詢', '问': '問', '地': '地',
    '址': '址', '未': '未', '找': '找', '到': '到', '匹': '匹', '搜': '搜',
    '索': '索', '选': '選', '藏': '藏', '取': '取', '消': '消',
    '便': '便', '于': '於', '识': '識', '别': '別', '编': '編', '辑': '輯',
    '该': '該', '删': '刪', '除': '除', '精': '精', '度': '度', '模': '模',
    '拟': '擬', '静': '靜', '止': '止', '状': '狀', '态': '態', '运': '運',
    '行': '行', '自': '自', '检': '檢', '直': '直', '接': '接', '判': '判',
    '断': '斷', '通': '通', '常': '常', '米': '米', '较': '較', '然': '然',
    '托': '託', '管': '管', '填': '填', '带': '帶', '重': '重',
    '连': '連', '畅': '暢', '客': '客', '户': '戶', '端': '端',
    '模': '模', '块': '塊', '只': '只', '负': '負', '责': '責',
    '写': '寫', '入': '入', '标': '標', '代': '代', '理': '理',
    '状': '狀', '态': '態', '当': '當', '前': '前', '网': '網',
    '开': '開', '启': '啟', '关': '關', '闭': '閉',
    '重': '重', '置': '置', '引': '導', '流': '流', '程': '程',
    '需': '需', '要': '要', '完': '完', '成': '成', '已': '已',
    '保': '保', '存': '存', '的': '的', '收': '收', '藏': '藏',
    '和': '和', '证': '證', '书': '書', '不': '不', '受': '受',
    '影': '影', '响': '響', '关': '關', '于': '於',
    '应': '應', '用': '用', '版': '版', '本': '本', '构': '構',
    '建': '建', '号': '號', '内': '內', '核': '核', '心': '心',
    '数': '數', '据': '據', '共': '共', '享': '享',
    '启': '啟', '用': '用', '可': '可', '不': '不',
    '当': '當', '前': '前', '系': '係', '统': '統', '版': '版',
    '本': '本', '可': '可', '能': '能', '不': '不', '受': '受',
    '支': '支', '持': '持', '用': '用', '于': '於',
    '定': '定', '位': '位', '服': '服', '务': '務', '的': '的',
    '开': '開', '发': '發', '测': '測', '试': '試', '与': '與',
    '研': '研', '究': '究', '请': '請', '仅': '僅', '在': '在',
    '你': '你', '拥': '擁', '有': '有', '或': '或', '获': '獲',
    '得': '得', '授': '授', '权': '權', '的': '的', '设': '設',
    '备': '備', '与': '與', '网': '網', '络': '絡', '环': '環',
    '境': '境', '中': '中', '使': '使', '用': '用',
    '诊': '診', '断': '斷', '环': '環', '境': '境', '检': '檢',
    '查': '查', '重': '重', '新': '新', '结': '結', '果': '果',
    '当': '當', '前': '前', '配': '配', '置': '置', '虚': '虛',
    '拟': '擬', '定': '定', '位': '位', '已': '已', '开': '開',
    '启': '啟', '关': '關', '闭': '閉', '坐': '坐', '标': '標',
    '地': '地', '图': '圖', '体': '體', '系': '係', '日': '日',
    '志': '誌', '条': '條', '数': '數', '运': '運', '行': '行',
    '暂': '暫', '无': '無', '匹': '匹', '配': '配', '筛': '篩',
    '选': '選', '级': '級', '别': '別', '全': '全', '部': '部',
    '自': '自', '动': '動', '刷': '刷', '新': '新', '复': '複',
    '制': '製', '清': '清', '空': '空', '保': '保', '存': '存',
    '在': '在', '本': '本', '机': '機', '保': '保', '留': '留',
    '最': '最', '近': '近', '天': '天', '时': '時', '会': '會',
    '脱': '脫', '敏': '敏', '问': '問', '题': '題', '报': '報',
    '告': '告', '描': '描', '述': '述', '说': '說', '明': '明',
    '遇': '遇', '到': '到', '例': '例', '如': '如', '仍': '仍',
    '真': '真', '实': '實', '位': '位', '置': '置', '稳': '穩',
    '附': '附', '带': '帶', '先': '先', '做': '做', '处': '處',
    '理': '理', '去': '去', '令': '令', '牌': '牌', '感': '感',
    '内': '內', '容': '容', '生': '生', '成': '成', '认': '認',
    '希': '希', '望': '望', '公': '公', '信': '信', '息': '息',
    '提': '提', '交': '交', '型': '型', '号': '號',
    '状': '狀', '态': '態', '共': '共', '享': '享',
    '设': '設', '备': '備',
    '开': '開', '启': '啟', '前': '前', '确': '確', '认': '認',
    '如': '如', '何': '何', '彻': '徹', '底': '底', '恢': '恢',
    '复': '復', '真': '真', '实': '實', '位': '位', '置': '置',
    '第': '第', '三': '三', '方': '方', '模': '模', '式': '式',
    '说': '說', '明': '明', '关': '關', '于': '於', '证': '證',
    '书': '書', '信': '信', '任': '任',
}

# 简 → 繁 词组映射（优先于单字映射，处理「内/裡」这类上下文相关的转换）
PHRASES = {
    '里面': '裡面',
    '内在': '內在',
}

# 英文文案映射。key 与简体中文的 key 完全一致。
EN = {
    # 通用
    '未启动': 'Not started',
    '启动中': 'Starting',
    '运行中': 'Running',
    '启动失败': 'Failed to start',
    '未检测': 'Not checked',
    '未配置': 'Not configured',
    '已生效': 'Active',
    '检测中': 'Checking',
    '未验证': 'Unverified',
    '已信任': 'Trusted',
    '未信任': 'Not trusted',
    '验证失败': 'Verification failed',
    '无法判定': 'Undetermined',
    '取消': 'Cancel',
    '保存': 'Save',
    '完成': 'Done',
    '关闭': 'Close',
    '删除': 'Delete',
    '清空': 'Clear',
    '重置': 'Reset',
    '名称': 'Name',
    '精度': 'Accuracy',
    '未知': 'Unknown',

    # 坐标体系
    '国际标准 (WGS-84)': 'International (WGS-84)',
    '国内标准 (GCJ-02)': 'China (GCJ-02)',

    # 运行模式
    '应用内代理': 'In-app proxy',
    '第三方代理': 'Third-party proxy',
    '在设备内运行拦截代理，只覆盖当前 Wi-Fi，需要安装并信任证书。':
        'Runs the intercepting proxy on-device. Covers the current Wi-Fi only, and requires installing a trusted certificate.',
    '由你自己的代理客户端执行拦截，可覆盖蜂窝网络，无需安装本应用证书。':
        'Your own proxy client performs the interception. Can cover cellular networks, and needs no certificate from this app.',
    '运行模式': 'Runtime mode',
    '切换后会重新进入配置引导，两种模式的配置互不影响。':
        'Switching restarts the setup guide. Each mode keeps its own configuration.',

    # 引导流程
    '选择运行模式': 'Choose runtime mode',
    '授予必要权限': 'Grant permissions',
    '配置代理环境': 'Set up proxy',
    '执行环境检测': 'Run environment checks',
    '先确定拦截在哪里执行。这一步之后仍可随时切换。':
        'Decide where interception happens. You can switch later at any time.',
    '地图显示与 Wi-Fi 名称读取需要定位权限，本应用不会上传任何位置数据。':
        'Showing the map and reading the Wi-Fi name require location permission. This app never uploads location data.',
    '需要安装本机证书，并把当前 Wi-Fi 的代理指向本机。':
        'Install the on-device certificate and point the current Wi-Fi proxy to this device.',
    '需要在你的代理客户端中导入模块，并开启对应主机名的解密。':
        'Import the module into your proxy client and enable HTTPS decryption for the relevant hosts.',
    '运行完整检测，确认每个环节都通了再开始使用。':
        'Run the full check to confirm every step works before you begin.',
    '上一步': 'Back',
    '下一步': 'Next',
    '开始检测': 'Start check',
    '重新检测': 'Recheck',
    '复制报告': 'Copy report',
    '已复制': 'Copied',
    '通过': 'Passed',
    '未通过': 'Failed',
    '跳过': 'Skipped',
    '还没有检测结果': 'No results yet',
    '点击下方按钮开始检测。检测会逐项验证证书信任、代理链路与改写引擎。':
        'Tap the button below to start. The check verifies certificate trust, the proxy path, and the rewrite engine.',
    '环境检测通过': 'Environment check passed',
    '有项目未通过': 'Some checks failed',
    '可以开始使用虚拟定位了。': 'You can start using location spoofing.',
    '可以继续，但未通过的项目可能导致定位不生效。':
        'You can continue, but failed checks may prevent the spoof from working.',
    '环境检测报告': 'Environment check report',
    '生成时间': 'Generated at',

    # 权限
    '定位权限': 'Location permission',
    'Wi-Fi 信息': 'Wi-Fi information',
    '用于在地图上显示真实位置，便于与虚拟位置对照。':
        'Used to show your real position on the map so you can compare it with the spoofed one.',
    '用于读取当前 Wi-Fi 名称，在引导中明确指出该去哪一页配置代理。':
        'Used to read the current Wi-Fi name so the guide can point you to the right settings page.',
    '未读取到名称': 'Name unavailable',
    '未授权': 'Not granted',
    '受限': 'Restricted',
    '已拒绝': 'Denied',
    '使用期间': 'While using',
    '始终': 'Always',
    '授权': 'Grant',
    '关于隐私': 'About privacy',
    '本应用不包含遥测，不上传位置数据。运行日志只保存在设备本地，自动保留最近 3 天，在提交问题报告时会自动对经纬度、令牌等信息做脱敏处理。':
        'This app contains no telemetry and uploads no location data. Logs stay on the device, are kept for three days, and are redacted (coordinates, tokens) before you submit a report.',

    # 环境检测项
    '证书信任': 'Certificate trust',
    'Wi-Fi 代理链路': 'Wi-Fi proxy path',
    '第三方模块连通': 'Third-party module link',
    '改写引擎自检': 'Rewrite engine self-check',
    '代理服务': 'Proxy service',
    '模块连接': 'Module connection',
    '系统已信任本机根证书': 'The system trusts the on-device root certificate',
    '证书未安装或未开启完全信任': 'Certificate not installed, or full trust not enabled',
    '证书服务未启动': 'Certificate service not started',
    '请先启动代理': 'Start the proxy first',
    '请求没有经过本机代理，请检查 Wi-Fi 代理配置':
        'Requests are not going through the on-device proxy. Check your Wi-Fi proxy settings.',
    '代理未启动': 'Proxy not started',
    '客户端已响应配置接口': 'The client responded to the configuration endpoint',
    '模块未生效，请确认已导入并开启解密':
        'Module is inactive. Make sure it is imported and decryption is enabled.',
    '未完成检测': 'Check not completed',

    # 代理配置
    '配置步骤': 'Steps',
    '下载证书': 'Download certificate',
    '信任设置': 'Trust settings',
    '前往 Wi-Fi 设置': 'Open Wi-Fi settings',
    '启动代理服务': 'Start proxy service',
    '用 Safari 打开 %@ 下载证书，然后在「设置 → 通用 → VPN 与设备管理」中安装。':
        'Open %@ in Safari to download the certificate, then install it under Settings → General → VPN & Device Management.',
    '先启动代理以生成证书服务。': 'Start the proxy first to bring up the certificate service.',
    '在「设置 → 通用 → 关于本机 → 证书信任设置」中为证书开启完全信任。':
        'Enable full trust for the certificate under Settings → General → About → Certificate Trust Settings.',
    '当前 Wi-Fi': 'current Wi-Fi',
    '当前 Wi-Fi「%@」': 'current Wi-Fi “%@”',
    '在「设置 → 无线局域网 → %@ → 配置代理」中选择「手动」，服务器填 %@，端口填 %d。':
        'Under Settings → Wi-Fi → %@ → Configure Proxy, choose Manual, set the server to %@ and the port to %d.',
    '回到本应用执行环境检测，两项都通过后即可开启虚拟定位。':
        'Return to this app and run the environment check. Once both items pass, you can enable spoofing.',
    '不要同时开启应用内代理和第三方代理，两条链路会互相干扰。':
        'Do not enable the in-app proxy and a third-party proxy at the same time — the two paths interfere with each other.',

    # 第三方模式
    '选择你使用的客户端': 'Choose your client',
    '已真机验证': 'Verified on device',
    '待验证': 'Unverified',
    '已安装': 'Installed',
    '未安装': 'Not installed',
    '复制模块订阅地址': 'Copy module URL',
    '打开客户端': 'Open client',
    '打开 %@': 'Open %@',
    '复制下方的模块订阅地址。': 'Copy the module URL below.',
    '在 %@ 中导入该地址对应的模块。': 'Import the module from that URL in %@.',
    '确认模块已启用，并为定位相关主机名开启 HTTPS 解密。':
        'Make sure the module is enabled and HTTPS decryption is on for the location hosts.',
    '回到本应用点击「重新检测」，状态变为「已连接」即可。':
        'Come back and tap Recheck. When the status shows Connected, you are done.',
    '注意：该客户端在当前版本下可能无法覆盖蜂窝网络。':
        'Note: this client may not cover cellular networks in the current version.',
    '未安装客户端': 'Client not installed',
    '模块未生效': 'Module inactive',
    '已连接，未开启': 'Connected, not enabled',
    '已连接': 'Connected',
    '配置失败': 'Configuration failed',

    # 主界面
    '搜索地点或地址': 'Search a place or address',
    '没有找到匹配的地点': 'No matching place found',
    '搜索失败：%@': 'Search failed: %@',
    '已选位置': 'Selected location',
    '保存为收藏': 'Save as favorite',
    '为当前选点取一个便于识别的名字。': 'Give this location an easy-to-recognize name.',
    '已收藏': 'Saved to favorites',
    '已取消收藏': 'Removed from favorites',
    '编辑收藏': 'Edit favorite',
    '删除该收藏': 'Delete this favorite',
    '开启虚拟定位': 'Enable spoofing',
    '停止虚拟定位': 'Stop spoofing',
    '虚拟定位已开启': 'Spoofing enabled',
    '请先在地图上选择位置': 'Pick a location on the map first',
    '证书尚未被信任，定位不会生效': 'The certificate is not trusted yet, so spoofing will not work',
    'Wi-Fi 代理未生效，请检查代理配置': 'The Wi-Fi proxy is not active. Check your proxy settings.',
    '坐标已写入客户端': 'Coordinates written to the client',
    '写入失败，请检查客户端模块是否生效':
        'Write failed. Check that the client module is active.',
    '已停止虚拟定位，请同时关闭 Wi-Fi 代理':
        'Spoofing stopped. Remember to turn off the Wi-Fi proxy as well.',
    '已清除客户端坐标': 'Client coordinates cleared',
    '当前系统版本（%@）可能已禁用对定位服务的拦截，功能可能不生效。':
        'The current system version (%@) may have blocked interception of location services, so this feature may not work.',

    # 设置
    '设置': 'Settings',
    '客户端': 'Client',
    '连接状态': 'Connection',
    '自定义模块托管地址': 'Custom module host',
    '重新检测连通性': 'Recheck connection',
    '清除客户端坐标': 'Clear client coordinates',
    '模块由第三方客户端执行拦截，本应用只负责写入坐标。':
        'The third-party client performs the interception; this app only writes coordinates.',
    '托管地址前缀': 'Host URL prefix',
    '填写模块文件所在目录的地址前缀，不带文件名。':
        'Enter the URL prefix of the directory holding the modules, without the file name.',
    '模块托管地址': 'Module host',
    '代理状态': 'Proxy status',
    '当前网络': 'Current network',
    '重新检测环境': 'Recheck environment',
    '下载 CA 证书': 'Download CA certificate',
    '打开证书信任设置': 'Open certificate trust settings',
    '打开 Wi-Fi 设置': 'Open Wi-Fi settings',
    '重置本机证书': 'Reset on-device certificate',
    '重置证书后需要重新下载并在系统设置中再次信任。':
        'After resetting, you must download the certificate again and re-trust it in system settings.',
    '虚拟定位参数': 'Spoofing parameters',
    '模拟精度': 'Simulated accuracy',
    '模拟静止状态': 'Simulate stationary state',
    '运行改写引擎自检': 'Run rewrite engine self-check',
    '精度会写入客户端配置；运动状态模拟仅在应用内代理模式下可用。':
        'Accuracy is written to the client configuration. Motion simulation is available in in-app proxy mode only.',
    '精度直接影响系统对定位可信度的判断，通常 25 米较为自然。':
        'Accuracy affects how the system judges location reliability. 25 m usually looks natural.',
    '收藏位置': 'Favorites',
    '清空全部收藏': 'Clear all favorites',
    '清空全部收藏？': 'Clear all favorites?',
    '语言': 'Language',
    '界面语言': 'Interface language',
    '跟随系统': 'Follow system',
    '切换语言后部分界面需要重新进入才会完全生效。':
        'After switching, some screens need to be reopened for the change to fully apply.',
    '支持': 'Support',
    '运行日志与诊断': 'Logs and diagnostics',
    '生成问题报告': 'Generate bug report',
    '重置引导流程': 'Reset setup guide',
    '重置引导流程？': 'Reset the setup guide?',
    '重置后需要重新完成当前模式的配置引导。已保存的收藏和证书不受影响。':
        'You will need to go through setup for the current mode again. Saved favorites and certificates are kept.',
    '关于': 'About',
    '应用版本': 'App version',
    '构建号': 'Build',
    '内核版本': 'Core version',
    '数据共享': 'Data sharing',
    '已启用': 'Enabled',
    '不可用': 'Unavailable',
    '当前系统版本可能不受支持': 'The current system version may be unsupported',
    '本应用用于定位服务的开发测试与研究，请仅在你拥有或获得授权的设备与网络环境中使用。':
        'This app is for development, testing and research on location services. Use it only on devices and networks you own or are authorized to use.',

    # 诊断
    '诊断': 'Diagnostics',
    '环境检查': 'Environment check',
    '重新检查环境': 'Recheck environment',
    '检查结果': 'Results',
    '当前配置': 'Current configuration',
    '虚拟定位': 'Spoofing',
    '已开启': 'Enabled',
    '已关闭': 'Disabled',
    '当前坐标 (WGS-84)': 'Current coordinate (WGS-84)',
    '当前坐标 (GCJ-02)': 'Current coordinate (GCJ-02)',
    '地图坐标体系': 'Map coordinate system',
    '日志条数': 'Log entries',
    '运行日志': 'Runtime logs',
    '暂无匹配的日志': 'No matching log entries',
    '筛选日志': 'Filter logs',
    '日志级别': 'Log level',
    '全部': 'All',
    '自动刷新': 'Auto refresh',
    '复制全部日志': 'Copy all logs',
    '清空日志': 'Clear logs',
    '清空全部日志？': 'Clear all logs?',
    '日志仅保存在本机，自动保留最近 3 天，复制时会自动脱敏。':
        'Logs stay on this device, are kept for three days, and are redacted when copied.',

    # 问题报告
    '问题报告': 'Bug report',
    '问题描述': 'Description',
    '说明一下遇到的问题，例如：开启虚拟定位后地图仍显示真实位置。':
        'Describe the problem, for example: after enabling spoofing, Maps still shows the real location.',
    '可以稳定复现': 'Reproducible',
    '附带运行日志': 'Attach runtime logs',
    '日志会先做脱敏处理，去除经纬度、令牌、MAC 等敏感内容。':
        'Logs are redacted first, removing coordinates, tokens, MAC addresses and similar data.',
    '生成报告': 'Generate report',
    '已复制到剪贴板': 'Copied to clipboard',
    '报告预览': 'Report preview',
    '请确认内容没有你不希望公开的信息后再提交。':
        'Please make sure the content contains nothing you would rather keep private before submitting.',
    '环境信息': 'Environment',
    '设备型号': 'Device',
    '环境状态': 'Status',
    '代理': 'proxy',

    # 提示
    '开启前请确认': 'Before you enable',
    '如何彻底恢复真实位置': 'How to fully restore your real location',
    '第三方模式说明': 'About third-party mode',
    '关于证书信任': 'About certificate trust',
    '开启后定位响应会被改写。部分应用有独立的定位缓存或校验策略，可能需要等待缓存刷新或重启目标应用。':
        'Once enabled, location responses are rewritten. Some apps keep their own cache or validation, so you may need to wait for a refresh or restart the target app.',
    '停止虚拟定位后，还需要关闭 Wi-Fi 的手动代理配置。如果系统仍显示旧位置，等待缓存刷新，必要时重启设备。':
        'After stopping, also turn off the manual Wi-Fi proxy. If the old location still shows, wait for the cache to refresh or restart the device.',
    '本应用只负责把坐标写给你的代理客户端，拦截与规则由客户端执行。应用关闭后客户端里的配置可能继续生效。':
        'This app only writes coordinates to your proxy client; the client performs interception. Its configuration may keep working after this app is closed.',
    '安装描述文件后，还需要在「设置 → 通用 → 关于本机 → 证书信任设置」中手动开启完全信任，否则拦截不会生效。':
        'After installing the profile, you must also enable full trust under Settings → General → About → Certificate Trust Settings, or interception will not work.',

    # 错误
    '无法生成本机证书': 'Could not generate the on-device certificate',
    '无法启动本机证书服务': 'Could not start the on-device certificate service',
    '无法启动本机代理服务': 'Could not start the on-device proxy service',
    '证书内容编码失败': 'Failed to encode the certificate',
    '写入钥匙串失败（状态码 %d）': 'Failed to write to the keychain (status %d)',
    '无法构造查询地址': 'Could not build the query URL',
    '无法构造保存地址': 'Could not build the save URL',
    '客户端拒绝保存': 'The client rejected the save',

    # 其它
    '位置 %d': 'Location %d',
    '未检测到已安装的 %@': 'No installed %@ detected',
}


def to_traditional(text):
    """简体转繁体。先处理词组，再逐字替换。"""
    for simplified, traditional in PHRASES.items():
        text = text.replace(simplified, traditional)
    return ''.join(S2T.get(ch, ch) for ch in text)


def write_file(path, header, entries):
    lines = [header, '']
    for key, value in entries:
        lines.append(f'"{escape(key)}" = "{escape(value)}";')
    lines.append('')
    with open(path, 'w', encoding='utf-8') as handle:
        handle.write('\n'.join(lines))


def main():
    source = os.path.join(RESOURCES, 'zh-Hans.lproj', 'Localizable.strings')
    entries = parse(source)
    keys = {key for key, _ in entries}

    missing_en = sorted(keys - set(EN))
    if missing_en:
        print('以下 key 缺少英文翻译：')
        for key in missing_en:
            print('  ' + key)
        return 1

    # 英文
    en_entries = [(key, EN[key]) for key, _ in entries]
    write_file(
        os.path.join(RESOURCES, 'en.lproj', 'Localizable.strings'),
        '// English localization',
        en_entries,
    )

    # 繁体
    zh_hant_entries = [(key, to_traditional(value)) for key, value in entries]
    write_file(
        os.path.join(RESOURCES, 'zh-Hant.lproj', 'Localizable.strings'),
        '// 繁體中文文案',
        zh_hant_entries,
    )

    print(f'已生成 en 与 zh-Hant，各 {len(entries)} 条')
    return 0


if __name__ == '__main__':
    sys.exit(main())
