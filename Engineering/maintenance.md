# App 维护说明（维护者与 AI）

先读根目录 `AGENTS.md`。编译/测试使用 `ios-ci-workflows`，本地不跑 Xcode；部署/TestFlight 走 git → CI。修复业务行为带回归测试，不能删断言来让 CI 变绿。

## 开奖数据与首页

- `LotteryAPIClient` 请求云端主源/GitHub 兜底，镜像通常次日更新；只对云端发读取密钥，跨域重定向移除它。`LotteryRepository` 负责缓存、去重、降级，V2 DTO/Mapper 负责共同契约，`DrawStore` 提供页面查询。
- 最新开奖首屏取 bootstrap；首页另调用 `loadCalendar(year:)`，年度日历缓存并去重，不拉全部彩种历史。
- “今日开奖”匹配北京时间当天在年度日历中的实际 `drawDate`，不得使用 `schedule.weekdays` 或硬编码星期兜底。休市和调期会使星期错误，日历未加载/失败时不显示确定性标记。
- “已过开奖时刻但未更新”使用同一实际条目的开奖时刻。日历到达后 `calendarRevision` 改变 `scheduleToken`，首页必须重算。
- 日历缺下半年先排查源端分页和完整性，云端不完整可回落 GitHub。回归：`HomeDrawCalendarTests`、`DrawCalendarTests`、`ProgressiveLoadingTests`。

## 票夹号码命中

- 复式/胆拖展开成多注，由 `PrizeRules` 逐注计算 `matched` 和奖金。`TicketCard.wholeZones` 还原整票选号并汇总真正命中的号，视图只读纯值快照，不在渲染时查询 SwiftData。
- `WholeZone.hits` 表示命中的号码；`WholeZone.hasResult` 表示完整逐球标记是否存在。零命中不等于未核对。
- `WalletTicketCard.wholeRow` 用 `zone.hasResult` 决定置灰，禁止用 `!zone.hits.isEmpty`，否则蓝球/后区全未命中仍呈彩色，看起来像全中。
- 未开奖票保留正常颜色；已结算却缺标记的旧导入票由 RecordService 修复标记，不伪造命中/奖金来修显示。
- 回归：`WholeTicketMatchTests` 覆盖双色球蓝球零命中、大乐透后区零/部分/全部命中、胆拖与未核对票；奖金/注数另见 `TicketCardPrizeTests`。

## 读取密钥与发布

- 两个仓库各保存同值 Repository Actions Secret `LOTTERY_READ_API_KEY`：32–128 位英文字母、数字、`_`、`-`，推荐 64 位随机十六进制，不写进源码/参数/日志。
- TestFlight 调用中央 `APP_RUNTIME_API_KEY` Secret 输入，仅归档准备步骤获得密钥。`Scripts/write-api-config.py` 在 XcodeGen 前生成 gitignore 的 `GeneratedLotteryReadKey.swift`。
- 密钥字符串编入安装包，没有额外加密或 Keychain 存储；HTTPS 保护传输。它可被提取，不能证明官方 App 身份。云管理凭据和上游密钥绝不能进入安装包。
- Build & Test 不获得生产读取密钥，合成密钥验证请求头；归档缺密钥必须阻断。生产密钥不得进入公开模拟器产物或测试截图。
- 首次启用/轮换先构建并安装新 App，再部署云端对应密钥。
- 发布前读 CI 测试报告、截图/无障碍信息并核对签名/Bundle ID。上传成功后还需确认 Apple 处理状态，排队或归档成功不等于 TF 可安装。
- 首页/票夹视觉状态改变时按 AGENTS.md 录制快照再跑检查。示例数据通过指定脚本生成，不手改 `DemoDataset.swift`。

构建细节见 `docs/API_ACCESS.md`；服务端维护入口为开奖仓库 `docs/MAINTENANCE.md`。
