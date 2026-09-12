import Foundation
import Vision
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// 用 Apple Vision 在本机识别票面文字。
/// 图片不上传、不写入数据库，识别完即释放。
enum TicketVisionScanner {

    enum ScanError: LocalizedError {
        case invalidImage
        case recognitionFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "这张图片无法读取，请重新拍摄"
            case .recognitionFailed: return "识别失败，请换一张更清晰的照片"
            }
        }
    }

    /// 一次扫描的产物：识别结果 + 那张票裁切矫正后的正片。
    struct ScannedPage {
        var result = ScanResult()
        /// 按票的 id 存正片，复核和改号的时候贴出来。
        /// 一次只扫一张票，所以这些指向的是同一张图。
        var images: [ScannedTicket.ID: UIImage] = [:]
        /// 配准的结果（号码区四角 + 调试记录）。
        ///
        /// **阶段 1 它不参与识别**，只画给人看：号码还是走老路认的。
        /// 先让「摆正没摆正」肉眼可判，再把识别接到标准矩形上（阶段 2）——
        /// 反过来做的话，一旦结果不对，没人分得清是配准错了还是识别错了。
        var registration = TicketRegistration.Result()
    }

    /// 识别一张**已经裁切矫正过**的票。
    ///
    /// 找票、摆正这两步在这之前由 `TicketCropView` + `TicketImagePreprocessor`
    /// 完成，而且最终的框是用户点头的。到这里图已经是正的、放大过的，
    /// OCR 只需要认字。
    static func scan(_ image: UIImage) async throws -> ScannedPage {
        var page = ScannedPage()
        let fragments = try await recognizeFragments(in: image)
        // **配准跑在识别前面。**
        //
        // 阶段 2 起，号码是摆到配准后的格子上去认的，所以基准得先定下来。
        // 阶段 1 时它跑在最后、只画给人看；现在它是号码那条路的入口。
        let detected = TicketTextParser.detectGame(LayoutSegmenter.lines(fragments))
        var registration = await TicketRegistration.run(image: image,
                                                        fragments: fragments,
                                                        game: detected)
        // **不再做版面切分。**
        //
        // 递归 XY 切分是为「一张照片里几张票」写的，现在一次只认一张，
        // 它变成了纯粹的风险：一张票内部同样有整列的空白 ——
        // 右边那一竖排的机号、每注的 (3) 倍数、合计金额，正好能凑够
        // 切分要求的碎片数，于是一张完整的票被从中间劈开：
        // 左半边只剩号码没有彩种名（认不出彩种），右半边只有几个金额。
        // 两半都解析不出票，用户看到的就是「没有识别到彩票」——
        // 而且他明明裁得很准。
        //
        // 现在整块文本一起交给解析器，同一张纸上连着打两张票的情况
        // 由 `splitBlocks` 按「玩法:」这类票头来切，那是按内容切的，不会误伤。
        let merged = await mergedText(image: image, base: fragments, frame: registration.frame)
        // 划出来的格子画到调试图上，盖掉阶段 1 那版"墨迹自己切出来的段" ——
        // 现在画的是真正拿去认号码的那些格子，位置对不对一眼就看得出来。
        if let grid = merged.grid, let frame = registration.frame {
            registration.debug.cells = grid.debugCells(frame: frame)
        }
        // **号码走了哪条路，永远写一句。**
        //
        // 「退回老路」和「新路读错」在识别结果上长得一模一样，没有这一句
        // 就只能对着号码猜 —— 上一轮我就猜错了两次。
        if let note = merged.note { registration.debug.notes.append(note) }
        var result = TicketTextParser.parse(merged.text)
        if result.tickets.isEmpty {
            // 再放大一遍重试。裁切之后还认不出，多半是原图本身就糊。
            if let bigger = upscaled(image, factor: 1.6),
               let retry = try? await recognizeFragments(in: bigger) {
                let second = TicketTextParser.parse(LayoutSegmenter.lines(retry))
                if !second.tickets.isEmpty { result = second }
            }
        }
        // 一个字都没认出来和「认出字但拼不成票」是两回事，
        // 复核页要能把原文摆出来，否则用户只能干瞪眼。
        if result.rawText.isEmpty { result.rawText = LayoutSegmenter.lines(fragments) }
        page.result = result
        // 复核页每张票下面贴的那张图，裁到**有字的那一块**再给出去。
        //
        // 整张票面上下常有大片空白、底部还有一长条码 —— 原图塞进一个
        // 132pt 高的预览框里，真正要核对的彩种名、期号、号码球全被压成一条。
        // 裁掉没信息的边缘之后，同样的框里这些东西能大好几倍。
        let content = contentCrop(image, fragments: fragments) ?? image
        for ticket in result.tickets { page.images[ticket.id] = content }
        page.registration = registration
        return page
    }

    // MARK: - 号码行的二次识别

    /// 中文模型 + 拉丁数字混在一起时，**间距很宽的单个数字最容易被并掉或漏掉**。
    ///
    /// 双色球和大乐透之所以准，是因为它们印的是两位数、还带 `-` `+` 分隔符，
    /// 整体是一团紧凑的字符；而排列3/5、七星彩印的是一个个孤零零的个位数，
    /// 中间空好几个字符宽 —— 这正是中文识别模型最容易把它们当成排版空白、
    /// 或者干脆并成一个 token 的地方。真实识别结果里
    /// `8 4 4 1 5` 认成 `8 4 1`、`3 6 7` 认成 `3 6`，都是这个原因。
    ///
    /// 所以号码行单独再认一遍：图放大两倍、**只挂英数模型**。
    /// 非号码行（彩种名、玩法、期号、金额）仍然用中文那一遍的结果。
    ///
    /// 一位一个数字的那几个彩种（排列3/5、福彩3D、七星彩）走的是另一条路：
    /// 它们的号码印成一个紧密的矩阵，上下的空隙比左右的窄好几倍，
    /// Vision 干脆**按竖列**读 —— 分行结果本身就是错的，基于它修修补补没有意义。
    /// 所以整段交给 `DigitMatrixReader` 按坐标重建。
    /// 号码那一段的产物：文本 + 格子 + 走了哪条路。
    struct DigitPass {
        var text: String
        var grid: NumberGrid?
        /// 调试图上写出来的那句话。号码路没跑（不是数字型彩种）时为 nil。
        var note: String?
    }

    static func mergedText(image: UIImage, base: [TextFragment],
                          frame: TicketFrame? = nil) async -> DigitPass {
        let baseRows = LayoutSegmenter.rows(base)
        let originals = baseRows.map(LayoutSegmenter.join)
        // 彩种要先认出来，二次识别的结果才有得校验 —— 见 `isImprovement`。
        let game = TicketTextParser.detectGame(originals.joined(separator: "\n"))
        // 数字型彩种先走矩阵重建。它**整段接管**号码区，因为对这些票来说
        // Vision 的分行结果本身就是错的（它按竖列读），基于它再修修补补没有意义。
        if let game, let layout = DigitTicketLayout.of(game) {
            // 阶段 2：配准成功就走格子那条路 —— 先有格子再去认，
            // 几何不再是从识别结果里估出来的。
            var note = "格子路：没配准成功，基准都没找到"
            if let frame {
                let outcome = await RegisteredDigitReader.read(image: image, frame: frame,
                                                              layout: layout)
                note = outcome.note
                if let reading = outcome.reading {
                    return DigitPass(
                        text: compose(rows: baseRows, originals: originals,
                                      matrix: reading.matrix),
                        grid: reading.grid, note: note)
                }
            }
            // 配准没成功（基准没找到、格子划不齐）就退回老路。
            // 老路会从识别结果里估几何，没有配准那么稳，但总比什么都不给强。
            //
            // 只有一格一位的那几种票能退到这儿：老路是按「一列一个个位数」写的，
            // 双色球和大乐透印的是两位数，喂给它读出来的是垃圾，
            // 还不如直接退到逐行二次识别 —— 那条路本来就是它们一直在走的。
            if layout.singleDigit,
               let matrix = await DigitMatrixReader.read(image: image, layout: layout,
                                                        labelBoundary: rowLabelBoundary(base)) {
                return DigitPass(
                    text: compose(rows: baseRows, originals: originals, matrix: matrix),
                    grid: nil, note: note + "；退回老路（按字符坐标估几何）")
            }
            return DigitPass(text: await secondPass(image: image, rows: baseRows,
                                                    originals: originals, game: game),
                             grid: nil,
                             note: note + "；老路也没读出来，退回逐行二次识别")
        }

        return DigitPass(text: await secondPass(image: image, rows: baseRows,
                                               originals: originals, game: game),
                         grid: nil, note: nil)
    }

    /// 最老的那条路：一行一行裁出来再认一遍。
    /// 不是数字型彩种的票走它，数字型的两条路都失败时也退到它。
    private static func secondPass(image: UIImage, rows: [[TextFragment]],
                                   originals: [String], game: GameKey?) async -> String {
        var result: [String] = []
        for (index, row) in rows.enumerated() {
            let original = originals[index]
            guard looksLikeNumberRow(original) else {
                result.append(original)
                continue
            }
            let band = LayoutSegmenter.band(row)
            let columns = LayoutSegmenter.columns(row)
            let better = await bestDigitReading(image: image, band: band, columns: columns)
            guard let better, isImprovement(better, over: original, game: game) else {
                result.append(original)
                continue
            }
            result.append(graft(prefix: original, digits: better))
        }
        return result.joined(separator: "\n")
    }

    /// 票面左边那一竖排注序号的右边界 —— `①②③④⑤`、`A. B. C.`、3D 的 `组六:`。
    ///
    /// 号码矩阵全在它右边。这一条是防止注序号被当成一列号码的**主闸**：
    /// 实测注序号列和号码列的间距完全一样（62.5 对 65），几何上根本分不开，
    /// 而 `.fast` 又会把圈码读成 `0`，靠字符本身也挡不住。
    /// 不挡的话整个矩阵右移一格、真正的最后一列被挤掉。
    ///
    /// 判据是**相对票面内容**算的，不是相对整张照片 —— 用户裁得松一点、
    /// 票只占画面一半时，按整张图算的比例全都会偏，
    /// 这正是「裁切稍微不准就识别失败」的来源之一。
    static func rowLabelBoundary(_ fragments: [TextFragment]) -> CGFloat? {
        guard let content = contentBox(fragments), content.width > 0 else { return nil }
        let labels = fragments.filter { fragment in
            // 太宽的不是标签 —— 整行号码也可能以 `A.` 开头，
            // 拿它当边界会把半张票的号码切掉。
            guard fragment.box.width < content.width * 0.12 else { return false }
            // 注序号印在票面左边。右半张票上碰巧匹配到的东西不能当边界。
            guard fragment.box.maxX < content.minX + content.width * 0.4 else { return false }
            return fragment.text.range(of: rowLabelPrefix, options: .regularExpression) != nil
        }
        return labels.map(\.box.maxX).max()
    }

    /// 票面上所有文字占的那一块。
    static func contentBox(_ fragments: [TextFragment]) -> CGRect? {
        guard let first = fragments.first else { return nil }
        return fragments.dropFirst().reduce(first.box) { $0.union($1.box) }
    }

    /// 把重建出来的号码矩阵拼回整篇文本。
    ///
    /// 矩阵占的那一段纵向区间里，Vision 原来的分行结果整段丢掉 —— 那几行
    /// 十有八九是竖着读出来的，留着只会让解析器多读出几注不存在的号码。
    /// 区间外的行（彩种名、期号、玩法、合计）原样保留，它们是横排文本，
    /// Vision 读得好好的。
    private static func compose(rows: [[TextFragment]],
                                originals: [String],
                                matrix: DigitMatrixReader.Matrix) -> String {
        var result: [String] = []
        var inserted = false
        for (index, row) in rows.enumerated() {
            let band = LayoutSegmenter.band(row)
            let overlaps = band.lowerBound <= matrix.span.upperBound
                && band.upperBound >= matrix.span.lowerBound
            guard overlaps else {
                result.append(originals[index])
                continue
            }
            guard !inserted else { continue }
            inserted = true
            result.append(contentsOf: matrix.rows.map { line(for: $0, rows: rows) })
        }
        if !inserted {
            result.append(contentsOf: matrix.rows.map { line(for: $0, rows: rows) })
        }
        return result.joined(separator: "\n")
    }

    /// 一注拼成一行文本，前面带上票面印的玩法标签。
    ///
    /// 标签只从**和这一注同高、而且不横跨多行**的碎片里找。
    /// 福彩 3D 每一注前面印着「组六:」「组三:」，那是核奖要用的；
    /// 而 `①②③④⑤` 那一竖排常常被 Vision 当成一个碎片整条读出来，
    /// 它横跨所有行，认作谁的标签都不对。
    private static func line(for row: DigitMatrixReader.Row, rows: [[TextFragment]]) -> String {
        let digits = slotText(row.values)
        let height = row.band.upperBound - row.band.lowerBound
        for fragment in rows.flatMap({ $0 }) {
            guard fragment.box.height < height * 2 else { continue }
            let center = fragment.box.midY
            guard row.band.contains(center) else { continue }
            guard let range = fragment.text.range(of: Self.rowLabelPrefix, options: .regularExpression)
            else { continue }
            let label = fragment.text[range].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            return "\(label) \(digits)"
        }
        return digits
    }

    /// 栅格铺成文本。认不出的那一位写成 `?`，由解析器带到复核页去。
    static func slotText(_ slots: [Int?]) -> String {
        slots.map { slot in slot.map { String($0) } ?? "?" }.joined(separator: " ")
    }

    /// 二次识别的结果该不该采纳。
    ///
    /// 上一版的判据是「数字更多就换」，方向**正好是反的**：裁条时扫进来的
    /// 机号、金额、邻行残字天生数字更多，垃圾永远赢。真实结果里
    /// `A.05 16 24 33 45 52 66 80` 被换成了
    /// `A.05 16 24 33 45 52 66 80 ( 1 R 1. 07 Z0 CO 70`，
    /// 一整张快乐8 票就此读不出任何一注。
    ///
    /// 现在的判据是**这一行读不读得成一注**，而不是有几个数字：
    /// 1. 候选必须是**干干净净一排数字**。上面那串里的 `(` `R` `.` 一个都过不去。
    /// 2. 原来读不成、现在读得成 —— 换。这正是二次识别要救的那种行。
    /// 3. 原来读得成、现在读不成 —— 不换。只补漏，不改坏。
    /// 4. 两边一样（都成或都不成）才退回比数字个数。
    ///
    /// 认不出彩种时没有第 2、3 条可用，只剩第 1 条加数字个数。
    static func isImprovement(_ candidate: String, over original: String, game: GameKey?) -> Bool {
        guard TicketTextParser.isBareNumberLine(candidate) else { return false }
        guard let game else { return digitCount(candidate) > digitCount(original) }
        let body = original.replacingOccurrences(of: Self.rowLabelPrefix,
                                                 with: "", options: .regularExpression)
        let originalReads = TicketTextParser.singleLineForTesting(body, game: game) != nil
        let candidateReads = TicketTextParser.singleLineForTesting(candidate, game: game) != nil
        // 原行里混进了右边那一竖排机号时，它本来就读不成一注；
        // 裁条之后机号被挡在外面，数字反而**变少**了 —— 这时候按个数比就全错了。
        if candidateReads != originalReads { return candidateReads }
        return digitCount(candidate) > digitCount(original)
    }

    /// 把这一行**单独裁出来**再识别一遍。
    ///
    /// 这是精度上最大的一个杠杆。整张票一起送进 Vision 时，一行里那几个
    /// 间距很宽的个位数在整幅画面里只占很小一块，模型既要处理中文标题、
    /// 又要处理条码和一长串机号，孤立的数字最容易被丢掉 ——
    /// `8 4 4 1 5` 认成 `8 4 1`、`3 6 7` 认成 `3 6` 都是这么来的。
    ///
    /// 裁成一条窄带之后，这一行就占满了整幅输入：字被放大好几倍，
    /// 周围也没有别的东西来抢注意力。再挂上只认英数的模型，
    /// 中文识别那套「把宽间距当排版空白」的倾向也一并避开了。
    ///
    /// **横向必须卡在这一行自己那一段。** 上一版裁的是整幅宽度，
    /// 票面右边那一竖排机号于是行行都被扫进来。
    private static func bestDigitReading(image: UIImage,
                                         band: ClosedRange<CGFloat>,
                                         columns: ClosedRange<CGFloat>) async -> String? {
        guard let rowStrip = strip(image, band: band, columns: columns) else { return nil }

        var tokens: [DigitToken] = []
        // 一条窄带很小，放大三倍也不贵；两个倍数各认一遍，**按位置取并集**。
        for factor in [3.0, 5.0] as [CGFloat] {
            let slice = UIImage(cgImage: rowStrip, scale: 1, orientation: .up)
            guard let big = upscaled(slice, factor: factor),
                  let fragments = try? await recognizeFragments(in: big, languages: ["en-US"]) else { continue }
            merge(digitTokens(in: fragments), into: &tokens)
        }
        guard !tokens.isEmpty else { return nil }
        return tokens.sorted { $0.box.minX < $1.box.minX }
            .map(\.text)
            .joined(separator: " ")
    }

    /// 把某一行单独裁成一条窄带。
    ///
    /// 横向卡在这一行自己那一段（`columns` 已经把右边那一竖排机号挡在外面），
    /// 上下各留半行余量 —— 贴着字边切会把笔画削掉，反而更难认。
    static func strip(_ image: UIImage,
                      band: ClosedRange<CGFloat>,
                      columns: ClosedRange<CGFloat>) -> CGImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let padY = Swift.max((band.upperBound - band.lowerBound) * 0.45, 0.004)
        // Vision 的 y 向上为正，位图向下，所以要翻过来
        let top = (1 - Swift.min(band.upperBound + padY, 1)) * height
        let bottom = (1 - Swift.max(band.lowerBound - padY, 0)) * height
        let span = stripColumns(columns)
        let left = span.lowerBound * width
        let right = span.upperBound * width
        let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.height > 8, rect.width > 24 else { return nil }
        return cgImage.cropping(to: rect)
    }

    /// `strip` 实际裁到的横向区间 —— 两边各放宽一点，接住首尾那个
    /// 可能整块没认出来的数字。在裁条上认完之后要按它把坐标换算回整张图。
    static func stripColumns(_ columns: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> {
        let pad = Swift.max((columns.upperBound - columns.lowerBound) * 0.08, 0.03)
        return Swift.max(columns.lowerBound - pad, 0)...Swift.min(columns.upperBound + pad, 1)
    }

    /// 一个认出来的数字字符及其位置。
    struct DigitChar: Sendable {
        let value: Int
        /// 归一化坐标，原点左下角。
        let box: CGRect
    }

    /// 认出图里每一个**数字字符**及其位置。
    ///
    /// 和 `recognizeFragments` 的区别在于按字符取框（`boundingBox(for:)`）。
    /// 按坐标重建矩阵要知道"哪个数字在哪儿"，整块文本的框给不了这个 ——
    /// Vision 经常把一整排号码当成一个碎片返回，那个框横跨整行。
    ///
    /// **必须用 `.fast`。** `.accurate` 下 `boundingBox(for:)` 对一个词里的
    /// 每个字符返回的是**同一个框**（整个词的框）—— 这是 Apple 技术支持
    /// 确认过的 bug，只有 `.fast` 给逐字符的框。上一版默认走 `.accurate`，
    /// 于是所有字符的中心都一样、间距全是 0，按坐标补位那条路
    /// **一次都没真正跑起来过**。
    ///
    /// 顺带：`.fast` 走的是按字符识别，`.accurate` 走的是整行的序列模型 ——
    /// 对付票面上这种孤零零的个位数，前者本来就更合适。
    static func recognizeDigits(in image: UIImage,
                                fast: Bool = true) async -> [DigitChar] {
        guard let cgImage = image.cgImage else { return [] }
        let orientation = cgOrientation(image.imageOrientation)
        let results: [DigitChar] = await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = fast ? .fast : .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.02
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            guard (try? handler.perform([request])) != nil else { return [] }

            var chars: [DigitChar] = []
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                var index = text.startIndex
                while index < text.endIndex {
                    let next = text.index(after: index)
                    defer { index = next }
                    // 这里**不能**用 `digitValue` —— 它把圈码 `①` 认成数字 1，
                    // 于是票面左边那一竖排注序号会被当成一列号码。
                    guard let value = TicketTextParser.plainDigitValue(text[index]) else { continue }
                    // `try?` 会把 `throws -> VNRectangleObservation?` 压成一层 optional，
                    // 所以这里拿到的已经是非可选的观测结果，不要再点问号。
                    guard let rect = try? candidate.boundingBox(for: index..<next) else { continue }
                    chars.append(DigitChar(value: value, box: rect.boundingBox))
                }
            }
            return chars
        }.value
        return results.sorted { $0.box.midX < $1.box.midX }
    }

    /// 裁条里认出来的一小块数字。
    private struct DigitToken {
        let text: String
        let box: CGRect
    }

    /// 只收「落在条带正中间、而且只有数字」的碎片。
    ///
    /// 上下各留了 45% 余量，邻行的笔画会探进来一点；号码行左右也常有
    /// 括号里的倍数。这两样都不能混进号码。
    private static func digitTokens(in fragments: [TextFragment]) -> [DigitToken] {
        fragments.compactMap { fragment in
            guard (0.2...0.8).contains(fragment.box.midY) else { return nil }
            let text = fragment.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, TicketTextParser.isBareNumberLine(text) else { return nil }
            return DigitToken(text: text, box: fragment.box)
        }
    }

    /// 多个放大倍数的结果按位置合并，而不是取数字最多的那一遍。
    ///
    /// 宽间距的个位数最要命的地方是**每一遍漏掉的不是同一位**：
    /// 3 倍那遍读出 `8 4 1`，5 倍那遍读出 `4 1 5`，单看哪一遍都缺。
    /// 按横坐标取并集，缺的那两位就补回来了。
    ///
    /// 位置重叠的一律跳过 —— Vision 有时把一整排号码当成一个碎片返回，
    /// 它的框横跨整行，不跳过的话同一个号会被数两遍。
    private static func merge(_ incoming: [DigitToken], into tokens: inout [DigitToken]) {
        for token in incoming where !tokens.contains(where: { $0.box.intersects(token.box) }) {
            tokens.append(token)
        }
    }

    /// 这一行是不是一排号码。
    ///
    /// **不能按"数字占比"判。** 上一版就是这么判的，两头都错：
    ///
    /// - 「第26088期 2026年04月08日开奖」去掉空白后数字占 61%，被当成号码行，
    ///   于是拿旁边票号行的内容覆盖掉了它 —— 排列3 从此读不到期号。
    /// - 「组六: U 7」数字只占 20%，被当成不是号码行，于是**恰恰最需要**
    ///   二次识别的那一行被跳过了。
    ///
    /// 正确的判据是结构：摘掉行首的标签（`A.`、`①`、`组六:`）之后，
    /// 剩下的部分**一个汉字都不能有**。号码行天生满足，
    /// 而期号行、合计行、销售期行的汉字都夹在数字中间，天生不满足。
    static func looksLikeNumberRow(_ text: String) -> Bool {
        let body = text.replacingOccurrences(of: Self.rowLabelPrefix,
                                             with: "", options: .regularExpression)
        guard body.contains(where: { $0.isNumber }) else { return false }
        return !body.contains(where: isHan)
    }

    /// 号码行行首允许出现的标签。
    private static let rowLabelPrefix =
        // 字符类里直接写西里尔字面量。**不能写 `\\u{0410}`** ——
        // 那是 Swift 的字符串转义语法，ICU 正则不认，整个模式会静默失效，
        // 于是所有标签都摘不掉，`组六: U 7` 这种行永远被判成"不是号码行"。
        "^\\s*(?:组[六三选]|单选|直选|[A-Ea-eАВСЕ]\\s*[.。·:、)]|[①-⑮]|[(（]\\s*\\d{1,2}\\s*[)）])\\s*[:：]?\\s*"

    private static func isHan(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value)
    }

    private static func digitCount(_ text: String) -> Int {
        text.filter(\.isNumber).count
    }

    /// 保留原行开头的标签（`A.`、`组六:`、`①`），号码换成重认那一遍的。
    ///
    /// 标签必须留着 —— 玩法和注序号都在那里，而只认英数的那一遍读不出中文。
    ///
    /// 取的是**行首那个标签**，不是"第一个数字之前的全部内容"。
    /// `组六: U 7` 里那个 `U` 是把 `1` 认错了的残渣，留着它整行就废了：
    /// 拼出来的 `组六: U 1 8 9` 过不了"一位一个数字"那道闸，一注照样丢。
    private static func graft(prefix original: String, digits: String) -> String {
        let body = digits.trimmingCharacters(in: .whitespaces)
        guard let range = original.range(of: Self.rowLabelPrefix, options: .regularExpression) else {
            return body
        }
        let head = original[range].trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? body : "\(head) \(body)"
    }

    /// 票面最后一行**有意义的内容**通常带着这些词。
    ///
    /// 它们下面那一截 —— 条形码、以及「XX市福利彩票发行中心承销」这类落款 ——
    /// 核对时一点用都没有，却占掉预览框近一半高度。福彩票尤其明显：
    /// 落款那行字也会被 OCR 认出来，于是"所有文字的并集"把条码整个圈了进去。
    private static let footerAnchors = ["公益", "合计", "开奖期", "销售期", "兑奖", "有效期"]

    /// 丢掉落款行以下的碎片。
    ///
    /// 认不出任何锚点时原样返回 —— 宁可裁得松一点，也不能因为一条启发式规则
    /// 把号码那几行切掉。
    static func fragmentsAboveFooter(_ fragments: [TextFragment]) -> [TextFragment] {
        // Vision 的 y 向上为正，所以「更靠下」= minY 更小
        let anchors = fragments.filter { fragment in
            footerAnchors.contains { fragment.text.contains($0) }
        }
        guard let bottom = anchors.map(\.box.minY).min() else { return fragments }
        let kept = fragments.filter { $0.box.minY >= bottom - 0.005 }
        guard let full = span(of: fragments), let trimmed = span(of: kept) else { return fragments }
        // 砍掉一多半就不对劲了，多半是锚点认错了位置，退回原样更安全
        guard trimmed >= full * 0.5 else { return fragments }
        return kept
    }

    private static func span(of fragments: [TextFragment]) -> CGFloat? {
        guard let low = fragments.map(\.box.minY).min(),
              let high = fragments.map(\.box.maxY).max() else { return nil }
        return high - low
    }

    /// 按识别到的文字把图裁到内容区。
    ///
    /// Vision 的框是归一化坐标、原点在**左下角**，UIImage 是左上角，
    /// 所以 y 要翻过来。四周各留一点余量，免得贴着字边切、看着发憋。
    static func contentCrop(_ image: UIImage, fragments: [TextFragment]) -> UIImage? {
        guard !fragments.isEmpty, let cgImage = image.cgImage else { return nil }
        let kept = fragmentsAboveFooter(fragments)
        guard let first = kept.first else { return nil }
        let union = kept.dropFirst().reduce(first.box) { $0.union($1.box) }
        // 几乎占满整张图就没必要裁了，白费一次重绘
        guard union.width < 0.97 || union.height < 0.94 else { return nil }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let padX = width * 0.02
        let padY = height * 0.02
        var rect = CGRect(x: union.minX * width - padX,
                          // 归一化 y 向上，位图 y 向下
                          y: (1 - union.maxY) * height - padY,
                          width: union.width * width + padX * 2,
                          height: union.height * height + padY * 2)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width > 40, rect.height > 40,
              let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - 文字识别

    /// 一块识别出来的文字及其在画面里的位置。
    struct TextFragment: Sendable {
        let text: String
        /// Vision 归一化坐标，原点在**左下角**。
        let box: CGRect
        /// 这一块文字的**四个角**（Vision 归一化坐标，原点左下）。
        ///
        /// `VNRecognizedTextObservation` 继承自 `VNRectangleObservation`，
        /// 给的是四边形而不是正框 —— 里面自带这一行的走向和透视信息。
        ///
        /// 两个用处：
        /// 1. 上下两角连起来就是票面的倾角，投影方向照它来（`textTilt`）。
        /// 2. **它就是基准本身。** 机号行、公益行、福彩的哈希行和开奖期行，
        ///    Vision 每张票都读得出来；两行 8 个点，拟合单应绰绰有余。
        ///    比虚线可靠得多 —— 虚线要过五道阈值，这个一道都不用过。
        var topLeft: CGPoint?
        var topRight: CGPoint?
        var bottomLeft: CGPoint?
        var bottomRight: CGPoint?

        /// 上边那条线（左上 → 右上），左上原点的归一化坐标。
        var topEdge: (CGPoint, CGPoint)? {
            guard let topLeft, let topRight else { return nil }
            return (Self.flip(topLeft), Self.flip(topRight))
        }

        /// 下边那条线（左下 → 右下），左上原点的归一化坐标。
        var bottomEdge: (CGPoint, CGPoint)? {
            guard let bottomLeft, let bottomRight else { return nil }
            return (Self.flip(bottomLeft), Self.flip(bottomRight))
        }

        /// Vision 的 y 向上为正，翻成左上原点。
        static func flip(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: 1 - point.y)
        }
    }

    /// 票面还歪着多少 —— 用文字行自己的走向量出来。
    ///
    /// 返回的是**位图坐标系**下的斜率（y 向下为正），可以直接喂给
    /// `InkMask.binProfile`。Vision 的 y 向上，所以这里要取负号。
    ///
    /// 取中位数不取平均：票上总有几个歪的印章、手写签名，平均值会被拽跑。
    /// 太短的文字块量出来的角度噪声太大，按票面宽度的 8% 卡掉 ——
    /// 和 `TicketImagePreprocessor.deskewed` 用的是同一条判据。
    static func textTilt(_ fragments: [TextFragment], size: CGSize) -> Double? {
        guard size.width > 0, size.height > 0 else { return nil }
        var slopes: [Double] = []
        for fragment in fragments {
            guard let left = fragment.topLeft, let right = fragment.topRight else { continue }
            let dx = Double(right.x - left.x) * Double(size.width)
            let dy = Double(right.y - left.y) * Double(size.height)
            guard dx > Double(size.width) * 0.08 else { continue }
            slopes.append(-dy / dx)
        }
        guard slopes.count >= 3 else { return nil }
        let sorted = slopes.sorted()
        return sorted[sorted.count / 2]
    }

    static func recognizeFragments(in image: UIImage,
                                   languages: [String] = ["zh-Hans", "en-US"]) async throws -> [TextFragment] {
        guard let cgImage = image.cgImage else { throw ScanError.invalidImage }
        let orientation = cgOrientation(image.imageOrientation)

        // Vision 的 perform 是同步的，放到后台线程跑，避免阻塞主线程。
        let observations: [VNRecognizedTextObservation] = try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            // 彩票号码不是自然语言，语言纠正只会把号码改坏
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.008

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            try handler.perform([request])
            return request.results ?? []
        }.value

        let fragments = observations.compactMap { observation -> TextFragment? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return TextFragment(text: text, box: observation.boundingBox,
                                topLeft: observation.topLeft, topRight: observation.topRight,
                                bottomLeft: observation.bottomLeft,
                                bottomRight: observation.bottomRight)
        }
        guard !fragments.isEmpty else { throw ScanError.recognitionFailed }
        return fragments
    }

    /// 兼容旧调用：整张图当成一块，拼成逐行文本。
    static func recognizeText(in image: UIImage) async throws -> String {
        LayoutSegmenter.lines(try await recognizeFragments(in: image))
    }

    /// 拉一把对比度，顺手去色。
    ///
    /// 热敏票印在银灰色的纸上，票面反光、纸还是弯的 —— 有些笔画淡到
    /// 识别模型直接看不见。去色是因为票面本来就只有明暗，留着色度只会带进噪声。
    ///
    /// 不做二值化：阈值一刀切在票面明暗不均的时候会**吃掉整片笔画**，
    /// 比淡一点更糟。拉对比度是可逆的、温和的，认不出来还有原图那一遍兜着。
    static func contrastBoosted(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let filter = CIFilter.colorControls()
        filter.inputImage = CIImage(cgImage: cgImage)
        filter.saturation = 0
        filter.contrast = 1.7
        filter.brightness = 0.03
        guard let output = filter.outputImage,
              let result = TicketImagePreprocessor.context.createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: result)
    }

    /// 放大到 `factor` 倍，超限时**按比例收着放**而不是干脆不放。
    ///
    /// 上一版是超限直接返回 nil。票面本身已经被预处理放大过，
    /// 于是"号码行再认一遍"这条路在大图上**整个静默跳过**了 ——
    /// 明明是最该起作用的那些票。
    static func upscaled(_ image: UIImage, factor: CGFloat) -> UIImage? {
        let limit: CGFloat = 8000
        let longest = Swift.max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let capped = Swift.min(factor, limit / longest)
        // 已经够大了就原样用，总比一遍都不认强
        guard capped > 1.05 else { return image }
        let size = CGSize(width: image.size.width * capped, height: image.size.height * capped)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func cgOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}

