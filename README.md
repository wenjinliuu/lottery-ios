# 彩票夹 iOS

`lottery-web` 的 iOS 原生版：SwiftUI + Liquid Glass，本地优先的彩票记录与自动核对工具。
不销售、不代购彩票，只帮你把已经买好的票记下来、按官方开奖数据核对。

- **最低系统**：iOS 26（液态玻璃、`Tab` 新标签栏、SwiftData 都要求 26 起）
- **开奖数据**：只读取公开仓库 [`lottery-data-repo`](https://github.com/wenjinliuu/lottery-data-repo)，不需要任何 API key
- **票据存储**：SwiftData，只存在本机，没有账号也不上传
- **票面识别**：Apple Vision 在本机完成，照片不上传也不保存

## 目录结构

```
project.yml                     XcodeGen 工程定义（.xcodeproj 不入库）
Scripts/bootstrap.sh            本地生成并打开工程
DesignAssets/AppIcon/           App 图标原始 SVG 与图层说明
LotteryWallet/
  App/                          入口、根标签栏、用户偏好
  Design/                       Liquid Glass 封装、配色、号码球、电子票纸张
  Models/                       彩种配置、号码、开奖、票据
  Rules/PrizeRules.swift        奖级判定（对照 web/rules.js 逐条移植）
  Data/                         数据仓库客户端、开奖状态、票据服务、备份
  Resources/AppIcon.icon/       Xcode 直接编译的 Icon Composer 分层图标
  Features/Home                 首页：逐日盈亏方格图、开奖轮播、本月概览、往期开奖
  Features/Wallet               票夹：电子票列表、筛选、排序、核对
  Features/Entry                录入：手选 / 复式 / 胆拖，整票预览，期次选择日历
  Features/Scan                 扫票：人工框选 → 透视矫正 → 水平矫正 → Vision 识别 → 复核
  Features/Stats                统计
  Features/Settings             设置、备份、关于
Tests/LotteryWalletTests/       奖级、组合展开、票面解析的单元测试
```

## 本地开发

```bash
brew install xcodegen
./Scripts/bootstrap.sh --open
```

`.xcodeproj` 是生成物，不进版本库。改了 `project.yml` 或增删文件后重新跑一次即可。

## App 图标交接

图标已采用 A 方案：项目主蓝圆球（`#3B82F6`）与白色幸运星。原始图层在
`DesignAssets/AppIcon/`，可编译的分层包在 `LotteryWallet/Resources/AppIcon.icon/`；
后续开发无需重复生成，正常运行 Build 或 TestFlight workflow 就会自动带入最新版图标。

修改图形时先更新两个 SVG，再用 Apple Icon Composer 或 `icon-composer-mcp@1.1.0`
同步 `.icon` 包，并运行 `App Icon Preview` workflow。该 workflow 会返回六种苹果真实渲染、
营销 PNG 和一份完整 `.icon` 包作为 Artifact。编译产生的 `Assets.car`、IPA 不回写源码。

## 开奖日历

期号和开奖日期不在 App 里推算，来自数据仓库预生成的静态文件
`public_data/calendar/{year}.json`（八个彩种、全年每一期）。生成规则已用真实
开奖记录逐期比对验证；休市日单独维护在 `calendar/closures.json`，每年 12 月
补一次次年的春节日期即可（国庆固定 10-01 至 10-04）。

App 侧只读不算：`LotteryDataClient.fetchDrawCalendar(year:)` 拉取并缓存，
`DrawStore.nextDrawTarget` 顺着期次表找第一期还没停售的 —— 过了当期截止时间
自动落到下一期。

## 扫票流程

1. 拍照或选图
2. **人工框出票面**（矩形检测只提供四个角的初始位置，最终由用户确认）
3. 透视矫正 —— 按四个角把票拉成正矩形
4. 水平矫正 —— 量文字基线角度的中位数再转回来，透视矫正保证不了这一步
5. 放大到短边 1500px，Vision 本机识别
6. 按票面标签解析（红单/红复/红胆/红拖、前区胆/前区拖…），用票面「合计 N 元」
   反查注数做交叉验证
7. 逐张复核，号码球可点开改

一次一张票。解析规则由 23 张真实样票的单元测试锁定，每张都用票面印的金额
当独立答案验注数。

## 液态玻璃写在哪里

所有 iOS 26 的 Liquid Glass 系统 API 只出现在 `LotteryWallet/Design/LiquidGlass.swift`，
页面代码一律走 `glassCard` / `glassPill` / `glassCircle` / `GlassGroup` 这些语义化封装。
SDK 若调整签名，改动范围锁在这一个文件里。

## CI

| Workflow | 触发 | 作用 |
| --- | --- | --- |
| `Build & Test` | push / PR | 生成工程、模拟器编译、跑单元测试 |
| `App Icon Preview` | 图标变更 / 手动 | 用苹果 `ictool` 验证并导出六种图标外观 |
| `TestFlight` | 手动 / `v*` tag | 归档、签名、上传 TestFlight |

### TestFlight 需要的 Secrets

在仓库 `Settings → Secrets and variables → Actions` 添加：

| Secret | 说明 |
| --- | --- |
| `APPLE_TEAM_ID` | 10 位 Team ID（开发者账号 Membership 页面） |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API 密钥 ID |
| `APP_STORE_CONNECT_ISSUER_ID` | 同页面的 Issuer ID |
| `APP_STORE_CONNECT_PRIVATE_KEY` | `.p8` 私钥文件的完整内容（含 BEGIN/END 行） |

API 密钥在 App Store Connect → 用户和访问 → 集成 → App Store Connect API 创建**团队密钥**，
角色必须选 **Admin**。App Manager 不够：云端签名需要创建分发证书，而 App Store Connect
只允许 Admin 角色管理证书，否则 `exportArchive` 会报 `Cloud signing permission error`。
`.p8` 只能下载一次，注意保存。

上传前需要先在 App Store Connect 建好 App 记录，Bundle ID 用 `com.wenjinliu.lotterywallet`
（要改的话同时改 `project.yml` 里的 `PRODUCT_BUNDLE_IDENTIFIER`）。

构建号默认取 GitHub run number，手动触发时也可以指定。

签名分两步走：归档时关闭签名，导出时才用 App Store 分发身份签名并上传。
这么做是因为 Xcode 自动签名在归档阶段申请的是「开发」描述文件，而它必须绑定
一台已注册设备 —— CI 上没有设备可绑，会直接失败。分发签名不需要注册设备。

## 与 web 版的关系

两个版本共用同一份开奖数据契约和同一套奖级规则，同一张票在两端必须给出相同结论
（`Tests/LotteryWalletTests/PrizeRulesTests.swift` 就是照着 web 版的 `tests/prize-rules.test.js` 写的）。

备份文件互通：iOS 导出的 JSON 字段与 web 版一致，可以直接在网页端导入，反之亦然。
唯一差别是 web 版的 `checksum` 依赖 `JSON.stringify` 的逐字节结果，Swift 无法复现，
所以 iOS 导出不写 checksum（web 端只在字段存在时才校验），iOS 导入也只做结构与数值校验。

## 免责声明

本项目仅用于记录和辅助核对，不销售、不代购、不提供兑奖服务。
开奖结果以官方渠道公布为准。如需购买，请通过当地合法、正规的线下彩票销售渠道，理性参与。
