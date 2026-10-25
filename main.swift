//
// main.swift — RestReminder 久坐休息提醒（macOS 菜单栏小工具）
//
// 纯 Swift + AppKit 单文件实现：
//   1. NSStatusItem 菜单栏：开始/暂停、间隔设置(5/10/20/30/45/60分钟)、立即休息、语言切换、开机启动、退出
//   2. 桌面悬浮倒计时小窗：NSPanel 置顶、不抢焦点、可拖动、屏幕边缘自动吸附、位置记忆
//   3. 到点系统通知（UNUserNotificationCenter）+ 休息提示
//   4. 休息时全屏柔和渐变遮罩，提示站立/拉伸活动，可一键跳过
//   5. 中英双语（L10n 文案层 + AppLanguage 语言管理：跟随系统/中文/English）
//
// 构建:  bash build.sh
// 运行:  open RestReminder.app
// 调试:  open RestReminder.app --args --demo   (启动 5 秒后立即触发一次休息流程)
//

import AppKit
import UserNotifications
import QuartzCore
import Darwin

// MARK: - 配置

enum Config {
    static let bundleID = "com.xiweicheng.RestReminder"
    static let intervals = [5, 10, 20, 30, 45, 60]      // 可选休息间隔（分钟）
    static let defaultMinutes = 30                       // 默认间隔
    static let restSeconds: Int = {                      // 每次休息时长（秒），可用环境变量 RR_REST 覆盖
        if let s = Int(ProcessInfo.processInfo.environment["RR_REST"] ?? ""), s > 0 { return s }
        return 30
    }()
    static let panelSize = NSSize(width: 132, height: 58)
    static let snapThreshold: CGFloat = 48               // 吸附判定距离（pt）
    static let edgeMargin: CGFloat = 10                  // 吸附后距屏幕边缘留白
    static let intervalKey = "restIntervalMinutes"
    static let pausedKey = "isPaused"
    static let panelOriginKey = "floatingPanelOrigin"
}

func mmss(_ seconds: Int) -> String {
    let v = max(0, seconds)
    return String(format: "%02d:%02d", v / 60, v % 60)
}

// MARK: - 多语言（L10n）

/// 用户可选语言：跟随系统 / 简体中文 / English
enum AppLanguage: String, CaseIterable {
    case system
    case zhHans
    case en

    /// UserDefaults 存储键
    static let storageKey = "appLanguage"

    /// 手动选择的语言（.system 表示跟随系统），持久化到 UserDefaults
    static var selected: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }

    /// 当前实际生效语言：手动选择优先；跟随系统时读系统首选语言（zh 开头→中文，其余→英文）
    static var resolved: AppLanguage {
        if selected != .system { return selected }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .zhHans : .en
    }

    /// 语言菜单里展示的名称（各语言自称，便于辨认）
    var displayName: String {
        switch self {
        case .system: return AppLanguage.resolved == .zhHans ? "跟随系统" : "Follow System"
        case .zhHans: return "简体中文"
        case .en:     return "English"
        }
    }
}

/// L10n 文案表：全部 UI 文案集中于此，按当前生效语言取值；带参数的文案用模板函数。
/// 所有取值都是实时计算，切换语言后下一次取值即生效。
enum L10n {
    /// 当前生效语言是否为简体中文
    static var isChinese: Bool { AppLanguage.resolved == .zhHans }

    // MARK: 菜单栏图标 tooltip
    static var tooltip: String { isChinese ? "RestReminder 休息提醒" : "RestReminder break reminder" }

    // MARK: 悬浮倒计时窗
    static var panelNextBreak: String { isChinese ? "距下次休息" : "Next break in" }
    static var panelPaused: String { isChinese ? "已暂停" : "Paused" }
    static var panelResting: String { isChinese ? "🌿 休息中" : "🌿 Resting" }
    static func panelRestSeconds(_ seconds: Int) -> String { isChinese ? "还剩 \(seconds) 秒" : "\(seconds)s left" }

    // MARK: 菜单状态头
    static func menuRestingHeader(_ seconds: Int) -> String { isChinese ? "休息中 — 还剩 \(seconds) 秒" : "Resting — \(seconds)s left" }
    static func menuPausedHeader(_ time: String) -> String { isChinese ? "已暂停 — 剩余 \(time)" : "Paused — \(time) left" }
    static func menuWorkingHeader(_ time: String) -> String { isChinese ? "工作中 — 距下次休息 \(time)" : "Working — next break in \(time)" }

