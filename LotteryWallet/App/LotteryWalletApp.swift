import SwiftUI
import SwiftData
import Observation

@main
struct LotteryWalletApp: App {
    @State private var drawStore = DrawStore()
    @State private var settings = AppSettings()
    /// 数据库的健康状态。建库和它一起产生，见 `ModelStore`。
    @State private var storeHealth: StoreHealth
    @State private var backupCenter = BackupCenter()
    private let container: ModelContainer

    /// **建库不再用 `.modelContainer(for:)`。**
    ///
    /// 那一行默认 `cloudKitDatabase: .automatic` —— 只要 App 带着 iCloud
    /// 权限，本地库就会被自动切成 CloudKit 同步，而 `TicketRecord` 上的
    /// `@Attribute(.unique)` 是 CloudKit 镜像不支持的。加一个权限就能让库
    /// 打不开，这种耦合必须断掉。理由全写在 `ModelStore` 里。
    init() {
        let health = StoreHealth()
        container = ModelStore.makeContainer(health: health)
        _storeHealth = State(initialValue: health)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(drawStore)
                .environment(settings)
                .environment(storeHealth)
                .environment(backupCenter)
                .preferredColorScheme(settings.colorScheme)
                .tint(Color.accentColor)
        }
        .modelContainer(container)
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

    /// 自动备份。**默认打开，但默认只写本机。**
    ///
    /// 写进 App 自己的沙盒不涉及任何隐私取舍，却能挡住这次这种事故；
    /// 默认关着才是危险的默认值 —— 用户通常在丢了数据之后才会想起它。
    var autoBackupEnabled: Bool {
        didSet { defaults.set(autoBackupEnabled, forKey: Keys.autoBackup) }
    }

    /// 备份是否同时放一份到 iCloud。**默认关闭** —— 数据出不出这台设备
    /// 是用户的选择，不该由我们替他决定，隐私政策也是照着这个写的。
    var iCloudBackupEnabled: Bool {
        didSet { defaults.set(iCloudBackupEnabled, forKey: Keys.iCloudBackup) }
    }

    /// 理性购彩提示是否已确认过。
    var responsibleAcknowledged: Bool {
        didSet { defaults.set(responsibleAcknowledged, forKey: Keys.responsible) }
    }

    /// 识别调试图。**默认关闭。**
    ///
    /// 打开之后复核页会把「机器看到了什么」画在票面上：检测到的基准（虚线 /
    /// 文本行）、配准后的号码区、每一个格子。出问题时用户截个图发过来，
    /// 就能分清是基准没找对、格子划歪了、还是那一格单纯没认出来 ——
    /// 这三种毛病的修法完全不同，靠一句「又认错了」永远分不清。
    ///
    /// 常驻，不做成 DEBUG 编译开关：要排查的正是装了正式版的那台手机。
    var debugVision: Bool {
        didSet { defaults.set(debugVision, forKey: Keys.debugVision) }
    }

    /// 「结果已读」这个状态是后加的，老库里全是 nil。
    /// 首次启动时回填一次，之后不再重复扫全表。
    var seenBackfilled: Bool {
        didSet { defaults.set(seenBackfilled, forKey: Keys.seenBackfilled) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let autoCheck = "lottery.autoCheck"
        static let appearance = "lottery.appearance"
        static let lastBackup = "lottery.lastBackupAt"
        static let responsible = "lottery.responsibleAck"
        static let seenBackfilled = "lottery.resultSeenBackfilled.v1"
        static let debugVision = "lottery.debugVision"
        static let iCloudBackup = "lottery.iCloudBackup"
        static let autoBackup = "lottery.autoBackup"
    }

    init() {
        autoCheck = defaults.object(forKey: Keys.autoCheck) as? Bool ?? true
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        let stamp = defaults.double(forKey: Keys.lastBackup)
        lastBackupAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        responsibleAcknowledged = defaults.bool(forKey: Keys.responsible)
        seenBackfilled = defaults.bool(forKey: Keys.seenBackfilled)
        debugVision = defaults.bool(forKey: Keys.debugVision)
        iCloudBackupEnabled = defaults.bool(forKey: Keys.iCloudBackup)
        autoBackupEnabled = defaults.object(forKey: Keys.autoBackup) as? Bool ?? true
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
