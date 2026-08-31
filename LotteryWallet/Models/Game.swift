import Foundation

/// 号码区键名，与 web 版 `GAME_CONFIGS.sections[].key` 一一对应，
/// 保证两端的票面 JSON 可以互相导入导出。
enum SectionKey: String, Codable, Hashable, Sendable {
    case red, blue          // 双色球
    case front, back        // 大乐透前后区 / 七乐彩基本号
    case nums               // 快乐8、开奖数字串
    case nums3, nums5       // 3D、排列3 / 排列5
    case nums6, tail        // 七星彩
    case nums7              // 七乐彩投注号
    case special            // 七乐彩特别号
}

/// 号码球配色，对应 web 版 styles.css 的 `.ball[data-color]`。
enum BallColor: String, Codable, Sendable {
    case red, blue, yellow, amber, indigo, plum, k8orange, fc3d
}

struct GameSection: Hashable, Sendable, Identifiable {
    let key: SectionKey
    let label: String
    let count: Int
    let color: BallColor
    /// 号码取值范围（闭区间）。数字型玩法为 0...9。
    let range: ClosedRange<Int>

    var id: SectionKey { key }

    /// 数字型号码区（3D、排列3/5、七星彩前六位）：按位取值、允许重复、
    /// 顺序本身有意义，任何时候都不能排序。
    var isPositional: Bool { range.lowerBound == 0 && range.upperBound <= 9 }
}

struct PlayMode: Hashable, Sendable, Identifiable {
    let key: String
    let label: String
    var id: String { key }
}

enum GameKey: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case ssq, dlt, k8, fc3d
    case pl3, qlc, qxc, pl5

    var id: String { rawValue }

    /// 首页 / 录入页的 4×2 排列顺序，与 web 版 `GAME_ROWS` 一致。
    static let rows: [[GameKey]] = [[.ssq, .dlt, .k8, .fc3d], [.pl3, .qlc, .qxc, .pl5]]
    static let ordered: [GameKey] = rows.flatMap { $0 }

    /// 数据仓库里的键名，只有快乐8 不同（kl8）。
    var remoteKey: String { self == .k8 ? "kl8" : rawValue }

    static func fromRemoteKey(_ key: String) -> GameKey? {
        key == "kl8" ? .k8 : GameKey(rawValue: key)
    }

    var label: String {
        switch self {
        case .ssq: "双色球"
        case .dlt: "大乐透"
        case .k8: "快乐8"
        case .fc3d: "福彩3D"
        case .pl3: "排列3"
        case .qlc: "七乐彩"
        case .qxc: "七星彩"
        case .pl5: "排列5"
        }
    }

    var accent: BallColor {
        switch self {
        case .ssq: .red
        case .dlt: .blue
        case .k8: .k8orange
        case .fc3d: .fc3d
        case .pl3, .pl5: .plum
        case .qlc: .yellow
        case .qxc: .indigo
        }
    }

    /// 单注价格，八个彩种当前都是 2 元。
    var unitPrice: Double { 2 }

    /// 支持"注数"快捷选择的彩种，与 web 版 `COUNT_GAMES` 一致。
    var supportsMultiTicketCount: Bool {
        [.ssq, .dlt, .pl5, .qxc, .qlc].contains(self)
    }

    /// 支持复式与胆拖的彩种。
    var supportsSystemPlay: Bool { self == .ssq || self == .dlt }

    var isDigitGame: Bool { self == .fc3d || self == .pl3 }

    /// 投注票的号码区定义。
    var sections: [GameSection] {
        switch self {
        case .ssq:
            [GameSection(key: .red, label: "红球", count: 6, color: .red, range: 1...33),
             GameSection(key: .blue, label: "蓝球", count: 1, color: .blue, range: 1...16)]
        case .dlt:
            [GameSection(key: .front, label: "前区", count: 5, color: .blue, range: 1...35),
             GameSection(key: .back, label: "后区", count: 2, color: .yellow, range: 1...12)]
        case .k8:
            [GameSection(key: .nums, label: "号码", count: 20, color: .k8orange, range: 1...80)]
        case .fc3d:
            [GameSection(key: .nums3, label: "号码", count: 3, color: .fc3d, range: 0...9)]
        case .pl3:
            [GameSection(key: .nums3, label: "号码", count: 3, color: .plum, range: 0...9)]
        case .pl5:
            [GameSection(key: .nums5, label: "号码", count: 5, color: .plum, range: 0...9)]
        case .qlc:
            [GameSection(key: .nums7, label: "基本号", count: 7, color: .yellow, range: 1...30)]
        case .qxc:
            [GameSection(key: .nums6, label: "前六位", count: 6, color: .indigo, range: 0...9),
             GameSection(key: .tail, label: "特别号", count: 1, color: .amber, range: 0...14)]
        }
    }

    /// 开奖号的号码区定义，多数与投注票相同，七乐彩多一个特别号。
    var drawSections: [GameSection] {
        switch self {
        case .qlc:
            [GameSection(key: .nums7, label: "基本号", count: 7, color: .yellow, range: 1...30),
             GameSection(key: .special, label: "特别号", count: 1, color: .k8orange, range: 1...30)]
        default:
            sections
        }
    }

    var playModes: [PlayMode] {
        switch self {
        case .fc3d, .pl3:
            [PlayMode(key: "single", label: "直选"),
             PlayMode(key: "group3", label: "组三"),
             PlayMode(key: "group6", label: "组六")]
        case .dlt:
            [PlayMode(key: "normal", label: "普通"), PlayMode(key: "add", label: "追加")]
        case .k8:
            (1...10).map { PlayMode(key: String($0), label: "选\(Self.chineseDigits[$0])") }
        default:
            []
        }
    }

    var defaultPlayMode: String {
        switch self {
        case .k8: "10"
        case .fc3d, .pl3: "single"
        case .dlt: "normal"
        default: ""
        }
    }

    private static let chineseDigits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
}
