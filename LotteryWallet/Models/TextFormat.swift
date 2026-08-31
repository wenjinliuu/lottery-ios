import Foundation

/// 奖金文本解析，对齐 web 版 `parseMoneyNumber`：支持 "1,234"、"500万"、"1.2亿"。
enum MoneyText {
    static func parse(_ raw: String) -> Double {
        let text = raw.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return 0 }
        let digits = text.filter { $0.isNumber || $0 == "." }
        guard let number = Double(digits) else { return 0 }
        if text.contains("亿") { return number * 100_000_000 }
        if text.contains("万") { return number * 10_000 }
        return number
    }

    /// "1,234 元" 形式。
    static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value == value.rounded() ? 0 : 2
        let text = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return "\(text)元"
    }

    /// 紧凑写法，用于图表刻度和 KPI。
    static func compact(_ value: Double) -> String {
        let absolute = abs(value)
        if absolute >= 100_000_000 { return String(format: "%.2f亿", value / 100_000_000) }
        if absolute >= 10_000 { return String(format: "%.1f万", value / 10_000) }
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.1f", value)
    }
}

/// 中文数字，用于快乐8 的"选七中五"奖级匹配。
enum ChineseNumber {
    private static let table = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]

    static func text(_ value: Int) -> String {
        (0...10).contains(value) ? table[value] : String(value)
    }
}

/// 日期解析与格式化。开奖数据里的日期都是 `yyyy-MM-dd`，
/// 时间戳是 ISO8601，统一按东八区展示。
enum DateText {
    static let chinaTimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = chinaTimeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = chinaTimeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 兼容 `yyyy-MM-dd`、`yyyy-MM-dd HH:mm:ss` 和 ISO8601 三种写法。
    static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let date = dayFormatter.date(from: text) { return date }
        if let date = dateTimeFormatter.date(from: text) { return date }
        if let date = isoFormatter.date(from: text) { return date }
        if let date = isoPlainFormatter.date(from: text) { return date }
        return nil
    }

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// "08-31" 形式，卡片副标题用。
    static func monthDay(_ raw: String) -> String {
        guard let date = parse(raw) else { return raw }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = chinaTimeZone
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }

    /// "8月31日 20:30" 形式。
    static func friendly(_ raw: String) -> String {
        guard let date = parse(raw) else { return raw }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = chinaTimeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    /// 东八区的"今天"，用于判断今日开奖安排。
    static func chinaToday(_ now: Date = Date()) -> String { day(now) }
}
