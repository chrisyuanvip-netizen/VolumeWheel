import Cocoa
import CoreAudio
import CoreGraphics
import ApplicationServices

func loc(_ key: String) -> String { NSLocalizedString(key, comment: "") }

// MARK: - 系统音频设备与音量控制 (CoreAudio)

func defaultOutputDevice() -> AudioObjectID {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
    return st == noErr ? device : 0
}

func allAudioDevices() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let sys = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return [] }
    var devices = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &devices) == noErr else { return [] }
    return devices
}

func deviceName(_ dev: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr,
          let n = name?.takeRetainedValue() else {
        return String(format: loc("Device %d"), dev)
    }
    return n as String
}

/// 该设备是否支持以音量标量（volume scalar）方式调节
func supportsVolume(_ dev: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var v: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr
}

/// 可调节音量的输出设备列表
func outputDevices() -> [(id: AudioObjectID, name: String)] {
    allAudioDevices().compactMap { id in
        supportsVolume(id) ? (id, deviceName(id)) : nil
    }
}

func deviceVolume(_ dev: AudioObjectID) -> Float? {
    guard dev != 0 else { return nil }
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var v: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
    return v
}

func setDeviceVolume(_ dev: AudioObjectID, _ v: Float) {
    guard dev != 0 else { return }
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var val = v
    var size = UInt32(MemoryLayout<Float32>.size)
    AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &val)
}

// MARK: - 应用全局状态

final class AppState {
    static let shared = AppState()

    private let defaults = UserDefaults.standard

    // 所有设置都持久化。原来只有 step 存盘，重启后 zoneHeight 会回到 70pt、
    // deviceID 会回到「跟随系统默认」，看起来同样像“重启后就不对了”。
    var enabled: Bool {
        get { defaults.object(forKey: "vwEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "vwEnabled") }
    }
    var zoneHeight: CGFloat {             // 屏幕底部激活区高度（pt）
        get { (defaults.object(forKey: "vwZoneHeight") as? Double).map { CGFloat($0) } ?? 70 }
        set { defaults.set(Double(newValue), forKey: "vwZoneHeight") }
    }
    // 每格滚动音量步进（百分比，持久化，默认 1%）
    var step: Float {
        get { Float(defaults.object(forKey: "vwStepPercent") as? Int ?? 1) / 100.0 }
        set { defaults.set(Int(round(newValue * 100)), forKey: "vwStepPercent") }
    }
    var deviceID: AudioObjectID {         // 0 = 跟随系统默认输出设备
        get { AudioObjectID(defaults.object(forKey: "vwDeviceID") as? Int ?? 0) }
        set { defaults.set(Int(newValue), forKey: "vwDeviceID") }
    }
    // 每格滚动的详细日志默认关闭；打开：defaults write com.local.volumewheel vwVerboseLog -bool true
    var verboseLogging = UserDefaults.standard.bool(forKey: "vwVerboseLog")
    var tap: CFMachPort?
    /// true = 主动式 tap（可以吞掉事件，需要「辅助功能」授权）
    /// false = 只读 tap（只需要「输入监控」，但不能吞事件）
    var tapConsumesEvents = false
    var runLoopSource: CFRunLoopSource?
    var osd: OSDWindow?
    var statusItem: NSStatusItem?
    let menu = NSMenu()
    var deviceMenuDelegate: DeviceMenuDelegate?

    func effectiveDevice() -> AudioObjectID {
        deviceID != 0 ? deviceID : defaultOutputDevice()
    }

    /// 日志一律异步写。
    /// log() 会在 CGEventTap 回调里被调用，而在事件回调里做同步文件 I/O 会拖慢回调，
    /// 严重时会被系统判定为超时并禁用整个 tap（kCGEventTapDisabledByTimeout）。
    private let logQueue = DispatchQueue(label: "com.local.volumewheel.log")

    func log(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        logQueue.async {
            if let data = line.data(using: .utf8) {
                if let fh = FileHandle(forWritingAtPath: "/tmp/vw_log.txt") {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    try? fh.close()
                } else {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/vw_log.txt"))
                }
            }
        }
    }
}

// MARK: - 音量 OSD 反馈

final class VolumeBarView: NSView {
    var volume: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height

        let bg = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
        bg.fill()

        let trackH: CGFloat = 8
        let inset: CGFloat = 14
        let track = NSRect(x: inset, y: 9, width: w - inset * 2, height: trackH)
        NSColor(calibratedWhite: 1.0, alpha: 0.18).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackH / 2, yRadius: trackH / 2).fill()

        let v = min(max(volume, 0), 1)
        let fillW = max(track.width * v, 4)
        let fill = NSRect(x: track.minX, y: track.minY, width: fillW, height: track.height)
        NSColor(calibratedRed: 0.38, green: 0.78, blue: 1.0, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: fill, xRadius: trackH / 2, yRadius: trackH / 2).fill()

        let pct = Int(v * 100)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let s = NSAttributedString(string: String(format: loc("Volume  %d%%"), pct), attributes: attrs)
        let ss = s.size()
        s.draw(at: NSPoint(x: (w - ss.width) / 2, y: h - ss.height - 7))
    }
}

