# App 审核信息 · 备注（App Review Notes）

用途：App Store Connect →「App 审核信息 → 备注」。上限 4000 字符。
英文在前（审核员默认语言），中文摘要在后。每次提交前核对一遍与代码是否仍然一致。

---

## 可直接粘贴的正文

DEMO ACCOUNT: Not required. This app has no accounts, no login and no backend. Every feature is available on first launch.

WHAT THIS APP IS
"彩票夹-号码记录" (Lottery Wallet - Number Records) is an offline personal record-keeping utility. The user types in, or photographs, the numbers printed on lottery tickets they have ALREADY purchased at licensed physical retail outlets in China. The app then checks those numbers against published draw results and summarises the user's own spending. It is a notebook and a calculator, nothing more.

WHAT THIS APP DOES NOT DO (regarding Guideline 5.3 / 5.3.4)
- It does NOT sell, order, reserve, broker or facilitate the purchase of a lottery ticket. There is no purchase entry point anywhere in the app.
- It handles NO money: no payment, no wager, no balance, no top-up, no prize redemption, no In-App Purchase. The binary contains no StoreKit code.
- It contains NO links, buttons, web views or deep links to any external website. The binary contains no WKWebView, no SFSafariViewController, no openURL call, and links zero third-party SDKs.
- It does NOT predict, recommend or generate numbers, and gives no odds, trend or "lucky number" advice of any kind.
- Every amount shown is either the ticket cost the user typed in themselves, or the published fixed prize tier of a ticket that has already been drawn. It is a personal ledger, not a payout.
The app never places the user in a position to gamble. It only helps someone read a paper ticket they already hold.

HOW TO TEST (no photograph needed)
1. Tap the scan button on the right of the tab bar, then choose "手动录入" (Manual entry).
2. Choose a game (e.g. 双色球 / Double Colour Ball), tap any 6 red numbers and 1 blue number, then save.
3. The ticket appears in the "票夹" (Wallet) tab. Once the draw result for that issue is available, the matching numbers are highlighted and the prize tier is displayed. The "统计" tab then shows the totals.
To test photo recognition, a sample ticket photograph is attached to this submission: save it into Photos, then use the scan button and pick it from the album. Recognition is only a convenience; every feature is reachable through manual entry.

PERMISSIONS
Camera and Photo Library are requested only at the moment the user taps the scan button, in order to read the numbers printed on their own ticket. Text recognition runs entirely on-device using Apple's Vision framework. Photographs are never uploaded and are never stored by the app.

NETWORKING AND PRIVACY
The app makes exactly one kind of network request: an unauthenticated HTTPS GET for static public JSON files (official draw results and the yearly draw calendar) hosted at raw.githubusercontent.com. No user data, device identifier or usage information is ever transmitted. There is no analytics, no advertising and no server of our own, which is why the privacy nutrition label declares "Data Not Collected".

DISCLAIMERS SHOWN IN THE APP
A disclaimer sits directly beneath the draw numbers on the Home screen: "开奖信息仅供参考，请以官方公布为准" (results are for reference only; official announcements prevail). A fuller statement under 设置 → 关于与免责声明 (Settings → About and Disclaimer) states that the app does not sell, broker or redeem tickets, that purchases should be made only through licensed local retail channels, and that users should play responsibly and within their means.

Support URL: https://wenjinliuu.github.io/lottery-ios/support.html
Privacy Policy: https://wenjinliuu.github.io/lottery-ios/

Thank you for your review. We are glad to provide a video walkthrough on request.

【中文摘要】
本应用是一款纯本地的彩票号码记录与核对工具，供用户记录自己已在合法线下渠道购买的彩票号码，并在开奖后自动比对、统计个人投入。应用不销售彩票、不代购、不提供任何购买入口，不涉及任何资金往来与内购，不做号码预测或推荐，也不含任何跳转到外部网站的链接或内嵌网页。无账号、无登录、无服务器，审核无需测试账号，首次启动即可使用全部功能：点击标签栏右侧扫描按钮 →「手动录入」即可创建一张彩票记录。相机与相册权限仅在用户主动点击扫描时调用，文字识别全部在设备本机通过 Vision 完成，照片不上传、不留存。应用唯一的网络请求是向 raw.githubusercontent.com 只读拉取公开的开奖结果与开奖日历静态文件，不携带任何用户信息，因此隐私标签声明为「不收集数据」。首页开奖号码下方与「设置 → 关于与免责声明」中均已标明开奖信息以官方公布为准、本应用不销售不代购不兑奖、请通过合法渠道理性购彩。

---

## 与备注对应的代码事实（每次提交前复核）

| 备注里的断言 | 验证方式 |
| --- | --- |
| 无第三方 SDK | `project.yml` 无 `packages:` 段 |
| 无内购 / 无 WebView / 无外链 | `grep -rn 'StoreKit\|WKWebView\|SFSafariViewController\|openURL' LotteryWallet/` 为空 |
| 唯一网络端点 | `LotteryWallet/Data/LotteryDataClient.swift` 只有 raw.githubusercontent.com 一个 baseURL |
| 权限用途 | `project.yml` 的 NSCameraUsageDescription / NSPhotoLibraryUsageDescription |
| 首页免责声明 | `LotteryWallet/Features/Home/HomeView.swift` |
| 设置页免责声明 | `LotteryWallet/Features/Settings/SettingsView.swift` |
