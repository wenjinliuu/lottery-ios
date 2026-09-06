import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// 扫描纸质彩票：拍照或选图 → 本机 Vision 识别 → 复核 → 导入票夹。
struct TicketScanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(DrawStore.self) private var drawStore
    @Environment(\.showToast) private var showToast
    @Environment(\.celebrate) private var celebrate

    @State private var stage: Stage = .intro
    @State private var isCameraPresented = false
    @State private var photoItem: PhotosPickerItem?
    @State private var preview: UIImage?
    @State private var result: ScanResult?
    @State private var errorText: String?

    // 复核页可编辑字段
    @State private var editedIssue = ""
    @State private var editedMultiple = 1
    @State private var editedAddOn = false
    @State private var editedTickets: [ScannedTicket] = []
    @FocusState private var isIssueFocused: Bool

    enum Stage {
        case intro, scanning, review
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .intro: intro
                case .scanning: scanning
                case .review: review
                }
            }
            .background(Palette.canvas)
            .navigationTitle("扫描彩票")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                // 期号用的是数字键盘，没有回车键。不给一个"完成"，
                // 键盘弹起来之后就再也收不掉，底部的"加入票夹"被永久挡住。
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { isIssueFocused = false }
                }
            }
            // 复核页的错误（比如导入失败）原来只在入口页显示，等于静默失败
            .alert("操作没有完成", isPresented: .init(
                get: { errorText != nil && stage == .review },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("好", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraPicker { image in
                preview = image
                Task { await run(image) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    errorText = "这张图片读不出来"
                    return
                }
                preview = image
                await run(image)
            }
        }
    }

    // MARK: - 入口

    private var intro: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 6) {
                Text("把整张彩票放进取景框")
                    .font(.headline)
                Text("号码识别全部在这台设备上完成，照片不会上传，也不会保存。目前支持双色球、大乐透单式票。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Palette.warning)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 12) {
                Button("拍摄彩票") { isCameraPresented = true }
                    .buttonStyle(ProminentGlassButton(tint: .accentColor))
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("从相册选择", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .foregroundStyle(Color.accentColor)
                .glassPill(tint: .accentColor)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
    }

    private var scanning: some View {
        VStack(spacing: 20) {
            Spacer()
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    // 白色描边在浅色模式下等于没有，用系统分隔线色两种模式都看得见
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Palette.separator))
            }
            ProgressView()
            Text("正在本机识别号码…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
    }

    // MARK: - 复核

    @ViewBuilder
    private var review: some View {
        if let result, let game = result.game {
            ScrollView {
                VStack(spacing: 16) {
                    if !result.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(result.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(Palette.warning)
                            }
                        }
                        .contentCard(cornerRadius: 18, padding: 14)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: game.label, subtitle: "确认无误后加入票夹")
                        LabeledContent("期号") {
                            TextField("期号", text: $editedIssue)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                                .focused($isIssueFocused)
                        }
                        Stepper("倍数 \(editedMultiple)", value: $editedMultiple, in: 1...99)
                        if game == .dlt {
                            Toggle("追加投注", isOn: $editedAddOn)
                        }
                    }
                    .contentCard()

                    VStack(alignment: .leading, spacing: 12) {
                        // 这里是普通的 VStack，不是 List，本来就没有左滑删除。
                        // 原文案写"左滑可以删除"，用户会一直左滑却什么都不发生。
                        SectionHeader(title: "识别到 \(editedTickets.count) 注", subtitle: "点右侧减号删掉认错的一注")
                        ForEach(Array(editedTickets.enumerated()), id: \.element.id) { index, ticket in
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                TicketNumbersView(
                                    game: game,
                                    ticket: Ticket(numbers: ticket.numbers),
                                    size: 30
                                )
                                Spacer(minLength: 0)
                                Button {
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        editedTickets.removeAll { $0.id == ticket.id }
                                    }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                        // 图标本身只有 20pt 出头，够不上 44pt 的最小点击区
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("删除第 \(index + 1) 注")
                            }
                        }
                    }
                    .contentCard()

                    DisclosureGroup("查看识别原文") {
                        Text(result.rawText)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                    .contentCard(cornerRadius: 18)
                }
                .padding(.horizontal, 16)
                // 底栏走的是 safeAreaInset，内容已经被顶上去了，不用再垫 120
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Divider()
                    Text("\(editedTickets.count) 注 × \(editedMultiple) 倍 · \(MoneyText.format(Double(editedTickets.count) * game.unitPrice * Double(editedMultiple)))")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("重新扫描") { reset() }
                            .buttonStyle(SecondaryGlassButton(tint: game.tint))
                            .fixedSize()
                        Button("加入票夹") { importTickets(game: game) }
                            .buttonStyle(ProminentGlassButton(tint: game.tint, foreground: game.onTint, stroke: game.accent.solidStroke))
                            .disabled(editedTickets.isEmpty || editedIssue.isEmpty)
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 14)
                .background(.bar)
            }
        } else {
            ContentUnavailableView("没有识别到彩票", systemImage: "doc.questionmark",
                                   description: Text("请把整张票放进画面，避开反光和折痕，然后重试。"))
                .safeAreaInset(edge: .bottom) {
                    Button("重新扫描") { reset() }
                        .buttonStyle(ProminentGlassButton(tint: .accentColor))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                }
        }
    }

    // MARK: - 动作

    private func run(_ image: UIImage) async {
        stage = .scanning
        errorText = nil
        do {
            let scanned = try await TicketVisionScanner.scan(image)
            result = scanned
            editedIssue = scanned.issue
            editedMultiple = Swift.max(scanned.multiple, 1)
            editedAddOn = scanned.addOn
            editedTickets = scanned.tickets
            stage = .review
        } catch {
            errorText = error.localizedDescription
            stage = .intro
        }
    }

    private func reset() {
        stage = .intro
        result = nil
        preview = nil
        photoItem = nil
        editedTickets = []
        errorText = nil
        isIssueFocused = false
    }

    private func importTickets(game: GameKey) {
        // 扫描票绑定的是票面上印的期号，而不是"下一期"
        var target = drawStore.nextDrawTarget(for: game)
        if target.expect != editedIssue {
            target.expect = editedIssue
            target.openDate = result?.drawDate ?? target.openDate
            target.status = .confirmed
            target.source = "ticket_scan"
            target.isAvailable = true
            target.message = ""
        }

        let tickets = editedTickets.map { scanned -> Ticket in
            var ticket = Ticket(numbers: scanned.numbers,
                                playMode: game == .dlt ? (editedAddOn ? "add" : "normal") : "",
                                entryLabel: EntryKind.scan.label)
            ticket.addOn = game == .dlt && editedAddOn
            return ticket
        }

        let service = RecordService(context: context, drawStore: drawStore)
        do {
            try service.save(tickets: tickets,
                             game: game,
                             entryKind: .scan,
                             price: game.unitPrice,
                             multiple: editedMultiple,
                             target: target,
                             source: "ticket_scan")
            let checked = try? service.checkAll()
            showToast("已导入 \(tickets.count) 注", symbol: "checkmark.seal.fill")
            if let checked, checked.won > 0 { celebrate() }
            dismiss()
        } catch {
            errorText = "导入失败：\(error.localizedDescription)"
        }
    }
}

/// 系统相机。彩票是静态平面物体，用 UIImagePickerController 足够，
/// 也省掉一整套 AVCapture 会话管理。
struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onFinish: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onFinish: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }
    }
}
