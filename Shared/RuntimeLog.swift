import Foundation

/// 运行日志。
///
/// 设计要点：
///   - 日志同时写内存环形缓冲和磁盘文件，内存供诊断页实时展示，磁盘供跨启动查阅；
///   - 只保留最近 3 天，避免无限增长；
///   - 输出前会做脱敏，经纬度、令牌、MAC 等敏感内容会被替换。
enum RuntimeLogger {

    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let source: String
        let category: String
        let message: String
        let details: [String: String]

        var formattedTime: String {
            Self.timeFormatter.string(from: timestamp)
        }

        /// 单行文本形式，用于复制和写入文件。
        var line: String {
            var text = "\(formattedTime)  [\(level.rawValue)]  \(source)/\(category)  \(message)"
            if !details.isEmpty {
                let pairs = details
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                text += "  {\(pairs)}"
            }
            return text
        }

        private static let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            return formatter
        }()
    }

    // MARK: - 配置

    /// 内存中保留的最大条数。
    private static let maxMemoryEntries = 500
    /// 磁盘日志保留天数。
    private static let retentionDays = 3
    /// 低于此级别的日志不记录。
    static var minimumLevel: Level = .info

    private static let queue = DispatchQueue(label: "com.fff.loc.logger")
    private static var memoryBuffer: [Entry] = []

    // MARK: - 写入

    static func debug(_ source: String, _ category: String, _ message: String, details: [String: String] = [:]) {
        append(level: .debug, source: source, category: category, message: message, details: details)
    }

    static func info(_ source: String, _ category: String, _ message: String, details: [String: String] = [:]) {
        append(level: .info, source: source, category: category, message: message, details: details)
    }

    static func warn(_ source: String, _ category: String, _ message: String, details: [String: String] = [:]) {
        append(level: .warn, source: source, category: category, message: message, details: details)
    }

    static func error(_ source: String, _ category: String, _ message: String, details: [String: String] = [:]) {
        append(level: .error, source: source, category: category, message: message, details: details)
    }

    private static func append(
        level: Level,
        source: String,
        category: String,
        message: String,
        details: [String: String]
    ) {
        guard level.allows(minimumLevel) else { return }

        let entry = Entry(
            timestamp: Date(),
            level: level,
            source: source,
            category: category,
            message: Redactor.redact(message),
            details: details.mapValues { Redactor.redact($0) }
        )

        queue.async {
            memoryBuffer.append(entry)
            if memoryBuffer.count > maxMemoryEntries {
                memoryBuffer.removeFirst(memoryBuffer.count - maxMemoryEntries)
            }
            writeToDisk(entry)
        }
    }

    // MARK: - 读取

    /// 读取内存中的日志快照。
    static func snapshot() -> [Entry] {
        queue.sync { memoryBuffer }
    }

    /// 导出全部日志为可复制的文本。
    static func exportText() -> String {
        snapshot().map(\.line).joined(separator: "\n")
    }

    /// 清空日志（内存 + 磁盘）。
    static func clear() {
        queue.sync {
            memoryBuffer.removeAll()
            let files = (try? FileManager.default.contentsOfDirectory(
                at: AppGroup.logsDirectoryURL,
                includingPropertiesForKeys: nil
            )) ?? []
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    // MARK: - 磁盘

    private static var currentLogFileURL: URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let name = "runtime-\(formatter.string(from: Date())).log"
        return AppGroup.logsDirectoryURL.appendingPathComponent(name)
    }

    private static func writeToDisk(_ entry: Entry) {
        let line = entry.line + "\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = currentLogFileURL

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 清理超过保留期的日志文件。建议在 App 启动时调用一次。
    static func purgeExpiredLogs() {
        queue.async {
            let fileManager = FileManager.default
            let directory = AppGroup.logsDirectoryURL
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { return }

            let deadline = Date().addingTimeInterval(-Double(retentionDays) * 86400)
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? Date()
                if modified < deadline {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
    }
}

private extension RuntimeLogger.Level {
    var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }

    func allows(_ minimum: RuntimeLogger.Level) -> Bool {
        rank >= minimum.rank
    }
}

/// 日志脱敏。
///
/// 日志可能被用户复制后贴到公开 Issue，因此写入前必须把可能泄露隐私的内容
/// 替换掉。这里做保守处理：宁可多脱敏，也不要漏。
enum Redactor {

    private static let rules: [(pattern: String, replacement: String)] = [
        // 长小数（经纬度特征：小数点后 6 位以上）
        (#"-?\d{1,3}\.\d{6,}"#, "<坐标已脱敏>"),
        // MAC 地址
        (#"(?i)\b[0-9a-f]{1,2}(:[0-9a-f]{1,2}){5}\b"#, "<MAC 已脱敏>"),
        // 长十六进制串（可能是密钥、哈希、令牌）
        (#"\b[0-9a-fA-F]{32,}\b"#, "<长串已脱敏>"),
        // PEM 私钥片段
        (#"(?s)-----BEGIN [^-]+-----.*?-----END [^-]+-----"#, "<密钥已脱敏>"),
        // URL 中的查询参数值（可能含令牌）
        (#"([?&](?:token|key|sign|auth)=)[^&\s]+"#, "$1<已脱敏>"),
    ]

    static func redact(_ text: String) -> String {
        var result = text
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: rule.replacement
            )
        }
        return result
    }
}
