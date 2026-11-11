import XCTest
@testable import LotteryWallet

/// 自己训练的数字模型。
///
/// 模型是在另一个仓库里用 Python 训练的，App 里用纯 Swift 重算一遍。
/// 两边只要有一步不一样（百分位怎么取、缩放怎么平均、卷积的方向），
/// 模型在手机上就是另一个模型，而且**不会报错，只会悄悄认得更差**。
/// 所以这里拿训练时导出的真票小图逐个对拍：同样的像素进去，要出同样的数。
final class DigitClassifierTests: XCTestCase {

    private struct Fixture: Decodable {
        let width: Int
        let height: Int
        let pixels: [UInt8]
        let digit: Int
        let preprocessedSum: Float
        let preprocessedCenter: Float
        let logits: [Float]

        enum CodingKeys: String, CodingKey {
            case width, height, pixels, digit, logits
            case preprocessedSum = "preprocessed_sum"
            case preprocessedCenter = "preprocessed_center"
        }
    }

    private func fixtures() throws -> [Fixture] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "DigitNetFixtures", withExtension: "json"))
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    }

    func testModelShipsInTheAppBundle() {
        XCTAssertNotNil(DigitClassifier.shared, "安装包里没有 DigitNet.bin，交叉校验会整个跳过")
    }

    /// 预处理：同一块像素，Swift 算出来的 28×28 要和 Python 的一样。
    func testPreprocessingMatchesTraining() throws {
        let samples = try fixtures()
        XCTAssertGreaterThanOrEqual(samples.count, 8)
        for sample in samples {
            let output = DigitClassifier.preprocess(pixels: sample.pixels, width: sample.width, height: sample.height)
            XCTAssertEqual(output.count, 784)
            XCTAssertEqual(output.reduce(0, +), sample.preprocessedSum, accuracy: 0.01)
            XCTAssertEqual(output[14 * 28 + 14], sample.preprocessedCenter, accuracy: 0.001)
            XCTAssertTrue(output.allSatisfy { $0 >= 0 && $0 <= 1 })
        }
    }

    /// 整个网络：11 个输出逐个对上，认出来的数字也是同一个。
    func testNetworkMatchesTraining() throws {
        let classifier = try XCTUnwrap(DigitClassifier.shared)
        for sample in try fixtures() {
            let input = DigitClassifier.preprocess(pixels: sample.pixels, width: sample.width, height: sample.height)
            let logits = classifier.logits(input)
            XCTAssertEqual(logits.count, sample.logits.count)
            for (mine, theirs) in zip(logits, sample.logits) {
                XCTAssertEqual(mine, theirs, accuracy: 0.02)
            }
            let expected = sample.logits.indices.max { sample.logits[$0] < sample.logits[$1] }
            let verdict = classifier.classify(pixels: sample.pixels, width: sample.width, height: sample.height)
            XCTAssertEqual(verdict.digit, expected)
            XCTAssertTrue(verdict.confidence > 0 && verdict.confidence <= 1)
        }
    }

    /// 这些样例是真票上抠下来的、没参与训练的数字：模型应该认对绝大多数。
    func testRecognisesHeldOutRealDigits() throws {
        let classifier = try XCTUnwrap(DigitClassifier.shared)
        let samples = try fixtures()
        let correct = samples.filter {
            classifier.classify(pixels: $0.pixels, width: $0.width, height: $0.height).digit == $0.digit
        }.count
        XCTAssertGreaterThanOrEqual(correct * 10, samples.count * 9, "\(samples.count) 个里只认对 \(correct) 个")
    }

    func testRejectsMalformedWeights() {
        XCTAssertNil(DigitClassifier(data: Data()))
        XCTAssertNil(DigitClassifier(data: Data("DGN1".utf8)))
        XCTAssertNil(DigitClassifier(data: Data(repeating: 0, count: 4 + 4 * 100)))
    }

    /// 空的、尺寸对不上的输入不能崩。
    func testPreprocessingSurvivesBadInput() {
        XCTAssertEqual(DigitClassifier.preprocess(pixels: [], width: 0, height: 0).count, 784)
        XCTAssertEqual(DigitClassifier.preprocess(pixels: [1, 2, 3], width: 2, height: 2).count, 784)
        // 一整块同一个颜色：没有黑白两端可拉伸，结果全是 0，不能出 NaN
        let flat = DigitClassifier.preprocess(pixels: [UInt8](repeating: 200, count: 100), width: 10, height: 10)
        XCTAssertTrue(flat.allSatisfy { $0 == 0 })
    }

    // MARK: - 两个读数怎么合

    func testCrossCheckOnlyOverrulesWhenTheModelIsSureAndDisagrees() {
        typealias Verdict = DigitClassifier.Verdict
        // 一致：保持
        XCTAssertEqual(DigitCrossCheck.resolve(vision: 8, model: Verdict(digit: 8, confidence: 0.99)).value, 8)
        // 模型很有把握地说是另一个数：标问号
        let clash = DigitCrossCheck.resolve(vision: 8, model: Verdict(digit: 3, confidence: 0.97))
        XCTAssertNil(clash.value)
        XCTAssertTrue(clash.disagreed)
        // 模型没把握：它的意见不算数
        let unsure = DigitCrossCheck.resolve(vision: 8, model: Verdict(digit: 3, confidence: 0.6))
        XCTAssertEqual(unsure.value, 8)
        XCTAssertFalse(unsure.disagreed)
        // 模型说「不是数字」：不算数
        XCTAssertEqual(DigitCrossCheck.resolve(vision: 8, model: Verdict(digit: DigitClassifier.reject, confidence: 0.99)).value, 8)
        // 模型不可用：照旧
        XCTAssertEqual(DigitCrossCheck.resolve(vision: 8, model: nil).value, 8)
    }

    /// Vision 没读出来时只剩模型一个读数。没有东西可以对，仍然是问号 ——
    /// 拿单独一个读数去填，就又回到「认错了还看起来对」。
    func testModelAloneNeverFillsABlank() {
        let outcome = DigitCrossCheck.resolve(vision: nil, model: DigitClassifier.Verdict(digit: 5, confidence: 0.999))
        XCTAssertNil(outcome.value)
        XCTAssertFalse(outcome.disagreed)
    }

    // MARK: - 从格子里取字

    /// 格子大半是空白，喂给模型的是其中有墨的那一块，四周各让 3 个像素。
    func testGlyphIsTheInkedPartOfTheCell() throws {
        let width = 40, height = 30
        var ink = [Bool](repeating: false, count: width * height)
        var red = [UInt8](repeating: 230, count: width * height)
        for y in 10..<20 {
            for x in 12..<18 {
                ink[y * width + x] = true
                red[y * width + x] = 40
            }
        }
        let mask = InkMask(width: width, height: height, ink: ink)
        let glyph = try XCTUnwrap(ZoneRaster.glyph(in: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.6), mask: mask, red: red))
        XCTAssertEqual(glyph.width, 6 + 6)
        XCTAssertEqual(glyph.height, 10 + 6)
        XCTAssertEqual(glyph.pixels[3 * glyph.width + 3], 40)      // 墨的左上角
        XCTAssertEqual(glyph.pixels[0], 230)                        // 让出来的边是纸
        // 格子里没有墨：没有东西可认
        XCTAssertNil(ZoneRaster.glyph(in: CGRect(x: 0.6, y: 0.7, width: 0.3, height: 0.2), mask: mask, red: red))
        // 像素数对不上：不认
        XCTAssertNil(ZoneRaster.glyph(in: CGRect(x: 0, y: 0, width: 1, height: 1), mask: mask, red: [1, 2, 3]))
    }
}
