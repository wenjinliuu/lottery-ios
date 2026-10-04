# AI 协作规则

- 业务与发布维护入口：`Engineering/maintenance.md`（实际开奖日历、复式命中渲染、密钥注入与上线顺序）。

- 本项目用 [ios-ci-workflows](https://github.com/wenjinliuu/ios-ci-workflows) 编译和测试；本地不跑 Xcode。改完代码 push，读 Build & Test 的测试报告再修。
- 新功能必须带测试；删测试、改断言的预期值必须在提交里写明理由。
- 有意改了界面：手动运行 Build & Test 并勾选 record_snapshots，再跑一次确认变绿，并说明改了哪些页面。
- 涉及 CloudBase 时，先执行 `npx skills add tencentcloudbase/cloudbase-skills` 并读取 cloudbase-guidelines。
- 部署只走 git → CI；MCP 只用来查数据、看日志、排查问题；AI 默认只连测试环境。
- 更多细节见 ios-ci-workflows 的 Skill：skills/ios-ci-workflows/SKILL.md。
- 截图和 UI 测试用 `--demo-data` 启动：内存里的示例票据（2026-06-01 至 09-27 的双色球、大乐透、七乐彩、七星彩），数据由 `Scripts/make-demo-data.py` 生成，不要手改 `DemoDataset.swift`。
- App Store 截图：手动运行 Build & Test 并勾选 record_snapshots，`AppStoreScreenshotTests` 会把五张图（首页、票夹、统计、扫描复核、设置）提交到 `Tests/LotteryWalletUITests/__Snapshots__/AppStoreScreenshotTests/`。
- 扫描复核截图要一张票据照片 `Tests/LotteryWalletUITests/Fixtures/review-ticket.jpg`；示例模式下预览图整张打马赛克。没有这张照片时扫描截图会跳过。
