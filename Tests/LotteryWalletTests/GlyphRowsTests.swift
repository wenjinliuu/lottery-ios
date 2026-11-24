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
}
