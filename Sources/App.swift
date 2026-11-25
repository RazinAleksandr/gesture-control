import AppKit
import AVFoundation
import QuartzCore

func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    FileHandle.standardError.write("[\(f.string(from: Date()))] \(s)\n".data(using: .utf8)!)
}

@MainActor final class AppController: NSObject, NSApplicationDelegate {
    let camera = Camera()
    let engine = GestureEngine()
    let picker = WindowPicker()
    let toast = Toast()
    let guide = GestureGuide()
    var hud: HUD?
    var statusItem: NSStatusItem!
    var enabledItem: NSMenuItem!
    var hudItem: NSMenuItem!
    var lastStatusLog: TimeInterval = 0
    var axTrusted = false
    var handSeenFrames = 0
    var frames = 0
    lazy var trace: FileHandle? = {
        guard CommandLine.arguments.contains("--trace") else { return nil }
        let url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("../../../trace.log").standardized
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let s = ProcessInfo.processInfo.environment["GC_SCROLL_SIGN"], let v = Double(s) { engine.cfg.scrollSign = CGFloat(v) }
        setupMenu()
        // start switched off: gestures work only after 👍 (held 1 s) or the menu
        if !CommandLine.arguments.contains("--on") { engine.enabled = false; updateEnabledUI() }
        picker.onClosed = { [weak self] in
            MainActor.assumeIsolated { self?.engine.pickerClosedExternally(now: CACurrentMediaTime()) }
        }
        picker.onEvent = { log("picker: \($0)") }
        axTrusted = Actions.accessibilityTrusted
        log("accessibility trusted: \(axTrusted)")
        if !axTrusted { Actions.requestAccessibility() }
        log("cameras: " + Camera.allDevices().map(\.localizedName).joined(separator: ", "))
        Camera.authorize { ok in
            MainActor.assumeIsolated { self.cameraAuthorized(ok) }
        }
        // re-check accessibility periodically (user may grant it while the app runs)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let t = Actions.accessibilityTrusted
                if t != self.axTrusted { self.axTrusted = t; log("accessibility trusted: \(t)") }
            }
        }
    }

    private func cameraAuthorized(_ ok: Bool) {
        guard ok else {
            log("camera access denied")
            alert(tr("No camera access", "Нет доступа к камере", "没有摄像头权限"),
                  tr("Allow the camera: System Settings → Privacy & Security → Camera → Gesture Control.",
                     "Разрешите камеру: Системные настройки → Конфиденциальность и безопасность → Камера → Gesture Control.",
                     "请允许使用摄像头：系统设置 → 隐私与安全性 → 摄像头 → Gesture Control。"))
            return
        }
        let pref = argValue("--camera") ?? ProcessInfo.processInfo.environment["GC_CAMERA"]
        do {
            try camera.configure(preferred: pref)
        } catch {
            log("camera error: \(error.localizedDescription)")
            alert(tr("The camera did not start", "Камера не запустилась", "摄像头未能启动"), error.localizedDescription)
            return
        }
        log("camera: \(camera.deviceName)")
        let hud = HUD(session: camera.session)
        self.hud = hud
        hud.onHelp = { [weak self] in MainActor.assumeIsolated { self?.guide.show() } }
        hud.onQuit = { MainActor.assumeIsolated { log("quit from camera panel"); NSApp.terminate(nil) } }
        hud.onCollapsedChanged = { [weak self] collapsed in
            MainActor.assumeIsolated { log("camera preview \(collapsed ? "hidden" : "shown")"); _ = self }
        }
        hud.show()
        // first launch: show the gesture guide once
        if !UserDefaults.standard.bool(forKey: "gc.guideShown") || CommandLine.arguments.contains("--guide") {
            UserDefaults.standard.set(true, forKey: "gc.guideShown")
            guide.show()
        }
        camera.onHand = { [weak self] h in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(h) } }
        }
        camera.start()
    }

    private func handle(_ h: HandFrame?) {
        let now = CACurrentMediaTime()
        frames += 1
        if h != nil { handSeenFrames += 1 }
        let actions = engine.process(h, now: now)
        if trace != nil, h != nil {
            let line = String(format: "%.3f ", now) + engine.debugLine + (actions.isEmpty ? "" : " ACT=\(actions)") + "\n"
            trace?.write(line.data(using: .utf8)!)
        }
        for a in actions { perform(a, now: now) }
        var label = engine.label
        if !axTrusted { label = tr("no Accessibility access · ", "нет доступа «Универсальный доступ» · ", "未获得辅助功能权限 · ") + label }
        hud?.update(hand: h, mode: engine.mode, label: label)
        if now - lastStatusLog > 3 {
            lastStatusLog = now
            log(String(format: "fps=%.1f vision=%.1fms hand=%d/%d pose=%@ mode=%@",
                       camera.fps, camera.visionMs, handSeenFrames, frames, engine.stablePose.rawValue, engine.mode.rawValue))
            handSeenFrames = 0; frames = 0
        }
    }

    private func perform(_ a: EngineAction, now: TimeInterval) {
        switch a {
        case .setEnabled(let on):
            log("gestures \(on ? "ON" : "OFF") (thumb up)")
            updateEnabledUI()
            announceEnabled()
            if !on { picker.close() }
        case .scrollBegin:
            Actions.ensureCursorInFocusedWindow()
        case .scroll(let dx, let dy):
            Actions.scroll(dx: dx, dy: dy)
        case .swipe(let d):
            log("swipe \(d.rawValue)")
            switch d {
            case .left: Actions.switchSpace(toRight: true)    // hand moves left → next space (like the trackpad)
            case .right: Actions.switchSpace(toRight: false)
            case .up: Actions.missionControl()
            }
        case .openPicker:
            let n = picker.open()
            log("picker open: \(n) windows")
            if n == 0 { engine.pickerClosedExternally(now: now) }
        case .pickerPointer(let p):
            picker.updatePointer(p)
        case .pickerPinch(let v):
            picker.setPinchProgress(v)
        case .pickerSelect(let p):
            let r = picker.select(at: p)
            log("picker select: \(r ?? "nothing")")
            if r == nil { picker.close() }
        case .closePicker:
            log("picker cancel")
            picker.close()
        }
    }

    // MARK: menu

    private var helpItem: NSMenuItem!
    private var axItem: NSMenuItem!
    private var quitItem: NSMenuItem!
    private var langItem: NSMenuItem!

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✋"
        let menu = NSMenu()
        enabledItem = NSMenuItem(title: "", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.state = .on
        hudItem = NSMenuItem(title: "", action: #selector(toggleHUD), keyEquivalent: "")
        hudItem.state = .on
        helpItem = NSMenuItem(title: "", action: #selector(showHelp), keyEquivalent: "/")
        axItem = NSMenuItem(title: "", action: #selector(openAXSettings), keyEquivalent: "")
        langItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for l in Lang.allCases {
            let it = NSMenuItem(title: l.title, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
            it.representedObject = l.rawValue
            it.target = self
            langMenu.addItem(it)
        }
        langItem.submenu = langMenu
        quitItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "q")
        menu.addItem(enabledItem)
        menu.addItem(hudItem)
        menu.addItem(helpItem)
        menu.addItem(langItem)
        menu.addItem(axItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
        applyMenuTexts()
        NotificationCenter.default.addObserver(forName: .gcLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyMenuTexts() }
        }
    }

    private func applyMenuTexts() {
        enabledItem.title = tr("Gestures on", "Жесты включены", "启用手势")
        hudItem.title = tr("Show camera", "Показывать камеру", "显示摄像头")
        helpItem.title = tr("Gesture guide…", "Справка по жестам…", "手势说明…")
        langItem.title = tr("Language", "Язык", "语言")
        axItem.title = tr("Open Accessibility settings", "Открыть настройки «Универсальный доступ»", "打开辅助功能设置")
        quitItem.title = tr("Quit", "Выйти", "退出")
        for it in langItem.submenu?.items ?? [] {
            it.state = (it.representedObject as? String) == L10n.shared.lang.rawValue ? .on : .off
        }
    }

    @objc func chooseLanguage(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let l = Lang(rawValue: raw) { L10n.shared.lang = l }
    }

    @objc func toggleEnabled() {
        engine.enabled.toggle()
        updateEnabledUI()
        announceEnabled()
        if !engine.enabled { picker.close() }
    }

    func announceEnabled() {
        toast.show(enabled: engine.enabled)
        NSSound(named: engine.enabled ? "Glass" : "Bottle")?.play()
    }

    func updateEnabledUI() {
        enabledItem?.state = engine.enabled ? .on : .off
        statusItem?.button?.title = engine.enabled ? "✋" : "✋⏸"
    }

    @objc func toggleHUD() {
        guard let hud else { return }
        if hud.isVisible { hud.hide(); hudItem.state = .off } else { hud.show(); hudItem.state = .on }
    }

    @objc func showHelp() { guide.show() }

    @objc func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func quit() { NSApp.terminate(nil) }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

func argValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// Entry point, called by the launcher (Launcher/main.c) on the main thread.
@_cdecl("gc_main")
public func gc_main() -> Int32 {
    let args = CommandLine.arguments
    if let l = argValue("--lang").flatMap(Lang.init(rawValue:)) { L10n.shared.lang = l }
    if args.contains("--selftest") { return SelfTest.run() }
    return MainActor.assumeIsolated {
        if let path = argValue("--render-picker") {
            WindowPicker().renderDebugPNG(to: URL(fileURLWithPath: path), pointer: CGPoint(x: 0.4, y: 0.45),
                                          size: CGSize(width: 1728, height: 1117))
            print("rendered \(path)")
            return 0
        }
        if let path = argValue("--render-guide") {
            GestureGuide.renderPNG(to: URL(fileURLWithPath: path))
            print("rendered \(path)")
            return 0
        }
        if args.contains("--list-windows") {
            for w in WindowPicker.listWindows() { print("\(w.appName) — \(w.title)  \(w.frame)") }
            return 0
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = AppController()
        app.delegate = controller
        log("Gesture Control started")
        app.run()
        return 0
    }
}
