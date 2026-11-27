import XCTest
@testable import LotteryWallet

/// 端侧全离线 CoreML v3 模型族的预处理、解码与安装包加载对拍测试。
final class CoreMLModelsTests: XCTestCase {

    func testAllFiveCoreMLModelsShipAndLoadFromAppBundle() {
        XCTAssertNotNil(CoreMLTicketDetector.shared, "TicketDetector.mlpackage 未打包进 App Bundle")
        XCTAssertNotNil(CoreMLZoneLayout.shared, "ZoneLayout.mlpackage 未打包进 App Bundle")
        XCTAssertNotNil(CoreMLHeaderClassifier.shared, "TicketHeaderMeta.mlpackage 未打包进 App Bundle")
        XCTAssertNotNil(CoreMLLineReader.shared, "LotteryLineOCR.mlpackage 未打包进 App Bundle")
        XCTAssertNotNil(CoreMLMetaReader.shared, "MetaFieldOCR.mlpackage 未打包进 App Bundle")
    }

    func testDetectorLetterboxAndQuadGeometry() {
        let meta = CoreMLTicketDetector.letterboxMeta(width: 1080, height: 1440, size: 384)
        XCTAssertEqual(meta.scale, 384.0 / 1440.0, accuracy: 1e-6)
        XCTAssertEqual(meta.padY, 0)
        XCTAssertEqual(meta.padX, (384 - 288) / 2)

        let shuffled = [CGPoint(x: 200, y: 300), CGPoint(x: 10, y: 20), CGPoint(x: 10, y: 300), CGPoint(x: 200, y: 20)]
        let ordered = CoreMLTicketDetector.orderQuad(shuffled)
        XCTAssertEqual(ordered, [CGPoint(x: 10, y: 20), CGPoint(x: 200, y: 20), CGPoint(x: 200, y: 300), CGPoint(x: 10, y: 300)])

        let q1 = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]
        let q2 = [CGPoint(x: 50, y: 0), CGPoint(x: 150, y: 0), CGPoint(x: 150, y: 100), CGPoint(x: 50, y: 100)]
        XCTAssertEqual(CoreMLTicketDetector.quadIoU(q1, q1), 1.0, accuracy: 1e-4)
        XCTAssertEqual(CoreMLTicketDetector.quadIoU(q1, q2), 5000.0 / 15000.0, accuracy: 1e-4)
    }

    func testDetectorPeakDecodingAndNMS() {
        let grid = CoreMLTicketDetector.grid
        let cells = grid * grid
        var hm = [Float](repeating: 0, count: 3 * cells)
        var cn = [Float](repeating: 0, count: 8 * cells)
        // 在 (gx=24, gy=24) 放一个 welfare 强峰值，周围邻格稍弱（验证 3x3 局部极大值抑制）
        let cell = 24 * grid + 24
        hm[0 * cells + cell] = 0.92
        hm[0 * cells + 24 * grid + 25] = 0.70
        // 四个角相对中心偏移 ±0.25 * 384 = ±96px
        let offs: [(Float, Float)] = [(-0.25, -0.3), (0.25, -0.3), (0.25, 0.3), (-0.25, 0.3)]
        for (k, (dx, dy)) in offs.enumerated() {
            cn[(k * 2) * cells + cell] = dx
            cn[(k * 2 + 1) * cells + cell] = dy
        }
        // 在同位置放一个分数更低的 sports 峰值，应被跨类多边形 NMS 抑制掉
        hm[1 * cells + cell] = 0.65

        let meta = CoreMLTicketDetector.letterboxMeta(width: 768, height: 768, size: 384)
        let dets = CoreMLTicketDetector.decodePeaks(heatmap: hm, corners: cn, meta: meta)
        XCTAssertEqual(dets.count, 1)
        XCTAssertEqual(dets[0].kind, .welfare)
        XCTAssertEqual(dets[0].score, 0.92, accuracy: 1e-4)
        XCTAssertEqual(dets[0].corners.count, 4)
    }

    func testStripPreprocessingInvertsInkAndLeftAligns() {
        let w = 80, h = 40
        var gray = [UInt8](repeating: 230, count: w * h)
        // 左半边印黑色竖墨，右半边留白纸
        for y in 8..<32 {
            for x in 10..<24 { gray[y * w + x] = 30 }
        }
        let strip = CoreMLBundle.preprocessStrip(gray, width: w, height: h, targetHeight: 32, targetWidth: 640)
        XCTAssertEqual(strip.count, 32 * 640)
        // 缩放后宽度 = 64，右侧补 0；墨区像素接近 1，纸底接近 0
        XCTAssertGreaterThan(strip[16 * 640 + 12], 0.8)
        XCTAssertEqual(strip[16 * 640 + 200], 0, accuracy: 1e-6)
    }

    func testLineCTCDecodeStripMultipleAndTokenBridge() {
        let T = 12, C = CoreMLLineReader.numClasses
        var probs = [Float](repeating: 0.01, count: T * C)
        // 序列: blank, '0','0', '9', blank, '(', '2', ')', blank...
        let seq = [0, 1, 1, 10, 0, 11, 3, 12, 0, 0, 0, 0]
        for (t, cls) in seq.enumerated() { probs[t * C + cls] = 0.96 }
        let decoded = CoreMLLineReader.decodeCTC(probs: probs, timeSteps: T, numClasses: C)
        XCTAssertEqual(decoded.text, "09(2)")
        let stripped = CoreMLLineReader.stripMultiple(text: decoded.text, confs: decoded.peaks)
        XCTAssertEqual(stripped.digits, [0, 9])
        XCTAssertEqual(stripped.multiple, 2)

        // 缺右括号的残缺倍数 `(3` 同样剥离干净
        let broken = CoreMLLineReader.stripMultiple(text: "05122330350211(3", confs: Array(repeating: 0.97, count: 16))
        XCTAssertEqual(broken.digits, [0, 5, 1, 2, 2, 3, 3, 0, 3, 5, 0, 2, 1, 1])
        XCTAssertEqual(broken.multiple, 3)

        // 转换成 `GlyphRows.Token` 后无缝兼容 `GlyphRows.readLine` 与 `ModelFusion.trailingMultiple`
        let tokens = CoreMLLineReader.makeTokens(digits: broken.digits, confs: broken.confs, multiple: broken.multiple, top: 0, bottom: 40)
        let read = GlyphRows.readLine(tokens, count: 14)
        XCTAssertEqual(read?.map(\.digit), broken.digits)
        XCTAssertEqual(ModelFusion.trailingMultiple(tokens), 3)
    }

    func testMetaFieldParserExtractsWelfareAndSportsFields() {
        let welfare = CoreMLMetaReader.parseFields([
            "开奖期:2026316 26-11-26 合计28元",
            "倍数:2"
        ], sports: false)
        XCTAssertEqual(welfare.issue, "2026316")
        XCTAssertEqual(welfare.drawDate, "2026-11-26")
        XCTAssertEqual(welfare.totalAmount, 28)
        XCTAssertEqual(welfare.multiple, 2)
        XCTAssertEqual(welfare.periods, 1)
        XCTAssertFalse(welfare.addOn)

        let sports = CoreMLMetaReader.parseFields([
            "第26128期 2026年11月09日开奖",
            "单式票 追加投注3期2倍 合计36元"
        ], sports: true)
        XCTAssertEqual(sports.issue, "26128")
        XCTAssertEqual(sports.drawDate, "2026-11-09")
        XCTAssertEqual(sports.totalAmount, 36)
        XCTAssertEqual(sports.multiple, 2)
        XCTAssertEqual(sports.periods, 3)
        XCTAssertTrue(sports.addOn)
    }

    func testHeaderDecoderHandlesSupportedAndUnsupportedTickets() throws {
        var g = [Float](repeating: 0.01, count: 9)
        g[3] = 0.94 // k8
        var p = [Float](repeating: 0.02, count: 5)
        p[2] = 0.91 // dantuo
        var k8 = [Float](repeating: 0.01, count: 11)
        k8[6] = 0.88 // 选六
        let pred = try XCTUnwrap(CoreMLHeaderClassifier.decode(gameProbs: g, playProbs: p, addOnProb: 0.05, k8Probs: k8))
        XCTAssertEqual(pred.game, .k8)
        XCTAssertFalse(pred.isUnsupported)
        XCTAssertEqual(pred.play, .dantuo)
        XCTAssertEqual(pred.k8Pick, 6)

        var unsupp = [Float](repeating: 0.005, count: 9)
        unsupp[8] = 0.96
        let uPred = try XCTUnwrap(CoreMLHeaderClassifier.decode(gameProbs: unsupp, playProbs: [0.01, 0.01, 0.01, 0.01, 0.96], addOnProb: 0.01, k8Probs: [0.95] + Array(repeating: 0.005, count: 10)))
        XCTAssertNil(uPred.game)
        XCTAssertTrue(uPred.isUnsupported)
        XCTAssertGreaterThan(uPred.gameConfidence, 0.92)
    }
}
