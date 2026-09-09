# App Icon source artwork

最终采用 12 号“十八度开阔扇”方案：三张等尺寸票据围绕左侧缺口圆心旋转。

- `front-ticket.svg`：前层蓝票，`#3B82F6`，旋转 `+12°`。
- `middle-ticket.svg`：中层红票，`#EF4444`，旋转 `-6°`。
- `back-ticket.svg`：后层橙票，`#FF9C34`，旋转 `-24°`。
- 三张票的共同支点是左侧缺口圆心，因此叠放后始终形成一个完整圆形缺口。
- SVG 均使用 1024×1024 画布，不包含圆角蒙版、高光、阴影或玻璃效果。
- 最终材质、深色与着色外观由 `AppIcon.icon/icon.json` 和 Apple Icon Composer 渲染。

`LotteryWallet/Resources/AppIcon.icon/Assets/` 保存同一套可编译图层。修改源图后需同步两处，随后运行 `App Icon Preview` workflow。