    // MARK: 菜单项
    static var menuStart: String { isChinese ? "开始提醒" : "Start Reminders" }
    static var menuPause: String { isChinese ? "暂停提醒" : "Pause Reminders" }
    static var menuRestNow: String { isChinese ? "立即休息" : "Take a Break Now" }
    static func menuMinutes(_ m: Int) -> String { isChinese ? "\(m) 分钟" : "\(m) min" }
    static var menuInterval: String { isChinese ? "休息间隔" : "Break Interval" }
    static var menuLaunchAtLogin: String { isChinese ? "开机自动启动" : "Launch at Login" }
    static var menuGitHub: String { isChinese ? "项目主页（GitHub）" : "Project Homepage (GitHub)" }
    static var menuQuit: String { isChinese ? "退出 RestReminder" : "Quit RestReminder" }

    // MARK: 语言子菜单
    /// 子菜单标题固定双语展示：无论当前显示语言是哪种，都能一眼找到语言入口
    static var menuLanguage: String { "语言 / Language" }

    // MARK: 全屏休息遮罩
    static var overlayTitle: String { isChinese ? "🌿 该休息啦" : "🌿 Time for a Break" }
    static var overlaySubtitle: String { isChinese ? "站起来走一走，伸个懒腰，让颈椎和腰椎放松一下" : "Stand up and stretch — give your neck and back a break" }
    static func overlayCountdown(_ seconds: Int) -> String { isChinese ? "休息还剩 \(seconds) 秒" : "Rest ends in \(seconds)s" }
    static var overlayTips: String { isChinese ? "👁 远眺放松眼睛 · 🔄 缓缓转脖子 · 💪 耸肩绕肩 · 💧 喝口水" : "👁 Look into the distance · 🔄 Roll your neck · 💪 Shrug and roll shoulders · 💧 Sip some water" }
    static var overlaySkip: String { isChinese ? "提前结束休息" : "End Break Early" }

    // MARK: 系统通知
    static var notificationTitle: String { isChinese ? "🌿 该休息啦" : "🌿 Time for a Break" }
    static func notificationBody(_ minutes: Int) -> String { isChinese ? "已连续工作 \(minutes) 分钟，站起来活动一下吧！" : "You've been working for \(minutes) minutes — time to move!" }
}

/// 悬浮窗状态语义（用于着色等样式判断，与 UI 文案字符串解耦）
enum CountdownState { case working, resting, paused }

