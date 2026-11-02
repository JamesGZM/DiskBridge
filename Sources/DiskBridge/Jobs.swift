import Foundation

extension NativeService {
    func mountApplications(task: NativeTask, requested: String, automatic: Bool) throws -> Object {
        let initial = try NativeStore(root)
        let ids = Set(initial.apps.keys.map { groupID($0, app: initial.apps.o($0)) }).sorted()
        var results: Object = [:]
        for id in ids where requested.isEmpty || requested == id {
            try task.check()
            let store = try NativeStore(root), keys = groupKeys(store, id)
            guard !keys.isEmpty else { continue }
            if automatic {
                guard store.config.b("automatic_mount", true), !stateLock.locked({ suspended.contains(id) }),
                      keys.allSatisfy({ store.apps.o($0).b("enabled") && store.records.o($0).s("phase") == "active" && store.records.o($0).b("user_confirmed") }) else { continue }
            } else if requested.isEmpty {
                guard keys.allSatisfy({ store.records.o($0).s("phase") == "active" && store.records.o($0).b("user_confirmed") }) else { continue }
            }
            let name = store.apps.o(keys[0]).s("name")
            task.merge(["group_id": id]); task.identify(id, name)
            var alreadyReady = false
            do {
                let checked = NativeEngine(store, system: system, task: task)
                alreadyReady = try keys.allSatisfy {
                    guard ["active", "active_unconfirmed"].contains(store.records.o($0).s("phase")) else { return false }
                    return try checked.isMounted($0)
                }
                if alreadyReady {
                    let needsOpening = automatic ? try automaticOpenNeeded(id, keys: keys, store: store) : false
                    if !needsOpening {
                        results[id] = ["name": name, "ok": true, "phase": "complete", "message": "挂载就绪", "app_path": store.apps.o(keys[0]).s("app_path")]
                        task.merge(["results": results]); continue
                    }
                }
                let lock = automatic ? try store.lock("挂载 " + name) : try waitForLock(task, label: "挂载 " + name)
                defer { withExtendedLifetime(lock) {} }
                let current = try NativeStore(root), keys = groupKeys(current, id), engine = NativeEngine(current, system: system, task: task)
                guard !keys.isEmpty else { continue }
                if automatic {
                    guard current.config.b("automatic_mount", true), !stateLock.locked({ suspended.contains(id) }),
                          keys.allSatisfy({ current.apps.o($0).b("enabled") && current.records.o($0).s("phase") == "active" && current.records.o($0).b("user_confirmed") }) else { continue }
                }
                let wasReady = keys.allSatisfy { (try? engine.isMounted($0)) == true }
                if !wasReady {
                    let ledgerURL = runtime.appendingPathComponent("opened.json")
                    var ledger = try readObject(ledgerURL, fallback: [:]); ledger.removeValue(forKey: id)
                    try writeObject(ledger, to: ledgerURL)
                }
                for key in keys {
                    if current.records.o(key).s("phase") == "rolled_back" && !requested.isEmpty { continue }
                    _ = try engine.mount(key)
                }
                var row: Object = ["name": name, "ok": true, "phase": "complete", "message": "挂载就绪", "app_path": current.apps.o(keys[0]).s("app_path")]
                if automatic || (!wasReady && task.snapshot().s("action") != "prepare_launch") { do { try automaticOpen(id, keys: keys, store: current) } catch { row["launch_note"] = error.localizedDescription } }
                results[id] = row
            } catch {
                let error = error as? DBError ?? DBError(error.localizedDescription)
                if alreadyReady && automatic && error.reason == "busy" {
                    results[id] = ["name": name, "ok": true, "phase": "complete", "message": "挂载就绪", "launch_pending": true,
                                   "launch_note": "其他任务结束后自动打开应用。", "reason": "busy", "retryable": true]
                } else {
                    results[id] = ["name": name, "ok": false, "phase": error.retryable ? "waiting" : "failed", "reason": error.reason, "retryable": error.retryable, "message": error.localizedDescription]
                }
            }
            task.merge(["results": results])
        }
        if !automatic && !requested.isEmpty && results[requested] == nil { throw DBError("没有符合条件的应用迁移记录。") }
        return results
    }
    func automaticConnectionTokens(_ store: NativeStore, volumes: [Object]) -> Set<String> {
        guard store.config.b("automatic_mount", true) else { return [] }
        let targets = Set(store.apps.keys.filter {
            store.apps.o($0).b("enabled") && store.records.o($0).s("phase") == "active" && store.records.o($0).b("user_confirmed")
        }.map { store.apps.o($0).s("volume_uuid").lowercased() })
        return Set(volumes.filter { targets.contains($0.s("uuid").lowercased()) }.map { $0.s("uuid").lowercased() + ":" + $0.s("device") })
    }
    func clearTaskHistory(_ values: Object) throws -> Object {
        let cleanupLock = try NativeLock(runtime.appendingPathComponent("history-cleanup.lock"), label: "清理任务记录")
        defer { withExtendedLifetime(cleanupLock) {} }
        let requested = values.s("task_id")
        if !requested.isEmpty { _ = try safeTaskID(requested) }
        let excluded = Set(values["exclude_ids"] as? [String] ?? [])
        let history = runtime.appendingPathComponent("history")
        let urls = (try? nativeFM.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)) ?? []
        var removed: [String] = []
        for url in urls where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            guard requested.isEmpty || id == requested, !excluded.contains(id), (try? safeTaskID(id)) != nil else { continue }
            let row = try readObject(url), taskURL = runtime.appendingPathComponent("tasks/\(id).json")
            guard ["complete", "failed", "stopped", "interrupted"].contains(row.s("phase")), !stateLock.locked({ active[id] != nil }) else { continue }
            if exists(taskURL.path) {
                let taskRow = try readObject(taskURL)
                guard ["complete", "failed", "stopped", "interrupted"].contains(taskRow.s("phase")) else { continue }
                try nativeFM.removeItem(at: taskURL)
            }
            try nativeFM.removeItem(at: url); removed.append(id)
        }
        return ["removed_ids": removed]
    }
    func automaticOpenToken(_ keys: [String], store: NativeStore) throws -> String? {
        guard keys.allSatisfy({ store.apps.o($0).b("auto_open") && store.records.o($0).s("phase") == "active" }) else { return nil }
        let tokens = try keys.map { try system.diskInfo(store.apps.o($0).s("mount_point")).s("DeviceIdentifier") }.sorted()
        return bootID + ":" + tokens.joined(separator: ":")
    }
    func automaticOpenNeeded(_ id: String, keys: [String], store: NativeStore) throws -> Bool {
        guard let token = try automaticOpenToken(keys, store: store) else { return false }
        return try readObject(runtime.appendingPathComponent("opened.json"), fallback: [:]).s(id) != token
    }
    func automaticOpen(_ id: String, keys: [String], store: NativeStore) throws {
        guard let token = try automaticOpenToken(keys, store: store) else { return }
        let ledgerURL = runtime.appendingPathComponent("opened.json")
        var ledger = try readObject(ledgerURL, fallback: [:])
        guard ledger.s(id) != token else { return }
        ledger[id] = token; try writeObject(ledger, to: ledgerURL)
        let app = store.apps.o(keys[0])
        if !system.running(app) { try system.openApplication(app.s("app_path")) }
    }
    func scheduleAutomatic(appIDs: Set<String>? = nil) {
        if let appIDs, appIDs.isEmpty { return }
        let admitted = stateLock.locked { () -> Bool in
            if automaticRunning {
                if let appIDs { automaticPendingIDs.formUnion(appIDs) }
                else if automaticScope != nil { automaticPendingAll = true }
                return false
            }
            automaticRunning = true; automaticScope = appIDs; return true
        }
        guard admitted else { return }
        let task = NativeTask("automatic", values: ["internal": true], runtime: runtime)
        let summary = runtime.appendingPathComponent("automatic.json")
        task.onChange = { value in try? writeObject(value, to: summary) }
        stateLock.locked { active[task.id] = task }
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                let next: (Bool, Set<String>?) = stateLock.locked {
                    active.removeValue(forKey: task.id); automaticRunning = false
                    let pending = automaticPendingAll || !automaticPendingIDs.isEmpty
                    let ids: Set<String>? = automaticPendingAll ? nil : automaticPendingIDs
                    automaticPendingIDs.removeAll(); automaticPendingAll = false; automaticScope = nil
                    return (pending, ids)
                }
                if next.0 { scheduleAutomatic(appIDs: next.1) }
            }
            task.activate()
            let deadline = Date().addingTimeInterval(120)
            do {
                while true {
                    try task.check()
                    if !(try NativeStore(root)).config.b("automatic_mount", true) { task.merge(["disabled": true]); task.finish(Object()); return }
                    var result: Object = [:]
                    if let appIDs {
                        for id in appIDs.sorted() { result.merge(try mountApplications(task: task, requested: id, automatic: true)) { _, new in new } }
                    } else { result = try mountApplications(task: task, requested: "", automatic: true) }
                    let pending = result.values.compactMap { $0 as? Object }.filter { (!$0.b("ok") && $0.b("retryable")) || $0.b("launch_pending") }
                    task.merge(["results": result])
                    if pending.isEmpty || (Date() >= deadline && !pending.allSatisfy({ $0.s("reason") == "busy" })) {
                        if result.values.compactMap({ $0 as? Object }).contains(where: { !$0.b("ok") }) {
                            throw DBError(result.values.compactMap { $0 as? Object }.filter { !$0.b("ok") }.map { $0.s("message") }.joined(separator: "；"))
                        }
                        task.finish(result); return
                    }
                    let messages = Set(pending.map { $0.b("launch_pending") ? $0.s("launch_note") : $0.s("message") }).sorted()
                    task.merge(["label": pending.allSatisfy { $0.b("launch_pending") } ? "等待自动打开" : "等待挂载条件"])
                    task.waiting(messages.joined(separator: "；"))
                    Thread.sleep(forTimeInterval: 2)
                }
            } catch { task.fail(error) }
            notifyTask(task.snapshot())
        }
    }
    func deleteRetained(_ values: Object, task: NativeTask) throws -> Object {
        let store = try NativeStore(root), copyID = values.s("copy_id"), archived = values.b("archived")
        var archives = store.state.o("archives")
        let item = archives.o(copyID)
        let app = archived ? item.o("app") : store.apps.o(copyID)
        var record = archived ? item.o("record") : store.records.o(copyID)
        guard record.s("phase") == "rolled_back", !record.b("retained_image_deleted"), !app.isEmpty,
              values.s("phrase") == deletionConfirmation else { throw DBError("保留副本状态或确认短语不符合清理条件。") }
        let engine = NativeEngine(store, system: system, task: task), path = try engine.imageFor(app)
        for key in store.apps.keys where ["active", "active_unconfirmed", "restoring"].contains(store.records.o(key).s("phase")) {
            let current = store.apps.o(key)
            guard !(current.s("volume_uuid").lowercased() == app.s("volume_uuid").lowercased() && current.s("folder") == app.s("folder")) else { throw DBError("该副本仍是当前工作数据，不能清理。") }
        }
        func attachedElsewhere() throws -> Bool {
            try system.plist("/usr/bin/hdiutil", ["info", "-plist"]).list("images").contains {
                normalized($0.s("image-path")) == path && $0.list("system-entities").contains { !$0.s("mount-point").isEmpty }
            }
        }
        guard isDirectory(path), try !attachedElsewhere() else { throw DBError("副本不存在或仍被挂载，未清理。") }
        let check = engine.manifest(record, "retained-check-" + UUID().uuidString).path
        try privateDirectory(URL(fileURLWithPath: check))
        do {
            try task.begin("只读核对保留副本身份")
            try system.attach(path, check, task: task, readOnly: true)
            try engine.owned(record, at: check)
            guard try system.diskInfo(check).s("VolumeUUID") == record.s("image_volume_uuid") else { throw DBError("保留副本的 UUID 不匹配。") }
            try system.detach(check)
        } catch { if mounted(check) { try? system.detach(check) }; throw error }
        guard !mounted(check), try !attachedElsewhere() else { throw DBError("副本仍在使用，未清理。") }
        try? nativeFM.removeItem(atPath: check)
        try task.check(); try task.begin("清理已确认的外置保留副本")
        try nativeFM.removeItem(atPath: path)
        record["retained_image_deleted"] = true
        if archived { var value = item; value["record"] = record; archives[copyID] = value; store.state["archives"] = archives; try store.save() }
        else { try store.updateRecord(copyID, record) }
        return ["copy_id": copyID]
    }
}
