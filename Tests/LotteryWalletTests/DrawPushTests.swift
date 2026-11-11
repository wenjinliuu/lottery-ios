import XCTest
import SwiftData
@testable import LotteryWallet

/// 开奖通知：云端只推开奖号码，中没中在本机算。
///
/// 这里守的是两件事：通知里的开奖数据解得对（解错了会把票判错，而且是在后台、
/// 用户看不见的时候写进票夹）；以及推给用户的那句话和票夹里的结论一致。
@MainActor
final class DrawPushTests: XCTestCase {

    private var container: ModelContainer!
    private var service: RecordService!

    override func setUp() async throws {
        let configuration = ModelConfiguration(schema: ModelStore.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: ModelStore.schema, configurations: [configuration])
        service = RecordService(context: container.mainContext, drawStore: DrawStore())
    }

    /// 云端 `drawPayload` 发下来的样子（lottery-data-repo 的 draw-push.mjs）。
    private func ssqPush(prizes: [[String: Any]]? = [["name": "一等奖", "amount": "10000000"],
                                                     ["name": "六等奖", "amount": "5"]]) -> [AnyHashable: Any] {
        var draw: [String: Any] = ["issue": "2026130",
                                   "date": "2026-11-10",
                                   "numbers": ["red": [5, 6, 10, 25, 27, 30], "blue": [11]]]
        if let prizes { draw["prizes"] = prizes }
        return ["aps": ["alert": ["title": "双色球 2026130 期开奖", "body": "05 06 10 25 27 30 + 11"]],
                "lottery_type": "ssq",
                "draw": draw]
    }

    private func saveSSQ(_ lines: [(red: [Int], blue: Int)], issue: String = "2026130", multiple: Int = 1) throws {
        let tickets = lines.map { Ticket(numbers: NumberSet([.red: $0.red, .blue: [$0.blue]])) }
        try service.save(tickets: tickets, game: .ssq, entryKind: .manual, price: 2, multiple: multiple,
                         target: DrawTarget(expect: issue, openDate: "2026-11-10", status: .confirmed),
                         source: "manual")
    }

    // MARK: - 解析

    func testParsesDrawFromNotification() throws {
        let draw = try XCTUnwrap(DrawPushPayload.parse(ssqPush()))
        XCTAssertEqual(draw.gameKey, .ssq)
        XCTAssertEqual(draw.expect, "2026130")
        XCTAssertEqual(draw.openDate, "2026-11-10")
        XCTAssertEqual(draw.drawValues[.red], [5, 6, 10, 25, 27, 30])
        XCTAssertEqual(draw.drawValues[.blue], [11])
        XCTAssertEqual(draw.prizeList.map(\.prizeName), ["一等奖", "六等奖"])
        XCTAssertEqual(draw.prizeList.last?.amount, 5)
    }

    /// 快乐8 远端叫 kl8，本地叫 k8。认错了这个彩种的通知就永远核对不上。
    func testMapsRemoteLotteryKey() throws {
        let push: [AnyHashable: Any] = ["lottery_type": "kl8",
                                        "draw": ["issue": "2026300", "numbers": ["nums": [1, 7, 10]]]]
        XCTAssertEqual(DrawPushPayload.parse(push)?.gameKey, .k8)
        XCTAssertEqual(DrawPushPayload.identifier(game: .k8, issue: "2026300"), "draw-kl8-2026300")
    }

    /// 不是开奖通知、彩种不认识、没有号码：一律不处理，不能编一期开奖出来。
    func testRejectsAnythingThatIsNotADraw() {
        XCTAssertNil(DrawPushPayload.parse(["aps": ["alert": "hello"]]))
        XCTAssertNil(DrawPushPayload.parse(["lottery_type": "sports", "draw": ["issue": "1", "numbers": ["red": [1]]]]))
        XCTAssertNil(DrawPushPayload.parse(["lottery_type": "ssq", "draw": ["issue": "1", "numbers": [String: Any]()]]))
        XCTAssertNil(DrawPushPayload.parse(["lottery_type": "ssq", "draw": ["numbers": ["red": [1], "blue": [2]]]]))
        XCTAssertNil(DrawPushPayload.parse(["lottery_type": "ssq", "draw": "not a dictionary"]))
    }

    // MARK: - 本机核对

    func testSettlesOnlyTheTicketsOfThatIssue() throws {
        try saveSSQ([(red: [1, 2, 3, 4, 7, 8], blue: 11),      // 六等奖
                     (red: [1, 2, 3, 4, 7, 8], blue: 9)],      // 没中
                    multiple: 2)
        try saveSSQ([(red: [5, 6, 10, 25, 27, 30], blue: 11)], issue: "2026131")   // 别的期，不能碰

        let draw = try XCTUnwrap(DrawPushPayload.parse(ssqPush()))
        let outcome = DrawPushCenter.shared.settle(with: draw, in: container.mainContext)

        XCTAssertEqual(outcome.tickets, 2)
        XCTAssertEqual(outcome.won, 1)
        XCTAssertEqual(outcome.amount, 10)      // 5 元 × 2 倍
        XCTAssertEqual(outcome.text, "2 注中 1 注：六等奖 1 注，共 10元")

        let records = service.allRecords()
        let thisIssue = records.filter { $0.targetExpect == "2026130" }
        XCTAssertEqual(Set(thisIssue.map(\.status)), [.won, .lost])
        XCTAssertEqual(thisIssue.first { $0.status == .won }?.matched[.blue], [true])
        XCTAssertEqual(records.first { $0.targetExpect == "2026131" }?.status, .pending)
    }

