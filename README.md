# 桌面标语小部件 · Slogan Widget

一块常驻桌面的置顶小卡片：轮播「学习 / 工作」标语催你动手，每专注 45 分钟提醒你起来休息。

![预览](preview.png)

## 启动

| 方式 | 操作 |
| --- | --- |
| 推荐 | 双击 `启动标语小部件.vbs`（静默启动，不闪黑框） |
| 备选 | 右键 `SloganWidget.ps1` →「使用 PowerShell 运行」 |
| 命令行 | `powershell -ExecutionPolicy Bypass -File SloganWidget.ps1` |

如果双击 VBS 没反应（个别安全软件会拦脚本宿主），直接用「备选」方式启动即可，效果一样。

第一次启动会出现在屏幕右下角，之后自动记住位置（写入 `config.json`）。

## 交互

- **拖动** —— 移动位置，松手即记住
- **双击** —— 立刻换一句
- **右键** —— 菜单：下一句 / 暂停轮播 / 重置专注计时 / 始终置顶 / 开机自启 / 退出
- **退出** —— 右键菜单里点「退出」

## 它显示什么

- 左上：`专注 12:34` 计时；每 45 分钟自动进入 90 秒「休息」倒计时（卡片变绿，进度条倒着走）
- 中间：标语，每 30 秒淡入淡出换一句；每 4 句会穿插一句休息提醒
- 右下：今天已完成的专注轮数
- 底部细条：距离下一次休息的进度

## 开机自启

右键菜单勾选「开机自启」即可（在系统启动文件夹里放一个指向本目录的快捷方式），取消勾选即删除。
命令行也可以：

```
powershell -ExecutionPolicy Bypass -File SloganWidget.ps1 -InstallAutostart
```

## 自定义

用 VS Code / PowerShell ISE 打开 `SloganWidget.ps1`（**保持 UTF-8 带 BOM**，否则中文会乱码）：

- **改文案**：`$quotesStudy` / `$quotesWork` / `$quotesRest` 三个数组，`|` 表示换行
- **改节奏**：`FocusTarget = 2700`（45 分钟一轮）、`RestTotal = 90`（休息 90 秒）、`$script:RotTimer.Interval = 30000`（30 秒换一句）
- **改配色**：`Accents` 里的 `study` / `work` / `rest` 三个颜色

## 说明

- 只用系统自带的 Windows PowerShell 5.1，**不需要安装任何依赖**
- 自动适配屏幕缩放（本机 3200×2000 @200% 已适配）
- 只允许单实例，重复启动会自动退出
- 出问题看 `widget.log`；加 `-Trace` 参数运行会额外写 `_trace.txt`

## 文件

| 文件 | 用途 |
| --- | --- |
| `SloganWidget.ps1` | 主程序（窗体、绘制、计时、菜单） |
| `启动标语小部件.vbs` | 静默启动器 |
| `config.json` | 自动生成：位置 / 置顶 / 轮数 |
| `preview.png` | 效果预览 |
