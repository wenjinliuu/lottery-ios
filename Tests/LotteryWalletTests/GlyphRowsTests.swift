import XCTest
@testable import LotteryWallet

/// 模型按行读号码：切行、切字、认字、挑出那一串号码。
///
/// 这套算法先在 `lottery-ocr` 仓库里用 Python 在真票上调好，再照抄成 Swift。
/// 样例是那边画出来的一张号码区（不是真票）和它算出的每一步结果，这里逐项对拍。
final class GlyphRowsTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Row: Decodable {
            let top: Int, bottom: Int
            let segments: [[Int]]
            let digits: [Int]
            let confidences: [Float]
        }
        let width: Int, height: Int
        let gray: String
        let rows: [Row]
        let reads: [String?]
        let counts: [Int]
    }

    private func fixture() throws -> (Fixture, [UInt8]) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "GlyphRowFixture", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let gray = [UInt8](try XCTUnwrap(Data(base64Encoded: fixture.gray)))
        XCTAssertEqual(gray.count, fixture.width * fixture.height)
        return (fixture, gray)
    }

    func testRowsAndSegmentsMatchTraining() throws {
        let (fixture, gray) = try fixture()
        let rows = GlyphRows.rows(gray, width: fixture.width, height: fixture.height)
        XCTAssertEqual(rows.count, fixture.rows.count)
        for (mine, theirs) in zip(rows, fixture.rows) {
            XCTAssertEqual(mine.top, theirs.top)
            XCTAssertEqual(mine.bottom, theirs.bottom)
            XCTAssertEqual(mine.segments.map { [$0.x0, $0.x1, $0.y0, $0.y1] }, theirs.segments)
        }
    }

    func testEverySegmentReadsTheSameAsTraining() throws {
        let (fixture, gray) = try fixture()
        let classifier = try XCTUnwrap(DigitClassifier.shared)
        let rows = GlyphRows.read(gray, width: fixture.width, height: fixture.height, classifier: classifier)
        XCTAssertEqual(rows.count, fixture.rows.count)
        for (mine, theirs) in zip(rows, fixture.rows) {
            XCTAssertEqual(mine.map(\.digit), theirs.digits)
            for (token, confidence) in zip(mine, theirs.confidences) {
                XCTAssertEqual(token.confidence, confidence, accuracy: 0.01)
            }
        }
    }

    /// 行首的字母不是数字、`+` 太矮被筛掉：剩下正好 14 个数字，读成一注大乐透。
    func testReadsTheNumberRunOutOfEachRow() throws {
        let (fixture, gray) = try fixture()
        let classifier = try XCTUnwrap(DigitClassifier.shared)
        let rows = GlyphRows.read(gray, width: fixture.width, height: fixture.height, classifier: classifier)
        for (index, tokens) in rows.enumerated() {
            let read = GlyphRows.readLine(tokens, count: fixture.counts[index])
            XCTAssertEqual(read.map { $0.map { String($0.digit) }.joined() }, fixture.reads[index])
        }
        XCTAssertEqual(fixture.reads.first ?? nil, "05122330350211")
    }

    // MARK: - readLine 的规矩

    private func tokens(_ text: String) -> [GlyphRows.Token] {
        // 一个字符一段；空格是空隙；x 是「不是数字」
        var out: [GlyphRows.Token] = []
        var x = 0
        for character in text {
            defer { x += 30 }
            guard character != " " else { continue }
            let digit = character == "x" ? DigitClassifier.reject : Int(String(character))!
            out.append(.init(digit: digit, confidence: 0.99, segment: .init(x0: x, x1: x + 24, y0: 0, y1: 40)))
        }
        return out
    }

    func testOneDigitTooManyOrTooFewIsNotARead() {
        XCTAssertNotNil(GlyphRows.readLine(tokens("x 05 12 23 30 35 02 11"), count: 14))
        // 多读出一位：不能错开一位去凑 14 个
        XCTAssertNil(GlyphRows.readLine(tokens("x 05 12 23 30 35 02 111"), count: 14))
        XCTAssertNil(GlyphRows.readLine(tokens("x 05 12 23 30 35 02 1"), count: 14))
    }

    func testRejectedGlyphInsideTheRunVoidsTheRow() {
        XCTAssertNil(GlyphRows.readLine(tokens("x 05 1x 23 30 35 02 11"), count: 14))
    }

    /// 福彩行尾的「(1)」：括号筛掉以后剩一个 1，离号码很远，不算进号码里。
    func testFarAwayDigitAfterTheRunIsNotPartOfIt() {
        let read = GlyphRows.readLine(tokens("x 05 12 23 30 35 02 11      1"), count: 14)
        XCTAssertEqual(read?.map { String($0.digit) }.joined(), "05122330350211")
    }

    // MARK: - 粘连两位数字切分

    /// 福彩热敏票上同一个两位数的两位只隔 1–2px（如快乐8 的 `03`、双色球的 `22`/`25`），
    /// 经模糊和局部阈值后常粘成一段超宽墨迹被整块丢掉。`read` 按列投影波谷切开、裁字卡在切缝不串墨，
    /// 并要求两半都被模型以 ≥ 0.80 把握认成数字，才采纳。
    func testSplitsTouchingDigitPairAndPreservesFullRowRead() throws {
        let (fixture, original) = try fixture()
        let classifier = try XCTUnwrap(DigitClassifier.shared)
        var bridged = original
        // 第 0 行里 `0`（x 106..131）和 `5`（x 137..162）之间画一条 4px 高的墨桥让两者粘成一段
        for y in 40..<44 {
            for x in 129..<140 {
                bridged[y * fixture.width + x] = 40
            }
        }
        // 纯几何 `rows` 会丢掉粘连超宽的 `05`，少两段
        let rawRows = GlyphRows.rows(bridged, width: fixture.width, height: fixture.height)
        XCTAssertEqual(rawRows[0].segments.count, fixture.rows[0].segments.count - 2)

        // `read` 切开 `05`、裁字边界卡在切缝，两半均以高把握认出，整行照常读成 14 位
        let readRows = GlyphRows.read(bridged, width: fixture.width, height: fixture.height, classifier: classifier)
        let line = GlyphRows.readLine(readRows[0], count: 14)
        XCTAssertEqual(line?.map { String($0.digit) }.joined(), "05122330350211")
        XCTAssertGreaterThanOrEqual(line?[0].confidence ?? 0, 0.9)
        XCTAssertGreaterThanOrEqual(line?[1].confidence ?? 0, 0.9)
    }

    /// 宽的非数字（圈码 `①–⑤`、汉字或两个粘连字母 `AA`）即使几何上有波谷，
    /// 拆开后达不到「两半都是高把握数字」这道闸，一律不采纳 —— 避免给数字行凭空多塞一位。
    func testDoesNotEmitSplitTokensForWideNonDigits() throws {
        let (fixture, original) = try fixture()
        let classifier = try XCTUnwrap(DigitClassifier.shared)
        var bridged = original
        // 把第 0 行开头的 `A`（x 40..71）复制一份紧挨着放到 x 73..104 并桥接成一段宽非数字
        for y in 21..<63 {
            for dx in 0..<31 {
                bridged[y * fixture.width + 73 + dx] = original[y * fixture.width + 40 + dx]
            }
        }
        for y in 40..<44 {
            for x in 69..<76 {
                bridged[y * fixture.width + x] = 40
            }
        }
        let readRows = GlyphRows.read(bridged, width: fixture.width, height: fixture.height, classifier: classifier)
        // `AA` 整块被跳过，不会往行首多塞假数字，后面 14 个数字照常读成
        let line = GlyphRows.readLine(readRows[0], count: 14)
        XCTAssertEqual(line?.map { String($0.digit) }.joined(), "05122330350211")
    }

    /// 体彩号码区最右侧常带竖排「☆中国体育彩票」边条（x ≈ 920–1000），
    /// 找行投影算进全宽时会把多行粘成一块；截到 `ModelRowReader.sportsRowColumns`（0.85）后各行清晰分开。
    func testSportsRowColumnsIgnoresRightMarginRibbon() throws {
        let (fixture, original) = try fixture()
        let classifier = try XCTUnwrap(DigitClassifier.shared)
        var bordered = original
        for y in 0..<fixture.height {
            for x in 920..<990 {
                bordered[y * fixture.width + x] = 60
            }
        }
        let fullWidthRows = GlyphRows.rows(bordered, width: fixture.width, height: fixture.height, rowColumns: 1.0)
        XCTAssertLessThan(fullWidthRows.count, fixture.rows.count, "全宽投影会被右侧竖条粘成一整块")

        let trimmedRows = GlyphRows.rows(bordered, width: fixture.width, height: fixture.height,
                                         rowColumns: ModelRowReader.sportsRowColumns)
        XCTAssertEqual(trimmedRows.count, fixture.rows.count)
        let readRows = GlyphRows.read(bordered, width: fixture.width, height: fixture.height,
                                      rowColumns: ModelRowReader.sportsRowColumns, classifier: classifier)
        let line = GlyphRows.readLine(readRows[0], count: 14)
        XCTAssertEqual(line?.map { String($0.digit) }.joined(), "05122330350211")
    }
}
