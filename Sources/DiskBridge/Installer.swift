import Foundation
import Darwin

enum NativeInstaller {
    static let agentLabel = "com.local.appdatamount"
    static let uiLabel = "com.local.appdatamount.statusbar"
    static func dataRoot(home: URL, runtime: URL, explicit: String? = nil) throws -> URL {
        if let explicit { return URL(fileURLWithPath: normalized(explicit)) }
        let defaultRoot = home.appendingPathComponent("Library/Application Support/DiskBridge")
        let settings = try readObject(runtime.appendingPathComponent("settings.json"), fallback: [:])
        let remembered = settings.s("root")
        if !remembered.isEmpty {
            guard remembered.hasPrefix("/"), normalized(remembered) != "/" else { throw DBError("已保存的数据目录无效，请显式指定 --root。") }
            let root = URL(fileURLWithPath: normalized(remembered))
            if root.path != defaultRoot.path && !exists(root.appendingPathComponent("config.json").path) && !exists(root.appendingPathComponent("state.json").path) {
                throw DBError("原数据目录中的迁移记录不可用，未创建空记录。请恢复原目录或显式指定 --root。")
            }
            return root
        }
        return defaultRoot
    }
    static func currentApplication() -> URL {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var candidate = executable
        while candidate.path != "/" { if candidate.pathExtension == "app" { return candidate }; candidate.deleteLastPathComponent() }
        return Bundle.main.bundleURL
    }
    static func file(_ label: String) -> URL { nativeFM.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    static func plistWrite(_ value: Object, at url: URL) throws {
        try privateDirectory(url.deletingLastPathComponent())
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        try data.write(to: url, options: .atomic); guard chmod(url.path, 0o600) == 0 else { throw DBError.io(errno) }
    }
    static func load(_ url: URL) -> Object? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? Object
    }
    static func install(root: URL, runtime: URL, application: URL, system: NativeSystem = NativeSystem(), replace: Bool = false) throws {
        let binary = application.appendingPathComponent("Contents/MacOS/DiskBridge").path
        guard exists(binary) else { throw DBError("盘桥原生可执行文件不存在。") }
        try privateDirectory(runtime)
        let existing = load(file(agentLabel))
        let switching = replace || (existing?["ProgramArguments"] as? [String])?.first != binary
        let switchLock = switching ? try NativeStore(root).lock("切换盘桥原生后台") : nil
        defer { withExtendedLifetime(switchLock) {} }
        let enabled = (try? NativeStore(root).config.o("preferences").b("login_start", true)) ?? true
        let definitions: [(String, [String])] = [(agentLabel, [binary, "--agent", "--root", root.path, "--runtime", runtime.path]),
                                               (uiLabel, [binary, "--background", "--root", root.path, "--runtime", runtime.path])]
        for (label, arguments) in definitions {
            let path = file(label), old = load(path)
            if let old, old.s("AppDataMountRoot", old.s("DiskBridgeRoot")) != root.path { throw DBError("同名登录任务不属于当前工具，未覆盖。") }
            var value: Object = ["Label": label, "ProgramArguments": arguments, "RunAtLoad": enabled, "ProcessType": label == agentLabel ? "Background" : "Interactive",
                "DiskBridgeRoot": root.path, "AppDataMountRoot": root.path, "StandardErrorPath": runtime.appendingPathComponent(label == agentLabel ? "agent-error.log" : "ui-error.log").path, "Umask": 0o077]
            if label == agentLabel { value["KeepAlive"] = enabled ? ["SuccessfulExit": false] : false as Any; value["ThrottleInterval"] = 10 }
            let changed = replace || (old?["ProgramArguments"] as? [String]) != arguments
            if changed {
                if let old {
                    let backup = runtime.appendingPathComponent("previous-agents/\(label).plist")
                    if !exists(backup.path) { try plistWrite(old, at: backup) }
                    // Never replace a backend while it owns a data operation.
                    _ = try? system.command("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 10)
                }
                try plistWrite(value, at: path)
                _ = try system.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", path.path], timeout: 15)
            } else {
                try plistWrite(value, at: path)
                let status = try system.command("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"], timeout: 5)
                if status.code != 0 { _ = try system.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", path.path], timeout: 15) }
            }
            if label == agentLabel { _ = try system.run("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(label)"], timeout: 10) }
        }
        try writeObject(["root": root.path, "application": application.path, "native": true, "product_name": "盘桥"], to: runtime.appendingPathComponent("settings.json"))
    }
    static func updateLogin(_ enabled: Bool, root: URL) throws {
        for label in [agentLabel, uiLabel] {
            let path = file(label)
            guard var value = load(path), value.s("DiskBridgeRoot") == root.path else { continue }
            value["RunAtLoad"] = enabled
            if label == agentLabel { value["KeepAlive"] = enabled ? ["SuccessfulExit": false] : false as Any }
            try plistWrite(value, at: path)
        }
    }
}
