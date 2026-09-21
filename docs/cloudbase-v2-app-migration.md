# 对个号 iOS：CloudBase API V2 迁移与渐进式加载要求

> 本文是交给 Claude 的实施文档。请先完整阅读本文和现有工程，再开始修改代码。  
> 目标仓库：`wenjinliuu/lottery-ios`  
> 修改范围：仅 iOS App 的公共开奖数据读取层及相关 UI 状态，不修改 CloudBase 服务端和数据仓库。

## 1. 最终目标

将 App 的公共开奖数据从旧 GitHub `public_data` 静态文件迁移到腾讯云 CloudBase API V2。

数据源优先级固定为：

1. CloudBase V2 API
2. GitHub `public_data/v2` 静态文件
3. App 本地磁盘缓存
4. 全部不可用时显示局部错误和重试入口

CloudBase PostgreSQL 是当前数据真相。GitHub V2 是延迟灾备源，不是主数据源。

生产代码直接迁移到 V2，不再接入 V1；不得把不同来源的数据拼接成一次响应。

## 2. 实施前先检查

开始修改前，完整阅读并追踪以下内容：

- `LotteryWallet/Data/LotteryDataClient.swift`
- `DrawStore` 及其 `bootstrap()` 加载链路
- 首页最新开奖展示
- 各彩种历史开奖页面
- “查看更多”“查看全部”和按年份浏览
- 开奖日历、期号及日期判断
- 当前本地缓存和错误处理
- `LotteryType`、开奖模型及 `k8` 映射
- Widget 或其他扩展是否复用开奖模型
- 相关单元测试与 CI

先给出简短的现状分析，再采用最小、清晰、可测试的改造。不要顺带重做 UI，也不要破坏票夹、OCR、选号、核对、统计或用户本地记录。

## 3. 正式接口

CloudBase 基础地址：

```text
https://wenjin-cloudbase-d1empq882391ac1-1311287495.ap-shanghai.app.tcloudbase.com/lottery
```

只使用公开 GET 接口。App 不需要、也不得包含任何服务端密钥。

### 3.1 冷启动：首页合集

```http
GET /v2/bootstrap
```

响应包含：

- 所有彩种最新一期开奖
- 各彩种开奖星期、开奖时间、销售截止时间
- 推算的下一期开奖信息

大致结构：

```json
{
  "schema": "duigehao.lottery.bootstrap",
  "version": 2,
  "generated_at": "ISO-8601",
  "timezone": "Asia/Shanghai",
  "latest": {
    "ssq": {
      "issue": "2026100",
      "date": "2026-09-20",
      "time": "21:15",
      "numbers": {},
      "pool": "optional",
      "sales": "optional",
      "prizes": [],
      "fetched_at": "optional"
    }
  },
  "schedule": {
    "ssq": {
      "name": "双色球",
      "weekdays": [2, 4, 7],
      "draw_time": "21:15",
      "sale_close_time": "20:00",
      "next": {
        "issue": "2026101",
        "date": "2026-09-22",
        "open_time": "21:15",
        "buy_end_time": "20:00",
        "status": "inferred",
        "source": "schedule_inference",
        "confirmed": false,
        "basis_issue": "2026100"
      }
    }
  }
}
```

JSON 会省略空值和空字段。Swift DTO 必须对 `time`、`pool`、`sales`、`prizes`、`fetched_at` 等字段使用 Optional 或安全默认值。

`schedule.next` 可能只是日历推算结果：

- `confirmed == false`：只能显示为“预计/推算”
- `status == unavailable`：不要强行生成或展示下一期
- 不得把推算数据包装成官方确认数据

### 3.2 最近开奖

```http
GET /v2/draws/{lottery_type}
```

服务端最大返回最近 30 期。不要继续按 50 期设计。

```json
{
  "schema": "duigehao.lottery.draws",
  "version": 2,
  "lottery_type": "ssq",
  "generated_at": "ISO-8601",
  "limit": 30,
  "draws": []
}
```

单条开奖数据：

