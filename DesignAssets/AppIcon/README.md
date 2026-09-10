# App Icon source artwork

最终采用 18 号“无缺口圆角扇”方案：三张等尺寸圆角票据围绕左侧同一支点规则展开。

- `front-ticket.svg`：前层蓝票，`#3B82F6`，旋转 `+12°`。
- `middle-ticket.svg`：中层红票，`#EF4444`，旋转 `-6°`。
- `back-ticket.svg`：后层橙票，`#FF9C34`，旋转 `-24°`。
- 三张票不使用左右缺口，保持完全一致的圆角矩形轮廓。
- 三张票统一围绕左侧支点 `(42, 100)` 等距旋转，外轮廓在 1024×1024 画布中重新校准居中。
- SVG 均使用 1024×1024 画布，不包含圆角蒙版、高光、阴影或玻璃效果。
- 最终材质、深色与着色外观由 `AppIcon.icon/icon.json` 和 Apple Icon Composer 渲染。

`LotteryWallet/Resources/AppIcon.icon/Assets/` 保存同一套可编译图层。修改源图后需同步两处，随后运行 `App Icon Preview` workflow。
