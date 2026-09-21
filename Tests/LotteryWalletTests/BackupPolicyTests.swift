import XCTest
@testable import LotteryWallet

/// 备份的命名与留存策略。
///
/// 这块必须有测试，因为它错了是**不可逆**的：该留的被删掉，用户不会收到
/// 任何提示，等他想恢复的时候才发现那一份早就没了。1.2.0 那次数据事故
/// 之所以救不回来，正是因为上一版自动备份只有一份、固定文件名、反复覆盖 ——
/// 库一变空，退到后台就把唯一那份历史盖掉了。
final class BackupPolicyTests: XCTestCase {

    private func item(_ name: String, minutesAgo: Int) -> BackupItem {
        BackupItem(name: name,
                   location: .local,
                   kind: BackupNaming.kind(of: name),
                   modifiedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(minutesAgo) * 60),
                   size: 100)
    }

    // MARK: - 命名

    /// 自动备份的前缀同时也是手动备份的前缀，判别顺序错了就全认成手动。
    ///
    /// `lottery-backup-auto-20260919-120000.json` 也以 `lottery-backup-` 开头。
    /// 要是先判手动，自动备份会被当成手动、从此永不回收，云上迟早堆成灾。
    func testKindIsDerivedFromPrefixInTheRightOrder() {
        XCTAssertEqual(BackupNaming.kind(of: "lottery-backup-auto-20260919-120000.json"), .auto)
        XCTAssertEqual(BackupNaming.kind(of: "lottery-backup-safety-20260919-120000.json"), .safety)
        XCTAssertEqual(BackupNaming.kind(of: "lottery-backup-20260919-120000.json"), .manual)
        // 1.2.0 之前那两个固定文件名仍然要认得出来
        XCTAssertEqual(BackupNaming.kind(of: BackupNaming.legacyAuto), .auto)
        XCTAssertEqual(BackupNaming.kind(of: BackupNaming.legacyManual), .manual)
    }

    /// 生成的文件名必须能被自己认回去，否则写进去的自动备份会被当成手动。
    func testGeneratedNamesRoundTrip() {
        for kind in [BackupItem.Kind.auto, .manual, .safety] {
            let name = BackupNaming.name(for: kind)
            XCTAssertTrue(BackupNaming.isBackupFile(name), "\(name) 不被认作备份文件")
            XCTAssertEqual(BackupNaming.kind(of: name), kind, "\(name) 的类别认错了")
        }
    }

    /// 时间戳带到秒，同一分钟内连备两次也不能互相覆盖。
    func testNamesAreUniquePerSecond() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let a = BackupNaming.name(for: .manual, now: base)
        let b = BackupNaming.name(for: .manual, now: base.addingTimeInterval(1))
        XCTAssertNotEqual(a, b)
    }

    // MARK: - 回收

    /// 自动备份滚动保留，超出的才回收，而且回收的一定是最旧的那几份。
    func testAutoBackupsKeepTheNewestOnes() {
        let items = (0..<8).map { item("lottery-backup-auto-\($0).json", minutesAgo: $0 * 10) }
        let expired = BackupCenter.expired(in: items)
        XCTAssertEqual(expired.count, 8 - BackupPolicy.autoKeep)
        // 被回收的必须都比留下来的旧
        let keptOldest = items.prefix(BackupPolicy.autoKeep).map(\.modifiedAt).min()!
        for gone in expired {
            XCTAssertLessThan(gone.modifiedAt, keptOldest)
        }
    }

    /// **手动备份一份都不许回收。** 用户自己点的那一下就是「这份我要留着」。
    func testManualBackupsAreNeverExpired() {
        let items = (0..<20).map { item("lottery-backup-\($0).json", minutesAgo: $0 * 10) }
        XCTAssertTrue(BackupCenter.expired(in: items).isEmpty)
    }

    /// 恢复前快照有自己的配额，不和自动备份抢名额。
    ///
    /// 混在一起算的话，连着恢复几次就能把自动备份全挤掉 —— 而那时候
    /// 恰恰是最需要旧备份的时刻。
    func testSafetySnapshotsHaveTheirOwnQuota() {
        var items = (0..<BackupPolicy.autoKeep).map { item("lottery-backup-auto-\($0).json", minutesAgo: $0) }
        items += (0..<(BackupPolicy.safetyKeep + 2)).map {
            item("lottery-backup-safety-\($0).json", minutesAgo: 100 + $0)
        }
        let expired = BackupCenter.expired(in: items)
        XCTAssertEqual(expired.count, 2)
        XCTAssertTrue(expired.allSatisfy { $0.kind == .safety })
    }

    /// 份数没到上限时一个都不该删。
    func testNothingExpiresBelowTheLimit() {
        let items = (0..<BackupPolicy.autoKeep).map { item("lottery-backup-auto-\($0).json", minutesAgo: $0) }
        XCTAssertTrue(BackupCenter.expired(in: items).isEmpty)
    }

    // MARK: - 身份

    /// 同名文件在两个地方是**两份**备份，不能因为名字一样就互相顶掉。
    func testIdentityIncludesLocation() {
        let name = "lottery-backup-20260919-120000.json"
        let cloud = BackupItem(name: name, location: .iCloud, kind: .manual, modifiedAt: Date(), size: 1)
        let local = BackupItem(name: name, location: .local, kind: .manual, modifiedAt: Date(), size: 1)
        XCTAssertNotEqual(cloud.id, local.id)
    }
}
