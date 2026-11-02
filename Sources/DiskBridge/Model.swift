import AppKit
import SwiftUI
import UserNotifications

func formattedBytes(_ value: Any?) -> String {
    guard let value = value as? NSNumber else { return "—" }
    if value.int64Value == 0 { return "0 KB" }
    return ByteCountFormatter.string(fromByteCount: value.int64Value, countStyle: .file)
}
let actionNames: [String: String] = ["migrate": "迁移应用", "rollback": "还原到内置硬盘", "recover": "继续任务", "mount": "挂载应用", "automatic": "自动挂载",
    "confirm": "应用验收", "delete_original": "清理原件备份", "delete_archived_original": "清理旧原件备份", "delete_retained": "清理外置副本", "unmount": "安全卸载", "plan": "统计迁移范围", "rollback_plan": "还原预览", "estimate": "统计数据大小", "scan_sizes": "读取应用数据大小", "prepare_launch": "挂载就绪后打开"]
struct BridgeApp: Identifiable {
    let value: Object
    let searchTerms: [String]
    let sortName: String
    init(value: Object) {
        self.value = value
        let pathName = value.s("app_path").isEmpty ? "" : URL(fileURLWithPath: value.s("app_path")).deletingPathExtension().lastPathComponent
        let names = (value["aliases"] as? [String] ?? []) + [value.s("name"), value.s("bundle_name"), value.s("file_name"), value.s("executable_name"), pathName]
        searchTerms = value["search_terms"] as? [String] ?? Array(Set(names.filter { !$0.isEmpty }.flatMap { applicationSearchTerms($0) }))
        sortName = value["sort_name"] as? String ?? applicationSearchText(value.s("name").applyingTransform(.toLatin, reverse: false) ?? value.s("name"))
    }
    private init(value: Object, terms: [String], sortName: String) { self.value = value; self.searchTerms = terms; self.sortName = sortName }
    func updating(_ value: Object) -> BridgeApp { BridgeApp(value: value, terms: searchTerms, sortName: sortName) }
    var id: String { value.s("id") }
    var name: String { value.s("name") }
    var paths: [Object] { value.list("paths") }
    var migrated: Bool { value.s("migration_state") == "migrated" }
    var pending: Bool { value.s("migration_state") == "pending" }
    var relocated: Bool { migrated || pending }
    var incomplete: Bool { value.s("migration_state") == "incomplete" }
    var stateName: String { migrated ? "已迁移" : pending ? "待验收" : incomplete ? "待恢复" : "未迁移" }
    var mounted: Bool { value.b("mounted") }
    var activePaths: [Object] { (relocated || incomplete) ? paths.filter { $0.s("phase") != "rolled_back" } : [] }
    var installedDate: Date? { (value["installed_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return true }
        if query.contains("/") { return value.s("app_path").localizedCaseInsensitiveContains(query) }
        let needle = applicationSearchText(query)
        guard !needle.isEmpty else { return false }
        return searchTerms.contains { term in
            if term.contains(needle) { return true }
            var next = needle.startIndex
            for letter in term where next < needle.endIndex { if letter == needle[next] { next = needle.index(after: next) } }
            return next == needle.endIndex
        } || (query.contains(".") && value.s("bundle_id").localizedCaseInsensitiveContains(query))
    }
}
func applicationSearchText(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
}
func applicationSearchTerms(_ text: String) -> [String] {
    let words = text.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
    let latin = words.applyingTransform(.toLatin, reverse: false) ?? words
    let initials = latin.components(separatedBy: CharacterSet.alphanumerics.inverted).compactMap(\.first).map(String.init).joined()
    return [applicationSearchText(text), applicationSearchText(latin), applicationSearchText(initials)].filter { !$0.isEmpty }
}
struct ApplicationSort: SortComparator {
    var field: String
    var order: SortOrder
    init(_ field: String) { self.field = field; order = field == "name" ? .forward : .reverse }
    func compare(_ lhs: BridgeApp, _ rhs: BridgeApp) -> ComparisonResult {
        if field == "size" || field == "installed" {
            let key = field == "size" ? "bytes" : "installed_at", a = lhs.value[key] as? NSNumber, b = rhs.value[key] as? NSNumber
            if (a == nil) != (b == nil) { return a == nil ? .orderedDescending : .orderedAscending }
            if let a, let b, a != b {
                let less = a.doubleValue < b.doubleValue
                return (order == .forward ? less : !less) ? .orderedAscending : .orderedDescending
            }
        }
        let names = lhs.sortName.localizedStandardCompare(rhs.sortName)
        if names != .orderedSame { return names }
        return lhs.id.compare(rhs.id)
    }
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
    @Published var sortField = "name"
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
    @Published var clearingTasks = false
    @Published var disksLoading = false
    var measurementVersion: Int64 = 0
    var callbacks: [String: (Object) -> Void] = [:], pendingDates: [String: Date] = [:]
    var timer: Timer?, lastHistory = Date.distantPast, lastStatus = Date.distantPast
    var automaticVersion: Int64 = 0
    var statusPending = false
    var authorizationPrompted = false
    let snapshotQueue = DispatchQueue(label: "DiskBridge.AppListCache", qos: .utility)
    var snapshotWork: DispatchWorkItem?
    var openSettings: () -> Void = {}, openAuthorization: () -> Void = {}, refreshRegistration: () -> Void = {}, recheckAuthorization: () -> Void = {}, onAuthorizationRequired: () -> Void = {}

    init(root: URL, runtime: URL) {
        self.root = root; self.runtime = runtime
        diskHistory = (try? readObject(runtime.appendingPathComponent("disks.json"), fallback: [:])) ?? [:]
        if let saved = try? readObject(runtime.appendingPathComponent("app-list.json")), saved.n("version") == 1 {
            apps = saved.list("apps").map { row in
                var value = row
                if value.b("managed") {
                    value["mounted"] = false; value["status_cached"] = true
                    value["availability_note"] = "正在后台核对缓存中的迁移状态。"
                }
                return BridgeApp(value: value)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
    }
    deinit { timer?.invalidate(); snapshotWork?.cancel() }
    var activeCount: Int { tasks.filter(\.active).count }
    func saveAppSnapshot() {
        let rows = apps.map(\.value), url = runtime.appendingPathComponent("app-list.json")
        snapshotWork?.cancel()
        let work = DispatchWorkItem { try? writeObject(["version": 1, "apps": rows, "saved_ns": stamp()], to: url) }
        snapshotWork = work; snapshotQueue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    var measuringSizes: Bool { tasks.contains { $0.active && $0.value.s("action") == "scan_sizes" } }
    func applyMeasurements(_ sizes: Object) {
        apps = apps.map { app in
            let row = sizes.o(app.id)
            guard row.n("version") == 2, row.s("location") == app.value.s("data_location", "internal"), row.n("updated_ns") != app.value.n("measurement_ns") else { return app }
            var value = app.value
            if let bytes = row["bytes"] as? NSNumber { value["bytes"] = bytes }
            else if row.s("status") == "not_found" { value["bytes"] = NSNull() }
            value["size_status"] = row.s("status"); value["size_note"] = row.s("note")
            value["measurement_ns"] = row.n("updated_ns")
            return app.updating(value)
        }
        saveAppSnapshot()
    }
    func applyDisks(_ result: [Object]) {
        disks = result
        for disk in result { diskHistory[disk.s("uuid")] = disk }
        if targetDisk.isEmpty { targetDisk = result.first?.s("uuid") ?? "" }
    }
    func mergeOverviewApps(_ rows: [Object]) {
        var previous: [String: BridgeApp] = [:], merged: [String: BridgeApp] = [:]
        for app in apps { previous[app.id] = app; if !app.value.b("managed") { merged[app.id] = app } }
        for row in rows {
            let id = row.s("id")
            var value = previous[id]?.value ?? [:]
            value.merge(row) { _, current in current }; value.removeValue(forKey: "measurement_ns")
            value.removeValue(forKey: "status_cached")
            merged[id] = BridgeApp(value: value)
        }
        apps = Array(merged.values)
        if let sizes = try? readObject(runtime.appendingPathComponent("sizes.json")) { applyMeasurements(sizes) }
        else { saveAppSnapshot() }
    }
    var visibleApps: [BridgeApp] {
        let values = apps.filter { $0.matches(search) &&
            (filter == "all" || (filter == "migrated" ? $0.relocated : $0.value.s("migration_state") == "unmigrated")) }
        return values.sorted(using: ApplicationSort(sortField))
    }
    var tableSort: [ApplicationSort] {
        get { [ApplicationSort(sortField)] }
        set { if let field = newValue.first?.field { sortField = field } }
    }
    var migratedApps: [BridgeApp] { apps.filter(\.relocated) }
    func clearTasks(_ id: String? = nil) {
        clearingTasks = true
        var values: Object = ["exclude_ids": Array(callbacks.keys)]
        if let id { values["task_id"] = id }
        send("clear_tasks", values) { response in
            self.clearingTasks = false
            let removed = Set(response.o("result")["removed_ids"] as? [String] ?? [])
            self.tasks.removeAll { removed.contains($0.id) }
            if let selected = self.selectedTask, removed.contains(selected) { self.selectedTask = nil; self.taskDetail = [:] }
            self.lastHistory = .distantPast
        }
    }
    var knownDisks: [Object] {
        var known: Object = [:]
        for disk in disks { known[disk.s("uuid").lowercased()] = disk }
        for app in apps { for path in app.activePaths where known[path.s("volume_uuid").lowercased()] == nil {
            let uuid = path.s("volume_uuid")
            known[uuid.lowercased()] = diskHistory.values.compactMap { $0 as? Object }.first { $0.s("uuid").lowercased() == uuid.lowercased() } ?? ["uuid": uuid, "name": path.s("volume_name", "已配置外置硬盘")]
        } }
        return known.values.compactMap { $0 as? Object }.sorted { $0.s("name").localizedStandardCompare($1.s("name")) == .orderedAscending }
    }
    func relatedApps(_ uuid: String) -> [BridgeApp] { apps.filter { $0.activePaths.contains { $0.s("volume_uuid").lowercased() == uuid.lowercased() } } }
    func appDestination(_ app: BridgeApp) -> String { app.activePaths.first.map(destination) ?? "本机" }
    func authorization(_ required: Bool) {
        needsAuthorization = required; authorizationChecked = true
        if required && !authorizationPrompted { authorizationPrompted = true; onAuthorizationRequired() }
    }
    func destination(_ path: Object) -> String {
        let disk = disks.first { $0.s("uuid").lowercased() == path.s("volume_uuid").lowercased() }
        let previous = diskHistory.values.compactMap { $0 as? Object }.first { $0.s("uuid").lowercased() == path.s("volume_uuid").lowercased() }
        let name = disk?.s("name") ?? previous?.s("name") ?? path.s("volume_name", "外置硬盘")
        return name + (disk == nil ? (disksLoading ? "（读取中）" : "（未连接）") : "") + " / " + path.s("folder")
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
            if row.s("action") == "disks", let partial = row["result"] as? [Object] { applyDisks(partial) }
            if ["complete", "failed", "stopped", "interrupted"].contains(row.s("phase")) {
                callbacks.removeValue(forKey: id); pendingDates.removeValue(forKey: id)
                if row.s("phase") != "complete" { error = row.s("message"); if row.s("reason") == "authorization" { authorization(true) } }
                callback(row)
                if !publicTaskAction(row.s("action")) { try? nativeFM.removeItem(at: runtime.appendingPathComponent("tasks/\(id).json")) }
            }
        }
        if let sizes = try? readObject(runtime.appendingPathComponent("sizes.json")), sizes.n("_updated_ns") != measurementVersion {
            measurementVersion = sizes.n("_updated_ns"); applyMeasurements(sizes)
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
                self.mergeOverviewApps(result.list("apps"))
                if result.b("requires_authorization") { self.authorization(true) }
            }
        }
    }
    func refresh(forceCatalog: Bool = false) {
        guard !loading else { return }
        loading = true; disksLoading = true
        send("catalog", ["force": forceCatalog]) { response in
            self.loading = false
            guard let result = response["result"] as? Object else { return }
            self.apps = result.list("apps").map { BridgeApp(value: $0) }; self.preferences = result.o("preferences")
            if let sizes = try? readObject(self.runtime.appendingPathComponent("sizes.json")) { self.applyMeasurements(sizes) }
            else { self.saveAppSnapshot() }
            self.retained = result.list("retained_copies"); if result.b("requires_authorization") { self.authorization(true) }
            self.archivedBackups = result.list("archived_backups").map { BridgeApp(value: $0) }
        }
        send("disks") { response in
            self.disksLoading = false
            self.applyDisks(response["result"] as? [Object] ?? [])
            try? writeObject(self.diskHistory, to: self.runtime.appendingPathComponent("disks.json"))
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
