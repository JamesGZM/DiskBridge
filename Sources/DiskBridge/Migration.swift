import Foundation
import Darwin

extension NativeSystem {
    func copy(_ source: String, _ target: String, task: NativeTask, label: String, volumeRoot: Bool = false) throws {
        let entries = try inventory(source, task: task), counts = totals(entries)
        try task.begin(label, total: counts.n("bytes"), files: counts.n("files"))
        let credit = NSLock()
        var current: String?, credited: [String: Int64] = [:], completed = Set<String>(), stopped = false
        var bytes: Int64 = 0
        func update(_ relative: String, complete: Bool) {
            let entry = entries.o(relative)
            guard entry.s("type") == "file" else { return }
            let amount = complete ? entry.n("size") : min(entry.n("size"), (try? fileStat(target + "/" + relative).st_size) ?? 0)
            bytes += max(0, amount - (credited[relative] ?? 0)); credited[relative] = max(amount, credited[relative] ?? 0)
            if complete { completed.insert(relative) }
            task.absolute(bytes, files: Int64(completed.count))
        }
        let monitor = DispatchGroup(); monitor.enter()
        DispatchQueue.global().async {
            while true {
                let stop = credit.locked { () -> Bool in if let current { update(current, complete: false) }; return stopped }
                if stop { break }; Thread.sleep(forTimeInterval: 0.2)
            }
            monitor.leave()
        }
        defer { credit.locked { stopped = true }; monitor.wait() }
        let parts: [(String, String, String)]
        if volumeRoot {
            guard !exists(target) else { throw DBError("还原工作副本已存在，未覆盖。") }
            try privateDirectory(URL(fileURLWithPath: target))
            parts = try nativeFM.contentsOfDirectory(atPath: source).filter { !ignoredVolumeItems.contains($0) }.map { (source + "/" + $0, target + "/" + $0, $0) }
        } else { parts = [(source, target, "")] }
        for (src, dst, prefix) in parts {
            try task.check()
            if volumeRoot && isLink(src) {
                try nativeFM.createSymbolicLink(atPath: dst, withDestinationPath: nativeFM.destinationOfSymbolicLink(atPath: src)); continue
            }
            credit.locked { current = volumeRoot && !isDirectory(src) ? prefix : nil }
            _ = try run("/usr/bin/ditto", ["-V", "--nonAtomicCopies", "--rsrc", "--extattr", "--acl", src, dst], timeout: 86_400, task: task) { line in
                let marker = "copying file ./"
                credit.locked {
                    if line.hasPrefix(marker), line.hasSuffix(" ...") {
                        if let current { update(current, complete: true) }
                        let relative = String(line.dropFirst(marker.count).dropLast(4))
                        current = prefix.isEmpty ? relative : prefix + "/" + relative
                    } else if line.hasPrefix("copied ") || line.hasPrefix("hardlinked ") {
                        if let current { update(current, complete: true) }; current = nil
                    }
                }
            }
            credit.locked { if let current { update(current, complete: true) }; current = nil }
        }
        task.absolute(counts.n("bytes"), files: counts.n("files"))
    }
}

