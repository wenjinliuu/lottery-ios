# App 审核信息 · 备注（App Review Notes）

用途：App Store Connect →「App 审核信息 → 备注」。上限 4000 字符。

**纯英文，不放中文摘要。** 审核队列以英文处理，中英各写一遍只是把 4000 字符
的预算花掉一半；真正需要中文的场合（中国区管局问询）也不会看这个字段。

每次提交前照文末的对照表复核一遍，避免备注和实现漂移。

---

## 可直接粘贴的正文

DEMO ACCOUNT: Not required. The app has no accounts and no login; every feature works on first launch.

WHAT THIS APP IS
"对个号" is a local-first record-keeping utility for paper lottery tickets. The user types in, or photographs, the numbers printed on tickets they have ALREADY bought at licensed retail outlets in China. The app checks those numbers against published draw results and summarises the user's own spending. A notebook and a calculator, nothing more. Every entry field is labelled as a transcription of the physical ticket ("票面玩法", "票面倍数", "票面金额" = the play type, multiplier and amount printed on the ticket).

WHAT THIS APP DOES NOT DO (Guideline 5.3 / 5.3.4)
- It does NOT sell, order, reserve, broker or facilitate the purchase of a ticket. There is no purchase entry point anywhere in the app, and no draw is ever shown as "on sale" or "closed".
- It handles NO money: no payment, wager, balance, top-up, prize redemption or In-App Purchase. The binary contains no StoreKit code.
- It does NOT predict or recommend numbers; no odds, trends or "hot/cold numbers".
- The only outbound links, all in Settings > About, are the Privacy Policy, Support, and the ICP filing number, which opens the MIIT filing lookup (beian.miit.gov.cn). No web view, no third-party SDK.
- Every amount shown is either the amount printed on the user's ticket or the published prize of a ticket already drawn.

ABOUT "随机填充" (FILL RANDOMLY)
It only fills the on-screen number pad to save tapping while copying a ticket. Every number stays editable and nothing is submitted. A typing convenience, not a recommendation.

HOW TO TEST
A. Scan (sample ticket attached): save the attached image, marked "审核测试用票" (review test ticket, not a real ticket), to Photos. Tap the camera button at the right of the tab bar > "从相册选择" (Choose from Photos) and pick it. On the crop screen tap "重置" (Reset) so the frame covers the whole ticket, then "识别这张" (Recognise). The review screen shows Super Lotto issue 26082, 3 lines, add-on, x2, total 18 yuan, and confirms it matches the printed total. Tap "加入票夹" (Add to wallet). That draw is already published, so the Wallet shows the result immediately (this ticket did not win; matched numbers are highlighted).
B. Manual entry: camera button > "手动录入号码" (Manual entry). Choose a game, tap the numbers, pick an issue marked "已开奖" (drawn) to see a result right away, then "加入票夹".
The first save shows a "理性购彩" (play responsibly) notice that must be acknowledged.

PERMISSIONS
Camera and Photos are requested only from the scan button. Text recognition runs entirely on-device with Apple's Vision framework. Photos are never uploaded or stored.

NETWORKING AND PRIVACY
The app downloads public draw results and the yearly draw calendar with unauthenticated HTTPS GET requests: first from our read-only public data endpoint on Tencent CloudBase (ap-shanghai.app.tcloudbase.com), falling back to a static mirror on raw.githubusercontent.com. These requests carry no user data, identifiers or tickets. There is no analytics, advertising or account system, hence "Data Not Collected".
Tickets are stored only on the device (SwiftData, CloudKit explicitly off). Backups are JSON files in the app's own sandbox; optionally ("存到 iCloud", off by default) the same file goes to the user's own iCloud Drive (iCloud Documents only, no CloudKit).

DISCLAIMERS
Shown wherever numbers appear: under the draw numbers on Home, on every ticket card, on the scan, crop and review screens, and above the save button. They say recognition can be wrong, the physical ticket and official claim process govern any prize, and the app does not sell, buy or redeem tickets. Settings > About repeats this and asks users to buy only through licensed retail channels and play responsibly.

