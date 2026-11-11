import XCTest
@testable import LotteryWallet

/// 一图多票：在整张照片里把每张票分开。
///
/// 坐标取自真票照片上量出来的文字行位置（1080×1440 的图），流水号和哈希换成了假的。
/// 这套规则错了的后果是**两张票的号码串到一起**，或者少认一张而没人发现，
/// 所以并排、叠放、连体三种摆法各锁一个用例。
final class TicketLocatorTests: XCTestCase {

    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat = 18) -> TicketLocator.Line {
        TicketLocator.Line(text: text, corners: [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y),
                                                 CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)])
    }

    private func box(_ found: TicketLocator.Found) -> CGRect {
        let xs = found.corners.map(\.x), ys = found.corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// 上面一张、下面并排两张福彩票，四周是垫子上印的字。
    private var threeWelfare: [TicketLocator.Line] {
        [
            line("祝您中奖", 479, 43, 334, 60),
            // 上：双色球复式
            line("中国福利彩票", 483, 209, 189),
            line("玩法：双色球-复式", 340, 238, 140),
            line("AB12-0FBA-AA24-EDA9-3228/12664950/42F03", 337, 257, 322),
            line("红复:06111216171823", 337, 285, 265),
            line("蓝复：0112", 335, 308, 105),
            line("开奖期：202612826-11-08", 331, 400, 189),
            line("合计28元", 573, 403, 77),
            line("感谢您为公益慈善事业贡献10.08元", 325, 465, 258),
            line("上海市福利彩票发行中心承销", 358, 671, 220),
            // 左下：快乐8
            line("中国福利彩票", 253, 726, 190),
            line("玩法：快乐8-选五单式", 105, 768, 165),
            line("47C0-CE87-E268-9EA5-C611/12664950/0EB01", 105, 790, 326),
            line("A.02 05 24 40 44", 105, 818, 185),
            line("开奖期：202629826-11-08", 107, 945, 180),
            line("合计4元", 363, 931, 70),
            line("上海市福利彩票发行中心承销", 150, 1228, 310),
            // 右下：双色球复式
            line("中国福利彩票", 690, 715, 198),
            line("玩法：双色球-复式", 541, 756, 141),
            line("机号：31130622", 778, 760, 116),
            line("0CD1-2164-A717-88CE-5D39/12664950/22314", 539, 778, 339),
            line("红单：031114172533", 539, 808, 244),
            line("开奖期：202612826-11-08", 538, 929, 200),
            line("上海市福利彩票发行中心承销", 582, 1226, 320),
            line("请仔细核对投注内容和金额", 235, 1390, 400, 24)
        ]
    }

    func testSeparatesThreeTicketsAndOrdersThem() {
        let found = TicketLocator.locate(threeWelfare)
        XCTAssertEqual(found.count, 3)
        XCTAssertTrue(found.allSatisfy { $0.kind == .welfare && $0.complete })
        // 顺序：上面那张，然后左下、右下
        let boxes = found.map(box)
        XCTAssertLessThan(boxes[0].minY, 230)
        XCTAssertLessThan(boxes[1].minX, boxes[2].minX)
        XCTAssertGreaterThan(boxes[1].minY, 650)
        // 并排的两张互不越界：左边那张的右沿在右边那张的锚行左边
        XCTAssertLessThan(boxes[1].maxX, 539)
        XCTAssertGreaterThan(boxes[2].minX, 431)
    }

    /// 每张票的框要把自己的票头（彩种名印在那儿）和票底都包进去，垫子上的字不能带进来。
    func testEachBoxCoversItsOwnHeadAndFootOnly() {
        let boxes = TicketLocator.locate(threeWelfare).map(box)
        XCTAssertLessThanOrEqual(boxes[0].minY, 209)      // 标志
        XCTAssertGreaterThanOrEqual(boxes[0].maxY, 689)   // 「…发行中心承销」
        XCTAssertGreaterThan(boxes[0].minY, 103)          // 「祝您中奖」在外面
        XCTAssertLessThan(boxes[1].maxY, 1390)            // 「请仔细核对」在外面
        XCTAssertLessThan(boxes[2].maxY, 1390)
    }

    /// 叠着放：下面那张票的票头范围会盖住上面那张的下半截。
    /// 上面那张的「开奖期」一行不是票头，不能被下面那张吞掉。
    func testOverlappingStackKeepsUpperTicketsLowerHalf() {
        let lines = [
            line("中国福利彩票", 480, 60, 190),
            line("玩法：双色球-复式", 340, 82, 140),
            line("1BA7-3764-0624-D5F4-D551/48304636/2201C", 337, 100, 322),
            line("红复:01031222252628", 337, 130, 265),
            line("开奖期：202612526-11-01", 331, 240, 189),
            // 第二张压在第一张的下半截上
            line("中国福利彩票", 470, 300, 190),
            line("玩法：双色球-复式", 330, 325, 140),
            line("7E92-0DEB-BB99-45D9-5164/48304636/02F07", 327, 345, 322),
            line("红单:070810132230", 327, 375, 240),
            line("上海市福利彩票发行中心承销", 350, 760, 220)
        ]
        let found = TicketLocator.locate(lines)
        XCTAssertEqual(found.count, 2)
        let boxes = found.map(box)
        XCTAssertGreaterThanOrEqual(boxes[0].maxY, 258, "上面那张的「开奖期」被下面那张吞掉了")
        XCTAssertLessThanOrEqual(boxes[1].minY, 300)
        // 上面那张的票底被压住了：照样交出去，但标成不完整
        XCTAssertFalse(found[0].complete)
        XCTAssertTrue(found[1].complete)
    }

    /// 两张体彩票连着没撕开：第二张的标题在第一张的正下方，要归第二张。
    func testJoinedSportsStripSplitsAtTheSecondTitle() {
        let lines = [
            line("体彩 超级大乐透", 420, 300, 300, 40),
            line("第 26128期", 390, 360, 100),
            line("2026年11月09日开奖", 590, 360, 160),
            line("110310-309661-112089-342471 562783 rCVxQg", 392, 380, 360),
            line("① 09 11 13 16 28 + 05 07", 405, 458, 335),
            line("感谢您为公益事业贡献 3.24元", 455, 560, 230),
            line("20-020689-101 00004 26/11/09 10:03:37", 403, 612, 332),
            // 第二张
            line("体彩 排列5", 470, 880, 230, 40),
            line("第 26299期", 388, 932, 100),
            line("110310-337361-121177-002117 057246 f4ef4Q", 388, 952, 360),
            line("① 3 4 9 2 4", 475, 1035, 195),
            line("20-020689-101 00005 26/11/09 10:03:40", 397, 1212, 332)
        ]
        let found = TicketLocator.locate(lines)
        XCTAssertEqual(found.map(\.kind), [.sports, .sports])
        XCTAssertTrue(found.allSatisfy(\.complete))
        let boxes = found.map(box)
        XCTAssertLessThanOrEqual(boxes[0].minY, 300)       // 第一张的标题
        XCTAssertLessThan(boxes[0].maxY, 880)              // 没伸到第二张的标题
        XCTAssertLessThanOrEqual(boxes[1].minY, 880)       // 第二张的标题归第二张
        XCTAssertGreaterThanOrEqual(boxes[1].maxY, 1230)
    }

    /// 标题没认出来（艺术字经常认不出）：框的上沿照样要留够票头的高度。
    func testKeepsRoomForAnUnreadTitle() {
        let lines = [
            line("110310-309661-112089-342471 562783 rCVxQg", 392, 380, 360),
            line("① 09 11 13 16 28 + 05 07", 405, 458, 335),
            line("20-020689-101 00004 26/11/09 10:03:37", 403, 612, 332)
        ]
        let found = TicketLocator.locate(lines)
        XCTAssertEqual(found.count, 1)
        XCTAssertLessThanOrEqual(box(found[0]).minY, 380 - 6.5 * 18)
    }

    /// 票是斜着拍的：框跟着票转，不是一个横平竖直的大框。
    func testFollowsATiltedTicket() {
        let angle = CGFloat.pi / 9      // 20°
        func turn(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * cos(angle) - point.y * sin(angle) + 600,
                    y: point.x * sin(angle) + point.y * cos(angle))
        }
        let upright = Array(threeWelfare[1...9])
        let tilted = upright.map { TicketLocator.Line(text: $0.text, corners: $0.corners.map(turn)) }
        let straight = TicketLocator.locate(upright), turned = TicketLocator.locate(tilted)
        XCTAssertEqual(turned.count, 1)
        for (a, b) in zip(straight[0].corners.map(turn), turned[0].corners) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.5)
            XCTAssertEqual(a.y, b.y, accuracy: 0.5)
        }
    }

    /// 横着拍的照片要先转正。转四次回到原样，转一次宽高互换。
    func testQuarterTurns() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        XCTAssertEqual(try XCTUnwrap(image.turned(quarterTurns: 1)).size, CGSize(width: 20, height: 40))
        XCTAssertEqual(try XCTUnwrap(image.turned(quarterTurns: 2)).size, CGSize(width: 40, height: 20))
        XCTAssertEqual(try XCTUnwrap(image.turned(quarterTurns: 3)).size, CGSize(width: 20, height: 40))
        XCTAssertTrue(image.turned(quarterTurns: 4) === image)
        XCTAssertEqual(try XCTUnwrap(image.turned(quarterTurns: -1)).size, CGSize(width: 20, height: 40))
    }

    /// 没有锚行就是没有票：不能把一段普通文字框成一张票。
    func testNothingWithoutAnAnchor() {
        XCTAssertTrue(TicketLocator.locate([]).isEmpty)
        XCTAssertTrue(TicketLocator.locate([line("祝您中奖", 479, 43, 334), line("2026-11-08 12:06:09", 300, 400, 200),
                                            line("合计28元", 573, 403, 77)]).isEmpty)
    }

    // MARK: - 流水号读不干净的时候（真机上两张票丢过一张）

    func testSportsSerialToleratesMisreads() {
        XCTAssertTrue(TicketLocator.isSportsSerial("110310-333361-121160-320322"))
        // 0 读成 O、1 读成 I
        XCTAssertTrue(TicketLocator.isSportsSerial("11O31O-333361-I2II60-320322"))
        // 只读出前三组
        XCTAssertTrue(TicketLocator.isSportsSerial("110310-333361-121160"))
        // 一根横线读丢了、另一根读成了波浪线
        XCTAssertTrue(TicketLocator.isSportsSerial("110310333361~121160-320322"))
    }

    func testOtherDigitRowsAreNotSerials() {
        XCTAssertFalse(TicketLocator.isSportsSerial("20-020689-101"), "票底的站号行")
        XCTAssertFalse(TicketLocator.isSportsSerial("0005526/10/2611:02:08"))
        XCTAssertFalse(TicketLocator.isSportsSerial("第26285期2026年10月26日开奖"))
        XCTAssertFalse(TicketLocator.isSportsSerial("①62572"))
    }

    func testLocateMarkTitles() {
        XCTAssertEqual(TicketLocateView.title(number: 2, game: .pl5), "2 排列5")
        XCTAssertEqual(TicketLocateView.title(number: 1, game: nil), "1 没认出彩种")
    }
}