final class OSDWindow: NSWindow {
    private let bar = VolumeBarView(frame: .zero)
    private var hideTimer: Timer?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = bar
    }

    func show(volume: Float) {
        bar.volume = CGFloat(volume)
        if let scr = NSScreen.main {
            let f = scr.visibleFrame
            let x = f.midX - frame.width / 2
            let y = f.minY + 26
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            self?.orderOut(nil)
        }
    }
}

// MARK: - 全局滚轮事件回调（C 兼容）

let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let state = Unmanaged<AppState>.fromOpaque(userInfo).takeUnretainedValue()

    // 系统会主动禁用 tap：回调超时（.tapDisabledByTimeout）或用户输入（.tapDisabledByUserInput）。
    // 必须在这里重新启用，否则滚轮监听会静默失效——这是“跑着跑着就不灵了 / 休眠唤醒后失灵”的主因。
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = state.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        state.log("tap 被系统禁用 (type=\(type.rawValue))，已重新启用")
        return Unmanaged.passUnretained(event)
    }

    guard state.enabled else {
        return Unmanaged.passUnretained(event)
    }

    // 鼠标是否位于屏幕底部激活区
    let mouse = NSEvent.mouseLocation
    guard mouse.y <= state.zoneHeight else {
        return Unmanaged.passUnretained(event)
    }

    // 读取纵向滚轮 delta（行）
    let dyLines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    var delta = Float(dyLines)
    if abs(delta) < 0.01 {
        let pts = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        delta = Float(pts) * 0.08
    }
    guard abs(delta) > 0 else {
        return Unmanaged.passUnretained(event)
    }

    let dev = state.effectiveDevice()
    guard let vol = deviceVolume(dev) else {
        return Unmanaged.passUnretained(event)
    }
    let change = delta * state.step
    let newVol = min(max(vol + change, 0), 1)
    if state.verboseLogging {
        state.log("scroll delta=\(delta) mouseY=\(mouse.y) dev=\(dev) \(vol) -> \(newVol)")
    }
    setDeviceVolume(dev, newVol)
    state.osd?.show(volume: newVol)

    // 主动式 tap 才能吞掉事件；只读 tap 的返回值会被系统忽略，
    // 此时该区域的滚轮仍会传给下层窗口，但音量调节照常生效。
    return state.tapConsumesEvents ? nil : Unmanaged.passUnretained(event)
}

/// 辅助功能（Accessibility）授权状态。
/// prompt = true 时，如果尚未授权，系统会弹出标准授权框（带“打开系统设置”按钮）。
/// 主动式事件 tap（会吞/改事件）需要这项授权；只读监听不需要。
func accessibilityTrusted(prompt: Bool = false) -> Bool {
    guard prompt else { return AXIsProcessTrusted() }
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
}