```json
{
  "issue": "2026100",
  "date": "2026-09-20",
  "time": "21:15",
  "numbers": {},
  "pool": "optional",
  "sales": "optional",
  "prizes": [
    {
      "name": "一等奖",
      "match": "optional",
      "winners": "optional",
      "amount": "optional",
      "extra_winners": "optional",
      "extra_amount": "optional"
    }
  ],
  "fetched_at": "optional"
}
```

`numbers` 会随彩种变化。建立 V2 DTO → App Domain Model 转换层，不要让网络 JSON 结构侵入所有 SwiftUI 页面。

### 3.3 按年历史

```http
GET /v2/by-year/{lottery_type}/{year}
```

```json
{
  "schema": "duigehao.lottery.by-year",
  "version": 2,
  "lottery_type": "ssq",
  "year": 2026,
  "generated_at": "ISO-8601",
  "draws": []
}
```

### 3.4 年度开奖日历

```http
GET /v2/calendar/{year}
```

```json
{
  "schema": "duigehao.lottery.calendar",
  "version": 2,
  "year": 2026,
  "generated_at": "ISO-8601",
  "entries": [
    {
      "lottery_type": "ssq",
      "issue": "2026100",
      "date": "2026-09-20",
      "draw_time": "21:15",
      "sale_close_time": "20:00"
    }
  ]
}
```

年度日历用于具体日期、期号、节假日、休市和调整日期判断。普通星期规则可读 `bootstrap.schedule.weekdays`。

不要重新引入已经删除的“下期信息及开奖星期同步函数”。

### 3.5 健康检查

```http
GET /v2/health
```

只用于调试、诊断或设置页。不得作为冷启动前置条件，也不得在每次启动时额外请求。

## 4. 彩种映射

远程 API 标识：

```text
ssq, dlt, kl8, fc3d, pl3, qlc, qxc, pl5
```

App 内部快乐8目前可能使用 `k8`，远程使用 `kl8`。必须集中映射：

```text
App k8 ↔ API kl8
```

建议由统一的 `LotteryType` 扩展提供：

- 本地标识
- API 标识
- GitHub 文件标识
- 显示名称

禁止在多个页面散落字符串替换。

## 5. GitHub V2 兜底

基础地址：

```text
https://raw.githubusercontent.com/wenjinliuu/lottery-data-repo/main/public_data/v2
```

映射关系：

| CloudBase | GitHub V2 |
| --- | --- |
| `/v2/bootstrap` | `/public_data/v2/bootstrap.json` |
| `/v2/draws/{type}` | `/public_data/v2/draws/{type}.json` |
| `/v2/by-year/{type}/{year}` | `/public_data/v2/by-year/{type}/{year}.json` |
| `/v2/calendar/{year}` | `/public_data/v2/calendar/{year}.json` |

CloudBase 和 GitHub V2 必须复用同一套 DTO、Decoder 和转换层。

迁移完成后，不再把以下旧文件作为生产数据源：

```text
/public_data/latest.json
/public_data/calendar.json
/public_data/draws/*.json
```

## 6. 渐进式读取：强制要求

### 6.1 冷启动

冷启动只请求：

```http
GET /v2/bootstrap
```

冷启动禁止：

- 请求八个彩种的最近 30 期
- 请求任何年度历史
- 请求全部年度日历
- 请求 health
- 预加载用户尚未打开的历史页面

现有 `DrawStore.bootstrap()` 如果会加载 latest、calendar、health、全部历史或所有年度日历，必须拆分。

### 6.2 “查看更多”或进入单一彩种历史页

只请求当前彩种：

```http
GET /v2/draws/{lottery_type}
```

例如进入双色球历史，只请求 `/v2/draws/ssq`，不得同时请求其他七个彩种。

### 6.3 “查看全部”

用户点击“查看全部”时，才请求当前彩种当前年度：

```http
GET /v2/by-year/{lottery_type}/{currentYear}
```

将最近 30 期和年度数据按 `lotteryType + issue` 去重，按日期与期号倒序。

### 6.4 继续查看往年

用户滚动到底、点击“加载上一年”或切换具体年份时，一次只加载一个年份：

```text
当前年 → 前一年 → 再前一年
```

为每个彩种分别维护：

- 已加载年份
- 正在加载年份
- 年份错误
- 是否还有更早数据

