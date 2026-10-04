# App 开奖读取密钥

GitHub 数据保持公开，CloudBase 使用仅限开奖查询的 `X-Lottery-Api-Key`。不新增账号、用户登录或设置界面。

在本仓库和 `wenjinliuu/lottery-data-repo` 的 Actions Secrets 中设置相同的 `LOTTERY_READ_API_KEY`（32–128 位随机英文字母、数字、下划线或短横线，推荐随机 64 位十六进制）。不要使用 CloudBase 管理密钥。

TestFlight 入口把它映射为中央工作流的可选 Secret `APP_RUNTIME_API_KEY`。仅归档准备步骤生成 `LotteryWallet/Data/V2/GeneratedLotteryReadKey.swift`；该文件已 gitignore，不能提交。Build & Test 不注入生产密钥，相关测试用显式测试密钥。

先构建并安装带密钥的 App，再启用开奖仓库的云端访问保护。带密钥的 App 可以同时访问启用前、启用后的服务。不配置密钥会阻止 TestFlight 归档；无密钥模拟器构建仍可使用 GitHub 兜底。

所有 CloudBase 请求（含 `/v2/status`）带读取密钥；GitHub 请求及跨域重定向不会携带它。401、限流或其他服务错误保留现有 GitHub/本地缓存回落方式。GitHub 规范路径已修复为 `/public_data/v2/bootstrap.json` 等，不再重复 `/v2/v2/`。

固定密钥能被从安装包提取，不能替代 App Attest。若轮换，要同时协调 App 更新和服务器配置，避免已安装版本失去云端读取能力。