// MARK: - App 委托

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var retryTimer: Timer?
    private var retryCount = 0
    private var firstFailureAt: Date?          // 首次发现权限不可用的时刻（用于延迟弹引导框）
    private var permissionAlertShown = false
    private var observersInstalled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState.shared
        state.log("== launched == pid=\(ProcessInfo.processInfo.processIdentifier) "
                  + "listen=\(CGPreflightListenEventAccess())")
        state.osd = OSDWindow()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        state.statusItem = item
        if let btn = item.button {
            btn.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                                accessibilityDescription: "VolumeWheel")
        }
        buildMenu()

        installSessionObservers()
        setupEventTap()
        checkPermissions()
        startTapSelfHeal()
    }

    // MARK: 会话激活 / 休眠唤醒 / 解锁：一旦发现 tap 不可用就立刻重建，不必等自愈轮询

    private func installSessionObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true

        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.rearmTap(reason: name.rawValue)
            }
        }
        // 锁屏解锁：开机登录早期 TCC（输入监控）要等到会话真正激活后才可用，这里补一次重建
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] _ in
            self?.rearmTap(reason: "screenIsUnlocked")
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.rearmTap(reason: "didBecomeActive")
        }
    }

    private func rearmTap(reason: String) {
        let state = AppState.shared
        if let tap = state.tap {
            CGEvent.tapEnable(tap: tap, enable: true)   // 可能被系统禁用了，直接重新启用
            return
        }
        state.log("re-arm(\(reason))：tap 为空，重建")
        retryCount = 0
        setupEventTap()
        if state.tap == nil { startTapSelfHeal() }
    }

    // MARK: 自愈：tap 未就绪时一直重试，直到权限就绪

    func startTapSelfHeal() {
        scheduleTapRetry()
    }

    func scheduleTapRetry() {
        retryTimer?.invalidate()
        let state = AppState.shared
        if state.tap != nil && state.tapConsumesEvents {   // 完全就绪，无需再自愈
            firstFailureAt = nil
            return
        }
        if firstFailureAt == nil { firstFailureAt = Date() }

        retryCount += 1
        // 前 12 次每 5s，之后每 15s。
        // 这里**故意不设重试上限**：开机登录后 TCC 可能要好几分钟才就绪，
        // 一旦放弃就只能由用户手动重启 App（这正是本来的故障）。
        let interval: TimeInterval = retryCount <= 12 ? 5 : 15

        // 关键修复：必须用 .common 模式调度定时器。
        // Timer.scheduledTimer 只注册在 .default 模式，而 NSAlert.runModal() 会把运行循环
        // 切到 NSModalPanelRunLoopMode —— 于是“授权引导框”一弹出来，自愈定时器就被彻底冻结。
        // 实测日志：首次重试被推迟了 6 分 43 秒，正好等于授权框停留在屏幕上的时间。
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            let st = AppState.shared

            // 情况 A：已经有 tap
            if st.tap != nil {
                guard !st.tapConsumesEvents else { return }   // 主动式，完全就绪
                // 目前是只读 tap（功能可用，只是不吞事件）。
                // 辅助功能一旦授权，就升级成主动式 tap，恢复「吞掉 Dock 区滚轮」的行为。
                if AXIsProcessTrusted() {
                    st.log("辅助功能已授权，升级为主动式 tap")
                    self.tearDownTap()
                    self.setupEventTap()
                }
                if st.tap != nil && st.tapConsumesEvents { return }
                self.scheduleTapRetry()      // 还没升级成功，继续等（15s 一次，不打扰）
                return
            }

            // 情况 B：完全没有 tap
            let listen = CGPreflightListenEventAccess()
            if self.retryCount <= 12 || self.retryCount % 20 == 0 {
                st.log("自愈重试 #\(self.retryCount): listen=\(listen) axTrusted=\(AXIsProcessTrusted())")
            }
            if listen || AXIsProcessTrusted() {
                self.setupEventTap()                // 权限已就绪，重建 tap
            }
            guard st.tap == nil else { return }

            // 先把下一次重试排上（.common 模式，即使随后弹窗也能继续触发）
            self.scheduleTapRetry()

            // 开机早期 TCC 未就绪属于正常现象，此时弹“缺少权限”是误报；
            // 持续 60s 仍拿不到权限，才引导用户去系统设置里授权。
            let waited = Date().timeIntervalSince(self.firstFailureAt ?? Date())
            if waited > 60, !self.permissionAlertShown {
                self.showPermissionGuide()
            }
        }
        retryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: 菜单

    func buildMenu() {
        let state = AppState.shared
        let m = state.menu
        m.removeAllItems()

        let toggle = NSMenuItem(title: loc("Enable Scroll Volume"), action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = state.enabled ? .on : .off
        m.addItem(toggle)

        m.addItem(.separator())

        // 输出设备选择
        let devItem = NSMenuItem(title: loc("Output Device"), action: nil, keyEquivalent: "")
        let dsub = NSMenu()
        dsub.autoenablesItems = false
        let delegate = DeviceMenuDelegate()
        delegate.owner = self
        dsub.delegate = delegate
        state.deviceMenuDelegate = delegate
        rebuildDeviceSubmenu(dsub)
        devItem.submenu = dsub
        m.addItem(devItem)

        // 设置（激活区高度 + 滚动步长）
        let settings = NSMenuItem(title: loc("Settings"), action: nil, keyEquivalent: "")
        let ssub = NSMenu()

        let zoneTitle = NSMenuItem(title: loc("Activation Zone Height"), action: nil, keyEquivalent: "")
        zoneTitle.isEnabled = false
        ssub.addItem(zoneTitle)
        let presets: [(String, CGFloat)] = [
            (loc("40 pt (near the bottom)"), 40),
            (loc("70 pt (dock area, recommended)"), 70),
            (loc("120 pt"), 120),
            (loc("200 pt"), 200),
            (loc("Anywhere (global)"), CGFloat.greatestFiniteMagnitude)
        ]
        for (label, h) in presets {
            let it = NSMenuItem(title: label, action: #selector(setZone(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = h
            it.state = (h == state.zoneHeight) ? .on : .off
            ssub.addItem(it)
        }

        ssub.addItem(.separator())

        let stepTitle = NSMenuItem(title: loc("Scroll Step (per notch)"), action: nil, keyEquivalent: "")
        stepTitle.isEnabled = false
        ssub.addItem(stepTitle)
        let steps: [(String, Int)] = [
            (loc("1% per notch"), 1),
            (loc("2% per notch"), 2),
            (loc("5% per notch"), 5)
        ]
        let currentStep = Int(round(state.step * 100))
        for (label, p) in steps {
            let it = NSMenuItem(title: label, action: #selector(setStep(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = p
            it.state = (p == currentStep) ? .on : .off
            ssub.addItem(it)
        }

        settings.submenu = ssub
        m.addItem(settings)

        m.addItem(.separator())

        // 权限状态（一眼看出当前是「能吞事件」还是「只监听」）
        let status = NSMenuItem(title: permissionStatusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        m.addItem(status)
        if !AXIsProcessTrusted() {
            let grant = NSMenuItem(title: loc("Grant Accessibility (to swallow scroll)"),
                                   action: #selector(openAccessibilitySettings), keyEquivalent: "")
            grant.target = self
            m.addItem(grant)
        }

        m.addItem(NSMenuItem(title: loc("Show Current Volume"), action: #selector(showVolume), keyEquivalent: "v"))
        let reauth = NSMenuItem(title: loc("Re-authorize Permission"), action: #selector(reauthorize), keyEquivalent: "")
        reauth.target = self
        m.addItem(reauth)
        m.addItem(NSMenuItem(title: loc("About"), action: #selector(about), keyEquivalent: ""))
        m.addItem(.separator())
        let quit = NSMenuItem(title: loc("Quit VolumeWheel"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        m.addItem(quit)

        for it in m.items {
            if it.action != nil { it.target = self }
        }
        state.statusItem?.menu = m
    }

    func rebuildDeviceSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = AppState.shared

        let follow = NSMenuItem(title: loc("Follow System Default"), action: #selector(setDevice(_:)), keyEquivalent: "")
        follow.target = self
        follow.representedObject = NSNumber(value: 0)
        follow.state = (state.deviceID == 0) ? .on : .off
        menu.addItem(follow)
        menu.addItem(.separator())

        let devices = outputDevices()
        if devices.isEmpty {
            let none = NSMenuItem(title: loc("No Adjustable Output Devices"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for (id, name) in devices {
            let it = NSMenuItem(title: name, action: #selector(setDevice(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = NSNumber(value: id)
            it.state = (state.deviceID == id) ? .on : .off
            menu.addItem(it)
        }
    }

    @objc func toggleEnabled() {
        AppState.shared.enabled.toggle()
        buildMenu()
    }

    @objc func setDevice(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        AppState.shared.deviceID = AudioObjectID(n.uint32Value)
        buildMenu()
    }

    @objc func setZone(_ sender: NSMenuItem) {
        guard let h = sender.representedObject as? CGFloat else { return }
        AppState.shared.zoneHeight = h
        buildMenu()
    }

    @objc func setStep(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? Int else { return }
        AppState.shared.step = Float(p) / 100.0
        buildMenu()
    }

    @objc func showVolume() {
        let dev = AppState.shared.effectiveDevice()
        if let v = deviceVolume(dev) {
            AppState.shared.osd?.show(volume: v)
        }
    }

    @objc func reauthorize() {
        permissionAlertShown = false
        retryCount = 0
        firstFailureAt = nil
        checkPermissions()
        // 用户主动点的：直接把缺的那一项面板打开
        openPrivacyPane(accessibility: CGPreflightListenEventAccess())
        startTapSelfHeal()
    }

    /// 菜单里显示的当前权限/运行状态
    func permissionStatusText() -> String {
        let listen = CGPreflightListenEventAccess()
        let ax = AXIsProcessTrusted()
        let listenMark = listen ? "✓" : "✗"
        let axMark = ax ? "✓" : "✗"
        let mode: String
        if AppState.shared.tapConsumesEvents {
            mode = loc("mode: swallowing scroll")
        } else if AppState.shared.tap != nil {
            mode = loc("mode: listen only (no swallowing)")
        } else {
            mode = loc("mode: not working yet")
        }
        return "\(loc("Input Monitoring")) \(listenMark)   \(loc("Accessibility")) \(axMark)   ·   \(mode)"
    }

    @objc func about() {
        let alert = NSAlert()
        alert.messageText = "VolumeWheel"
        alert.informativeText = loc("about_info")
        alert.addButton(withTitle: loc("OK"))
        alert.runModal()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: 事件监听

    /// 彻底销毁现有 tap（升级为主动式 tap 时需要先拆掉只读的那个）
    private func tearDownTap() {
        let state = AppState.shared
        if let src = state.runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        if let tap = state.tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        state.runLoopSource = nil
        state.tap = nil
        state.tapConsumesEvents = false
    }

    func setupEventTap() {
        let state = AppState.shared
        if let existing = state.tap {             // 已有 tap：只确保它处于启用状态
            CGEvent.tapEnable(tap: existing, enable: true)
            retryCount = 0
            firstFailureAt = nil
            return
        }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let info = Unmanaged.passUnretained(state).toOpaque()

        // 方案 1：主动式 tap —— 可以吞掉 Dock 区域的滚轮事件，
        // 但 macOS 要求这种「可修改事件」的 tap 必须有「辅助功能」授权。
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventCallback,
            userInfo: info) {
            install(tap: tap, consumesEvents: true)
            return
        }

        // 方案 2：退一步用只读 tap —— 只需要「输入监控」授权，功能照常可用，
        // 唯一区别是该区域的滚轮仍会传给下层窗口（不吞事件）。
        // 这样即使辅助功能没授权，用户也不会遇到「完全不能用」。
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: eventCallback,
            userInfo: info) {
            install(tap: tap, consumesEvents: false)
            return
        }

        // 两种都不行：开机登录早期 tccd 尚未就绪时会出现这种情况，
        // 交给 scheduleTapRetry() 持续重试即可（不再设上限）。
        state.log("!! tapCreate FAILED(both); listen=\(CGPreflightListenEventAccess()) axTrusted=\(AXIsProcessTrusted())")
    }

    private func install(tap: CFMachPort, consumesEvents: Bool) {
        let state = AppState.shared
        state.tap = tap
        state.tapConsumesEvents = consumesEvents
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        state.runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        retryCount = 0
        firstFailureAt = nil
        permissionAlertShown = false
        state.log("tap enabled ok; mode=\(consumesEvents ? "active/吞事件" : "listenOnly/只监听"); "
                  + "listen=\(CGPreflightListenEventAccess()) axTrusted=\(AXIsProcessTrusted())")
    }

    func checkPermissions() {
        let state = AppState.shared
        NSApp.activate(ignoringOtherApps: true)

        // 「输入监控」：只读监听的最低要求，用系统标准弹窗请求
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            if !CGPreflightListenEventAccess() {
                let granted = CGRequestListenEventAccess()
                state.log("CGRequestListenEventAccess returned \(granted); "
                          + "listen=\(CGPreflightListenEventAccess()) axTrusted=\(AXIsProcessTrusted())")
            }
            if AppState.shared.tap == nil { self.setupEventTap() }

            // 「辅助功能」：只有它能让 tap 变成主动式（吞掉 Dock 区滚轮）。
            // 如果现在只拿到了只读 tap，说明缺的正是这项，弹系统标准授权框引导一次。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self else { return }
                let st = AppState.shared
                if st.tap != nil && !st.tapConsumesEvents && !AXIsProcessTrusted() {
                    state.log("只读 tap 已就绪；请求辅助功能以启用「吞事件」")
                    _ = accessibilityTrusted(prompt: true)
                } else if st.tap == nil && !AXIsProcessTrusted() {
                    _ = accessibilityTrusted(prompt: true)
                }
                self.startTapSelfHeal()
            }
        }
    }

    /// 引导用户去系统设置授权（输入监控 / 辅助功能）。
    /// 注意：runModal() 会把运行循环切到 modal 模式，因此自愈定时器必须注册在
    /// .common 模式（见 scheduleTapRetry），否则弹窗期间自愈会被冻死。
    private func showPermissionGuide() {
        guard !permissionAlertShown else { return }
        permissionAlertShown = true
        let needListen = !CGPreflightListenEventAccess()
        let alert = NSAlert()
        alert.messageText = loc(needListen ? "Input Monitoring Permission Required"
                                           : "Accessibility Permission Required")
        alert.informativeText = loc("permission_info")
        alert.addButton(withTitle: loc("Open System Settings"))
        alert.addButton(withTitle: loc("Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            openPrivacyPane(accessibility: !needListen)
        }
    }

    @objc func openAccessibilitySettings() {
        openPrivacyPane(accessibility: true)
    }

    private func openPrivacyPane(accessibility: Bool) {
        let pane = accessibility ? "Privacy_Accessibility" : "Privacy_ListenEvent"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 输出设备子菜单动态刷新

final class DeviceMenuDelegate: NSObject, NSMenuDelegate {
    weak var owner: AppDelegate?
    func menuNeedsUpdate(_ menu: NSMenu) {
        owner?.rebuildDeviceSubmenu(menu)
    }
}

// MARK: - 启动

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