同一彩种同一年不得重复请求。

### 6.5 日历

只在日历页面或实际业务判断需要时加载指定年份。默认按需加载当前年；临近年末且 UI 确实需要时，才加载下一年。

禁止冷启动加载所有年份。

## 7. 推荐数据层职责

命名可以适配现有项目，但职责必须清晰。

### LotteryAPIClient

负责：

- 构造 V2 URL
- GET 请求、超时与 HTTP 状态校验
- 解码 V2 DTO
- CloudBase → GitHub V2 在线降级
- 不涉及 SwiftUI 页面状态

### LotteryCache

按 endpoint 维度缓存，建议键名：

```text
v2-bootstrap
v2-draws-{lotteryType}
v2-year-{lotteryType}-{year}
v2-calendar-{year}
```

要求：

- 原子写入
- 记录缓存时间
- 单个缓存损坏时安全忽略
- 不因一个文件损坏清空全部缓存
- 已结束年份可以长期保存
- 过期缓存不立即删除，网络失败时仍可展示

### LotteryRepository

统一执行：

```text
先读取可展示缓存
→ 尝试 CloudBase V2
→ CloudBase 失败后尝试 GitHub V2
→ 两个在线源都失败时继续使用本地缓存
```

一次请求选择一个成功数据源，不混拼来源。可返回数据来源用于日志：

```swift
enum LotteryDataSource {
    case cloudBase
    case githubFallback
    case localCache
}
```

### DrawStore

负责：

- bootstrap 状态
- 各彩种最近 30 期
- 各彩种已加载年份
- 各 endpoint 的 loading/error 状态
- 去重、排序和页面状态
- 在 `MainActor` 更新 UI

不要用一个全局 `isLoading` 阻塞所有页面。至少拆分 bootstrap、最近开奖、年度历史和日历状态。

## 8. 缓存与刷新

参考服务端缓存时间：

| 数据 | 建议刷新间隔 |
| --- | --- |
| bootstrap | 约 60 秒 |
| 最近 30 期 | 约 60 秒 |
| 按年历史 | 约 1 小时 |
| 年度日历 | 约 24 小时 |

行为要求：

- 有缓存时立即展示，再后台刷新
- 缓存过期只表示应该刷新，不表示必须删除
- 刷新失败时保留旧数据
- 已结束年份基本不变，可长期缓存
- 当前年份可以定期刷新
- 缓存使用临时文件 + 原子替换
- 缓存读取和网络请求不阻塞主线程

## 9. 请求去重、并发和取消

SwiftUI 的 `.task` 或 `onAppear` 可能多次触发，必须做到：

- 相同 endpoint 的并发请求合并或复用
- 同一彩种最近开奖不重复请求
- 同一彩种同一年不重复请求
- 已加载且未要求刷新时不再次请求
- 下拉刷新只刷新当前页面的数据
- 页面消失时允许取消纯 UI 触发且已无用途的任务
- UI 状态更新在 `MainActor`
- 优先使用现有 async/await，不引入不必要的第三方网络库

## 10. 错误和降级体验

### 有缓存、刷新失败

继续显示缓存，只给轻量提示；不得清空列表或用全屏错误覆盖现有内容。

### CloudBase 失败、GitHub 成功

正常显示 GitHub V2 数据，并在调试日志中记录 fallback。用户无需手动切换。

### 在线源和缓存都不可用

显示当前区域的空状态与重试按钮。只重试当前页面需要的数据，不得因某个历史年份失败影响首页。

内部应区分网络不可达、超时、非 2xx、解码失败、空数据和缓存损坏；用户文案保持简洁。

## 11. 安全要求

公开只读接口不需要 API Key。

绝对禁止：

- 在 App 中加入 `CLOUDBASE_API_KEY`
- 在 App 中加入 `JISU_APPKEY`
- 从 GitHub Secrets 动态读取服务端密钥
- 将抓取或部署密钥打包进 App
- 日志输出密钥、令牌或敏感 Header

这些密钥只属于服务端、抓取任务或 GitHub Actions。

## 12. 兼容现有功能

不得破坏：

