import SwiftUI
import SwiftData
import Observation

@main
struct LotteryWalletApp: App {
    @State private var drawStore = DrawStore()
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(drawStore)
                .environment(settings)
                .preferredColorScheme(settings.colorScheme)
                .tint(Color.accentColor)
        }
        .modelContainer(for: TicketRecord.self)
    }
}

/// 用户偏好。全部落在 UserDefaults，和票据数据分开。
@MainActor
@Observable
final class AppSettings {
    /// 开奖后自动核对。
    var autoCheck: Bool {
        didSet { defaults.set(autoCheck, forKey: Keys.autoCheck) }
    }

    /// 外观：跟随系统 / 浅色 / 深色。
    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// 上次导出备份的时间，超过 7 天在设置页提醒。
    var lastBackupAt: Date? {
        didSet { defaults.set(lastBackupAt?.timeIntervalSince1970 ?? 0, forKey: Keys.lastBackup) }
    }

    /// 理性购彩提示是否已确认过。
    var responsibleAcknowledged: Bool {
        didSet { defaults.set(responsibleAcknowledged, forKey: Keys.responsible) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let autoCheck = "lottery.autoCheck"
        static let appearance = "lottery.appearance"
        static let lastBackup = "lottery.lastBackupAt"
        static let responsible = "lottery.responsibleAck"
    }

    init() {
        autoCheck = defaults.object(forKey: Keys.autoCheck) as? Bool ?? true
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        let stamp = defaults.double(forKey: Keys.lastBackup)
        lastBackupAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        responsibleAcknowledged = defaults.bool(forKey: Keys.responsible)
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// 距上次备份的天数，从未备份返回 nil。
    var daysSinceBackup: Int? {
        guard let lastBackupAt else { return nil }
        return Calendar.current.dateComponents([.day], from: lastBackupAt, to: Date()).day
    }

    var backupNeedsAttention: Bool {
        guard let days = daysSinceBackup else { return true }
        return days >= 7
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: "跟随系统"
            case .light: "浅色"
            case .dark: "深色"
            }
        }

        var symbol: String {
            switch self {
            case .system: "circle.lefthalf.filled"
            case .light: "sun.max"
            case .dark: "moon"
            }
        }
    }
}
