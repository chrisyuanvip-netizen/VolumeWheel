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
    var enabled = true
    var zoneHeight: CGFloat = 70          // 屏幕底部激活区高度（pt）
    var step: Float = 0.02                // 每格滚动音量步进
    var deviceID: AudioObjectID = 0       // 0 = 跟随系统默认输出设备
    var tap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var osd: OSDWindow?
    var statusItem: NSStatusItem?
    let menu = NSMenu()
    var deviceMenuDelegate: DeviceMenuDelegate?

    func effectiveDevice() -> AudioObjectID {
        deviceID != 0 ? deviceID : defaultOutputDevice()
    }

    func log(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
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

        let pct = String(Int(v * 100))
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

let eventCallback: CGEventTapCallBack = { _, _, event, userInfo in
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let state = Unmanaged<AppState>.fromOpaque(userInfo).takeUnretainedValue()
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
    state.log("scroll delta=\(delta) mouseY=\(mouse.y) dev=\(dev) \(vol) -> \(newVol)")
    setDeviceVolume(dev, newVol)
    state.osd?.show(volume: newVol)

    // 吞掉事件：该区域滚轮不再触发页面滚动
    return nil
}

// MARK: - App 委托

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState.shared
        state.log("== launched ==")
        state.osd = OSDWindow()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        state.statusItem = item
        if let btn = item.button {
            btn.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                                accessibilityDescription: "VolumeWheel")
        }
        buildMenu()

        setupEventTap()
        checkPermissions()
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

        // 激活区高度
        let zone = NSMenuItem(title: loc("Activation Zone Height"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
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
            sub.addItem(it)
        }
        zone.submenu = sub
        m.addItem(zone)

        m.addItem(.separator())
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

    @objc func showVolume() {
        let dev = AppState.shared.effectiveDevice()
        if let v = deviceVolume(dev) {
            AppState.shared.osd?.show(volume: v)
        }
    }

    @objc func reauthorize() {
        checkPermissions()
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

    func setupEventTap() {
        let state = AppState.shared
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventCallback,
            userInfo: Unmanaged.passUnretained(state).toOpaque())
        else {
            state.log("!! tapCreate FAILED; listen=\(CGPreflightListenEventAccess()) axTrusted=\(AXIsProcessTrusted())")
            // CGEventTap 需要「输入监控」权限，主动请求（系统会把当前实例加入输入监控）
            _ = CGRequestListenEventAccess()
            return
        }
        state.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        state.runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        state.log("tap enabled ok; listen=\(CGPreflightListenEventAccess())")
    }

    func checkPermissions() {
        let state = AppState.shared
        if CGPreflightListenEventAccess() { return }
        // 激活到前台，让系统的“输入监控”授权框能够弹出
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            let granted = CGRequestListenEventAccess()
            state.log("CGRequestListenEventAccess returned \(granted); listen now \(CGPreflightListenEventAccess())")
            // 授权成功则立即重建 tap
            if CGPreflightListenEventAccess() {
                state.log("获得输入监控权限，重建 tap")
                self.setupEventTap()
                return
            }
            // 未授权，弹自定义引导
            let alert = NSAlert()
            alert.messageText = loc("Input Monitoring Permission Required")
            alert.informativeText = loc("permission_info")
            alert.addButton(withTitle: loc("Open System Settings"))
            alert.addButton(withTitle: loc("Later"))
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
            }
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