- SwiftData 中的用户票据和号码
- 选号、OCR、扫描、核对
- 提醒、统计和用户配置
- 旧版本本地数据
- Widget 或扩展
- 现有视觉风格

网络 DTO 与业务模型分离：

```text
V2 DTO → Domain Model → Store / SwiftUI
```

如果必须调整持久化模型，先确保旧数据可兼容读取，并提供迁移；不得造成用户记录丢失。

## 13. 下一期开奖信息的语义

`bootstrap.schedule.next` 只用于辅助展示：

- 预计期号
- 预计日期
- 开奖时间
- 销售截止时间

规则：

- `confirmed == true`：可按确认信息展示
- `confirmed == false`：明确使用“预计/推算”语义
- `status == unavailable`：不强行生成下一期
- 普通开奖星期读 `schedule.weekdays`
- 具体年度日期、休市和期号读 `/v2/calendar/{year}`

不要恢复旧的独立“下期信息及开奖星期”云端同步逻辑。

## 14. 必须补充的测试

### URL 与映射

验证：

- `/v2/bootstrap`
- `/v2/draws/ssq`
- `/v2/draws/kl8`
- `/v2/by-year/ssq/2026`
- `/v2/calendar/2026`
- 本地 `k8` → 远程 `kl8`

### 解码

使用 fixture 覆盖：

- bootstrap、recent、by-year、calendar
- Optional 字段缺失
- prizes 为空
- 某彩种没有 latest
- `next.status == unavailable`
- `confirmed == false`
- 不同彩种的 numbers 结构

### 渐进式加载

验证：

- 冷启动只请求 bootstrap
- 冷启动不请求八个 recent
- 冷启动不请求 health
- 冷启动不请求年度历史或全部日历
- 打开双色球历史只请求 `draws/ssq`
- 点击“查看全部”才请求当前年度
- 用户继续浏览才请求前一年
- 同一请求不并发执行两次
- 最近 30 期与年度数据正确去重和倒序

### 降级

验证：

- CloudBase 成功时不请求 GitHub
- CloudBase 失败时请求对应 GitHub V2 文件
- 两个在线源失败时读取本地缓存
- 有缓存且刷新失败时 UI 保留原数据
- 缓存损坏不导致 App 崩溃

### 回归

确认首页八个彩种、快乐8、历史详情、开奖日历、对号、用户记录和离线启动均正常。

## 15. 实施顺序

1. 分析现有数据流和调用页面。
2. 建议新建分支 `migration/cloudbase-v2-app`。
3. 增加 V2 DTO、日期解码和 Domain 转换。
4. 建立彩种集中映射。
5. 改造或替换 `LotteryDataClient`。
6. 实现 CloudBase → GitHub V2 → 本地缓存。
7. 拆分 `DrawStore.bootstrap()`，冷启动只加载 bootstrap。
8. 实现单彩种最近 30 期按需加载。
9. 实现历史数据逐年加载。
10. 实现年度日历按年加载。
11. 调整相关 SwiftUI 页面触发点。
12. 补充单元测试。
13. 运行完整 Build & Test。
14. 全仓检查旧 V1、旧 `public_data` 和启动时全量请求。
15. 使用聚焦、清晰的 commits 提交，创建 PR。

不要自动发布 TestFlight，不要创建正式版本，不要修改 CloudBase 或 `lottery-data-repo`。

## 16. 完成后的汇报格式

完成后报告：

1. 迁移前与迁移后的数据流
2. 修改文件列表
3. V2 DTO 到业务模型的映射
4. 各页面的渐进式加载触发点
5. CloudBase、GitHub、本地缓存三级降级实现
6. `k8` / `kl8` 映射
7. 新增测试与结果
8. 完整构建结果
9. 是否仍存在 V1 或旧 `public_data` 调用
10. 需要人工验证的页面和步骤
11. 未解决风险

## 17. 不可偏离的验收原则

```text
直接使用 V2
冷启动只读取 bootstrap
最近 30 期按彩种、按需加载
年度历史一次只加载一年
年度日历按年加载
CloudBase 优先
GitHub public_data/v2 兜底
本地缓存最终兜底
客户端不包含服务端密钥
不破坏用户已有数据
不自动发布 TestFlight
```
