import AppKit
import SwiftUI
import UserNotifications

func formattedBytes(_ value: Any?) -> String {
    guard let value = value as? NSNumber else { return "—" }
    if value.int64Value == 0 { return "0 KB" }
    return ByteCountFormatter.string(fromByteCount: value.int64Value, countStyle: .file)
}
let actionNames: [String: String] = ["migrate": "迁移应用", "rollback": "还原到内置硬盘", "recover": "继续任务", "mount": "挂载应用", "automatic": "自动挂载",
    "confirm": "应用验收", "delete_original": "清理原件备份", "delete_archived_original": "清理旧原件备份", "delete_retained": "清理外置副本", "unmount": "安全卸载", "plan": "统计迁移范围", "rollback_plan": "还原预览", "estimate": "统计数据大小", "prepare_launch": "挂载就绪后打开"]
struct BridgeApp: Identifiable {
    let value: Object
    var id: String { value.s("id") }
    var name: String { value.s("name") }
    var paths: [Object] { value.list("paths") }
    var migrated: Bool { value.s("migration_state") == "migrated" }
    var pending: Bool { value.s("migration_state") == "pending" }
    var incomplete: Bool { value.s("migration_state") == "incomplete" }
    var stateName: String { migrated ? "已迁移" : pending ? "待验收" : incomplete ? "待恢复" : "未迁移" }
    var mounted: Bool { value.b("mounted") }
}
struct BridgeTask: Identifiable {
    let value: Object
    var id: String { value.s("id") }
    var phase: String { value.s("phase") }
    var active: Bool { ["queued", "running", "waiting"].contains(phase) }
    var attention: Bool { ["failed", "stopped", "interrupted"].contains(phase) }
    var title: String { actionNames[value.s("action")] ?? "后台任务" }
    var stateName: String { ["queued": "排队中", "running": "进行中", "waiting": "等待处理", "complete": "已完成", "failed": "失败", "stopped": "已停止", "interrupted": "可继续" ][phase] ?? phase }
}
struct BridgeFlow: Identifiable {
    let app: BridgeApp
    let kind: String
    var id: String { app.id + ":" + kind }
}

final class BridgeModel: ObservableObject {
    let root: URL, runtime: URL
    @Published var page = "applications"
    @Published var apps: [BridgeApp] = []
    @Published var tasks: [BridgeTask] = []
    @Published var disks: [Object] = []
    @Published var retained: [Object] = []
    @Published var archivedBackups: [BridgeApp] = []
    @Published var preferences: Object = [:]
    @Published var automatic: Object = [:]
    @Published var selection: String?
    @Published var selectedTask: String?
    @Published var search = ""
    @Published var filter = "all"
    @Published var taskFilter = "all"
    @Published var sortField = UserDefaults.standard.string(forKey: "sortField") ?? "name" { didSet { UserDefaults.standard.set(sortField, forKey: "sortField") } }
    @Published var ascending = UserDefaults.standard.object(forKey: "ascending") as? Bool ?? true { didSet { UserDefaults.standard.set(ascending, forKey: "ascending") } }
    @Published var loading = false
    @Published var error = ""
    @Published var needsAuthorization = false
    @Published var authorizationChecked = false
    @Published var diskHistory: Object = [:]
    @Published var flow: BridgeFlow?
    @Published var plan: Object?
    @Published var planBusy = false
    @Published var candidates: [Object] = []
    @Published var chosenSources = Set<String>()
    @Published var targetDisk = ""
    @Published var targetFolder = ""
    @Published var sharedConfirmed = false
    @Published var taskDetail: Object = [:]
    var callbacks: [String: (Object) -> Void] = [:], pendingDates: [String: Date] = [:]
    var timer: Timer?, lastHistory = Date.distantPast, lastStatus = Date.distantPast
    var automaticVersion: Int64 = 0
    var statusPending = false
    var authorizationPrompted = false
    var openSettings: () -> Void = {}, openAuthorization: () -> Void = {}, refreshRegistration: () -> Void = {}, recheckAuthorization: () -> Void = {}, onAuthorizationRequired: () -> Void = {}