/// 把识别出来的文字块按版面切成「一张票一块」。
///
/// 一张照片里放两三张票是很常见的（用户就是这么拍的）。如果先把所有文字块
/// 按纵坐标拼成一整篇文本，并排的两张票会被拼进**同一行** ——
/// 「红单:12 14 …」和另一张的「红复: 4 8 …」串在一起，两张票都读不出来。
///
/// 这里用的是版面分析里最经典的**递归 XY 切分**：先找横向上完全空白的
/// 竖直缝把左右分开，再找纵向上完全空白的横缝把上下分开，如此递归。
/// 「完全空白」这个条件很关键 —— 票面内部虽然也有大段留白（比如
/// 「玩法:双色球-复式」和右边的机号之间），但总有别的行横跨那个位置，
/// 所以不会被误切。
enum LayoutSegmenter {
    /// 缝隙要有多宽才算「两张票之间」，按当前这块的尺寸取比例。
    private static let columnGap: CGFloat = 0.055
    private static let rowGap: CGFloat = 0.045
    /// 一张票至少要有这么多块文字，否则不值得再切。
    private static let minimumFragments = 6
    private static let maximumDepth = 4

    static func blocks(from fragments: [TicketVisionScanner.TextFragment]) -> [String] {
        let groups = split(fragments, depth: 0)
        let texts = groups.map { lines($0) }.filter { $0.contains(where: \.isNumber) }
        return texts.isEmpty ? [lines(fragments)] : texts
    }

