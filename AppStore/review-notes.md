# App 审核信息 · 备注（App Review Notes）

用途：App Store Connect →「App 审核信息 → 备注」。上限 4000 字符。

**纯英文，不放中文摘要。** 审核队列以英文处理，中英各写一遍只是把 4000 字符
的预算花掉一半；真正需要中文的场合（中国区管局问询）也不会看这个字段。

每次提交前照文末的对照表复核一遍，避免备注和实现漂移。

**措辞原则：直说这是彩票记录 App，主动交代全部功能。**
- 1.2.0 (70) 因 5.2.1（开发者不是彩票发行方）被拒。
- (71) 改成「个人票据记账本」、刻意少提彩票后，先因 2.3.1(a)「描述里没写彩票功能」被拒，
  随后被定为 5.6「审核期间故意隐藏功能」。
- 教训：商店描述和这份备注都要开门见山写明「记录用户自己的纸质彩票」；列出**完整功能清单**；
  写明没有远程开关、审核模式；本次构建改了什么也要写。不点名发行机构、不引用赌博类条款编号。
- 审核员手上没有实体票：测试步骤必须写清楚示例图片怎么用、手动录入怎么点，并附录屏。
- 商店描述的现行版本在 `AppStore/description.md`。

---

## 可直接粘贴的正文

REGARDING THE PREVIOUS GUIDELINE 5.6 DECISION
We have rewritten the App Description so that it states the app's purpose plainly and lists every feature. Nothing in the app is hidden, enabled remotely, or different during review. Changes in this build:
- Removed "随机填充" (fill randomly) from manual entry. The app no longer generates numbers; it only records numbers printed on the user's ticket.
- The sample-data mode used by our automated screenshot tests now exists only in test builds and is not in this release binary.

WHAT THE APP IS
A local record-keeping tool for paper lottery tickets that users have already bought offline. The user photographs a ticket (or types the numbers in by hand); the app recognizes and stores the numbers on the device, checks them against publicly published draw results, and summarizes the user's own spending and winnings. Supported games: 双色球, 大乐透, 快乐8, 3D, 排列3, 排列5, 七乐彩, 七星彩. The developer is an independent individual, not affiliated with any lottery operator.

Complete feature list (the same as the App Description; nothing else exists):
1. Home: the user's income and expense summary, and the latest published results ("更多" shows past results).
2. Wallet: the user's saved tickets and whether each one won; tickets can be edited or deleted.
3. Add a ticket: scan a photo on the device, or enter the numbers manually.
4. Statistics: spending and winnings by month and by game.
5. Settings: auto-check, appearance, data status, refresh results, backup and restore (optionally to the user's own iCloud Drive), a scan debug overlay toggle, and the About page.

There is no remote configuration, feature flag, review-only mode or time-based unlock. The server only provides public draw results as read-only data.

WHAT THE APP DOES NOT DO
It does not sell tickets, accept bets, process payments, offer number predictions or recommendations, or link to any purchasing channel. There is no In-App Purchase, no web view and no third-party SDK. No account or login is required, and all data stays on the device.

HOW TO REVIEW (no physical ticket needed)
A screen recording of the complete flow is attached.
A. Scan the attached sample ticket: save the attached image (a sample marked "审核测试用票") to Photos. In the app, tap the camera button at the right end of the tab bar, then "从相册选择" (Choose from Photos), and pick the image. On the crop screen tap "重置" (Reset), then "识别这张" (Recognize). The review screen shows Super Lotto issue 26082, 3 lines, add-on, x2, total 18 yuan. Tap "加入票夹" (Add to wallet). That draw has already been published, so the Wallet tab shows the result immediately.
B. Manual entry: camera button > "手动录入号码" (Manual entry). Pick a game, tap the numbers, choose an issue marked "已开奖" (published), then tap "加入票夹".
The first save shows a "使用提示" (usage notice) that must be acknowledged.

PRIVACY
Camera and Photos are used only after the user taps the scan button. Recognition is on-device; photos are never uploaded or stored. Draw results are downloaded via unauthenticated HTTPS GET from our read-only endpoint on Tencent CloudBase (ap-shanghai.app.tcloudbase.com), falling back to a static mirror on raw.githubusercontent.com. Requests contain no user data. No analytics, ads or accounts.

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
| 已删除随机填充，App 不生成号码 | `grep -rn 'fillRandom\|randomDigits\|pickUnique' LotteryWallet/` 为空 |
| 示例模式不进正式包 | `DemoData.isEnabled`、`DemoData.scanImage`、`AppClock.now` 的启动参数分支都在 `#if DEBUG` 里；归档用 Release |
