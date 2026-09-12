import Foundation
import UIKit

/// 数字型彩种的号码行：**按坐标补位**。
///
/// 走到这一步的原因是「按文本认」这条路对这几个彩种走到头了。
/// 双色球印的是两位数、前导补零、值域 1–33、注长恒定 6+1 ——
/// 空格被吃掉能按两位切回来，越界的 token 自动丢掉，个数不对就知道错了，
/// 三重冗余叠在一起，认错一点也能兜住。
///
/// 排列3/5、福彩3D、七星彩把这三层全拿掉了：印的是**一个个孤零零的个位数**，
/// 值域 0–9 意味着任何数字字符都合法，于是
/// `8 4 4 1 5` 被认成 `8 4 1` 之后，在文本上和一注真的三位数**没有任何区别** ——
/// 信息是真没了，不是认错了，再怎么在文本层面补救都没有用。
///
/// 但票面本身还留着一条线索：**这些数字是等距印的**。丢掉一位，
/// 就会在那一位上留下正好一个字宽的空洞。所以这里不看文本，看坐标：
///
/// 1. 把这一行单独裁出来，认出每一个**字符**和它的位置（不是整行的文本）。
/// 2. 用相邻字符的最小间距估出印刷步距，把认出来的字符摆回等距栅格。
/// 3. 栅格上空着的槽位就是丢掉的那几位 —— 位置是算出来的，不是猜的。
/// 4. 把每个空槽**单独裁出来再认一遍**。这一遍 Vision 只看到两三个字符，
///    整行版面那套「宽间距当排版空白」的判断根本用不上。
/// 5. 还是认不出的，就如实标成「这一位没认出来」交给用户点一下补，
///    而不是整注丢掉、报「没有识别到彩票」。
enum DigitRowReader {

    /// 一个认出来的字符及其在裁条里的横向中心（裁条归一化坐标）。
    struct Observation: Equatable {
        let value: Int
        let center: CGFloat
    }

    /// 认出来的字符摆回栅格之后的样子。
    struct Layout: Equatable {
        /// 印刷步距，裁条归一化单位。
        let pitch: CGFloat
        /// 每个字符落在第几个槽位上，**以第一个认出来的字符为 0**。
        let indices: [Int]
        /// 还有几个槽位没着落 —— 它们只可能在两头，具体哪一头要靠裁图去试。
        let slack: Int
    }

    // MARK: - 纯几何

    /// 把认出来的几位数字摆回等距栅格。
    ///
    /// 步距取**相邻间距里最小的那个**：只要有任意一对相邻的数字之间没丢东西，
    /// 这个值就是真的步距。其余间距必须是它的整数倍（容差 0.3 个步距），
    /// 否则说明这一行根本不是等距印的，或者认出来的东西里混了别的，
    /// 这时候宁可什么都不返回 —— 摆错位比认不出更糟，用户会照着改错号。
    static func layout(_ observed: [Observation], expected: Int) -> Layout? {
        guard expected > 0, !observed.isEmpty, observed.count <= expected else { return nil }
        guard observed.count > 1 else {
            // 只认出一个字符时估不出步距。除非整行本来就只有一位。
            return expected == 1 ? Layout(pitch: 0, indices: [0], slack: 0) : nil
        }
        let centers = observed.map(\.center)
        guard centers == centers.sorted() else { return nil }
        let gaps = zip(centers, centers.dropFirst()).map { $1 - $0 }
        guard let pitch = gaps.min(), pitch > 0 else { return nil }

        var indices = [0]
        for gap in gaps {
            let steps = (gap / pitch).rounded()
            guard steps >= 1, abs(gap / pitch - steps) <= 0.3 else { return nil }
            indices.append(indices[indices.count - 1] + Int(steps))
        }
        let span = indices[indices.count - 1] + 1
        guard span <= expected else { return nil }
        return Layout(pitch: pitch, indices: indices, slack: expected - span)
    }

    /// 把栅格铺成 `expected` 个槽位，认出来的字符各就各位。
    ///
    /// `offset` 是整条栅格往右挪几格 —— `slack > 0` 时第一个认出来的字符
    /// 未必就是第一位（丢的可能正是开头那位），所以两头都要试。
    static func slots(_ observed: [Observation],
                      layout: Layout,
                      expected: Int,
                      offset: Int) -> [Int?] {
        var result = [Int?](repeating: nil, count: expected)
        for (index, observation) in zip(layout.indices, observed) {
            let slot = index + offset
            guard result.indices.contains(slot) else { continue }
            result[slot] = observation.value
        }
        return result
    }

    /// 第 `slot` 位的预测中心。
    static func center(of slot: Int, layout: Layout, offset: Int, first: CGFloat) -> CGFloat {
        first + CGFloat(slot - offset) * layout.pitch
    }
}

// MARK: - 实际读一行

extension DigitRowReader {

    /// 一行最多允许补几个空槽。再多就不是"漏了一两位"，是这一行根本没认出来，
    /// 硬补只会拿一堆问号糊弄用户，而且每个空槽都要额外跑几次识别。
    private static let holeBudget = 4

    /// 空槽单独重认时的几种裁法：先给三格宽的窗口（Vision 按"词"工作，
    /// 喂它一个孤零零的字符十有八九什么都不返回），再退到一格半。
    /// `.accurate` 认不动的孤立字符，`.fast` 有时反而认得出来。
    private static let attempts: [(span: CGFloat, fast: Bool)] =
        [(3.0, false), (3.0, true), (1.8, false)]

