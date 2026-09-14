# App Icon 维护工作流

## 文件位置

- 设计源图：`DesignAssets/AppIcon/`
- Xcode 编译文件：`LotteryWallet/Resources/AppIcon.icon/`
- 工程设置：`project.yml`，App Icon 名称为 `AppIcon`

`AppIcon.icon` 是 Apple Icon Composer 的分层文件，包含白色/深色画布与蓝、红、橙三张票据图层。`Assets.xcassets` 继续保存 AccentColor、启动背景等普通资源，不包含传统 `AppIcon.appiconset`。

## 修改方式

1. 在 `DesignAssets/AppIcon/` 修改 1024×1024、无系统圆角蒙版的 SVG。
2. 需要调整材质或外观时修改 `AppIcon.icon/icon.json`。
3. Push 后查看 `App Icon Preview` 与 `Build & Test`。三个 workflow 都会先运行 `Scripts/sync-app-icon.sh`，把源 SVG 同步到 `.icon/Assets/`，因此只修改设计源图并 push 即可。

## CI 的判断顺序

1. `App Icon Preview / Xcode native icon validation` 使用最新稳定版 Xcode 生成工程并执行 Release device build；只有 Xcode 成功生成 `Assets.car` 与 `AppIcon*.png` 才算有效。
2. `Build & Test` 再次原生编译图标并运行全部单元测试。
3. `TestFlight` 在归档后检查归档内的图标产物，再沿用原有签名与上传流程。
4. `App Icon Preview / Third-party preview` 使用固定版 `icon-composer-mcp` 做 inspect、六种外观预览与营销 PNG 导出。它是非阻塞辅助工具，兼容问题不会否定已通过的 Xcode 构建。

生产工作流只使用 `latest-stable`，不依赖 Xcode Beta 或 Icon Composer Beta。若未来 Icon Composer 保存了新版格式，应先让 Xcode 原生验证通过，再考虑更新第三方预览器。
