# App 审核信息 · 备注（App Review Notes）

用途：App Store Connect →「App 审核信息 → 备注」。上限 4000 字符。

**纯英文，不放中文摘要。** 审核队列以英文处理，中英各写一遍只是把 4000 字符
的预算花掉一半；真正需要中文的场合（中国区管局问询）也不会看这个字段。

每次提交前照文末的对照表复核一遍，避免备注和实现漂移。

---

## 可直接粘贴的正文

DEMO ACCOUNT: Not required. No accounts or login; every feature works on first launch.

WHAT THIS APP IS
"对个号" is a local-first personal record-keeping utility, built by an independent developer with no affiliation to any lottery operator, issuer or government entity. The user types in, or photographs, the numbers printed on paper tickets they ALREADY own, bought in person at retail outlets. The app checks those numbers against published draw results and summarises the user's own spending. A notebook and a calculator, nothing more.

WHAT THIS APP DOES NOT DO (Guideline 5.3 / 5.3.4)
- It does NOT sell, order, reserve, broker or facilitate the purchase of a ticket. No purchase entry point anywhere; no draw is shown as "on sale" or "closed".
- It handles NO money: no payment, wager, balance, prize redemption or In-App Purchase (no StoreKit code).
- No number prediction, odds, trends or "hot/cold numbers".
- The only outbound links, all in Settings > About, are the Privacy Policy, Support, and the ICP filing number, which opens the MIIT filing lookup (beian.miit.gov.cn). No web view, no third-party SDK.
- Every amount shown is either printed on the user's ticket or the published prize of a drawn ticket.
- It does NOT present itself as, or on behalf of, any lottery operator: no operator names, logos or emblems, and no rules or prize tables republished from operators. Game names appear only as plain text, so entries match what is printed on the user's own ticket.

HOW TO TEST
A. Scan (sample ticket attached): save the attached image, marked "审核测试用票" (review test ticket, not a real ticket), to Photos. Tap the camera button at the right of the tab bar > "从相册选择" (Choose from Photos) and pick it. On the crop screen tap "重置" (Reset) so the frame covers the whole ticket, then "识别这张" (Recognise). The review screen shows Super Lotto issue 26082, 3 lines, add-on, x2, total 18 yuan. Tap "加入票夹" (Add to wallet). That draw is already published, so the Wallet shows the result immediately (no win; matched numbers highlighted).
B. Manual entry: camera button > "手动录入号码" (Manual entry). Choose a game, tap the numbers, pick an issue marked "已开奖" (drawn) to see a result right away, then "加入票夹".
The first save shows a "使用提示" (usage notice) that must be acknowledged. It says the app only records tickets the user already owns, does not sell or handle any money, and asks the user to spend responsibly.

PERMISSIONS
Camera and Photos are requested only from the scan button. Recognition runs on-device (Apple Vision). Photos are never uploaded or stored.

NETWORKING AND PRIVACY
The app downloads public draw results and the yearly draw calendar via unauthenticated HTTPS GET: first from our read-only endpoint on Tencent CloudBase (ap-shanghai.app.tcloudbase.com), falling back to a static mirror on raw.githubusercontent.com. They carry no user data, identifiers or tickets. No analytics, ads or accounts, hence "Data Not Collected".
Tickets are stored only on the device (SwiftData, CloudKit explicitly off). Backups are JSON files in the app's own sandbox; optionally ("自动备份到 iCloud", off by default) the same file goes to the user's own iCloud Drive (iCloud Documents only, no CloudKit).

DISCLAIMERS
Shown under the draw numbers on Home, on every ticket card, on the scan, crop and review screens, and above the save button. They say recognition can be wrong, the physical ticket is authoritative, results are for personal reference only, and the app does not sell, buy or handle any money. Settings > About repeats this and states that the app is an independent personal tool not affiliated with any lottery operator.

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
| 各处免责声明 | `grep -rn 'Disclaimer\.' LotteryWallet/`，文案集中在 `Design/Disclaimer.swift` |
| 保存按钮写的是「加入票夹」 | `grep -rn '加入票夹' LotteryWallet/` 命中 `EntryFlowView.swift` 与 `TicketScanView.swift` |
| 界面不出现销售状态 | `grep -rn '停售\|已截止\|可购买\|在售\|投注' LotteryWallet/ --include=*.swift` 只应命中注释与内部字段名，无用户可见字符串 |
| 票面类型三条路径同源 | `EntryMode.shape` / `ScanPlay.shape` / `EntryKind.shape` 全部返回 `TicketShape`，显示名只在 `Models/TicketShape.swift` |
| 首次保存「使用提示」两条保存路径都拦 | `grep -rn 'responsibleAcknowledged' LotteryWallet/` 应同时命中 `EntryFlowView.swift` 与 `TicketScanView.swift` |
| 公益金按彩种计提 | `GameKey.welfareRate`，比例由 `Tests/` 里的真实样票反推 |
| 「自动备份到 iCloud」默认关闭 | `AppSettings.iCloudBackupEnabled` 初值来自 `defaults.bool`，未设置即 false |
| 数据库不做任何云同步 | `ModelStore.makeContainer` 显式传 `cloudKitDatabase: .none` |
| iCloud 只用 Documents，不用 CloudKit | `LotteryWallet.entitlements` 的 `icloud-services` 只有 `CloudDocuments` |
| 不再提供奖级对照表 | `grep -rn 'PrizeTable' LotteryWallet/` 为空（1.2.0 (70) 因 5.2.1 被拒后删除） |
| 不点名发行机构、不说「官方」「兑奖」「购彩」 | `grep -rn '福彩\|体彩\|官方\|兑奖\|购彩' LotteryWallet/ --include=*.swift` 在用户可见字符串里为空（票面识别规则、注释除外）；「福彩3D」显示为「3D」 |
| 测试票导入后当场出结果 | 附件「审核测试用票」是大乐透 26082 期（2026-07-22 已开奖，开奖号 16 26 27 28 34 + 02 06）：三注分别中 1+0、1+0、0+0，**未中奖**；追加 2 倍、合计 18 元 |
| 扫描步骤里的「重置」 | 这张图自动框选会框到打码的二维码（`TicketImagePreprocessor.suggestedQuad` 取面积最大的矩形），点「重置」用整张内缩 8% 的默认框。自动框选修好后删掉这一句 |
| 首次保存弹「使用提示」 | 见上面「首次保存「使用提示」两条保存路径都拦」 |
| 附件 | 提交时附上 `Tests/LotteryWalletUITests/Fixtures/review-ticket.jpg` |
| 备案号 | 关于页最底部 `AboutView.icpFiling`（沪ICP备2026015335号-2A），点了打开 beian.miit.gov.cn；所有地区都显示 |