    init(root: URL, runtime: URL) {
        self.root = root; self.runtime = runtime
        diskHistory = (try? readObject(runtime.appendingPathComponent("disks.json"), fallback: [:])) ?? [:]
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
    }
    var activeCount: Int { tasks.filter(\.active).count }
    var visibleApps: [BridgeApp] {
        let values = apps.filter { (search.isEmpty || ($0.name + " " + $0.value.s("app_path")).localizedCaseInsensitiveContains(search)) &&
            (filter == "all" || (filter == "migrated" ? $0.migrated : $0.value.s("migration_state") == "unmigrated")) }
        return values.sorted { a, b in
            if sortField == "size" {
                let left = a.value["bytes"] as? NSNumber, right = b.value["bytes"] as? NSNumber
                if left == nil || right == nil { if left == nil && right != nil { return false }; if right == nil && left != nil { return true } }
                if a.value.n("bytes") != b.value.n("bytes") { return ascending ? a.value.n("bytes") < b.value.n("bytes") : a.value.n("bytes") > b.value.n("bytes") }
            }
            if sortField == "state" && a.stateName != b.stateName { return ascending ? a.stateName < b.stateName : a.stateName > b.stateName }
            return ascending ? a.name.localizedStandardCompare(b.name) == .orderedAscending : a.name.localizedStandardCompare(b.name) == .orderedDescending
        }
    }
    var migratedApps: [BridgeApp] { apps.filter(\.migrated) }
    var knownDisks: [Object] {
        var known = diskHistory
        for app in apps { for path in app.paths where known[path.s("volume_uuid")] == nil {
            known[path.s("volume_uuid")] = ["uuid": path.s("volume_uuid"), "name": "已配置外置硬盘"]
        } }
        return known.values.compactMap { $0 as? Object }.sorted { $0.s("name").localizedStandardCompare($1.s("name")) == .orderedAscending }
    }
    func authorization(_ required: Bool) {
        needsAuthorization = required; authorizationChecked = true
        if required && !authorizationPrompted { authorizationPrompted = true; onAuthorizationRequired() }
    }
    func destination(_ path: Object) -> String {
        let disk = disks.first { $0.s("uuid").lowercased() == path.s("volume_uuid").lowercased() }
        return (disk?.s("name") ?? "离线硬盘") + " / " + path.s("folder")
    }
    var visibleTasks: [BridgeTask] { tasks.filter { taskFilter == "all" || (taskFilter == "active" ? $0.active : taskFilter == "complete" ? $0.phase == "complete" : $0.attention) } }
    func send(_ action: String, _ values: Object = [:], visible: Bool = false, completion: @escaping (Object) -> Void = { _ in }) {
        let id = UUID().uuidString
        do {
            try writeObject(["action": action, "values": values], to: runtime.appendingPathComponent("inbox/\(id).json"))
            callbacks[id] = completion; pendingDates[id] = Date()
            if visible { selectedTask = id; page = "tasks" }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "gui/\(getuid())/\(NativeInstaller.agentLabel)"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; try? process.run()
        } catch { self.error = error.localizedDescription }
    }
    func poll() {
        automatic = (try? readObject(runtime.appendingPathComponent("automatic.json"))) ?? [:]
        for (id, callback) in Array(callbacks) {
            guard let row = try? readObject(runtime.appendingPathComponent("tasks/\(id).json")) else {
                if Date().timeIntervalSince(pendingDates[id] ?? Date()) > 25 {
                    callbacks.removeValue(forKey: id); pendingDates.removeValue(forKey: id)
                    error = "后台尚未接收任务，请在设置中检查原生后台和授权。"; loading = false; planBusy = false
                }; continue
            }
            if ["complete", "failed", "stopped", "interrupted"].contains(row.s("phase")) {
                callbacks.removeValue(forKey: id); pendingDates.removeValue(forKey: id)
                if row.s("phase") != "complete" { error = row.s("message"); if row.s("reason") == "authorization" { authorization(true) } }
                callback(row)
                if !publicTaskAction(row.s("action")) { try? nativeFM.removeItem(at: runtime.appendingPathComponent("tasks/\(id).json")) }
            }
        }
        if Date().timeIntervalSince(lastHistory) >= 1 {
            let urls = (try? nativeFM.contentsOfDirectory(at: runtime.appendingPathComponent("history"), includingPropertiesForKeys: nil)) ?? []
            tasks = urls.compactMap { try? readObject($0) }.map { BridgeTask(value: $0) }.sorted { $0.value.n("created_ns") > $1.value.n("created_ns") }
            lastHistory = Date()
        }
        if let selectedTask { taskDetail = (try? readObject(runtime.appendingPathComponent("tasks/\(selectedTask).json"))) ?? [:] }
        let version = automatic.n("finished_ns")
        if !apps.isEmpty && !statusPending && (Date().timeIntervalSince(lastStatus) > 10 || version != automaticVersion) {
            automaticVersion = version; lastStatus = Date(); statusPending = true
            send("overview") { response in
                self.statusPending = false
                guard let result = response["result"] as? Object else { return }
                let managed = result.list("apps").map { BridgeApp(value: $0) }
                self.apps = self.apps.filter { !$0.value.b("managed") } + managed
                if result.b("requires_authorization") { self.authorization(true) }
            }
        }
    }
    func refresh(forceCatalog: Bool = false) {
        loading = true
        send("catalog") { response in
            self.loading = false
            guard let result = response["result"] as? Object else { return }
            self.apps = result.list("apps").map { BridgeApp(value: $0) }; self.preferences = result.o("preferences")
            self.retained = result.list("retained_copies"); if result.b("requires_authorization") { self.authorization(true) }
            self.archivedBackups = result.list("archived_backups").map { BridgeApp(value: $0) }
        }
        send("disks") { response in
            self.disks = response["result"] as? [Object] ?? []
            for disk in self.disks { self.diskHistory[disk.s("uuid")] = disk }
            try? writeObject(self.diskHistory, to: self.runtime.appendingPathComponent("disks.json"))
            if self.targetDisk.isEmpty { self.targetDisk = self.disks.first?.s("uuid") ?? "" }
        }
    }
    func beginFlow(_ app: BridgeApp) {
        selection = app.id; plan = nil; error = ""
        if app.pending { flow = BridgeFlow(app: app, kind: "accept"); return }
        if app.incomplete { flow = BridgeFlow(app: app, kind: "recover"); return }
        if app.migrated { flow = BridgeFlow(app: app, kind: "restore"); return }
        guard !app.value.b("own") else { error = "不能迁移盘桥自身的运行数据。"; return }
        candidates = []; chosenSources = []; sharedConfirmed = false
        targetFolder = preferences.s("default_directory", "Cache") + "/" + app.value.s("file_name", app.name)
        flow = BridgeFlow(app: app, kind: "migrate")
        send("candidates", ["app_id": app.id]) { response in
            guard self.flow?.app.id == app.id else { return }
            self.candidates = response["result"] as? [Object] ?? []
            self.chosenSources = Set(self.candidates.filter { !$0.b("shared") }.map { $0.s("path") })
        }
    }
    func addSources() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !candidates.contains(where: { $0.s("path") == url.path }) {
                let shared = url.path.contains("/Library/Group Containers/")
                candidates.append(["path": url.path, "label": "用户选择的目录", "shared": shared]); chosenSources.insert(url.path)
            }
        }
    }
    func preview() {
        guard let flow else { return }; planBusy = true
        let action = flow.kind == "restore" ? "rollback_plan" : "plan"
        let values: Object = flow.kind == "restore" ? ["app_id": flow.app.id] : ["app_id": flow.app.id, "sources": Array(chosenSources), "volume_uuid": targetDisk, "folder": targetFolder, "shared_confirmed": sharedConfirmed]
        send(action, values) { response in self.planBusy = false; self.plan = response["result"] as? Object }
    }
    func startPlan() {
        guard let flow, let plan else { return }
        let action = flow.kind == "restore" ? "rollback" : "migrate"
        let values: Object = flow.kind == "restore" ? ["app_id": flow.app.id, "confirmed": true] : ["plan_id": plan.s("plan_id")]
        self.flow = nil; self.plan = nil
        send(action, values, visible: true) { _ in self.refresh() }
    }
    func perform(_ action: String, app: BridgeApp, values: Object = [:]) {
        var value = values; value["app_id"] = app.id
        send(action, value, visible: true) { _ in self.refresh() }
    }
    func setting(_ app: BridgeApp, _ field: String, _ value: Bool) { send("app_settings", ["app_id": app.id, field: value]) { _ in self.refresh() } }
    func preference(_ key: String, _ value: Any) {
        send("set_preferences", [key: value]) { response in
            if let value = response["result"] as? Object { self.preferences = value }
            if key == "login_start" { self.refreshRegistration() }
        }
    }
    func openApp(_ app: BridgeApp) {
        send("prepare_launch", ["app_id": app.id], visible: true) { response in
            let result = response.o("result").o(app.id)
            if result.b("ok"), !result.s("app_path").isEmpty { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: result.s("app_path")), configuration: .init(), completionHandler: nil) }
            self.refresh()
        }
    }
}