/// 静默执行 launchctl，返回退出码
@discardableResult
func runLaunchctl(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

// MARK: - 悬浮倒计时窗（内容视图：负责拖动 + 边缘吸附）

final class CountdownView: NSView {
    let timeLabel = NSTextField(labelWithString: "30:00")
    let stateLabel = NSTextField(labelWithString: L10n.panelNextBreak)

    private var dragMouseStart: NSPoint?
    private var dragOrigin: NSPoint?
    var onDragEnd: (() -> Void)?

    // MARK: 贴边吸附收起 / 悬停展开 状态
    enum SnapEdge { case left, right, top, bottom }
    private(set) var snappedEdge: SnapEdge?      // 当前吸附边（nil=未贴边，常驻展开）
    var snappedExpandedFrame: NSRect?            // 吸附态的完整面板位置（带 edgeMargin），悬停展开回到此处
    private var isShowingBar = false             // 当前是否为贴边小条形态
    private var isDragging = false
    private var pendingCollapse: DispatchWorkItem?
    private var suppressHoverUntil = Date.distantPast
    private var barProgress: Double = 1
    private let barThickness: CGFloat = 14       // 收起小条厚度
    private let barTrack = NSView()              // 收起态进度轨道
    private let barFill = NSView()               // 收起态进度填充

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.19, alpha: 0.55).cgColor

        // 毛玻璃底层：模糊桌面背景
        let blur = NSVisualEffectView(frame: bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        addSubview(blur)

        // 深墨蓝渐变罩层：叠加在毛玻璃上，柔和且有层次
        let tint = NSView(frame: bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        let tintGradient = CAGradientLayer()
        tintGradient.frame = bounds
        tintGradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        tintGradient.colors = [
            NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.18, alpha: 0.58).cgColor,   // 底部：深墨蓝
            NSColor(calibratedRed: 0.27, green: 0.35, blue: 0.48, alpha: 0.38).cgColor    // 顶部：雾蓝
        ]
        tintGradient.startPoint = CGPoint(x: 0.5, y: 0)
        tintGradient.endPoint = CGPoint(x: 0.5, y: 1)
        tint.layer?.addSublayer(tintGradient)
        addSubview(tint)

        // 顶部柔和高光，强化玻璃质感
        let sheen = NSView(frame: bounds)
        sheen.autoresizingMask = [.width, .height]
        sheen.wantsLayer = true
        let sheenGradient = CAGradientLayer()
        sheenGradient.frame = bounds
        sheenGradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        sheenGradient.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(0.12).cgColor
        ]
        sheenGradient.locations = [0, 0.55, 1]
        sheenGradient.startPoint = CGPoint(x: 0.5, y: 0)
        sheenGradient.endPoint = CGPoint(x: 0.5, y: 1)
        sheen.layer?.addSublayer(sheenGradient)
        addSubview(sheen)

        // 收起态：贴边小条内的细进度指示（轨道 + 填充）
        for (v, c) in [(barTrack, NSColor.white.withAlphaComponent(0.28)),
                       (barFill, NSColor(calibratedRed: 0.62, green: 0.96, blue: 0.80, alpha: 0.95))] {
            v.wantsLayer = true
            v.layer?.backgroundColor = c.cgColor
            v.layer?.cornerRadius = 1.5
            v.isHidden = true
            addSubview(v)
        }

        // 悬停检测：鼠标移入小条展开、移开自动收起
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))

        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 23, weight: .semibold)
        timeLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.98)
        timeLabel.alignment = .center
        timeLabel.frame = NSRect(x: 0, y: 27, width: frameRect.width, height: 26)
        timeLabel.autoresizingMask = [.width]
        let timeShadow = NSShadow()
        timeShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        timeShadow.shadowBlurRadius = 3
        timeShadow.shadowOffset = NSSize(width: 0, height: -1)
        timeLabel.shadow = timeShadow
        addSubview(timeLabel)

        stateLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        stateLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.66)
        stateLabel.alignment = .center
        stateLabel.frame = NSRect(x: 0, y: 10, width: frameRect.width, height: 13)
        stateLabel.autoresizingMask = [.width]
        addSubview(stateLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 整个面板统一响应鼠标（便于拖动）
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func mouseDown(with event: NSEvent) {
        cancelPendingCollapse()
        isDragging = true
        if isShowingBar { expandBar(animated: false) }       // 抓起小条：先展开再拖
        dragMouseStart = NSEvent.mouseLocation
        dragOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragMouseStart, let origin = dragOrigin, let win = window else { return }
        let now = NSEvent.mouseLocation
        win.setFrameOrigin(NSPoint(x: origin.x + (now.x - start.x),
                                   y: origin.y + (now.y - start.y)))
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        snapToNearestEdge()
        dragMouseStart = nil
        dragOrigin = nil
        onDragEnd?()
    }

    /// 与给定窗口框重叠面积最大的屏幕
    private func bestScreen(for frame: NSRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for s in NSScreen.screens {
            let inter = s.frame.intersection(frame)
            if !inter.isNull && inter.width * inter.height > bestArea {
                bestArea = inter.width * inter.height
                best = s
            }
        }
        return best ?? NSScreen.main
    }

    /// 拖动结束后：靠近屏幕边缘 → 吸附并收起为贴边小条；否则常驻完整面板
    func snapToNearestEdge() {
        guard let win = window else { return }
        guard let vf = bestScreen(for: win.frame)?.visibleFrame else { return }
        var f = win.frame
        let th = Config.snapThreshold
        let mg = Config.edgeMargin

        let dL = abs(f.minX - vf.minX), dR = abs(f.maxX - vf.maxX)
        let dB = abs(f.minY - vf.minY), dT = abs(f.maxY - vf.maxY)
        var edge: SnapEdge?
        var bestDist = CGFloat.greatestFiniteMagnitude

        if dL < th {
            f.origin.x = vf.minX + mg
            edge = .left; bestDist = dL
        } else if dR < th {
            f.origin.x = vf.maxX - f.width - mg
            edge = .right; bestDist = dR
        }
        if dB < th {
            f.origin.y = vf.minY + mg
            if dB < bestDist { edge = .bottom; bestDist = dB }
        } else if dT < th {
            f.origin.y = vf.maxY - f.height - mg
            if dT < bestDist { edge = .top; bestDist = dT }
        }

        guard let e = edge else {
            // 未贴边：恢复常驻完整面板
            snappedEdge = nil
            snappedExpandedFrame = nil
            setBarMode(false)
            win.setFrame(f, display: true)
            win.invalidateShadow()
            return
        }

        // 贴边：记住展开位置（带边距），收起为贴边小条
        snappedEdge = e
        snappedExpandedFrame = f
        let bar = barFrame(for: e, expanded: f, visible: vf)
        setBarMode(true)
        win.setFrame(bar, display: true)
        win.invalidateShadow()
        suppressHoverUntil = Date().addingTimeInterval(0.6)  // 松手位置压住小条时不立即弹开
    }

    func update(time: String, state: String, kind: CountdownState, progress: Double? = nil) {
        timeLabel.stringValue = time
        stateLabel.stringValue = state
        if let p = progress { barProgress = p; updateBarFill() }
        // 状态行按状态着色：休息中薄荷绿点缀、暂停琥珀色、工作中柔白
        let resting = kind == .resting           // 语义状态判断，与文案字符串解耦
        // 收起态进度条颜色随状态同步：休息中薄荷绿 / 暂停琥珀 / 工作中柔白
        barFill.layer?.backgroundColor = resting
            ? NSColor(calibratedRed: 0.62, green: 0.96, blue: 0.80, alpha: 0.95).cgColor
            : (kind == .paused
               ? NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.55, alpha: 0.9).cgColor
               : NSColor.white.withAlphaComponent(0.55).cgColor)
        if resting {
            stateLabel.textColor = NSColor(calibratedRed: 0.62, green: 0.96, blue: 0.80, alpha: 1)
            layer?.borderColor = NSColor(calibratedRed: 0.62, green: 0.96, blue: 0.80, alpha: 0.45).cgColor
        } else if kind == .paused {
            stateLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.55, alpha: 1)
            layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        } else {
            stateLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.66)
            layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        }
    }
    // MARK: 收起 / 展开（贴边小条）

    /// 贴边小条的窗口框：贴死屏幕边缘，另一轴与展开位置对中（clamp 在屏内）
    private func barFrame(for edge: SnapEdge, expanded f: NSRect, visible vf: NSRect) -> NSRect {
        let t = barThickness
        switch edge {
        case .left:
            let cy = min(max(f.midY, vf.minY + f.height / 2), vf.maxY - f.height / 2)
            return NSRect(x: vf.minX, y: cy - f.height / 2, width: t, height: f.height)
        case .right:
            let cy = min(max(f.midY, vf.minY + f.height / 2), vf.maxY - f.height / 2)
            return NSRect(x: vf.maxX - t, y: cy - f.height / 2, width: t, height: f.height)
        case .bottom:
            let cx = min(max(f.midX, vf.minX + f.width / 2), vf.maxX - f.width / 2)
            return NSRect(x: cx - f.width / 2, y: vf.minY, width: f.width, height: t)
        case .top:
            let cx = min(max(f.midX, vf.minX + f.width / 2), vf.maxX - f.width / 2)
            return NSRect(x: cx - f.width / 2, y: vf.maxY - t, width: f.width, height: t)
        }
    }

    /// 切换"贴边小条"形态：隐藏文字标签，显示细进度指示
    private func setBarMode(_ show: Bool) {
        guard isShowingBar != show else { return }
        isShowingBar = show
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            timeLabel.animator().alphaValue = show ? 0 : 1
            stateLabel.animator().alphaValue = show ? 0 : 1
        }
        barTrack.isHidden = !show
        barFill.isHidden = !show
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.invalidateShadow()
    }

    /// 悬停展开：从贴边小条恢复为完整面板（回到吸附展开位）
    func expandBar(animated: Bool) {
        cancelPendingCollapse()
        guard snappedEdge != nil, let f = snappedExpandedFrame, let win = window, isShowingBar else { return }
        setBarMode(false)
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                win.animator().setFrame(f, display: true)
            }, completionHandler: {
                win.invalidateShadow()
            })
        } else {
            win.setFrame(f, display: true)
            win.invalidateShadow()
        }
    }

    /// 鼠标移开后自动收回小条
    private func collapseBar() {
        guard let e = snappedEdge, let f = snappedExpandedFrame, let win = window,
              !isShowingBar, !isDragging else { return }
        guard let vf = bestScreen(for: f)?.visibleFrame else { return }
        setBarMode(true)
        let bar = barFrame(for: e, expanded: f, visible: vf)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            win.animator().setFrame(bar, display: true)
        }, completionHandler: {
            win.invalidateShadow()
        })
    }

    private func cancelPendingCollapse() {
        pendingCollapse?.cancel()
        pendingCollapse = nil
    }

    override func mouseEntered(with event: NSEvent) {
        guard Date() >= suppressHoverUntil, !isDragging else { return }
        cancelPendingCollapse()
        if isShowingBar { expandBar(animated: true) }
    }

    override func mouseExited(with event: NSEvent) {
        guard snappedEdge != nil, !isDragging, !isShowingBar else { return }
        cancelPendingCollapse()
        let work = DispatchWorkItem { [weak self] in self?.collapseBar() }
        pendingCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)   // 1s 防抖
    }

    /// 启动恢复：上次停在贴边位置 → 直接以收起小条出现（无动画）
    func applySnapOnLaunch() {
        guard snappedEdge == nil, !isShowingBar else { return }
        snapToNearestEdge()
    }

    private func layoutBar() {
        guard isShowingBar, let e = snappedEdge else { return }
        let b = bounds
        let t: CGFloat = 4, len: CGFloat = 36
        switch e {
        case .left, .right:
            barTrack.frame = NSRect(x: b.midX - t / 2, y: b.midY - len / 2, width: t, height: len)
        case .bottom, .top:
            barTrack.frame = NSRect(x: b.midX - len / 2, y: b.midY - t / 2, width: len, height: t)
        }
        updateBarFill()
    }

    private func updateBarFill() {
        guard let e = snappedEdge else { return }
        let tr = barTrack.frame
        let frac = CGFloat(min(max(barProgress, 0), 1))
        switch e {
        case .left:   barFill.frame = NSRect(x: tr.minX, y: tr.minY, width: tr.width, height: tr.height * frac)
        case .right:  barFill.frame = NSRect(x: tr.minX, y: tr.maxY - tr.height * frac, width: tr.width, height: tr.height * frac)
        case .bottom: barFill.frame = NSRect(x: tr.minX, y: tr.minY, width: tr.width * frac, height: tr.height)
        case .top:    barFill.frame = NSRect(x: tr.maxX - tr.width * frac, y: tr.minY, width: tr.width * frac, height: tr.height)
        }
    }

    /// 尺寸变化后自适应重排（展开 ⇄ 收起）
    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        timeLabel.frame = NSRect(x: 0, y: h - 31, width: w, height: 26)
        stateLabel.frame = NSRect(x: 0, y: 10, width: w, height: 13)
        layoutBar()
    }
}

