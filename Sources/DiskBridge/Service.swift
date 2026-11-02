import Foundation
import AppKit
import Darwin
import UserNotifications

func groupKeys(_ store: NativeStore, _ id: String) -> [String] {
    store.apps.keys.filter { $0 == id || store.apps.o($0).s("parent_id") == id }.sorted()
}
func groupID(_ key: String, app: Object) -> String { app.s("parent_id", key) }
func publicTaskAction(_ action: String) -> Bool {
    ["migrate", "rollback", "recover", "mount", "confirm", "delete_original", "delete_archived_original", "delete_retained", "prepare_launch", "estimate", "scan_sizes", "plan", "rollback_plan", "unmount"].contains(action)
}

final class NativeService {
    let root: URL, runtime: URL, system: NativeSystem
    let writers = OperationQueue(), readers = OperationQueue()
    let stateLock = NSRecursiveLock()
    let measurementLock = NSLock()
    let catalogLock = NSLock()
    var measurementsRunning = false
    var active: [String: NativeTask] = [:], plans: [String: Object] = [:]
    var cachedApplications: [Object] = [], catalogDate = Date.distantPast
    var catalogRoots: Object = [:]
    var automaticRunning = false, suspended = Set<String>()
    var automaticScope: Set<String>?, automaticPendingIDs = Set<String>(), automaticPendingAll = false
    let bootID: String
    init(root: URL, runtime: URL, system: NativeSystem = NativeSystem()) throws {
        self.root = root; self.runtime = runtime; self.system = system
        for folder in [runtime, runtime.appendingPathComponent("inbox"), runtime.appendingPathComponent("tasks")] { try privateDirectory(folder) }
        writers.maxConcurrentOperationCount = 1; writers.name = "DiskBridge.WriteQueue"
        readers.maxConcurrentOperationCount = 2; readers.name = "DiskBridge.ReadQueue"
        if let cached = try? readObject(runtime.appendingPathComponent("catalog.json")), cached.n("version") == 1 {
            cachedApplications = cached.list("apps"); catalogRoots = cached.o("roots")
            catalogDate = Date(timeIntervalSince1970: cached.d("discovered_ns") / 1e9)
        }
        bootID = (try? system.run("/usr/sbin/sysctl", ["-n", "kern.bootsessionuuid"], timeout: 5)).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? String(Int(Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime))
    }
    func applicationList(_ task: NativeTask, force: Bool = false) throws -> [Object] {
        try catalogLock.locked {
            let cached = stateLock.locked { cachedApplications }, roots = applicationRootStamps()
            let sameRoots = NSDictionary(dictionary: roots).isEqual(to: catalogRoots)
            if !force && !cached.isEmpty && sameRoots && Date().timeIntervalSince(catalogDate) < 900 {
                if cached.allSatisfy({ applicationFingerprint($0.s("app_path")) == $0.s("catalog_signature") }) { return cached }
                let updated = cached.compactMap { app -> Object? in
                    applicationFingerprint(app.s("app_path")) == app.s("catalog_signature") ? app : applicationMetadata(app.s("app_path"))
                }
                try saveCatalog(updated, roots: roots, discovered: false); return updated
            }
            let result = try discoverApplications(system: system, task: task, cached: force ? [] : cached)
            try saveCatalog(result, roots: roots); return result
        }
    }
    func saveCatalog(_ apps: [Object], roots: Object, discovered: Bool = true) throws {
        let date = discovered ? Date() : catalogDate
        try writeObject(["version": 1, "updated_ns": stamp(), "discovered_ns": Int64(date.timeIntervalSince1970 * 1e9), "roots": roots, "apps": apps], to: runtime.appendingPathComponent("catalog.json"))
        stateLock.locked { cachedApplications = apps; catalogRoots = roots; catalogDate = date }
    }
    func overview(_ task: NativeTask, includeCatalog: Bool) throws -> Object {
        let store = try NativeStore(root)
        let installed = includeCatalog ? try applicationList(task) : stateLock.locked { cachedApplications }
        var appsByBundle: [String: Object] = [:]
        for app in installed { appsByBundle[app.s("bundle_id")] = app }
        var grouped: [String: [String]] = [:]
        for key in store.apps.keys { grouped[groupID(key, app: store.apps.o(key)), default: []].append(key) }
        var result: [Object] = []
        let sizes = (try? readObject(runtime.appendingPathComponent("sizes.json"), fallback: [:])) ?? [:]
        for (id, keys) in grouped {
            let base = store.apps.o(keys.sorted()[0]), recordRows = keys.map { store.records.o($0) }
            var app = appsByBundle.removeValue(forKey: base.s("bundle_id")) ?? base
            app["id"] = id; app["name"] = app.s("name", base.s("name")); app["app_path"] = base.s("app_path")
            app["aliases"] = Array(Set((app["aliases"] as? [String] ?? []) + [base.s("name")]))
            app["search_terms"] = Array(Set((app["search_terms"] as? [String] ?? []) + applicationSearchTerms(base.s("name"))))
            app["installed"] = exists(base.s("app_path")); app["managed"] = true
            let phases = recordRows.map { $0.s("phase", "configured") }
            let allRestored = phases.allSatisfy { $0 == "rolled_back" }
            let allActive = phases.allSatisfy { $0 == "active" }
            let pending = phases.allSatisfy { ["active_unconfirmed", "active"].contains($0) } && !allActive
            app["migration_state"] = allRestored ? "unmigrated" : allActive ? "migrated" : pending ? "pending" : "incomplete"
            app["phase"] = allRestored ? "rolled_back" : allActive ? "active" : pending ? "active_unconfirmed" : "incomplete"
            app["data_location"] = allRestored ? "internal" : (allActive || pending) ? "external" : "mixed"
            app["auto_mount"] = keys.allSatisfy { store.apps.o($0).b("enabled") }
            app["auto_open"] = keys.allSatisfy { store.apps.o($0).b("auto_open") }
            var paths: [Object] = [], amount: Int64 = 0, backups: Int64 = 0, released: Int64 = 0, releaseKnown = true
            var available = true, messages: [String] = [], amountKnown = true
            for key in keys.sorted() {
                let profile = store.apps.o(key), record = store.records.o(key)
                let originalPresent = !record.s("original").isEmpty && isDirectory(record.s("original"))
                let verification = record.s("phase") == "rolled_back" ? record.o("restore_verification") : record.o("verification")
                let knownBytes = verification["bytes"] as? NSNumber
                let bytes = knownBytes?.int64Value ?? 0; amount += bytes; amountKnown = amountKnown && knownBytes != nil
                if originalPresent { backups += record.o("verification").n("bytes") }
                if record.b("original_deleted") && record["measured_freed_bytes"] == nil { releaseKnown = false }
                released += record.n("measured_freed_bytes")
                var row: Object = ["id": key, "source": profile.s("mount_point"), "folder": profile.s("folder"), "volume_uuid": profile.s("volume_uuid"),
                    "bytes": knownBytes as Any? ?? NSNull(), "volume_name": profile.s("volume_name", "已配置外置硬盘"), "original": record.s("original"), "original_retained": originalPresent,
                    "phase": record.s("phase", "configured"), "mounted": false]
                do {
                    if !record.isEmpty && record.s("phase") != "rolled_back" {
                        let engine = NativeEngine(store, system: system, task: task)
                        let ready = try engine.isMounted(key); row["mounted"] = ready
                        if !ready { available = false; _ = try system.volume(profile.s("volume_uuid")); messages.append("等待挂载") }
                    }
                } catch {
                    available = false; row["message"] = error.localizedDescription; row["reason"] = (error as? DBError)?.reason ?? "failed"; messages.append(error.localizedDescription)
                }
                paths.append(row)
            }
            app["paths"] = paths; app["bytes"] = amountKnown ? amount as Any : NSNull(); app["backup_bytes"] = backups
            let measured = sizes.o(id)
            if measured.n("version") == 2, measured.s("location") == app.s("data_location"), let bytes = measured["bytes"] as? NSNumber { app["bytes"] = bytes }
            app["released_bytes"] = releaseKnown ? released as Any : NSNull()
            app["mounted"] = !allRestored && available; app["availability"] = allRestored ? "internal" : available ? "ready" : "waiting"
            app["availability_note"] = Array(Set(messages)).sorted().joined(separator: "；")
            app["original_retained"] = paths.contains { $0.b("original_retained") }
            app["can_delete_original"] = (allActive || allRestored) && paths.contains { $0.b("original_retained") }
            app["size_note"] = measured.s("note", "已记录的迁移校验数据量；后台可重新读取当前占用。")
            result.append(app)
        }
        if includeCatalog {
            for var app in appsByBundle.values {
                app["migration_state"] = "unmigrated"; app["data_location"] = "internal"; app["managed"] = false
                let measured = sizes.o(app.s("id"))
                app["bytes"] = measured.n("version") == 2 && measured.s("location") == "internal" ? measured["bytes"] ?? NSNull() : NSNull(); result.append(app)
            }
        }
        let retained = try retainedCopies(store)
        return ["apps": result.sorted { $0.s("name").localizedStandardCompare($1.s("name")) == .orderedAscending },
                "automatic": store.config.b("automatic_mount", true), "preferences": preferences(store), "root": root.path,
                "retained_copies": retained, "archived_backups": archivedBackups(store), "native": true, "requires_authorization": result.contains { $0.list("paths").contains { $0.s("reason") == "authorization" } }]
    }
    func archivedBackups(_ store: NativeStore) -> [Object] {
        store.state.o("archives").compactMap { id, value in
            guard let item = value as? Object else { return nil }
            let record = item.o("record")
            guard !record.b("original_deleted"), isDirectory(record.s("original")) else { return nil }
            return ["id": id, "name": item.o("app").s("name"), "archived": true, "original_retained": true,
                    "backup_bytes": record.o("verification").n("bytes"), "paths": [["original": record.s("original"), "original_retained": true]]]
        }
    }
    func preferences(_ store: NativeStore) -> Object {
        ["login_start": store.config.o("preferences").b("login_start", true), "notifications": store.config.o("preferences").b("notifications"),
         "default_directory": store.config.o("preferences").s("default_directory", "Cache"), "automatic": store.config.b("automatic_mount", true)]
    }
    func findApplication(_ id: String, task: NativeTask) throws -> Object {
        let store = try NativeStore(root)
        if let key = groupKeys(store, id).first {
            let old = store.apps.o(key)
            if var value = applicationMetadata(old.s("app_path")), value.s("bundle_id") == old.s("bundle_id") { value["id"] = id; return value }
            throw DBError("应用已卸载或位置变化，请先重新安装同一应用。")
        }
        guard let app = try applicationList(task).first(where: { $0.s("id") == id }) else { throw DBError("找不到选中的本机应用，请刷新列表。") }
        return app
    }
    func validateSources(_ sources: [String], app: Object, sharedConfirmed: Bool) throws -> [String] {
        guard !sources.isEmpty else { throw DBError("请至少选择一个数据目录。") }
        let home = nativeFM.homeDirectoryForCurrentUser.path
        let forbidden = [home + "/Library/Application Support", home + "/Library/Containers", home + "/Library/Group Containers", home + "/Library/Caches",
                         home + "/Library/Containers/" + app.s("bundle_id") + "/Data",
                         home + "/Library/Containers/" + app.s("bundle_id") + "/Data/Library",
                         home + "/Library/Containers/" + app.s("bundle_id") + "/Data/Documents"]
        let paths = try Array(Set(sources.map { try sourcePath($0) })).sorted()
        for path in paths {
            guard isDirectory(path), !mounted(path), !forbidden.contains(path), !path.hasPrefix(app.s("app_path") + "/"), path != app.s("app_path"),
                  !path.hasPrefix(root.path + "/"), !root.path.hasPrefix(path + "/") else { throw DBError("请选择具体的数据子目录，不能迁移系统管理的根目录、应用程序本体或盘桥运行目录。") }
            guard try fileStat(path).st_dev == fileStat("/System/Volumes/Data").st_dev else { throw DBError("请选择内置硬盘上的应用数据目录。") }
            if path.hasPrefix(home + "/Library/Group Containers/") && !sharedConfirmed { throw DBError("共享目录可能影响其他应用，请确认共享目录的迁移范围。") }
            for other in paths where other != path { if path.hasPrefix(other + "/") { throw DBError("选中的目录相互包含，请仅保留上层目录。") } }
        }
        return paths
    }
    func makePlan(_ values: Object, task: NativeTask) throws -> Object {
        let store = try NativeStore(root), id = values.s("app_id"), app = try findApplication(id, task: task)
        guard !app.b("own") else { throw DBError("盘桥不能迁移自身的运行目录。") }
        let existing = groupKeys(store, id)
        guard existing.allSatisfy({ store.records.o($0).isEmpty || store.records.o($0).s("phase") == "rolled_back" }) else { throw DBError("已有迁移或中断任务，请先继续或还原。") }
        try system.requireStopped(app)
        let sourceValues = values["sources"] as? [String] ?? (values.s("source").isEmpty ? [] : [values.s("source")])
        let sources = try validateSources(sourceValues, app: app, sharedConfirmed: values.b("shared_confirmed"))
        let disk = try system.volume(values.s("volume_uuid")), base = try relativeFolder(values.s("folder"))
        var profiles: [Object] = [], count: Int64 = 0, files: Int64 = 0, roundFolder = base, retained = false
        let targetFolders = sources.map { source in sources.count == 1 ? base : base + "/" + URL(fileURLWithPath: source).lastPathComponent + "-" + applicationKey(source).suffix(8) }
        retained = targetFolders.contains { exists(disk.s("path") + "/" + $0 + "/Data.sparsebundle") }
        if retained { roundFolder += "/迁移-" + String(stamp() / 1_000_000_000) + "-" + String(UUID().uuidString.prefix(6)) }
        for source in sources {
            let digest = applicationKey(source).suffix(8), key = sources.count == 1 ? id : id + "__" + digest
            let folder = sources.count == 1 ? roundFolder : roundFolder + "/" + URL(fileURLWithPath: source).lastPathComponent + "-" + digest
            try system.checkDestinationDirectory(disk.s("path"), folder: folder)
            let inventory = try inventory(source, task: task), summary = totals(inventory)
            count += summary.n("bytes"); files += summary.n("files")
            let capacity = max(Int64(128), Int64(ceil(Double(summary.n("bytes")) * 1.5 / pow(1024, 3))) + 1)
            var profile: Object = ["name": app.s("name"), "app_path": app.s("app_path"), "bundle_id": app.s("bundle_id"), "mount_point": source,
                "volume_uuid": disk.s("uuid"), "volume_name": disk.s("name"), "folder": folder, "capacity_gib": capacity, "enabled": false, "auto_open": false, "parent_id": id]
            profile["key"] = key; profile["bytes"] = summary.n("bytes"); profile["files"] = summary.n("files")
            guard !exists(disk.s("path") + "/" + folder + "/Data.sparsebundle") else { throw DBError("目标目录中已有副本，请修改目录后重新预览。") }
            profiles.append(profile)
        }
        guard disk.n("free") >= count + 512 * 1024 * 1024 else { throw DBError("外置硬盘空间不足。") }
        let token = UUID().uuidString
        let plan: Object = ["plan_id": token, "app_id": id, "name": app.s("name"), "profiles": profiles, "created_ns": stamp(),
                            "bytes": count, "files": files, "destination": disk.s("path") + "/" + roundFolder,
                            "retained_copy_preserved": retained, "sources": sources]
        stateLock.locked { plans[token] = plan }; return plan
    }
    func archiveRestoredGroup(_ store: NativeStore, id: String) throws {
        var records = store.records, apps = store.apps, archives = store.state.o("archives")
        for key in groupKeys(store, id) {
            let record = records.o(key)
            guard record.isEmpty || record.s("phase") == "rolled_back" else { throw DBError("当前任务尚未还原，未覆盖迁移记录。") }
            if !record.isEmpty { archives[record.s("id")] = ["app_id": id, "app": apps.o(key), "record": record] }
            records.removeValue(forKey: key); apps.removeValue(forKey: key)
        }
        store.records = records; store.apps = apps; store.state["archives"] = archives; try store.save()
    }
    func migrateGroup(_ plan: Object, task: NativeTask) throws -> Object {
        let store = try NativeStore(root), id = plan.s("app_id")
        for profile in plan.list("profiles") {
            let disk = try system.volume(profile.s("volume_uuid"))
            try system.checkDestinationDirectory(disk.s("path"), folder: profile.s("folder"))
        }
        try archiveRestoredGroup(store, id: id)
        let engine = NativeEngine(store, system: system, task: task)
        for var profile in plan.list("profiles") { let key = profile.s("key"); profile.removeValue(forKey: "key"); try engine.configure(key, profile: profile) }
        task.retryAs("recover", values: ["app_id": id])
        return try migrateExisting(store, id: id, task: task)
    }
    func migrateExisting(_ store: NativeStore, id: String, task: NativeTask) throws -> Object {
        let keys = groupKeys(store, id), engine = NativeEngine(store, system: system, task: task)
        guard !keys.isEmpty else { throw DBError("找不到需要继续的迁移任务。") }
        // Every source is copied and verified before any original directory is switched.
        for (index, key) in keys.enumerated() { task.merge(["path_index": index + 1, "path_total": keys.count]); _ = try engine.migrate(key, activateWhenReady: false) }
        for key in keys { _ = try engine.activate(key) }
        return ["app_id": id, "phase": "active_unconfirmed"]
    }
    func restoreGroup(_ store: NativeStore, id: String, task: NativeTask) throws -> Object {
        let keys = groupKeys(store, id), engine = NativeEngine(store, system: system, task: task)
        guard !keys.isEmpty else { throw DBError("迁移记录不存在。") }
        var required: Int64 = 0
        for key in keys where !["rolled_back", "restore_verified", "restore_detached"].contains(store.records.o(key).s("phase")) {
            try system.requireStopped(engine.app(key))
            if !(try engine.isMounted(key)) {
                if store.records.o(key).s("phase") == "restoring" { try engine.checkpoint(key, "active_unconfirmed") }
                _ = try engine.mount(key)
            }
            required += totals(try inventory(store.apps.o(key).s("mount_point"), task: task)).n("bytes")
        }
        guard required == 0 || freeBytes(nativeFM.homeDirectoryForCurrentUser.path) >= required + 512 * 1024 * 1024 else {
            throw DBError("内置盘空间不足以还原全部数据目录；当前工作卷与所有副本保留。")
        }
        task.retryAs("recover", values: ["app_id": id])
        for key in keys where store.records.o(key).s("phase") != "rolled_back" { _ = try engine.rollback(key, finishWhenReady: false) }
        for key in keys where store.records.o(key).s("phase") != "rolled_back" { _ = try engine.finishRollback(key, recheck: true) }
        return ["app_id": id, "phase": "rolled_back"]
    }
    func retainedCopies(_ store: NativeStore) throws -> [Object] {
        var values: [Object] = []
        for key in store.apps.keys {
            let record = store.records.o(key)
            if record.s("phase") == "rolled_back" && !record.b("retained_image_deleted") {
                values.append(["id": key, "app_id": groupID(key, app: store.apps.o(key)), "name": store.apps.o(key).s("name"), "folder": store.apps.o(key).s("folder"), "bytes": record.o("verification").n("bytes"), "archived": false])
            }
        }
        for (id, value) in store.state.o("archives") {
            guard let value = value as? Object, !value.o("record").b("retained_image_deleted") else { continue }
            values.append(["id": id, "app_id": value.s("app_id"), "name": value.o("app").s("name"), "folder": value.o("app").s("folder"), "bytes": value.o("record").o("verification").n("bytes"), "archived": true])
        }
        return values
    }
    func execute(_ action: String, values: Object, task: NativeTask) throws -> Any {
        switch action {
        case "catalog":
            if values.b("force") { _ = try applicationList(task, force: true) }
            let result = try overview(task, includeCatalog: true)
            _ = scheduleMeasurements(result.list("apps")); return result
        case "overview": return try overview(task, includeCatalog: false)
        case "disks":
            try task.begin("读取外置磁盘")
            var found: [Object] = []
            return try system.volumes { disk in found.append(disk); task.merge(["result": found]) }
        case "request_sizes":
            let result = try overview(task, includeCatalog: true)
            return ["task_id": scheduleMeasurements(result.list("apps"), force: true) ?? ""]
        case "clear_tasks": return try clearTaskHistory(values)
        case "candidates": return system.dataCandidates(try findApplication(values.s("app_id"), task: task))
        case "plan": return try makePlan(values, task: task)
        case "migrate":
            guard let plan = stateLock.locked({ plans[values.s("plan_id")] }), stamp() - plan.n("created_ns") < 1_800_000_000_000 else { throw DBError("迁移预览已过期，请重新确认范围。") }
            return try migrateGroup(plan, task: task)
        case "rollback_plan":
            let store = try NativeStore(root), id = values.s("app_id"), keys = groupKeys(store, id)
            guard !keys.isEmpty else { throw DBError("没有可还原的记录。") }
            let engine = NativeEngine(store, system: system, task: task); var amount: Int64 = 0
            for key in keys {
                try system.requireStopped(engine.app(key))
                guard try engine.isMounted(key) else { throw DBError("请先连接硬盘并挂载，再查看还原预览。", "disk_not_ready") }
                amount += totals(try inventory(store.apps.o(key).s("mount_point"), task: task)).n("bytes")
            }
            let free = freeBytes(nativeFM.homeDirectoryForCurrentUser.path)
            return ["app_id": id, "bytes": amount, "free": free, "enough_space": free >= amount + 512 * 1024 * 1024, "paths": keys.map { store.apps.o($0).s("mount_point") }]
        case "rollback", "recover", "confirm", "delete_original", "unmount":
            let store = try NativeStore(root), id = values.s("app_id"), keys = groupKeys(store, id), engine = NativeEngine(store, system: system, task: task)
            guard !keys.isEmpty else { throw DBError("应用迁移记录不存在。") }
            task.identify(id, store.apps.o(keys[0]).s("name"))
            if action == "rollback" { guard values.b("confirmed") else { throw DBError("还原尚未确认。") }; return try restoreGroup(store, id: id, task: task) }
            if action == "recover" {
                if keys.contains(where: { ["restoring", "restore_verified", "restore_detached"].contains(store.records.o($0).s("phase")) }) { return try restoreGroup(store, id: id, task: task) }
                return try migrateExisting(store, id: id, task: task)
            }
            if action == "confirm" {
                for key in keys { guard try engine.record(key).s("phase") == "active_unconfirmed", try engine.isMounted(key) else { throw DBError("请先完成全部目录挂载并检查应用内数据。") } }
                var apps = store.apps, records = store.records
                for key in keys { var app = apps.o(key), record = records.o(key); app["enabled"] = true; record["phase"] = "active"; record["user_confirmed"] = true; apps[key] = app; records[key] = record }
                store.apps = apps; store.records = records; try store.save()
                return ["app_id": id, "phase": "active"]
            }
            if action == "delete_original" {
                guard values.s("phrase") == deletionConfirmation else { throw DBError("请输入「确认删除」，未清理。") }
                for key in keys where isDirectory(store.records.o(key).s("original")) { _ = try engine.deleteOriginal(key) }
            }
            if action == "unmount" {
                guard values.b("confirmed") else { throw DBError("卸载尚未确认。") }
                for key in keys { try engine.unmount(key) }
                _ = stateLock.locked { suspended.insert(id) }
            }
            return ["app_id": id]
        case "app_settings":
            let store = try NativeStore(root), id = values.s("app_id"), keys = groupKeys(store, id)
            guard !keys.isEmpty, keys.allSatisfy({ store.records.o($0).s("phase") == "active" }) else { throw DBError("请先完成应用验收。") }
            var apps = store.apps
            for key in keys {
                var app = apps.o(key)
                for field in ["auto_mount", "auto_open"] where values[field] != nil {
                    guard let value = values[field] as? Bool else { throw DBError("开关值无效。") }; app[field == "auto_mount" ? "enabled" : field] = value
                }
                apps[key] = app
            }
            store.apps = apps; try store.save()
            if values.b("auto_open") {
                let engine = NativeEngine(store, system: system, task: task)
                if keys.allSatisfy({ (try? engine.isMounted($0)) == true }) {
                    let token = bootID + ":" + (try keys.map { try system.diskInfo(store.apps.o($0).s("mount_point")).s("DeviceIdentifier") }.sorted()).joined(separator: ":")
                    var ledger = try readObject(runtime.appendingPathComponent("opened.json"), fallback: [:]); ledger[id] = token; try writeObject(ledger, to: runtime.appendingPathComponent("opened.json"))
                }
            }
            if values.b("auto_mount") { _ = stateLock.locked { suspended.remove(id) }; scheduleAutomatic(appIDs: [id]) }
            return ["app_id": id]
        case "set_preferences":
            let store = try NativeStore(root); var prefs = store.config.o("preferences")
            for field in ["login_start", "notifications"] where values[field] != nil {
                guard let value = values[field] as? Bool else { throw DBError("设置值无效。") }; prefs[field] = value
            }
            if values["automatic"] != nil { guard let value = values["automatic"] as? Bool else { throw DBError("自动挂载设置无效。") }; store.config["automatic_mount"] = value }
            if values["default_directory"] != nil { prefs["default_directory"] = try relativeFolder(values.s("default_directory")) }
            store.config["preferences"] = prefs; try store.save()
            if values["login_start"] != nil { try NativeInstaller.updateLogin(prefs.b("login_start", true), root: root) }
            if values.b("automatic") { scheduleAutomatic() }
            return preferences(store)
        case "estimate":
            let store = try NativeStore(root), id = values.s("app_id"), keys = groupKeys(store, id)
            let app = keys.isEmpty ? try findApplication(id, task: task) : store.apps.o(keys[0])
            return try measureApplication(id, app: app, task: task)
        case "mount", "prepare_launch":
            let id = values.s("app_id")
            stateLock.locked { if id.isEmpty { suspended.removeAll() } else { suspended.remove(id) } }
            if action == "prepare_launch" { _ = try findApplication(id, task: task) }
            if let ids = values["app_ids"] as? [String] {
                var combined: Object = [:]
                for id in ids { combined.merge(try mountApplications(task: task, requested: id, automatic: false)) { _, b in b } }; return combined
            }
            return try mountApplications(task: task, requested: id, automatic: false)
        case "automatic": scheduleAutomatic(); return ["scheduled": true]
        case "retry_task":
            let old = try readObject(runtime.appendingPathComponent("tasks/" + safeTaskID(values.s("task_id")) + ".json"))
            guard ["failed", "stopped", "interrupted"].contains(old.s("phase")), !old.s("action").hasPrefix("delete_") else { throw DBError("此任务需要重新确认操作。") }
            let retry = old.o("retry")
            if old.s("action") == "mount" {
                let results = old.o("results").isEmpty ? old.o("result") : old.o("results")
                let failed = results.keys.filter { !results.o($0).b("ok") }
                guard !failed.isEmpty else { throw DBError("没有需要重试的失败项。") }
                return ["task_id": submit("mount", values: ["app_ids": failed])]
            }
            return ["task_id": submit(retry.s("action", old.s("action")), values: retry.isEmpty ? old.o("values") : retry.o("values"))]
        case "probe":
            let store = try NativeStore(root)
            try system.checkAuthorization(store)
            scheduleAutomatic(); return ["passed": true, "native": true]
        case "delete_retained": return try deleteRetained(values, task: task)
        case "delete_archived_original":
            let store = try NativeStore(root), id = values.s("app_id")
            var archives = store.state.o("archives"), item = archives.o(id), record = item.o("record")
            let app = item.o("app")
            guard !item.isEmpty, record.s("phase") == "rolled_back", values.s("phrase") == deletionConfirmation else { throw DBError("旧原件备份身份或确认短语不符合清理条件。") }
            let changes = try NativeEngine(store, system: system, task: task).removeOriginalBackup(app, record: record)
            record.merge(changes) { _, b in b }; item["record"] = record; archives[id] = item; store.state["archives"] = archives; try store.save()
            return ["archive_id": id]
        default: throw DBError("不支持的任务。")
        }
    }
    func waitForLock(_ task: NativeTask, label: String) throws -> NativeLock {
        let deadline = Date().addingTimeInterval(30)
        while true {
            try task.check()
            do { return try NativeStore(root).lock(label) }
            catch let error as DBError where error.reason == "busy" && Date() < deadline { task.waiting(error.localizedDescription); Thread.sleep(forTimeInterval: 0.3) }
        }
    }
    @discardableResult func submit(_ action: String, values: Object = [:], id: String = UUID().uuidString) -> String {
        let task = NativeTask(action, values: values, runtime: runtime, id: id)
        stateLock.locked { active[id] = task }
        let writes: Set<String> = ["migrate", "rollback", "recover", "confirm", "delete_original", "delete_archived_original", "delete_retained", "app_settings", "set_preferences", "unmount", "mount", "prepare_launch"]
        let queue = writes.contains(action) ? writers : readers
        queue.addOperation { [self] in
            task.activate()
            do {
                let mutations: Set<String> = ["migrate", "rollback", "recover", "confirm", "delete_original", "delete_archived_original", "delete_retained", "app_settings", "set_preferences", "unmount"]
                let lock = mutations.contains(action) ? try waitForLock(task, label: action) : nil
                defer { withExtendedLifetime(lock) {} }
                try task.check(); let result = try execute(action, values: values, task: task)
                if ["mount", "prepare_launch"].contains(action), let result = result as? Object {
                    task.merge(["results": result])
                    let failed = result.values.compactMap { $0 as? Object }.filter { !$0.b("ok") }
                    if !failed.isEmpty { throw DBError(failed.map { $0.s("message") }.joined(separator: "；")) }
                }
                task.finish(result)
            } catch { task.fail(error) }
            notifyTask(task.snapshot())
            _ = stateLock.locked { active.removeValue(forKey: id) }
        }
        return id
    }
    func notifyTask(_ row: Object) {
        let action = row.s("action"), phase = row.s("phase")
        guard Bundle.main.bundleIdentifier == "com.local.diskbridge",
              (try? NativeStore(root).config.o("preferences").b("notifications")) == true,
              phase == "failed" || (phase == "complete" && ["migrate", "rollback", "recover", "delete_original", "delete_retained"].contains(action)),
              !["overview", "catalog", "candidates", "disks", "plan", "rollback_plan", "estimate"].contains(action) else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = phase == "failed" ? "盘桥 · 需要处理" : "盘桥 · 任务完成"
            content.body = phase == "failed" ? row.s("message", "请查看任务管理。") : row.s("app_name") + " · " + (actionNames[action] ?? "任务已完成")
            center.add(UNNotificationRequest(identifier: row.s("id"), content: content, trigger: nil))
        }
    }
    func safeTaskID(_ id: String) throws -> String { guard UUID(uuidString: id) != nil else { throw DBError("任务编号无效。") }; return id }
    func receive() {
        let inbox = runtime.appendingPathComponent("inbox")
        for url in (try? nativeFM.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            do {
                _ = try safeTaskID(url.deletingPathExtension().lastPathComponent)
                let metadata = try fileStat(url.path)
                guard metadata.st_uid == getuid(), metadata.st_size < 1_000_000, metadata.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG) else { continue }
                let request = try readObject(url), id = url.deletingPathExtension().lastPathComponent
                guard !request.s("action").isEmpty else { continue }
                try nativeFM.removeItem(at: url)
                if request.s("action") == "cancel" {
                    let target = stateLock.locked { active[request.o("values").s("task_id")] }; target?.cancel()
                    let task = NativeTask("cancel", runtime: runtime, id: id); task.finish(["cancel_requested": target != nil])
                } else { submit(request.s("action"), values: request.o("values"), id: id) }
            } catch { continue }
        }
    }
    func serve() throws {
        let lock = try NativeLock(runtime.appendingPathComponent("agent.lock"), label: "盘桥原生后台")
        defer { withExtendedLifetime(lock) {} }
        for url in (try? nativeFM.contentsOfDirectory(at: runtime.appendingPathComponent("tasks"), includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            if var row = try? readObject(url), ["queued", "running", "waiting"].contains(row.s("phase")) {
                row["phase"] = "interrupted"; row["message"] = "上次任务中断，可核对后继续。"; try writeObject(row, to: url)
            }
        }
        scheduleAutomatic()
        var heartbeat = Date.distantPast, volumeCheck = Date.distantPast, prior: Set<String>?, targetConnections: Set<String>?
        while true {
            receive()
            if Date().timeIntervalSince(heartbeat) >= 5 {
                try writeObject(["pid": getpid(), "updated_ns": stamp(), "root": root.path, "native": true], to: runtime.appendingPathComponent("service.json")); heartbeat = Date()
            }
            if Date().timeIntervalSince(volumeCheck) >= 2 {
                let current = Set(((try? nativeFM.contentsOfDirectory(atPath: "/Volumes")) ?? []).compactMap { name -> String? in
                    guard let value = try? fileStat("/Volumes/" + name), !isLink("/Volumes/" + name) else { return nil }; return name + ":" + String(value.st_dev)
                })
                if prior != current, let store = try? NativeStore(root), let disks = try? system.volumes() {
                    let connections = automaticConnectionTokens(store, volumes: disks)
                    if let previous = targetConnections, !connections.subtracting(previous).isEmpty {
                        let reconnected = connections.subtracting(previous)
                        let ids = Set(store.apps.keys.filter { key in
                            reconnected.contains { $0.hasPrefix(store.apps.o(key).s("volume_uuid").lowercased() + ":") }
                        }.map { groupID($0, app: store.apps.o($0)) })
                        stateLock.locked { suspended.subtract(ids) }; scheduleAutomatic(appIDs: ids)
                    }
                    targetConnections = connections
                }
                prior = current; volumeCheck = Date()
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}
