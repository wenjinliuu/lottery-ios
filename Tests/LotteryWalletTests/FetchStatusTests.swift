import XCTest
@testable import LotteryWallet

/// `/v2/status`：后端最近一次抓取任务跑得怎么样。
///
/// 设置页上就一行 `09月22日 02:44 · 执行成功 · 6/8 数据完整`，
/// 三段各回答一个问题。这一组用例钉的是那三段各自都不许说谎。
final class FetchStatusTests: XCTestCase {

    private func decode(_ json: String) throws -> FetchStatus {
        let payload = try JSONDecoder().decode(LotteryV2.Status.self, from: Data(json.utf8))
        return LotteryV2Mapper.status(payload)
    }

    // MARK: - 完成度

    /// 文档给的那份样例：六个 completed、一个 numbers_ready、一个 waiting。
    func testDocumentedSampleReadsSixOfEight() throws {
        let status = try decode(LotteryV2Fixtures.statusJSON)

        XCTAssertEqual(status.completed, 6)
        XCTAssertEqual(status.total, 8)
        XCTAssertEqual(status.progressText, "6/8 数据完整")
        XCTAssertEqual(status.isSuccess, true)
        XCTAssertEqual(status.resultText, "执行成功")
        XCTAssertEqual(status.summary, "09月22日 02:44 · 执行成功 · 6/8 数据完整")
    }

    /// **只有 `completed` 算数据完整。**
    ///
    /// `numbers_ready` 是号码到了、奖金还没回来，`waiting` 是还没开奖 ——
    /// 两者都还不能用来核对奖金。把它们算进去，界面会在数据其实还不能用的
    /// 时候显示 8/8。
    func testOnlyCompletedCounts() throws {
        let status = try decode(LotteryV2Fixtures.statusJSON)
        XCTAssertEqual(status.completed, 6, "numbers_ready 和 waiting 都不该计入")
        XCTAssertFalse(status.isComplete)
    }

    func testAllCompleted() throws {
        let status = try decode(LotteryV2Fixtures.completeStatusJSON)
        XCTAssertEqual(status.progressText, "8/8 数据完整")
        XCTAssertTrue(status.isComplete)
    }

    /// **分母恒为 8，不跟着 `lotteries` 字典的大小走。**
    ///
    /// 这份响应里只有六个键、其中一个还是 `null`。跟着字典走会显示成
    /// `5/5 数据完整` —— 一切正常，而「后端连三个彩种的记录都没有」
    /// 这件事被彻底抹平。这条用例就是为了它。
    func testMissingLotteriesStillCountAgainstEight() throws {
        let status = try decode(LotteryV2Fixtures.sparseStatusJSON)

        XCTAssertEqual(status.completed, 5)
        XCTAssertEqual(status.total, 8)
        XCTAssertEqual(status.progressText, "5/8 数据完整")
    }

    /// 快乐8 远端叫 `kl8`，App 内部叫 `k8`。查错键的表现是「永远差一个」，
    /// 而且看上去特别像后端的问题。
    func testKL8IsCounted() throws {
        let status = try decode("""
        {
          "latest_execution": {"executed_at": "2026-09-22T02:44:00+08:00",
                               "execution_status": "success"},
          "lotteries": {"kl8": {"data_status": "completed"}}
        }
        """)
        XCTAssertEqual(status.completed, 1, "kl8 没数进去说明彩种标识映射错了")
    }

    // MARK: - 执行结果

    func testFailedExecution() throws {
        let status = try decode(LotteryV2Fixtures.failedStatusJSON)

        XCTAssertEqual(status.isSuccess, false)
        XCTAssertEqual(status.resultText, "执行失败")
        XCTAssertTrue(status.needsAttention)
        XCTAssertEqual(status.summary, "09月22日 02:44 · 执行失败 · 1/8 数据完整")
    }

    /// **没见过的状态值不许当成成功。**
    ///
    /// 默认成功是最坏的一种猜：真出事的时候界面上一片正常。
    func testUnknownExecutionStatusIsNotSuccess() throws {
        let status = try decode("""
        {
          "latest_execution": {"executed_at": "2026-09-22T02:44:00+08:00",
                               "execution_status": "running"},
          "lotteries": {}
        }
        """)
        XCTAssertNil(status.isSuccess)
        XCTAssertNotEqual(status.resultText, "执行成功")
        XCTAssertFalse(status.needsAttention, "未知不等于失败，不该标黄")
    }

    /// 数据没齐不算需要注意 —— 今天还没开奖的彩种本来就是 waiting，
    /// 白天看到 6/8 是常态。天天弹一次假警报比不弹更糟。
    func testIncompleteDataIsNotAWarning() throws {
        let status = try decode(LotteryV2Fixtures.statusJSON)
        XCTAssertFalse(status.isComplete)
        XCTAssertFalse(status.needsAttention)
    }

    // MARK: - 没有执行记录

    /// `latest_execution` 为空时显示「暂无执行记录」，**不是「0/8」**。
    /// 后者会被读成「后端跑了但一个都没抓到」，意思完全反了。
    func testEmptyExecutionSaysSo() throws {
        let status = try decode(LotteryV2Fixtures.emptyStatusJSON)

        XCTAssertFalse(status.hasExecution)
        XCTAssertEqual(status.summary, "暂无执行记录")
        XCTAssertEqual(status.executionText, "暂无执行记录")
    }

    /// 整个响应是空对象也不能崩。
    func testEmptyObjectDecodes() throws {
        let status = try decode("{}")
        XCTAssertFalse(status.hasExecution)
        XCTAssertEqual(status.completed, 0)
        XCTAssertEqual(status.total, 8)
    }

    // MARK: - 时间格式

    /// `executed_at` 按上海时区显示成 `MM月dd日 HH:mm`，月日补零。
    func testExecutedAtFormatting() throws {
        let status = try decode(LotteryV2Fixtures.statusJSON)
        XCTAssertEqual(status.timeText, "09月22日 02:44")
    }

    /// 带别的时区偏移时要**换算到上海**再显示，不能照搬字面。
    /// `2026-09-21T18:44:00Z` 就是北京时间 09月22日 02:44。
    func testUTCIsConvertedToShanghai() throws {
        let status = try decode("""
        {
          "latest_execution": {"executed_at": "2026-09-21T18:44:00Z",
                               "execution_status": "success"},
          "lotteries": {}
        }
        """)
        XCTAssertEqual(status.timeText, "09月22日 02:44")
    }
}