    /// 通知里没带奖级（放不下，或者奖金还没公布）：中了的票是「奖金待公布」，
    /// 不能编一个金额，也不能说没中。
    func testWinWithoutPrizeTableIsFloating() throws {
        try saveSSQ([(red: [1, 2, 3, 4, 7, 8], blue: 11)])
        let draw = try XCTUnwrap(DrawPushPayload.parse(ssqPush(prizes: nil)))
        let outcome = DrawPushCenter.shared.settle(with: draw, in: container.mainContext)
        XCTAssertEqual(outcome.floating, 1)
        XCTAssertEqual(outcome.text, "1 注中 1 注：六等奖 1 注，奖金待公布")
        XCTAssertEqual(service.allRecords().first?.status, .prizeFloat)
    }

    /// 同一条通知到两次（苹果会重投）：结论不变，不重复计数。
    func testSettlingTwiceGivesTheSameAnswer() throws {
        try saveSSQ([(red: [1, 2, 3, 4, 7, 8], blue: 11)])
        let draw = try XCTUnwrap(DrawPushPayload.parse(ssqPush()))
        let first = DrawPushCenter.shared.settle(with: draw, in: container.mainContext)
        let second = DrawPushCenter.shared.settle(with: draw, in: container.mainContext)
        XCTAssertEqual(first, second)
        XCTAssertEqual(service.allRecords().first?.prizeAmount, 5)
    }

    /// 没有这一期的票：不出结论，那条开奖号码的通知原样留着。
    func testNoTicketsMeansNoReplacement() throws {
        let draw = try XCTUnwrap(DrawPushPayload.parse(ssqPush()))
        let outcome = DrawPushCenter.shared.settle(with: draw, in: container.mainContext)
        XCTAssertEqual(outcome.tickets, 0)
        XCTAssertNil(outcome.text)
    }

    // MARK: - 文案

    func testOutcomeWording() {
        var none = DrawPushPayload.Outcome()
        none.add(status: .lost, prizeName: "未中奖", amount: 0)
        none.add(status: .lost, prizeName: "未中奖", amount: 0)
        XCTAssertEqual(none.text, "2 注都没中")

        var mixed = DrawPushPayload.Outcome()
        mixed.add(status: .won, prizeName: "六等奖", amount: 5)
        mixed.add(status: .won, prizeName: "六等奖", amount: 5)
        mixed.add(status: .prizeFloat, prizeName: "二等奖", amount: 0)
        mixed.add(status: .lost, prizeName: "未中奖", amount: 0)
        XCTAssertEqual(mixed.text, "4 注中 3 注：六等奖 2 注、二等奖 1 注，已确定 10元，其余奖金待公布")
    }

    // MARK: - 订阅

    /// 订阅跟着票夹走：有待开奖的票、或 60 天内买过才订。
    func testSubscriptionFollowsTheWallet() {
        let now = DateText.parse("2026-11-12 12:00:00")!
        let day: TimeInterval = 86_400
        let lotteries = DrawPushPayload.subscription([
            (game: .ssq, createdAt: now.addingTimeInterval(-3 * day), isPending: false),
            (game: .k8, createdAt: now.addingTimeInterval(-59 * day), isPending: false),
            (game: .dlt, createdAt: now.addingTimeInterval(-200 * day), isPending: false),   // 太久了
            (game: .qxc, createdAt: now.addingTimeInterval(-200 * day), isPending: true),    // 但还没开奖
            (game: .ssq, createdAt: now, isPending: true)
        ], now: now)
        XCTAssertEqual(lotteries, ["kl8", "qxc", "ssq"])
        XCTAssertEqual(DrawPushPayload.subscription([], now: now), [])
    }

    /// 登记用的请求体和云端 `registerDevice` 的字段一一对应。
    func testRegistrationBodyMatchesTheServerContract() {
        let body = DrawPushCenter.registrationBody(token: "ab", lotteries: ["ssq"], bundleID: "app")
        XCTAssertEqual(Set(body.keys), ["token", "environment", "bundle_id", "lotteries"])
        XCTAssertEqual(body["token"] as? String, "ab")
        XCTAssertEqual(body["lotteries"] as? [String], ["ssq"])
        XCTAssertTrue(["production", "sandbox"].contains(body["environment"] as? String ?? ""))
    }
}