// MARK: - 悬浮倒计时窗（NSPanel：置顶 + 不抢焦点）

final class CountdownPanel: NSPanel {
    let view: CountdownView

    init() {
        let size = Config.panelSize
        view = CountdownView(frame: NSRect(origin: .zero, size: size))
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating                                    // 置顶悬浮
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = view
    }

    override var canBecomeKey: Bool { false }                // 不抢焦点
    override var canBecomeMain: Bool { false }
}

// MARK: - 全屏休息遮罩（内容视图：柔和渐变 + 站立活动提示 + 跳过按钮）

final class RestOverlayView: NSView {
    var onSkip: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let tipsLabel = NSTextField(labelWithString: "")
    private let skipButton = NSButton(title: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true

        // 底层毛玻璃：模糊桌面，让全屏遮罩更柔和现代
        let blur = NSVisualEffectView(frame: bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        addSubview(blur)

        // 柔雾渐变纱层：晨雾绿 → 雾蓝 → 薰衣草，半透明叠加透出毛玻璃质感
        let scrim = NSView(frame: bounds)
        scrim.autoresizingMask = [.width, .height]
        scrim.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.frame = bounds
        gradient.colors = [
            NSColor(calibratedRed: 0.84, green: 0.95, blue: 0.89, alpha: 0.86).cgColor,
            NSColor(calibratedRed: 0.83, green: 0.90, blue: 0.99, alpha: 0.86).cgColor,
            NSColor(calibratedRed: 0.91, green: 0.89, blue: 0.99, alpha: 0.86).cgColor
        ]
        gradient.locations = [0, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0.1, y: 0.0)
        gradient.endPoint = CGPoint(x: 0.9, y: 1.0)
        gradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        scrim.layer?.addSublayer(gradient)
        addSubview(scrim)

        let ink = NSColor(calibratedRed: 0.13, green: 0.24, blue: 0.34, alpha: 1)   // 深青蓝墨色，柔和不刺眼
        let softInk = ink.withAlphaComponent(0.74)

        titleLabel.font = NSFont.systemFont(ofSize: 46, weight: .bold)
        titleLabel.textColor = ink

        subtitleLabel.font = NSFont.systemFont(ofSize: 21, weight: .medium)
        subtitleLabel.textColor = softInk

        countdownLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        countdownLabel.textColor = softInk

        tipsLabel.font = NSFont.systemFont(ofSize: 15)
        tipsLabel.textColor = softInk

        skipButton.bezelStyle = .rounded
        skipButton.controlSize = .large
        skipButton.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        skipButton.target = self
        skipButton.action = #selector(skipTapped)

        let stack = NSStackView(views: [titleLabel, subtitleLabel, countdownLabel, tipsLabel, skipButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        refreshText(remainingSeconds: Config.restSeconds)    // 首次文案；语言切换时也会重走此方法
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(remainingSeconds: Int) {
        countdownLabel.stringValue = L10n.overlayCountdown(max(0, remainingSeconds))
    }

    /// 刷新全部文案（语言切换后，遮罩若正在显示则调用此方法即时生效，无需重建窗口）
    func refreshText(remainingSeconds: Int) {
        titleLabel.stringValue = L10n.overlayTitle
        subtitleLabel.stringValue = L10n.overlaySubtitle
        tipsLabel.stringValue = L10n.overlayTips
        skipButton.title = L10n.overlaySkip
        update(remainingSeconds: remainingSeconds)
    }

    @objc private func skipTapped() { onSkip?() }
}

// MARK: - 全屏休息遮罩（NSPanel：最高层级 + 不抢焦点）

final class RestOverlayPanel: NSPanel {
    let overlayView: RestOverlayView

    init(forScreen screen: NSScreen) {
        overlayView = RestOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver                                 // 覆盖菜单栏/Dock/普通窗口
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = overlayView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 应用核心逻辑

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {

    // UI
    private var statusItem: NSStatusItem!
    private var countdownPanel: CountdownPanel!
    private var overlays: [RestOverlayPanel] = []

    // 状态
    private var ticker: Timer?
    private var remaining = Config.defaultMinutes * 60       // 距下次休息（秒）
    private var restRemaining = 0                            // 休息剩余（秒）
    private var isResting = false
    private var isPaused = false
    private var lastNotificationID: String?
    private let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")

    // 通知中心（非 .app 环境下安全降级为 nil）
    private lazy var notificationCenter: UNUserNotificationCenter? = {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    // 偏好
    private var intervalMinutes: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Config.intervalKey)
            return Config.intervals.contains(v) ? v : Config.defaultMinutes
        }
        set { UserDefaults.standard.set(newValue, forKey: Config.intervalKey) }
    }

    // MARK: 生命周期

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = notificationCenter                               // 尽早设置通知 delegate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)                // 菜单栏应用，无 Dock 图标

        setupStatusItem()
        setupFloatingPanel()

        isPaused = UserDefaults.standard.bool(forKey: Config.pausedKey)
        remaining = isDemo ? 5 : intervalMinutes * 60

        refreshUI()

        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)                // 菜单展开时也持续走表
        ticker = t

        notificationCenter?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func applicationWillTerminate(_ notification: Notification) {
        savePanelOrigin()
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshMenuBarIcon()
    }

    /// 把 emoji 渲染成固定边长的菜单图标。
    /// emoji 直接写在标题里时，不同字符（▶️/⏸/🌿…）的呈现形式（彩色 emoji / 文本字形）
    /// 与宽度不一致，导致菜单项大小不齐、起点参差；改为统一 image 后，NSMenu 自动对齐图标列。
    private func menuIcon(_ emoji: String) -> NSImage {
        let side: CGFloat = 18
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let str = NSAttributedString(string: emoji, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .paragraphStyle: para,
        ])
        let bounds = str.boundingRect(with: NSSize(width: side, height: side), options: [.usesLineFragmentOrigin])
        str.draw(in: NSRect(x: 0, y: (side - bounds.height) / 2, width: side, height: side))
        img.unlockFocus()
        img.isTemplate = false   // 保留彩色 emoji 呈现
        return img
    }

    /// 每次展开菜单时重建，保证状态实时
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header: String
        let headerEmoji: String
        if isResting {
            header = L10n.menuRestingHeader(max(0, restRemaining))
            headerEmoji = "🌿"
        } else if isPaused {
            header = L10n.menuPausedHeader(mmss(remaining))
            headerEmoji = "⏸️"
        } else {
            header = L10n.menuWorkingHeader(mmss(remaining))
            headerEmoji = "☕"
        }
        let headerItem = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        headerItem.image = menuIcon(headerEmoji)
        menu.addItem(headerItem)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: isPaused ? L10n.menuStart : L10n.menuPause,
                                action: #selector(togglePause), keyEquivalent: "p")
        toggle.target = self
        toggle.image = menuIcon(isPaused ? "▶️" : "⏸️")
        menu.addItem(toggle)

        let restNow = NSMenuItem(title: L10n.menuRestNow,
                                 action: #selector(restNow), keyEquivalent: "r")
        restNow.target = self
        restNow.image = menuIcon("🌿")
        restNow.isEnabled = !isResting
        menu.addItem(restNow)
        menu.addItem(.separator())

        let intervalMenu = NSMenu()
        intervalMenu.autoenablesItems = false
        for m in Config.intervals {
            let it = NSMenuItem(title: L10n.menuMinutes(m), action: #selector(setInterval(_:)), keyEquivalent: "")
            it.target = self
            it.state = (m == intervalMinutes) ? .on : .off
            it.representedObject = m
            intervalMenu.addItem(it)
        }
        let intervalItem = NSMenuItem(title: L10n.menuInterval, action: nil, keyEquivalent: "")
        intervalItem.image = menuIcon("⏱️")
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        // 🌐 语言 / Language 子菜单：跟随系统 / 简体中文 / English，✓ 标记当前选择
        let languageMenu = NSMenu()
        languageMenu.autoenablesItems = false
        for lang in AppLanguage.allCases {
            let it = NSMenuItem(title: lang.displayName, action: #selector(setLanguage(_:)), keyEquivalent: "")
            it.target = self
            it.state = (lang == AppLanguage.selected) ? .on : .off
            it.representedObject = lang.rawValue
            languageMenu.addItem(it)
        }
        let languageItem = NSMenuItem(title: L10n.menuLanguage, action: nil, keyEquivalent: "")
        languageItem.image = menuIcon("🌐")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        menu.addItem(.separator())

        let launch = NSMenuItem(title: L10n.menuLaunchAtLogin,
                                action: #selector(toggleLaunchAtLogin), keyEquivalent: "l")
        launch.target = self
        launch.image = menuIcon("🚀")
        launch.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(launch)
        menu.addItem(.separator())

        let about = NSMenuItem(title: L10n.menuGitHub, action: #selector(openGitHubRepo), keyEquivalent: "")
        about.target = self
        about.image = menuIcon("🔗")
        menu.addItem(about)

        let quit = NSMenuItem(title: L10n.menuQuit,
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = menuIcon("🚪")
        menu.addItem(quit)
    }

    @objc private func togglePause() {
        isPaused.toggle()
        UserDefaults.standard.set(isPaused, forKey: Config.pausedKey)
        refreshUI()
    }

    @objc private func restNow() { beginRest() }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? Int else { return }
        intervalMinutes = m
        if !isResting { remaining = m * 60 }                 // 切换间隔后重新计时
        refreshUI()
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let lang = AppLanguage(rawValue: raw),
              lang != AppLanguage.selected else { return }   // 重复点击当前项不做事
        AppLanguage.selected = lang                          // 写入 UserDefaults，重启后仍保持
        applyLanguageChange()
    }

    /// 语言切换立即生效，无需重启应用：
    /// 1) 强制重建菜单（平时每次展开菜单本就会重建，此处双保险）
    /// 2) 悬浮倒计时窗文案 + 菜单栏 tooltip 即时刷新
    /// 3) 全屏休息遮罩若正在显示，同步刷新其全部文案
    private func applyLanguageChange() {
        if let menu = statusItem?.menu { menuNeedsUpdate(menu) }
        refreshUI()
        if isResting {
            overlays.forEach { $0.overlayView.refreshText(remainingSeconds: restRemaining) }
        }
    }

    @objc private func openGitHubRepo() {
        guard let url = URL(string: "https://github.com/xiweicheng/RestReminder") else { return }
        NSWorkspace.shared.open(url)   // 用系统默认浏览器打开仓库主页
    }

    // MARK: 计时

    private func tick() {
        if isPaused { return }
        if isResting {
            restRemaining -= 1
            if restRemaining <= 0 {
                endRest()
            } else {
                overlays.forEach { $0.overlayView.update(remainingSeconds: restRemaining) }
                updatePanel()
            }
        } else {
            remaining -= 1
            if remaining <= 0 {
                beginRest()
            } else {
                updatePanel()
            }
        }
    }

    // MARK: 休息流程

    private func beginRest() {
        guard !isResting else { return }
        isResting = true
        restRemaining = Config.restSeconds
        sendRestNotification()
        showOverlays()
        refreshUI()
    }

    private func endRest() {
        isResting = false
        hideOverlays()
        if let id = lastNotificationID {
            notificationCenter?.removeDeliveredNotifications(withIdentifiers: [id])
            lastNotificationID = nil
        }
        remaining = intervalMinutes * 60
        refreshUI()
    }

    private func showOverlays() {
        hideOverlays(instant: true)                          // 防止重复叠加
        for screen in NSScreen.screens {
            let p = RestOverlayPanel(forScreen: screen)
            p.overlayView.onSkip = { [weak self] in self?.endRest() }
            p.alphaValue = 0
            p.orderFrontRegardless()                         // 不抢焦点地显示
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                p.animator().alphaValue = 1
            }
            overlays.append(p)
        }
    }

    private func hideOverlays(instant: Bool = false) {
        let panels = overlays
        overlays = []
        for p in panels {
            if instant {
                p.orderOut(nil)
            } else {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.3
                    p.animator().alphaValue = 0
                }, completionHandler: { p.orderOut(nil) })
            }
        }
    }

    // MARK: 系统通知

    private func sendRestNotification() {
        guard let center = notificationCenter else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.notificationTitle
        content.body = L10n.notificationBody(intervalMinutes)
        content.sound = .default
        let id = UUID().uuidString
        lastNotificationID = id
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])                 // 前台也弹横幅
    }

    // MARK: 悬浮倒计时窗

    private func setupFloatingPanel() {
        countdownPanel = CountdownPanel()
        countdownPanel.view.onDragEnd = { [weak self] in self?.savePanelOrigin() }

        let saved = UserDefaults.standard.string(forKey: Config.panelOriginKey)
            .flatMap { NSPointFromString($0) }
        if let p = saved, isRectOnAnyScreen(NSRect(origin: p, size: Config.panelSize)) {
            countdownPanel.setFrameOrigin(p)                 // 恢复上次位置
            countdownPanel.view.applySnapOnLaunch()          // 上次停在贴边 → 直接以收起小条出现
        } else if let vf = NSScreen.main?.visibleFrame {
            countdownPanel.setFrameOrigin(NSPoint(x: vf.maxX - Config.panelSize.width - 16,
                                                  y: vf.minY + 16))   // 默认右下角
        }
        countdownPanel.orderFrontRegardless()
    }

    private func isRectOnAnyScreen(_ r: NSRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(r) }
    }

