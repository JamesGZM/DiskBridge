import AppKit
import SwiftUI
import Darwin

final class BridgeDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model: BridgeModel
    let application: URL
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    var window: NSWindow?, settingsWindow: NSWindow?
    var instanceLock: NativeLock?
    var timer: Timer?, lastMenu = Date.distantPast
    var spin: CGFloat = 0, exitingWhenSafe = false
    var menuTracking = false, duplicateInstance = false
    init(root: URL, runtime: URL, application: URL) {
        model = BridgeModel(root: root, runtime: runtime); self.application = application; super.init()
        model.openSettings = { [weak self] in self?.showSettings() }
        model.openAuthorization = { [weak self] in self?.authorize() }
        model.refreshRegistration = { [weak self] in self?.registration() }
        model.recheckAuthorization = { [weak self] in self?.recheckAuthorization() }
        model.onAuthorizationRequired = { [weak self] in
            DispatchQueue.main.async { self?.showManager(); self?.authorize() }
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do { instanceLock = try NativeLock(model.runtime.appendingPathComponent("ui.lock"), label: "盘桥界面") }
        catch {
            duplicateInstance = true
            try? writeObject(["show": true], to: model.runtime.appendingPathComponent("show-window.json")); NSApp.terminate(nil); return
        }
        buildMainMenu(); status.menu = menu; menu.delegate = self
        status.button?.title = ""
        registration()
        model.refresh()
        let tick = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(tick, forMode: .common); timer = tick
        if !CommandLine.arguments.contains("--background") { showManager() }
    }
    func buildMainMenu() {
        let bar = NSMenu(), applicationMenu = NSMenu(), holder = NSMenuItem()
        holder.submenu = applicationMenu; bar.addItem(holder)
        func item(_ title: String, _ selector: Selector, _ key: String = "") -> NSMenuItem { let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self; return item }
        applicationMenu.addItem(item("关于盘桥", #selector(about)))
        applicationMenu.addItem(item("设置…", #selector(settingsAction), ","))
        applicationMenu.addItem(.separator()); applicationMenu.addItem(item("退出盘桥", #selector(quit), "q"))
        let edit = NSMenu(title: "编辑"), editHolder = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        editHolder.submenu = edit; bar.addItem(editHolder); NSApp.mainMenu = bar
    }
    func registration() {
        DispatchQueue.global(qos: .utility).async { [self] in
            do {
                try NativeInstaller.install(root: model.root, runtime: model.runtime, application: application)
                DispatchQueue.main.async {
                    self.model.send("probe") { response in
                        if response.o("result").b("passed") { self.model.authorization(false); self.model.error = "" }
                        self.model.refresh()
                    }
                }
            }
            catch { DispatchQueue.main.async { self.model.error = error.localizedDescription; self.model.needsAuthorization = (error as? DBError)?.reason == "authorization" } }
        }
    }
    @objc func showManager() {
        if window == nil {
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            value.title = "盘桥"; value.toolbarStyle = .unifiedCompact
            value.contentView = NSHostingView(rootView: BridgeView(model: model)); value.isReleasedWhenClosed = false; value.center(); window = value
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showSettings() {
        if settingsWindow == nil {
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            value.title = "盘桥设置"; value.contentView = NSHostingView(rootView: BridgeSettingsView(model: model)); value.isReleasedWhenClosed = false; value.center(); settingsWindow = value
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func settingsAction() { showSettings() }
    func authorize() {
        let alert = NSAlert(); alert.messageText = "盘桥需要完全磁盘访问权限"
        alert.informativeText = "此权限用于迁移、挂载和还原应用数据。点击下方按钮后，在系统设置点 +，添加 Finder 中选中的盘桥.app，并开启开关。授权后选择系统的“退出并重新打开”；如果盘桥已关闭，重新打开即可自动复查并继续挂载。"
        alert.addButton(withTitle: "前往系统设置"); alert.addButton(withTitle: "稍后处理")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.activateFileViewerSelecting([application])
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }
    func recheckAuthorization() {
        DispatchQueue.global(qos: .utility).async { [self] in
            do {
                let binary = application.appendingPathComponent("Contents/MacOS/DiskBridge").path
                guard (NativeInstaller.load(NativeInstaller.file(NativeInstaller.agentLabel))?["ProgramArguments"] as? [String])?.first == binary else {
                    throw DBError("请先重新打开盘桥，完成原生后台登记。")
                }
                let lock = try NativeStore(model.root).lock("重新检查原生后台授权")
                defer { withExtendedLifetime(lock) {} }
                _ = try NativeSystem().run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(NativeInstaller.agentLabel)"], timeout: 15)
                DispatchQueue.main.async {
                    self.model.error = ""; self.model.needsAuthorization = false
                    self.model.send("probe") { response in
                        if response.o("result").b("passed") { self.model.error = ""; self.model.authorization(false) }
                        self.model.refresh()
                    }
                }
            } catch { DispatchQueue.main.async { self.model.error = error.localizedDescription } }
        }
    }
    func tick() {
        let command = model.runtime.appendingPathComponent("show-window.json")
        if exists(command.path) { try? nativeFM.removeItem(at: command); showManager() }
        let active = model.tasks.filter(\.active), automatic = model.automatic
        let busy = active.contains { $0.phase == "running" } || automatic.s("phase") == "running"
        let waiting = active.contains { $0.phase == "waiting" } || automatic.s("phase") == "waiting"
        let failures = model.tasks.filter { $0.phase == "failed" }.first
        let successTime = model.tasks.filter { $0.phase == "complete" }.first?.value.n("finished_ns") ?? 0
        let failed = model.needsAuthorization || ((failures?.value.n("finished_ns") ?? 0) > successTime) ||
            (automatic.s("phase") == "failed" && automatic.n("finished_ns") > successTime)
        let eligible = model.migratedApps.filter { $0.value.b("auto_mount") }
        let ready = !eligible.isEmpty && eligible.allSatisfy(\.mounted) && !busy && !waiting
        let unavailable = !eligible.isEmpty && !eligible.allSatisfy(\.mounted)
        let title = busy ? "正在执行任务" : waiting ? "等待处理" : failed ? "需要处理" : ready ? "挂载就绪" : unavailable ? "等待挂载" : "待命"
        if busy {
            spin += 0.13
            let phase = spin
            let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
                NSColor.black.setStroke()
                let arc = NSBezierPath(); arc.lineWidth = 1.6; arc.lineCapStyle = .round
                arc.appendArc(withCenter: NSPoint(x: 11, y: 11), radius: 8.5, startAngle: phase * 180 / .pi, endAngle: phase * 180 / .pi + 260)
                arc.stroke(); NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)?.draw(in: NSRect(x: 5, y: 7, width: 12, height: 8)); return true
            }; image.isTemplate = true; status.button?.image = image
        } else {
            let symbol = waiting ? "clock" : failed ? "exclamationmark.circle" : ready ? "externaldrive.badge.checkmark" : unavailable ? "clock" : "externaldrive"
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); image?.isTemplate = true; status.button?.image = image
        }
        status.button?.title = ""; status.button?.toolTip = "盘桥 · " + title; status.button?.setAccessibilityLabel("盘桥，" + title)
        if Date().timeIntervalSince(lastMenu) > 1 { refreshMenu(title); lastMenu = Date() }
        if exitingWhenSafe && !model.tasks.contains(where: \.active) { NSApp.terminate(nil) }
    }
    func refreshMenu(_ title: String) {
        if menuTracking { return }
        menu.removeAllItems()
        let heading = NSMenuItem(title: "盘桥 · " + title, action: nil, keyEquivalent: ""); heading.isEnabled = false; menu.addItem(heading)
        for app in model.migratedApps {
            let item = NSMenuItem(title: app.name + " · " + (app.mounted ? "已挂载" : "等待挂载"), action: #selector(openApp(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = app.id; item.image = NSWorkspace.shared.icon(forFile: app.value.s("app_path")); item.image?.size = NSSize(width: 18, height: 18); menu.addItem(item)
        }
        if let task = model.tasks.first(where: \.active) {
            let stage = NSMenuItem(title: task.value.s("app_name") + " · " + task.value.s("label"), action: nil, keyEquivalent: ""); stage.isEnabled = false; menu.addItem(stage)
        }
        menu.addItem(.separator())
        for (title, selector) in [("打开盘桥…", #selector(showManager)), ("挂载全部应用", #selector(mountAll)), ("任务管理…", #selector(showTasks)), ("设置…", #selector(settingsAction))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator()); let quit = NSMenuItem(title: "退出盘桥", action: #selector(quit), keyEquivalent: ""); quit.target = self; menu.addItem(quit)
    }
    func menuWillOpen(_ menu: NSMenu) { refreshMenu(status.button?.toolTip ?? "盘桥"); menuTracking = true }
    func menuDidClose(_ menu: NSMenu) { menuTracking = false; lastMenu = Date.distantPast }
    @objc func openApp(_ sender: NSMenuItem) { if let id = sender.representedObject as? String, let app = model.apps.first(where: { $0.id == id }) { model.openApp(app) } }
    @objc func mountAll() { model.send("mount", visible: true) { _ in self.model.refresh() } }
    @objc func showTasks() { model.page = "tasks"; showManager() }
    @objc func about() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "盘桥", .applicationVersion: version, .credits: NSAttributedString(string: "应用数据外置管理 · Swift 原生实现")])
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showManager(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if duplicateInstance { return .terminateNow }
        let active = model.tasks.filter(\.active)
        if !active.isEmpty {
            let alert = NSAlert(); alert.messageText = "仍有后台任务"
            alert.informativeText = "可以关闭窗口留在后台，或在安全检查点停止后退出。"
            alert.addButton(withTitle: "留在后台"); alert.addButton(withTitle: "安全停止后退出"); alert.addButton(withTitle: "取消")
            let answer = alert.runModal()
            if answer == .alertFirstButtonReturn { window?.orderOut(nil); return .terminateCancel }
            if answer == .alertSecondButtonReturn { exitingWhenSafe = true; for task in active { model.send("cancel", ["task_id": task.id]) }; return .terminateCancel }
            return .terminateCancel
        }
        let ownBinary = application.appendingPathComponent("Contents/MacOS/DiskBridge").path
        if (NativeInstaller.load(NativeInstaller.file(NativeInstaller.agentLabel))?["ProgramArguments"] as? [String])?.first == ownBinary {
            _ = try? NativeSystem().command("/bin/launchctl", ["bootout", "gui/\(getuid())/\(NativeInstaller.agentLabel)"], timeout: 10)
        }
        return .terminateNow
    }
}

@main struct DiskBridgeMain {
    static func main() {
        let args = CommandLine.arguments
        func argument(_ name: String) -> String? { guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }; return args[index + 1] }
        let application = NativeInstaller.currentApplication()
        let home = nativeFM.homeDirectoryForCurrentUser
        let runtime = URL(fileURLWithPath: normalized(argument("--runtime") ?? home.appendingPathComponent("Library/Application Support/DiskBridge/runtime").path))
        do {
            let root = try NativeInstaller.dataRoot(home: home, runtime: runtime, explicit: argument("--root"))
            if args.contains("--agent") { try NativeService(root: root, runtime: runtime).serve(); return }
            if args.contains("--install") { try NativeInstaller.install(root: root, runtime: runtime, application: application); print("盘桥原生后台与界面已登记。"); return }
            if args.contains("--diagnose") {
                let store = try NativeStore(root), task = NativeTask("diagnose")
                var results: Object = [:]
                for key in store.apps.keys where store.records.o(key).s("phase") == "active" {
                    do { results[key] = ["mounted": try NativeEngine(store, task: task).isMounted(key)] }
                    catch { results[key] = ["error": error.localizedDescription] }
                }
                var authorization: Object = [:]
                do { try NativeSystem().checkAuthorization(store); authorization["passed"] = true }
                catch { authorization = ["passed": false, "message": error.localizedDescription] }
                let data = try JSONSerialization.data(withJSONObject: ["native": true, "apps": results, "authorization": authorization], options: [.prettyPrinted, .sortedKeys]); print(String(decoding: data, as: UTF8.self)); return
            }
            let app = NSApplication.shared, delegate = BridgeDelegate(root: root, runtime: runtime, application: application)
            app.delegate = delegate; withExtendedLifetime(delegate) { app.run() }
        } catch { fputs("盘桥：\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
