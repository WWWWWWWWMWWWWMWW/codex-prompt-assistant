# 原版 A：蓝橙衔接折纸

用户选择原版 A，2026-09-09 精修并用于应用和菜单栏。`AppIcon-master.png` 是图像工具生成的方形母版；`AppIcon-preview.png` 是原生圆角及透明留白后的 1024px 预览。

重新导出（仓库根目录）：

```sh
mkdir -p .build
clang -fobjc-arc -framework AppKit Tools/Icons/export.m -o .build/export-icons
.build/export-icons
make app
```

导出 16–1024px ICNS 表示及 18/36px 单色菜单栏模板 PNG。AppKit 负责平台圆角和缩放，PNG 外角是真实 alpha；没有把生成图中的棋盘格当作透明通道。菜单栏正常状态使用原生矢量绘制的同源折纸轮廓，NSImage.template=true，跟随系统明暗，暂停仍使用原有暂停符号；不影响补全或权限策略。