    private static func split(_ fragments: [TicketVisionScanner.TextFragment], depth: Int) -> [[TicketVisionScanner.TextFragment]] {
        guard depth < maximumDepth, fragments.count >= minimumFragments * 2 else { return [fragments] }
        if let parts = cut(fragments, vertical: true) ?? cut(fragments, vertical: false) {
            return parts.flatMap { split($0, depth: depth + 1) }
        }
        return [fragments]
    }

    /// 找一条把这组文字一分为二的空白缝。`vertical` 为真时找竖缝（左右分栏）。
    private static func cut(_ fragments: [TicketVisionScanner.TextFragment],
                            vertical: Bool) -> [[TicketVisionScanner.TextFragment]]? {
        let intervals = fragments.map { fragment -> (lower: CGFloat, upper: CGFloat) in
            vertical ? (fragment.box.minX, fragment.box.maxX)
                     : (fragment.box.minY, fragment.box.maxY)
        }.sorted { $0.lower < $1.lower }
        // 注意取的是所有区间里最大的 upper，不是最后一个区间的 —— 排序按的是 lower，
        // 最后一个区间未必伸得最远。
        guard let span = intervals.map(\.upper).max(),
              let start = intervals.first?.lower, span > start else { return nil }
        let threshold = (span - start) * (vertical ? columnGap : rowGap)
        guard threshold > 0 else { return nil }

        var reach = intervals[0].upper
        var bestCut: CGFloat?
        var widestGap: CGFloat = threshold
        for interval in intervals.dropFirst() {
            let gap = interval.lower - reach
            if gap > widestGap {
                widestGap = gap
                bestCut = reach + gap / 2
            }
            reach = Swift.max(reach, interval.upper)
        }
        guard let cut = bestCut else { return nil }

        let low = fragments.filter { (vertical ? $0.box.midX : $0.box.midY) < cut }
        let high = fragments.filter { (vertical ? $0.box.midX : $0.box.midY) >= cut }
        // 切出来两边都得像一张票，否则宁可不切
        guard low.count >= minimumFragments, high.count >= minimumFragments else { return nil }
        return [low, high]
    }

