# RestReminder · 久坐休息提醒（macOS 菜单栏小工具）

纯 **Swift + AppKit 单文件** 实现（`main.swift`），无需 Xcode 工程即可编译为 `.app`。
用于定时提醒起身活动，预防颈椎/腰椎职业病。

## 功能

- 🍵 **菜单栏常驻**（NSStatusItem，无 Dock 图标）
  - ⏸ 开始 / 暂停提醒（⇧ 状态记忆）
  - ⏱ 休息间隔：5 / 10 / 20 / 30 / 45 / 60 分钟（✓ 标记当前项）
  - 🌐 语言 / Language：跟随系统（默认）/ 简体中文 / English，切换即时生效
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
  - 遮罩提示站立/伸展动作（远眺、转脖子、耸肩、喝水），带休息倒计时，可点「提前结束休息」跳过
- 🌏 **中英文双语 / Bilingual（简体中文 · English）**
  - 默认**跟随系统（Follow System）**：系统语言为中文 → 显示中文，否则显示英文
  - 菜单栏 **「语言 / Language」** 子菜单手动切换：跟随系统 / 简体中文 / English（✓ 标记当前项）
  - **切换即时生效**，无需重启：菜单、悬浮倒计时窗、全屏休息遮罩、系统通知全部同步刷新
  - 手动选择会被记住，重启后保持；选回「跟随系统 / Follow System」则随系统语言
- ⚙️ 其他：间隔/暂停状态/悬浮窗位置/语言选择持久化（UserDefaults）；防重复启动

## 下载安装（Releases）

不想自己编译？直接下载打包好的 DMG 安装包（v1.2 起新增「中英双语界面」与菜单图标统一对齐；v1.1 包含「贴边吸附收起」与「关于菜单跳转 GitHub」改动）：

**👉 前往 [Releases 页面](https://github.com/xiweicheng/RestReminder/releases) 下载最新版**

| 版本 | 文件 | 大小 | SHA256 |
|---|---|---|---|
| v1.2 | `RestReminder-1.2.dmg` | 90 KB | `ef7d2441d61ab37e67b01b529386cde503a5840a4232807baab1bf556bc42e1e` |
| v1.1 | `RestReminder-1.1.dmg` | 76 KB | `9214d013a395d19524b1efa3fd35a8f9c8b6499bb0c6d45aed941ebc3c96b2d5` |

**安装步骤**

1. 双击打开 DMG，将 **RestReminder.app** 拖入「应用程序」文件夹；
2. 首次运行如遇 Gatekeeper 拦截（App 未签名）：在 App 上**右键 → 打开**，或前往 *系统设置 → 隐私与安全性 → 仍要打开*；
3. （可选）校验完整性：`shasum -a 256 RestReminder-1.2.dmg`，输出应与上表一致；
4. 覆盖安装旧版本前，请先退出 RestReminder（菜单栏图标 → 退出）。

> 🌍 **仓库可见性**：本仓库已设为 **Public**，任何人无需登录即可从 [Releases 页面](https://github.com/xiweicheng/RestReminder/releases) 下载 DMG；若日后改回 Private，Release 附件将仅对仓库所有者与受邀协作者可见。

### 发布新版本（维护者）

```bash
bash release.sh 1.2              # 构建 → tag → Release → 上传 → 核验，一键完成
bash release.sh 1.2 --reuse-dmg  # 复用已构建的 DMG 重发（幂等，可安全重跑）
```

脚本特性：gh 优先、网络抖动自动降级 curl + dig 多源钉 IP 自愈；token 仅从 `gh auth token` 读取、fail-fast 且全程脱敏（`-H @文件` 携带，零明文回显）；Release 正文自动复用 `release_notes_v<版本>.md` 模板；重复运行幂等（已存在则复用、同名附件先删后传）。

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
├── build.sh                # 一键构建 App
├── package.sh              # 一键构建 + DMG 打包
├── release.sh              # 一键发布 GitHub Release（gh 优先→钉 IP 兜底）
├── git-sync.sh             # 一键 git 提交推送
├── release_notes_v1.1.md   # v1.1 Release 正文模板（release.sh 自动复用）
├── README.md
└── RestReminder.app/       # 构建产物
    └── Contents/
        ├── Info.plist
        └── MacOS/RestReminder
```
