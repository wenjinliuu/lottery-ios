# App 审核信息 · 备注（App Review Notes）

用途：App Store Connect →「App 审核信息 → 备注」。上限 4000 字符。

**纯英文，不放中文摘要。** 审核队列以英文处理，中英各写一遍只是把 4000 字符
的预算花掉一半；真正需要中文的场合（中国区管局问询）也不会看这个字段。

每次提交前照文末的对照表复核一遍，避免备注和实现漂移。

**措辞原则：直说这是彩票记录 App。**
- 1.2.0 (70) 因 5.2.1（开发者不是彩票发行方）被拒。
- 1.2.0 (71) 改成「个人票据记账本」、刻意少提彩票后，又因 2.3.1(a) 被拒：
  「App 含有商店描述里没写的彩票功能」，即被当成隐藏功能。
- 所以：商店描述和这份备注都要**开门见山写明「记录和核对用户自己的纸质彩票」**，列出支持的
  玩法；同时写明不卖票、不碰钱、与任何彩票机构无关。不点名发行机构、不引用赌博类条款编号，
  这两条仍然保留。商店描述的现行版本在 `AppStore/description.md`。

---

## 可直接粘贴的正文

DEMO ACCOUNT: Not required. No accounts or login; every feature works on first launch.

WHAT THIS APP IS
"对个号" is a record-keeping and result-checking app for paper LOTTERY TICKETS the user has already bought in person at retail outlets. This is stated in the App Store description. The user enters, or photographs, the numbers printed on their own ticket; when results are published, the app checks the ticket, highlights matched numbers and the prize tier, and keeps a summary of the user's own spending and winnings. Supported games: 双色球, 大乐透, 快乐8, 3D, 排列3, 排列5, 七乐彩, 七星彩.

The developer is an independent individual. The app is not affiliated with, endorsed by, or acting for any lottery operator or government entity, and uses no operator's name, logo or materials.

WHAT IT DOES NOT DO
- No selling, ordering or buying on anyone's behalf; no purchase links or entry points.
- No money of any kind: no payments, balances, prize claims or In-App Purchase (no StoreKit code).
- No predictions, odds, trends or number recommendations.
- No web view, no third-party SDK. The only outbound links (Settings > About) are the Privacy Policy, Support, and the ICP filing number, which opens beian.miit.gov.cn.
- Amounts shown are only those printed on the user's own tickets, or results already published.

HOW TO TEST
A. Scan (sample lottery ticket image attached, marked "审核测试用票", a review sample): save it to Photos. Tap the camera button at the right of the tab bar > "从相册选择" (Choose from Photos) and pick it. On the crop screen tap "重置" (Reset), then "识别这张" (Recognise). The review screen shows issue 26082, 3 lines, x2, total 18 yuan, matching the printed total. Tap "加入票夹" (Add to wallet); the result appears in the Wallet right away.
B. Manual entry: camera button > "手动录入号码" (Manual entry). Pick a type, tap the numbers, choose an issue marked "已开奖" (published), then "加入票夹".
The first save shows a "使用提示" (usage notice): the app only records tickets the user already owns, does not sell anything or handle money, and asks users to spend responsibly.

PERMISSIONS, NETWORK AND PRIVACY
- Camera and Photos are requested only from the scan button. Recognition runs on-device (Apple Vision); photos are never uploaded or stored.
- Public results and the yearly calendar are downloaded via unauthenticated HTTPS GET from our read-only endpoint on Tencent CloudBase (ap-shanghai.app.tcloudbase.com), with a static mirror on raw.githubusercontent.com as fallback. Requests carry no user data or identifiers. No analytics, ads or accounts, hence "Data Not Collected".
- Records stay on the device (SwiftData, CloudKit off). Backups are JSON files in the app sandbox; optionally ("自动备份到 iCloud", off by default) copied to the user's own iCloud Drive (iCloud Documents only, no CloudKit).

DISCLAIMERS
Short notes on Home, on every record card, on the scan screens and above the save button say recognition can be wrong, the paper ticket is authoritative, and results are for personal reference only. Settings > About repeats this and states that the app is an independent personal tool.

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