    private func savePanelOrigin() {
        let o = countdownPanel?.view.snappedExpandedFrame?.origin ?? countdownPanel?.frame.origin
        if let o = o {
            UserDefaults.standard.set(NSStringFromPoint(o), forKey: Config.panelOriginKey)
        }
    }

    // MARK: 界面刷新

    private func updatePanel() {
        guard let v = countdownPanel?.view else { return }
        let total = isResting ? Double(Config.restSeconds) : Double(max(1, intervalMinutes * 60))
        let left = isResting ? Double(max(0, restRemaining)) : Double(max(0, remaining))
        let progress = min(max(left / total, 0), 1)          // 收起小条上的剩余时间比例
        if isResting {
            v.update(time: L10n.panelResting, state: L10n.panelRestSeconds(max(0, restRemaining)), kind: .resting, progress: progress)
        } else if isPaused {
            v.update(time: mmss(remaining), state: L10n.panelPaused, kind: .paused, progress: progress)
        } else {
            v.update(time: mmss(remaining), state: L10n.panelNextBreak, kind: .working, progress: progress)
        }
    }

    private func refreshMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        let symbolName = isResting ? "cup.and.saucer" : (isPaused ? "pause.fill" : "timer")
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "RestReminder") {
            img.isTemplate = true
            button.image = img
            button.title = ""
        } else {
            button.image = nil
            button.title = isResting ? "☕" : (isPaused ? "⏸" : "⏰")
        }
        button.toolTip = L10n.tooltip
    }

    private func refreshUI() {
        refreshMenuBarIcon()
        updatePanel()
    }

    // MARK: 开机启动（LaunchAgent）

    private var launchPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Config.bundleID).plist", isDirectory: false)
    }

    private var launchAtLoginEnabled: Bool {
        FileManager.default.fileExists(atPath: launchPlistURL.path)
    }

    @objc private func toggleLaunchAtLogin() {
        if launchAtLoginEnabled {
            unloadLaunchAgent()
            try? FileManager.default.removeItem(at: launchPlistURL)
        } else {
            guard let exePath = Bundle.main.executableURL?.path else { return }
            let dir = launchPlistURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(Config.bundleID)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(exePath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
                <key>ProcessType</key>
                <string>Interactive</string>
            </dict>
            </plist>
            """
            do {
                try xml.write(to: launchPlistURL, atomically: true, encoding: .utf8)
                loadLaunchAgent()
            } catch {
                NSSound.beep()
            }
        }
    }

    private func loadLaunchAgent() {
        let uid = getuid()
        let st = runLaunchctl(["bootstrap", "gui/\(uid)", launchPlistURL.path])
        if st != 0 { runLaunchctl(["load", launchPlistURL.path]) }   // 兼容旧系统
    }

    private func unloadLaunchAgent() {
        let uid = getuid()
        let st = runLaunchctl(["bootout", "gui/\(uid)/\(Config.bundleID)"])
        if st != 0 { runLaunchctl(["unload", launchPlistURL.path]) }
    }
}

// MARK: - 入口

// 防止重复启动（例如 LaunchAgent 已拉起、又手动双开）
if !ProcessInfo.processInfo.arguments.contains("--allow-multiple") {
    let same = NSRunningApplication.runningApplications(withBundleIdentifier: Config.bundleID)
    if same.count > 1 { exit(0) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