    /// 把一组文字块按纵坐标聚成行、行内按横坐标排序，拼成逐行文本。
    static func lines(_ fragments: [TicketVisionScanner.TextFragment]) -> String {
        rows(fragments).map(join).joined(separator: "\n")
    }

    /// 一行里的碎片按 x 排好拼成文本。
    static func join(_ row: [TicketVisionScanner.TextFragment]) -> String {
        row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
    }

    /// 这一行占的纵向区间。两遍识别靠它对齐同一行。
    static func band(_ row: [TicketVisionScanner.TextFragment]) -> ClosedRange<CGFloat> {
        let lower = row.map(\.box.minY).min() ?? 0
        let upper = row.map(\.box.maxY).max() ?? 0
        return Swift.min(lower, upper)...Swift.max(lower, upper)
    }

    /// 这一行占的横向区间，右边那一竖排机号不算在内。
    ///
    /// 号码印在票面左边，机号、流水号印在右边，中间隔着很宽一条空白。
    /// 按横坐标排开之后，第一个大缺口就是两者的分界 —— 只要左边这一簇。
    /// 裁条的时候拿它当右边界，机号就进不来了。
    static func columns(_ row: [TicketVisionScanner.TextFragment]) -> ClosedRange<CGFloat> {
        let sorted = row.sorted { $0.box.minX < $1.box.minX }
        guard let first = sorted.first else { return 0...1 }
        var lower = first.box.minX
        var upper = first.box.maxX
        for fragment in sorted.dropFirst() {
            guard fragment.box.minX - upper <= sideGap else { break }
            lower = Swift.min(lower, fragment.box.minX)
            upper = Swift.max(upper, fragment.box.maxX)
        }
        return Swift.min(lower, upper)...Swift.max(lower, upper)
    }

    /// 号码簇和机号之间至少有这么宽的空白。号码之间的间距远比它小。
    private static let sideGap: CGFloat = 0.12

    /// 把碎片按纵向位置聚成一行一行。
    static func rows(_ fragments: [TicketVisionScanner.TextFragment]) -> [[TicketVisionScanner.TextFragment]] {
        guard !fragments.isEmpty else { return [] }
        // Vision 的坐标原点在左下角，纵坐标要倒过来排
        let sorted = fragments.sorted { $0.box.midY > $1.box.midY }
        let averageHeight = fragments.map(\.box.height).reduce(0, +) / CGFloat(fragments.count)
        let tolerance = Swift.max(averageHeight * 0.6, 0.006)

        var rows: [[TicketVisionScanner.TextFragment]] = []
        for fragment in sorted {
            if var last = rows.last, let anchor = last.first,
               abs(anchor.box.midY - fragment.box.midY) <= tolerance {
                last.append(fragment)
                rows[rows.count - 1] = last
            } else {
                rows.append([fragment])
            }
        }
        return rows
    }
}