Support: https://wenjinliuu.github.io/lottery-ios/support.html
Privacy Policy: https://wenjinliuu.github.io/lottery-ios/

Thank you for your review.

---

## 与备注对应的代码事实（每次提交前复核）

| 备注里的断言 | 验证方式 |
| --- | --- |
| 无第三方 SDK | `project.yml` 无 `packages:` 段 |
| 无内购 / 无内嵌网页 | `grep -rn 'StoreKit\|WKWebView\|SFSafariViewController' LotteryWallet/` 为空 |
| 仅有的外链是隐私政策、技术支持和备案查询 | `grep -rn 'Link(destination\|openURL' LotteryWallet/` 只应命中 `SettingsView.swift` 的三条（`privacyURL`、`supportURL`、`icpLookupURL`） |
| 网络端点只有两个，都是公开只读 GET | `LotteryWallet/Data/V2/LotteryAPIClient.swift`：`cloudBase`（腾讯云 CloudBase，上海）为主、`github`（raw.githubusercontent.com）兜底；无 Authorization 头、无任何参数带用户数据。隐私政策第 04 节写的是同一件事 |
| 权限用途 | `project.yml` 的 NSCameraUsageDescription / NSPhotoLibraryUsageDescription |
| 随机填充只填选号盘 | `EntryFlowView.fillRandomSelection()` → `TicketBuilder.randomDigits` |
| 各处免责声明 | `grep -rn 'Disclaimer\.' LotteryWallet/`，文案集中在 `Design/Disclaimer.swift` |
| 保存按钮写的是「加入票夹」 | `grep -rn '加入票夹' LotteryWallet/` 命中 `EntryFlowView.swift` 与 `TicketScanView.swift` |
| 界面不出现销售状态 | `grep -rn '停售\|已截止\|可购买\|在售\|投注' LotteryWallet/ --include=*.swift` 只应命中注释与内部字段名，无用户可见字符串 |
| 票面类型三条路径同源 | `EntryMode.shape` / `ScanPlay.shape` / `EntryKind.shape` 全部返回 `TicketShape`，显示名只在 `Models/TicketShape.swift` |
| 理性购彩弹窗两条保存路径都拦 | `grep -rn 'responsibleAcknowledged' LotteryWallet/` 应同时命中 `EntryFlowView.swift` 与 `TicketScanView.swift` |
| 公益金按彩种计提 | `GameKey.welfareRate`，比例由 `Tests/` 里的真实样票反推 |
| 「存到 iCloud」默认关闭 | `AppSettings.iCloudBackupEnabled` 初值来自 `defaults.bool`，未设置即 false |
| 数据库不做任何云同步 | `ModelStore.makeContainer` 显式传 `cloudKitDatabase: .none` |
| iCloud 只用 Documents，不用 CloudKit | `LotteryWallet.entitlements` 的 `icloud-services` 只有 `CloudDocuments` |
| 奖级对照表不参与判奖 | `grep -rn 'PrizeTable' LotteryWallet/` 只应命中 `Features/Settings/` 下两个文件 |
| 测试票导入后当场出结果 | 附件「审核测试用票」是大乐透 26082 期（2026-07-22 已开奖，开奖号 16 26 27 28 34 + 02 06）：三注分别中 1+0、1+0、0+0，**未中奖**；追加 2 倍、合计 18 元 |
| 扫描步骤里的「重置」 | 这张图自动框选会框到打码的二维码（`TicketImagePreprocessor.suggestedQuad` 取面积最大的矩形），点「重置」用整张内缩 8% 的默认框。自动框选修好后删掉这一句 |
| 首次保存弹「理性购彩」 | 见上面「理性购彩弹窗两条保存路径都拦」 |
| 附件 | 提交时附上 `Tests/LotteryWalletUITests/Fixtures/review-ticket.jpg` |
| 备案号 | 关于页最底部 `AboutView.icpFiling`（沪ICP备2026015335号-2A），点了打开 beian.miit.gov.cn；所有地区都显示 |