final class NativeEngine {
    let store: NativeStore
    let system: NativeSystem
    let task: NativeTask
    init(_ store: NativeStore, system: NativeSystem = NativeSystem(), task: NativeTask = NativeTask("engine")) {
        self.store = store; self.system = system; self.task = task
    }
    func app(_ key: String) throws -> Object {
        let app = store.apps.o(key)
        for field in ["name", "app_path", "bundle_id", "mount_point", "volume_uuid", "folder"] {
            guard !app.s(field).isEmpty else { throw DBError("应用配置缺少 \(field)，未操作数据。") }
        }
        _ = try sourcePath(app.s("mount_point")); _ = try relativeFolder(app.s("folder"))
        guard (1...16384).contains(app.n("capacity_gib")) else { throw DBError("镜像逻辑容量超出支持范围。") }
        let binding = store.records.o(key).o("binding")
        for field in ["app_path", "bundle_id", "mount_point", "volume_uuid", "folder"] {
            if !binding.s(field).isEmpty && binding.s(field) != app.s(field) { throw DBError("迁移记录与配置中的 \(field) 不一致，请先恢复或还原。") }
        }
        return app
    }
    func record(_ key: String) throws -> Object {
        let record = store.records.o(key)
        guard !record.isEmpty, record.s("source") == store.apps.o(key).s("mount_point") else { throw DBError("应用迁移记录不存在或原路径不匹配。") }
        return record
    }
    @discardableResult func checkpoint(_ key: String, _ phase: String, _ values: Object = [:]) throws -> Object {
        var value = try record(key); value.merge(values) { _, b in b }; value["phase"] = phase
        value["updated_at"] = ISO8601DateFormatter().string(from: Date()); try store.updateRecord(key, value); return value
    }
    func manifest(_ record: Object, _ name: String) -> URL { store.root.appendingPathComponent("records/\(record.s("id"))/\(name)") }
    func imageFor(_ app: Object) throws -> String {
        let disk = try system.volume(app.s("volume_uuid"))
        let root = disk.s("path"), path = try root + "/" + relativeFolder(app.s("folder")) + "/Data.sparsebundle"
        guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path, path.hasPrefix(root + "/") else { throw DBError("外置镜像路径含软链接或越界。") }
        return path
    }
    func image(_ key: String) throws -> String { try imageFor(app(key)) }
    func owned(_ record: Object, at path: String) throws {
        let marker = try readObject(URL(fileURLWithPath: path).appendingPathComponent(volumeMarker))
        guard marker.s("id") == record.s("id") else { throw DBError("挂载卷的身份标识不匹配，未继续操作。") }
    }
    func isMounted(_ key: String) throws -> Bool {
        let app = try app(key), record = try record(key), source = app.s("mount_point")
        guard mounted(source) else { return false }
        try owned(record, at: source)
        guard let actual = try system.imageAt(source), normalized(actual) == (try image(key)) else { throw DBError("原路径挂载的是其他镜像，未覆盖或卸载。") }
        if !record.s("image_volume_uuid").isEmpty {
            guard try system.diskInfo(source).s("VolumeUUID") == record.s("image_volume_uuid") else { throw DBError("镜像宗卷 UUID 与迁移记录不一致。") }
        }
        return true
    }
    func guardMatches(_ path: String, inode: Int64) -> Bool {
        guard !mounted(path), let value = try? fileStat(path), value.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR),
              value.st_ino == UInt64(inode), value.st_flags & UInt32(UF_IMMUTABLE) != 0 else { return false }
        return (try? nativeFM.contentsOfDirectory(atPath: path).isEmpty) ?? false
    }
    func makeGuard(_ path: String) throws -> Int64 {
        guard !exists(path) else { throw DBError("挂载点已存在，未覆盖本地文件。") }
        guard mkdir(path, 0o700) == 0 else { throw DBError.io(errno) }
        let value = try fileStat(path)
        guard chflags(path, value.st_flags | UInt32(UF_IMMUTABLE)) == 0 else { throw DBError.io(errno) }
        return Int64(value.st_ino)
    }
    func removeGuard(_ path: String, inode: Int64) throws {
        guard guardMatches(path, inode: inode) else { throw DBError("挂载点不是匹配的空保护目录，未删除。") }
        let value = try fileStat(path)
        guard chflags(path, value.st_flags & ~UInt32(UF_IMMUTABLE)) == 0, rmdir(path) == 0 else { throw DBError.io(errno) }
    }
    func configure(_ key: String, profile: Object) throws {
        let source = try sourcePath(profile.s("mount_point"))
        let prior = store.records.o(key)
        if !prior.isEmpty {
            guard prior.s("phase") == "rolled_back", prior.s("source") == source else { throw DBError("已有迁移任务，请先继续任务或还原，不能覆盖记录。") }
            var archived = store.state.o("archives")
            archived[prior.s("id")] = ["app_id": key, "app": store.apps.o(key), "record": prior]
            store.state["archives"] = archived
            var records = store.records; records.removeValue(forKey: key); store.records = records
        }
        for (otherKey, anyApp) in store.apps where otherKey != key {
            guard let other = anyApp as? Object else { continue }
            let path = other.s("mount_point")
            guard path != source, !path.hasPrefix(source + "/"), !source.hasPrefix(path + "/") else { throw DBError("数据目录与另一个应用重叠。") }
            guard !(other.s("volume_uuid").lowercased() == profile.s("volume_uuid").lowercased() && other.s("folder") == profile.s("folder")) else { throw DBError("外置目录已被另一个应用使用。") }
        }
        var value = profile; value["enabled"] = false; value["auto_open"] = false
        var apps = store.apps; apps[key] = value; store.apps = apps
        _ = try app(key); try store.save()
    }
    @discardableResult func migrate(_ key: String, activateWhenReady: Bool = true) throws -> Object {
        let app = try app(key), source = app.s("mount_point")
        try system.requireStopped(app); task.identify(key, app.s("name"))
        let old = store.records.o(key), phase = old.s("phase")
        if ["active", "active_unconfirmed"].contains(phase) { _ = try mount(key); return old }
        if ["verified", "original_preserved", "guarded"].contains(phase) { return activateWhenReady ? try activate(key) : old }
        guard old.isEmpty || ["preparing", "image_created", "copying", "copy_failed"].contains(phase) else { throw DBError("任务当前不能重新迁移，请选择继续任务。") }
        guard isDirectory(source), !mounted(source), !isLink(source), !exists(source + "/" + volumeMarker),
              !source.hasPrefix(store.root.path + "/"), !store.root.path.hasPrefix(source + "/") else { throw DBError("原数据目录不存在、已迁移或与工具目录重叠。") }
        let entries = try inventory(source, task: task), size = totals(entries), disk = try system.volume(app.s("volume_uuid"))
        guard disk.n("free") >= size.n("bytes") + 512 * 1024 * 1024 else { throw DBError("外置盘空间不足。") }
        let capacityBytes = Double(app.n("capacity_gib")) * 1_073_741_824.0
        let requiredBytes = Double(size.n("bytes")) * 1.2 + 268_435_456.0
        guard capacityBytes >= requiredBytes else { throw DBError("镜像逻辑容量不足。") }
        let image = try image(key)
        if old.isEmpty {
            guard !exists(image) else { throw DBError("目标已有镜像，未覆盖。请重新选择目录。") }
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            var binding: Object = [:]; for field in ["mount_point", "volume_uuid", "folder", "app_path", "bundle_id"] { binding[field] = app[field] }
            var records = store.records
            records[key] = ["id": id, "phase": "preparing", "source": source, "original": source + ".AppDataMount-original-" + String(id.prefix(12)),
                            "mode": Int(try fileStat(source).st_mode & 0o7777), "binding": binding, "created_at": ISO8601DateFormatter().string(from: Date())]
            store.records = records; try store.save()
        }
        var record = try record(key)
        let expected = try hashTree(source, task: task, label: "读取内置原件校验值")
        try writeObject(expected, to: manifest(record, "original-manifest.json"))
        let temporary = manifest(record, "copy-volume").path
        if !exists(image) {
            try task.begin("创建外置稀疏镜像")
            try system.createImage(image, capacity: app.n("capacity_gib"), label: "DiskBridge-" + String(record.s("id").prefix(12)), task: task)
            try checkpoint(key, "image_created")
        }
        try privateDirectory(URL(fileURLWithPath: temporary))
        if mounted(temporary) {
            try owned(record, at: temporary)
            guard try system.imageAt(temporary).map(normalized) == image else { throw DBError("临时卷挂载身份不符。") }
        } else { try system.attach(image, temporary, task: task) }
        do {
            if exists(temporary + "/" + volumeMarker) { try owned(record, at: temporary) }
            else {
                let items = try nativeFM.contentsOfDirectory(atPath: temporary).filter { !ignoredVolumeItems.contains($0) }
                guard items.isEmpty else { throw DBError("镜像有未识别的数据，未覆盖。") }
                try writeObject(["id": record.s("id"), "version": 1], to: URL(fileURLWithPath: temporary + "/" + volumeMarker))
            }
            // A failed copy is restarted only inside this owned staging image.
            for item in try nativeFM.contentsOfDirectory(atPath: temporary) where !ignoredVolumeItems.contains(item) {
                try nativeFM.removeItem(atPath: temporary + "/" + item)
            }
            try checkpoint(key, "copying")
            try system.copy(source, temporary, task: task, label: "复制到外置硬盘")
            try owned(record, at: temporary)
            let copied = try hashTree(temporary, task: task, label: "校验外置副本")
            try requireEqual(expected, copied)
            try requireEqual(expected, hashTree(source, task: task, label: "复核内置原件未变化"))
            try system.requireStopped(app)
            let info = try system.diskInfo(temporary)
            try checkpoint(key, "verified", ["verification": totals(copied), "image_volume_uuid": info.s("VolumeUUID")])
        } catch {
            if (try? self.record(key).s("phase")) == "copying" { _ = try? checkpoint(key, "copy_failed") }
            if mounted(temporary) { try? system.detach(temporary) }
            throw error
        }
        if mounted(temporary) { try system.detach(temporary) }
        record = try self.record(key)
        return activateWhenReady ? try activate(key) : record
    }
    func activate(_ key: String) throws -> Object {
        let app = try app(key), record = try record(key), source = record.s("source"), original = record.s("original")
        try system.requireStopped(app)
        let expectedName = URL(fileURLWithPath: source).lastPathComponent + ".AppDataMount-original-" + String(record.s("id").prefix(12))
        guard URL(fileURLWithPath: original).deletingLastPathComponent() == URL(fileURLWithPath: source).deletingLastPathComponent(),
              URL(fileURLWithPath: original).lastPathComponent == expectedName, !isLink(original) else { throw DBError("原件备份路径身份异常。") }
        if mounted(source) { guard try isMounted(key) else { throw DBError("工作卷身份异常。") }; return try checkpoint(key, "active_unconfirmed") }
        if !exists(original) {
            let expected = try readObject(manifest(record, "original-manifest.json"))
            try requireEqual(expected, hashTree(source, task: task, label: "切换前核对内置原件"))
            try system.requireStopped(app)
            try nativeFM.moveItem(atPath: source, toPath: original); try checkpoint(key, "original_preserved")
        } else {
            try requireEqual(readObject(manifest(record, "original-manifest.json")), hashTree(original, task: task, label: "核对保留的原件备份"))
        }
        if !exists(source) { try checkpoint(key, "guarded", ["guard_inode": makeGuard(source)]) }
        let current = try self.record(key)
        guard guardMatches(source, inode: current.n("guard_inode")) else { throw DBError("原路径不是匹配的空保护目录，未覆盖本地数据。") }
        do {
            try task.begin("挂载外置数据卷")
            try system.attach(image(key), source, task: task)
            try owned(current, at: source)
        } catch {
            if !mounted(source), guardMatches(source, inode: current.n("guard_inode")) {
                try removeGuard(source, inode: current.n("guard_inode"))
                try nativeFM.moveItem(atPath: original, toPath: source)
                try checkpoint(key, "verified", ["guard_inode": NSNull()])
            }
            throw error
        }
        return try checkpoint(key, "active_unconfirmed")
    }
    func confirm(_ key: String) throws {
        guard try record(key).s("phase") == "active_unconfirmed", try isMounted(key) else { throw DBError("请先在已挂载状态检查旧记录，再完成验收。") }
        var app = try app(key); app["enabled"] = true
        var apps = store.apps; apps[key] = app; store.apps = apps
        try checkpoint(key, "active", ["user_confirmed": true])
    }
    @discardableResult func mount(_ key: String) throws -> String {
        let app = try app(key), record = try record(key), source = app.s("mount_point")
        task.identify(key, app.s("name")); try task.begin("核对当前挂载")
        guard ["active", "active_unconfirmed"].contains(record.s("phase")) else { throw DBError("迁移尚未完成或已经还原。") }
        if try isMounted(key) { return "已挂载" }
        try task.begin("检查应用是否退出"); try system.requireStopped(app)
        try task.begin("核对挂载点保护")
        guard guardMatches(source, inode: record.n("guard_inode")) else { throw DBError("原路径不是匹配的空保护目录，不能掩盖本地数据。") }
        try task.begin("定位外置硬盘与镜像"); let path = try image(key)
        guard isDirectory(path) else { throw DBError("外置镜像不存在；挂载点继续保持保护。") }
        try task.begin("系统正在挂载镜像"); try system.attach(path, source, task: task)
        do { try task.begin("校验镜像身份与 UUID"); guard try isMounted(key) else { throw DBError("挂载结果未通过校验。") } }
        catch { if !system.running(app) { try? system.detach(source) }; throw error }
        return "挂载成功"
    }
    func unmount(_ key: String) throws {
        let app = try app(key), record = try record(key)
        try system.requireStopped(app)
        if try isMounted(key) { try system.detach(app.s("mount_point")) }
        guard guardMatches(app.s("mount_point"), inode: record.n("guard_inode")) else { throw DBError("卸载后保护目录状态异常，请查看详情。") }
    }
    @discardableResult func rollback(_ key: String, finishWhenReady: Bool = true) throws -> Object {
        var app = try app(key); var record = try record(key)
        try system.requireStopped(app)
        if record.s("phase") == "rolled_back" { return record }
        if ["restore_verified", "restore_detached"].contains(record.s("phase")) { return finishWhenReady ? try finishRollback(key, recheck: true) : record }
        guard ["active", "active_unconfirmed", "restoring"].contains(record.s("phase")) else { throw DBError("任务尚未完成迁移，请先恢复任务。") }
        if record.s("phase") == "restoring" { record["phase"] = "active_unconfirmed"; try store.updateRecord(key, record) }
        _ = try mount(key)
        let source = record.s("source"), latest = try hashTree(source, task: task, label: "读取最新工作数据")
        guard freeBytes(URL(fileURLWithPath: source).deletingLastPathComponent().path) >= totals(latest).n("bytes") + 512 * 1024 * 1024 else { throw DBError("内置盘空间不足，当前工作卷与所有副本保留。") }
        let stage = source + ".AppDataMount-restore-" + String(UUID().uuidString.prefix(12))
        app["enabled"] = false; var apps = store.apps; apps[key] = app; store.apps = apps
        var attempts = record["restore_attempts"] as? [String] ?? []; attempts.append(stage)
        try checkpoint(key, "restoring", ["restore_stage": stage, "restore_attempts": attempts])
        try writeObject(latest, to: manifest(record, "latest-manifest.json"))
        try system.copy(source, stage, task: task, label: "同步最新数据回内置硬盘", volumeRoot: true)
        guard chmod(stage, mode_t(record.n("mode", 0o700))) == 0 else { throw DBError.io(errno) }
        let restored = try hashTree(stage, task: task, label: "校验内置工作副本")
        try requireEqual(latest, restored); try system.requireStopped(app)
        try checkpoint(key, "restore_verified", ["restore_verification": totals(restored)])
        return finishWhenReady ? try finishRollback(key, recheck: false) : try self.record(key)
    }
    func finishRollback(_ key: String, recheck: Bool) throws -> Object {
        let app = try app(key), record = try record(key), source = record.s("source"), stage = record.s("restore_stage")
        try system.requireStopped(app)
        guard normalized(stage) == stage, !isLink(stage), URL(fileURLWithPath: stage).deletingLastPathComponent() == URL(fileURLWithPath: source).deletingLastPathComponent(),
              stage.hasPrefix(source + ".AppDataMount-restore-") else { throw DBError("还原工作副本的路径异常。") }
        let expected = try readObject(manifest(record, "latest-manifest.json"))
        if exists(stage) {
            if recheck {
                if mounted(source) {
                    let latest = try hashTree(source, task: task, label: "核对中断后新增的数据")
                    if !NSDictionary(dictionary: expected).isEqual(to: latest) { try checkpoint(key, "restoring"); return try rollback(key) }
                }
                try requireEqual(expected, hashTree(stage, task: task, label: "复核还原工作副本"))
            }
            try system.requireStopped(app)
            if mounted(source) { guard try isMounted(key) else { throw DBError("源卷身份不匹配。") }; try system.detach(source) }
            if exists(source) { try removeGuard(source, inode: record.n("guard_inode")) }
            try checkpoint(key, "restore_detached")
            try nativeFM.moveItem(atPath: stage, toPath: source)
        } else { try requireEqual(expected, hashTree(source, task: task, label: "核对已经完成的还原")) }
        return try checkpoint(key, "rolled_back")
    }
    func recover(_ key: String) throws -> Object {
        if ["restoring", "restore_verified", "restore_detached"].contains(store.records.o(key).s("phase")) { return try rollback(key) }
        return try migrate(key)
    }
    func deleteOriginal(_ key: String) throws -> Object {
        let app = try app(key), record = try record(key)
        if record.s("phase") == "active" { guard try isMounted(key) else { throw DBError("请先挂载并确认外置工作数据可用。") } }
        return try checkpoint(key, record.s("phase"), removeOriginalBackup(app, record: record))
    }
    func removeOriginalBackup(_ app: Object, record: Object) throws -> Object {
        let source = record.s("source"), original = record.s("original")
        try system.requireStopped(app)
        guard ["active", "rolled_back"].contains(record.s("phase")), !isLink(original),
              original == source + ".AppDataMount-original-" + String(record.s("id").prefix(12)) else { throw DBError("原件备份身份或任务状态不符合清理条件。") }
        try requireEqual(readObject(manifest(record, "original-manifest.json")), hashTree(original, task: task, label: "校验待清理原件备份"))
        try task.check(); let before = freeBytes(URL(fileURLWithPath: original).deletingLastPathComponent().path)
        try task.begin("清理已核对的原件备份")
        try nativeFM.removeItem(atPath: original)
        let after = freeBytes(URL(fileURLWithPath: original).deletingLastPathComponent().path)
        return ["original_deleted": true, "measured_freed_bytes": max(0, after - before), "space_measured_ns": stamp()]
    }
}
