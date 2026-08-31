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
Scripts/make_appicon.py         生成 App 图标（无三方依赖）
LotteryWallet/
  App/                          入口、根标签栏、用户偏好
  Design/                       Liquid Glass 封装、配色、号码球、电子票纸张
  Models/                       彩种配置、号码、开奖、票据
  Rules/PrizeRules.swift        奖级判定（对照 web/rules.js 逐条移植）
  Data/                         数据仓库客户端、开奖状态、票据服务、备份
  Features/Home                 首页：盈亏折线、开奖轮播、本月概览、往期开奖
  Features/Wallet               票夹：电子票列表、筛选、核对
  Features/Entry                录入：随机 / 普通 / 复式 / 胆拖
  Features/Scan                 Vision 扫票与复核
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

## 液态玻璃写在哪里

所有 iOS 26 的 Liquid Glass 系统 API 只出现在 `LotteryWallet/Design/LiquidGlass.swift`，
页面代码一律走 `glassCard` / `glassPill` / `glassCircle` / `GlassGroup` 这些语义化封装。
SDK 若调整签名，改动范围锁在这一个文件里。

## CI

| Workflow | 触发 | 作用 |
| --- | --- | --- |
| `Build & Test` | push / PR | 生成工程、模拟器编译、跑单元测试 |
| `TestFlight` | 手动 / `v*` tag | 归档、签名、上传 TestFlight |

### TestFlight 需要的 Secrets

在仓库 `Settings → Secrets and variables → Actions` 添加：

| Secret | 说明 |
| --- | --- |
| `APPLE_TEAM_ID` | 10 位 Team ID（开发者账号 Membership 页面） |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API 密钥 ID |
| `APP_STORE_CONNECT_ISSUER_ID` | 同页面的 Issuer ID |
| `APP_STORE_CONNECT_PRIVATE_KEY` | `.p8` 私钥文件的完整内容（含 BEGIN/END 行） |

API 密钥在 App Store Connect → 用户和访问 → 集成 → App Store Connect API 创建，
角色至少选 **App Manager**（要让 `xcodebuild -allowProvisioningUpdates` 能自动创建证书和描述文件）。
只能下载一次，注意保存。

上传前需要先在 App Store Connect 建好 App 记录，Bundle ID 用 `com.wenjinliu.lotterywallet`
（要改的话同时改 `project.yml` 里的 `PRODUCT_BUNDLE_IDENTIFIER`）。

构建号默认取 GitHub run number，手动触发时也可以指定。

## 与 web 版的关系

两个版本共用同一份开奖数据契约和同一套奖级规则，同一张票在两端必须给出相同结论
（`Tests/LotteryWalletTests/PrizeRulesTests.swift` 就是照着 web 版的 `tests/prize-rules.test.js` 写的）。

备份文件互通：iOS 导出的 JSON 字段与 web 版一致，可以直接在网页端导入，反之亦然。
唯一差别是 web 版的 `checksum` 依赖 `JSON.stringify` 的逐字节结果，Swift 无法复现，
所以 iOS 导出不写 checksum（web 端只在字段存在时才校验），iOS 导入也只做结构与数值校验。

## 免责声明

本项目仅用于记录和辅助核对，不销售、不代购、不提供兑奖服务。
开奖结果以官方渠道公布为准。如需购买，请通过当地合法、正规的线下彩票销售渠道，理性参与。