    /// 读一行数字号码，返回 `expected` 个槽位。
    ///
    /// 认不出的那一位返回 `nil` —— **这正是这条路的价值所在**：
    /// 从前少认一位就整行判无效、用户看到「没有识别到彩票」；
    /// 现在能明确说出是第几位没认出来，其余几位照样是对的。
    ///
    /// 返回 `nil` 表示这一行压根不像等距印的一排数字，
    /// 这时候调用方应该原样保留文本那一遍的结果。
    static func read(image: UIImage,
                     band: ClosedRange<CGFloat>,
                     columns: ClosedRange<CGFloat>,
                     expected: Int) async -> [Int?]? {
        guard expected > 0,
              let strip = TicketVisionScanner.strip(image, band: band, columns: columns)
        else { return nil }

        let observed = await characters(in: strip)
        guard !observed.isEmpty else { return nil }
        // 一位没漏，直接用。这条快路同时避开了栅格分析的所有脆弱之处 ——
        // 票印歪一点、字距有抖动，都不该影响本来就认全了的那些行。
        if observed.count == expected { return observed.map { Optional($0.value) } }
        // 认出来的比该有的还多，说明裁条里混了别的东西（倍数、机号残字）。
        // 挑不出哪几个才是号码，交回给文本那一遍。
        guard observed.count < expected else { return nil }

        guard let grid = layout(observed, expected: expected) else { return nil }
        // 两头都空着就没有足够的信息定位了 —— 摆错位比认不出更糟，
        // 用户会照着一注错号去核奖。
        guard grid.slack <= 1 else { return nil }
        guard expected - observed.count <= holeBudget else { return nil }

        let first = observed[0].center
        var best: [Int?]?
        var bestKnown = -1
        for offset in 0...grid.slack {
            var filled = slots(observed, layout: grid, expected: expected, offset: offset)
            for index in filled.indices where filled[index] == nil {
                let target = center(of: index, layout: grid, offset: offset, first: first)
                guard (0...1).contains(target) else { continue }
                filled[index] = await readSlot(strip, center: target, pitch: grid.pitch)
            }
            let known = filled.compactMap { $0 }.count
            if known > bestKnown {
                bestKnown = known
                best = filled
            }
            // 全补齐了就不用再试另一头了
            if known == expected { break }
        }
        return best
    }

    /// 裁条里每一个数字字符，按横坐标排好。
    ///
    /// 两个放大倍数各认一遍再按位置取并集 —— 宽间距的个位数每一遍漏掉的
    /// 不是同一位，取并集能白捡回来几个，省掉几次单槽重认。
    private static func characters(in strip: CGImage) async -> [Observation] {
        var kept: [TicketVisionScanner.DigitChar] = []
        for factor in [3.0, 5.0] as [CGFloat] {
            let slice = UIImage(cgImage: strip, scale: 1, orientation: .up)
            guard let big = TicketVisionScanner.upscaled(slice, factor: factor) else { continue }
            for char in await TicketVisionScanner.recognizeDigits(in: big) {
                // 上下各留了 45% 余量，邻行的笔画会探进来一点
                guard (0.2...0.8).contains(char.box.midY) else { continue }
                guard !kept.contains(where: { $0.box.intersects(char.box) }) else { continue }
                kept.append(char)
            }
        }
        return kept
            .sorted { $0.box.midX < $1.box.midX }
            .map { Observation(value: $0.value, center: $0.box.midX) }
    }

    /// 把某一个槽位单独裁出来再认一遍。
    ///
    /// 认完按位置挑出**正中间那一个** —— 窗口里有三格，要的只是中间那一位；
    /// 挑出来的字符还得真的落在这一格里，否则那是隔壁那一位，
    /// 认回来只会把号码写错。
    private static func readSlot(_ strip: CGImage,
                                 center: CGFloat,
                                 pitch: CGFloat) async -> Int? {
        guard pitch > 0 else { return nil }
        let width = CGFloat(strip.width)
        let height = CGFloat(strip.height)
        for attempt in attempts {
            let half = pitch * attempt.span / 2
            let left = Swift.max(center - half, 0) * width
            let right = Swift.min(center + half, 1) * width
            let rect = CGRect(x: left, y: 0, width: right - left, height: height)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard rect.width > 6, let window = strip.cropping(to: rect) else { continue }
            let slice = UIImage(cgImage: window, scale: 1, orientation: .up)
            // 裁得越小越要放大 —— 单个字符要占满画面，Vision 才认得动
            guard let big = TicketVisionScanner.upscaled(slice, factor: 8) else { continue }

            // 目标字符在这个窗口里的相对位置
            let wanted = (center * width - rect.minX) / rect.width
            let chars = await TicketVisionScanner.recognizeDigits(in: big, fast: attempt.fast)
                .filter { (0.15...0.85).contains($0.box.midY) }
            let nearest = chars.min { abs($0.box.midX - wanted) < abs($1.box.midX - wanted) }
            guard let nearest,
                  abs(nearest.box.midX - wanted) * rect.width <= pitch * width * 0.5
            else { continue }
            return nearest.value
        }
        return nil
    }
}
