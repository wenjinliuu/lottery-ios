import Foundation

/// 一注号码（或一期开奖号）的通用容器。
/// 用字典而不是固定字段，是为了和 web 版 `record.numbers` 的 JSON 结构完全对齐，
/// 备份文件可以在两端直接互导。
struct NumberSet: Codable, Hashable, Sendable {
    var values: [SectionKey: [Int]] = [:]

    init(_ values: [SectionKey: [Int]] = [:]) {
        self.values = values
    }

    subscript(key: SectionKey) -> [Int] {
        get { values[key] ?? [] }
        set { values[key] = newValue }
    }

    /// 单值号码区（蓝球、特别号）的便捷读取。
    func first(_ key: SectionKey) -> Int? { values[key]?.first }

    var isEmpty: Bool { values.values.allSatisfy(\.isEmpty) }

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SectionKey.self)
        var parsed: [SectionKey: [Int]] = [:]
        for key in container.allKeys {
            // 号码区可能是数组（红球）也可能是裸数字（七星彩 tail、七乐彩 special）
            if let list = try? container.decode([Int].self, forKey: key) {
                parsed[key] = list
            } else if let single = try? container.decode(Int.self, forKey: key) {
                parsed[key] = [single]
            } else if let text = try? container.decode(String.self, forKey: key),
                      let single = Int(text) {
                parsed[key] = [single]
            }
        }
        values = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SectionKey.self)
        for (key, list) in values {
            // 单值区回写成裸数字，保持和 web 版一致
            if key == .tail || key == .special, let single = list.first {
                try container.encode(single, forKey: key)
            } else {
                try container.encode(list, forKey: key)
            }
        }
    }
}

extension SectionKey: CodingKey {
    var stringValue: String { rawValue }
    var intValue: Int? { return nil }
    init?(stringValue: String) { self.init(rawValue: stringValue) }
    init?(intValue: Int) { return nil }
}

/// 一注投注号码。
struct Ticket: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var numbers = NumberSet()
    /// 玩法键：直选/组三/组六、普通/追加、快乐8 的选几。
    var playMode: String = ""
    /// 快乐8 的"选几"，核对时用来查奖级。
    var playCount: Int?
    /// 大乐透追加。
    var addOn: Bool = false
    /// 录入方式标签：随机 / 普通 / 复式 / 胆拖。
    var entryLabel: String = ""

    enum CodingKeys: String, CodingKey {
        case numbers, playMode, playCount, addOn, entryLabel
    }

    init(numbers: NumberSet = NumberSet(), playMode: String = "", playCount: Int? = nil, addOn: Bool = false, entryLabel: String = "") {
        self.numbers = numbers
        self.playMode = playMode
        self.playCount = playCount
        self.addOn = addOn
        self.entryLabel = entryLabel
    }

    subscript(key: SectionKey) -> [Int] {
        get { numbers[key] }
        set { numbers[key] = newValue }
    }
}
