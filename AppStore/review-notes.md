# App 审核信息 · 备注（App Review Notes）

用途：App Store Connect →「App 审核信息 → 备注」。上限 4000 字符。

**纯英文，不放中文摘要。** 审核队列以英文处理，中英各写一遍只是把 4000 字符
的预算花掉一半；真正需要中文的场合（中国区管局问询）也不会看这个字段。

每次提交前照文末的对照表复核一遍，避免备注和实现漂移。

---

## 可直接粘贴的正文

DEMO ACCOUNT: Not required. The app has no accounts, no login and no backend; every feature works on first launch.

WHAT THIS APP IS
"对个号" is an offline record-keeping utility for paper lottery tickets. The user types in, or photographs, the numbers printed on tickets they ALREADY hold, bought at licensed retail outlets in China. The app checks those numbers against published draw results and summarises the user's own record. It is a notebook and a calculator, nothing more.

Every field in the entry and scan-review screens is labelled as a transcription of the physical ticket rather than a choice the user is making: "票面玩法" (ticket play type), "票面类型" (single / multiple / dan-tuo TICKET), "票面倍数" (ticket multiplier), "票面追加" (the "add-on" line printed on a Da Le Tou ticket), "票面共 N 注" (N lines printed on the ticket) and "票面金额" (the amount printed on the ticket). The issue picker shows only draw progress ("待开奖" pending / "已开奖" drawn); it never shows sales status, a sales cut-off time or whether a draw can still be entered.

Changing the ticket type on the scan-review screen never silently rewrites the recognised numbers: single, multiple and dan-tuo tickets have genuinely different number structures, so the app hands the user back to manual entry with the ticket photo attached and asks them to re-enter from the printed ticket.

WHAT THIS APP DOES NOT DO (regarding Guideline 5.3 / 5.3.4)
- It does NOT sell, order, reserve, broker or facilitate the purchase of a ticket. There is no purchase entry point anywhere in the app.
- It handles NO money: no payment, wager, balance, top-up, prize redemption or In-App Purchase. The binary contains no StoreKit code.
- It does NOT predict, recommend or rank numbers, and gives no odds, trend, "hot/cold number" or strategy advice.
- The only outbound links are the Privacy Policy and Support pages listed in App Store Connect, reachable from Settings > About. There is no embedded web view and no third-party SDK.
- Automatic backup (Settings > Backup & Restore) writes a timestamped JSON snapshot into the app's OWN sandbox by default; it never leaves the device. Optionally the user can switch on "Store in iCloud", which writes the same file into the user's OWN iCloud Drive container. It uses iCloud Documents only - no CloudKit, no developer-accessible storage, no server of ours. The local SwiftData database is explicitly configured with `cloudKitDatabase: .none`, so the app performs no cross-device sync of any kind.
- Every amount shown is either the face value the user transcribed from their ticket ("票面金额"), or the published fixed prize tier of a ticket already drawn. It is a personal ledger, not a payout. The app holds no balance and displays no sales cut-off, "on sale" or "closed" state for any draw.
The app never places the user in a position to gamble. It only helps someone read a paper ticket they already hold.

ABOUT THE "FILL RANDOMLY" BUTTON
Manual entry has a small "随机填充" (fill randomly) button. It only populates the on-screen number pad so the user need not tap 6-7 digits by hand while copying a ticket; every number stays freely editable and nothing is submitted anywhere. It makes no claim about the likelihood of winning and is not a recommendation - it is a text-entry convenience.

HOW TO TEST (no photograph needed)
1. Tap the scan button at the right of the tab bar, then "手动录入" (Manual entry).
2. Choose a game (e.g. 双色球), tap any 6 red numbers and 1 blue number, then save.
3. The ticket appears in the "票夹" (Wallet) tab. Once that issue's result is available, matching numbers are highlighted and the prize tier is shown; "统计" then shows totals.
A sample ticket photograph is attached to this submission for testing recognition: save it into Photos and pick it from the album via the scan button. Recognition is only a convenience; every feature is reachable through manual entry.

PERMISSIONS
Camera and Photo Library are requested only when the user taps the scan button, to read the numbers printed on their own ticket. Text recognition runs entirely on-device via Apple's Vision framework. Photographs are never uploaded and never stored by the app.

NETWORKING AND PRIVACY
Apart from the optional "Store in iCloud" backup described above (user's own iCloud account, opt-in, off by default), the app makes exactly one kind of network request: an unauthenticated HTTPS GET for static public JSON files (official draw results and the yearly draw calendar) hosted at raw.githubusercontent.com. No user data, device identifier or usage information is ever transmitted. There is no analytics, no advertising and no server of our own - hence the privacy label declares "Data Not Collected".

DISCLAIMERS SHOWN IN THE APP
Disclaimers appear wherever a number is shown or entered, not only in an About page: beneath the draw numbers on Home; at the bottom of every single ticket card in the Wallet; on the scan entry, crop and recognition-review screens; and directly above the "加入票夹" (add to wallet) save button in manual entry. They state that recognition can be wrong and must be checked against the physical ticket, that the physical ticket and the official claim process govern any prize, and that this app does not sell tickets, does not buy them on the user's behalf and does not redeem prizes. The first time a record is saved - by either manual entry or scan import - a "理性购彩" (play responsibly) dialog repeats this and must be acknowledged before anything is written. Settings > About repeats the full statement, links to the Privacy Policy and Support pages, and asks users to buy only through licensed local retail channels and to play responsibly.

Support URL: https://wenjinliuu.github.io/lottery-ios/support.html
Privacy Policy: https://wenjinliuu.github.io/lottery-ios/

Thank you for your review. A video walkthrough is available on request.

---

## 与备注对应的代码事实（每次提交前复核）

| 备注里的断言 | 验证方式 |
| --- | --- |
| 无第三方 SDK | `project.yml` 无 `packages:` 段 |
| 无内购 / 无内嵌网页 | `grep -rn 'StoreKit\|WKWebView\|SFSafariViewController' LotteryWallet/` 为空 |
| 仅有的外链是隐私政策与技术支持 | `grep -rn 'Link(destination\|openURL' LotteryWallet/` 只应命中 `SettingsView.swift` 的两条 |
| 唯一网络端点 | `LotteryWallet/Data/LotteryDataClient.swift` 只有 raw.githubusercontent.com 一个 baseURL |
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
