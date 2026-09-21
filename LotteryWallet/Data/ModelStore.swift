import Foundation
import SwiftData

/// 本地数据库的建立方式，以及它是否健康。
///
/// ## 为什么要把这件事从一行 `.modelContainer(for:)` 里拿出来
///
/// 原来是 `.modelContainer(for: TicketRecord.self)`。这一行看着无害，
/// 但它用的是默认的 `ModelConfiguration`，而默认值是
/// **`cloudKitDatabase: .automatic`** —— 意思是「这个 App 的 entitlements
/// 里要是有 iCloud 容器，就自动把整个库切成 CloudKit 同步」。
///
/// 也就是说：**只要给 App 加上 iCloud 权限，本地库的存储方式就会在我们
/// 完全没写过一行相关代码的情况下改变。** 而 `TicketRecord` 上有
/// `@Attribute(.unique) var id`，CloudKit 镜像**不支持唯一约束**
/// （它也要求所有属性可选或有默认值）。这两件事撞在一起，就是一个
/// 「加了个不相干的权限，库就打不开了」的地雷。
///
/// 这正是 1.2.0 构建 59 那次事故的形状：在那之前 entitlement 从来没真正
/// 签进二进制（见 `ICloudBackupService` 和 TestFlight 流水线里的说明），
/// 59 是第一个带上 iCloud 权限的包，用户更新后票据全部不见了。
///
/// 所以这里**把存储方式写死**：备份走 iCloud Documents（我们自己的一份
/// JSON 文件），数据库永远是本机的，和 entitlements 无关。以后不管加什么
/// 权限，这一行都不会再改变库的行为。
///
/// ## 为什么不再让它静默失败
///
/// `.modelContainer(for:)` 打不开库时只有两种结局：崩，或者换一个空库。
/// 两种都糟 —— 后者尤其糟，因为用户看到的是「我的数据没了」，而 App
/// 一切正常，连条错都不报，导入还能提示「成功 335 条」（写进了那个
/// 临时库，下次启动又没了）。**一个空库和一个打不开的库必须区分开。**
///
/// 现在打不开时退回内存库并把原因记在 `StoreHealth` 上，界面顶部挂一条
/// 醒目的警告，设置里能看到具体错误。临时库里录入的东西关掉就没了，
/// 所以必须让用户当场知道，而不是让他以为自己在正常使用。
@MainActor
enum ModelStore {

    static let schema = Schema([TicketRecord.self])

    /// 建库。**永远不会静默给出一个空的持久库。**
    static func makeContainer(health: StoreHealth) -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        health.storeURL = configuration.url
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            health.failure = nil
            health.isEphemeral = false
            return container
        } catch {
            // 退到内存库只是为了让 App 还能开、让用户看到那条警告并导出/求助，
            // 不是为了「装作没事」。
            health.failure = String(describing: error)
            health.isEphemeral = true
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // 内存库再建不起来就真的没有退路了，那种情况崩掉反而比假装正常好。
            return try! ModelContainer(for: schema, configurations: [fallback])
        }
    }
}

/// 数据库现在是不是健康的。
///
/// 只有两种状态值得区分：**正常的本机库**，和**打不开之后顶上来的临时库**。
/// 后者里的任何写入都活不过这次启动，必须在界面上说清楚。
@MainActor
@Observable
final class StoreHealth {
    /// 打不开时的原始错误。nil 表示正常。
    var failure: String?
    /// 现在用的是不是关掉就没的临时库。
    var isEphemeral = false
    /// 库文件的位置，排查时要看。
    var storeURL: URL?

    var isHealthy: Bool { !isEphemeral && failure == nil }

    /// 设置页里显示的人话诊断。
    func summary(recordCount: Int) -> String {
        var lines: [String] = []
        lines.append("存储：" + (isEphemeral ? "临时内存库（关掉就没）" : "本机数据库"))
        lines.append("同步：本机（已明确关闭 CloudKit）")
        lines.append("记录：\(recordCount) 条")
        if let storeURL {
            lines.append("位置：\(storeURL.lastPathComponent)")
        }
        if let failure {
            lines.append("错误：\(failure)")
        }
        return lines.joined(separator: "\n")
    }
}
