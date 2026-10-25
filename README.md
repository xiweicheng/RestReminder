# RestReminder · 久坐休息提醒（macOS 菜单栏小工具）

纯 **Swift + AppKit 单文件** 实现（`main.swift`），无需 Xcode 工程即可编译为 `.app`。
用于定时提醒起身活动，预防颈椎/腰椎职业病。

## 功能

- 🍵 **菜单栏常驻**（NSStatusItem，无 Dock 图标）
  - ⏸ 开始 / 暂停提醒（⇧ 状态记忆）
  - ⏱ 休息间隔：5 / 10 / 20 / 30 / 45 / 60 分钟（✓ 标记当前项）
  - 🌿 立即休息
  - 🚀 开机自动启动（LaunchAgent 开关）
  - 退出
- ⏳ **桌面悬浮倒计时小窗**
  - 置顶悬浮（`NSPanel` + `.floating` 层级 + `canJoinAllSpaces`，跨 Space 常显）
  - 不抢焦点（`.nonactivatingPanel` + `canBecomeKey = false`），打字/操作不受影响
  - 可拖动，靠近屏幕边缘自动吸附并收起为贴边小条（悬停展开、移开自动收起）；位置下次启动自动恢复
- 🔔 **到点提醒**
  - 系统通知横幅 + 提示音（UNUserNotificationCenter，首次运行请求授权）
  - 全屏柔和渐变休息遮罩（盖住菜单栏/Dock，多显示器全覆盖，淡入淡出）
  - 遮罩提示站立/��伸动作（远眺、转脖子、耸肩、喝水），带休息倒计时，可点「提前结束休息」跳过
- ⚙️ 其他：间隔/暂停状态/悬浮窗位置持久化（UserDefaults）；防重复启动

## 构建与运行

```bash
bash build.sh          # 编译 + 组装 RestReminder.app + ad-hoc 签名
open RestReminder.app
```

> 首次运行会弹出「通知授权」系统弹窗，允许后到点有横幅提醒（拒绝也不影响遮罩提醒）。

## 使用说明

| 界面 | 说明 |
|---|---|
| 菜单栏图标 | 工作中 ⏱ / 已暂停 ⏸ / 休息中 ☕（SF Symbol 自动切换） |
| 悬浮小窗 | 按住拖动，松手靠近边缘自动吸附收起为贴边小条（悬停展开 / 移开收起）；点击不抢焦点 |
| 休息遮罩 | 覆盖全屏 30 秒（默认），点按钮可提前结束 |
| 开机启动 | 写入 `~/Library/LaunchAgents/com.xiweicheng.RestReminder.plist` 并 `launchctl bootstrap` |

> 注意：若移动了 `RestReminder.app` 的位置，请关闭再重新打开「开机自动启动」开关以更新路径。

## 调试

- `open RestReminder.app --args --demo`：启动 5 秒后立即触发一次完整休息流程
- `RR_REST=10 open RestReminder.app`（需经 launchctl 环境或直接运行二进制）：把休息时长改为 10 秒

## 文件结构

```
RestReminder/
├── main.swift              # 全部实现（单文件）
├── Info.plist              # App 配置（LSUIElement 菜单栏应用）
├── build.sh                # 一键构建脚本
├── README.md
└── RestReminder.app/       # 构建产物
    └── Contents/
        ├── Info.plist
        └── MacOS/RestReminder
```
