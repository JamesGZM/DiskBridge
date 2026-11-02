import Foundation

extension NativeService {
    func measurementLocation(_ id: String, store: NativeStore) -> String {
        let keys = groupKeys(store, id)
        if keys.isEmpty || keys.allSatisfy({ store.records.o($0).s("phase") == "rolled_back" }) { return "internal" }
        return keys.allSatisfy({ ["active", "active_unconfirmed"].contains(store.records.o($0).s("phase")) }) ? "external" : "mixed"
    }
    func saveMeasurement(_ id: String, row: Object) throws {
        try measurementLock.locked {
            let url = runtime.appendingPathComponent("sizes.json")
            var sizes = try readObject(url, fallback: [:]), row = row
            row["version"] = 2; row["updated_ns"] = stamp(); sizes[id] = row; sizes["_updated_ns"] = row["updated_ns"]
            try writeObject(sizes, to: url)
        }
    }
    func measureApplication(_ id: String, app: Object, task: NativeTask) throws -> Object {
        let store = try NativeStore(root), keys = groupKeys(store, id), location = measurementLocation(id, store: store)
        guard location != "mixed" else { throw DBError("应用正在迁移或还原，请在任务完成后读取数据大小。", "busy") }
        let paths: [String]
        if keys.isEmpty { paths = system.dataCandidates(app).filter { !$0.b("shared") }.map { $0.s("path") } }
        else {
            if location == "external" {
                let engine = NativeEngine(store, system: system)
                for key in keys { guard try engine.isMounted(key) else { throw DBError("请连接目标硬盘并挂载后读取数据大小。", "disk_not_ready") } }
            }
            paths = keys.map { store.apps.o($0).s("mount_point") }
        }
        if paths.isEmpty {
            let row: Object = ["status": "not_found", "location": location, "measured_ns": stamp(), "note": "未发现可迁移的数据目录，不代表此应用没有数据。可在迁移流程中手动添加目录。"]
            try saveMeasurement(id, row: row); return row
        }
        try saveMeasurement(id, row: ["status": "reading", "location": location, "note": "后台读取中，不包含应用本体。"])
        do {
            let bytes = try system.dataBytes(paths, task: task)
            let current = try NativeStore(root)
            guard measurementLocation(id, store: current) == location,
                  groupKeys(current, id).map({ current.apps.o($0).s("mount_point") }) == keys.map({ store.apps.o($0).s("mount_point") }) else {
                throw DBError("数据位置已变化，将在下一次读取时更新大小。", "busy")
            }
            let row: Object = ["bytes": bytes, "status": "ready", "location": location, "measured_ns": stamp(),
                               "note": "可迁移数据目录的实际占用，不含应用本体、未选择的共享目录和原件备份。"]
            try saveMeasurement(id, row: row); return row
        } catch {
            try? saveMeasurement(id, row: ["status": "unknown", "location": location, "measured_ns": stamp(), "note": error.localizedDescription])
            throw error
        }
    }
    @discardableResult func scheduleMeasurements(_ apps: [Object], force: Bool = false) -> String? {
        let sizes = (try? readObject(runtime.appendingPathComponent("sizes.json"), fallback: [:])) ?? [:]
        let pending = apps.filter { app in
            guard !app.b("own"), app.s("migration_state") != "incomplete" else { return false }
            if !force, app.b("managed"), ["migrated", "pending"].contains(app.s("migration_state")), app["bytes"] is NSNumber { return false }
            let row = sizes.o(app.s("id")), age = stamp() - row.n("measured_ns")
            if !force, row.n("version") == 2, row.s("location") == app.s("data_location", "internal"), row.s("status") == "unknown", age < 300_000_000_000 { return false }
            return force || row.n("version") != 2 || row.s("location") != app.s("data_location", "internal") || !["ready", "not_found"].contains(row.s("status")) || age > 1_800_000_000_000
        }
        guard !pending.isEmpty, stateLock.locked({ if measurementsRunning { return false }; measurementsRunning = true; return true }) else { return nil }
        let task = NativeTask("scan_sizes", runtime: runtime)
        stateLock.locked { active[task.id] = task }
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { stateLock.locked { active.removeValue(forKey: task.id); measurementsRunning = false } }
            task.activate()
            do {
                try system.checkAuthorization(NativeStore(root))
                try task.begin("后台读取应用数据大小")
                for (index, app) in pending.enumerated() {
                    try task.check(); let id = app.s("id")
                    task.identify(id, app.s("name")); task.merge(["path_index": index + 1, "path_total": pending.count])
                    do { _ = try measureApplication(id, app: app, task: task) }
                    catch let error as DBError where error.reason == "stopped" { throw error }
                    catch { task.merge(["note": app.s("name") + "：" + error.localizedDescription]) }
                }
                task.finish(["count": pending.count])
            } catch { task.fail(error) }
        }
        return task.id
    }
}
