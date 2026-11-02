import Foundation
import AppKit
import CryptoKit
import Darwin

typealias Object = [String: Any]
let nativeFM = FileManager.default
let volumeMarker = ".appdatamount-volume.json"
let deletionConfirmation = "确认删除"
let ignoredVolumeItems: Set<String> = [volumeMarker, ".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems"]

extension Dictionary where Key == String, Value == Any {
    func s(_ key: String, _ fallback: String = "") -> String { self[key] as? String ?? fallback }
    func b(_ key: String, _ fallback: Bool = false) -> Bool { self[key] as? Bool ?? fallback }
    func n(_ key: String, _ fallback: Int64 = 0) -> Int64 { (self[key] as? NSNumber)?.int64Value ?? fallback }
    func d(_ key: String) -> Double { (self[key] as? NSNumber)?.doubleValue ?? 0 }
    func o(_ key: String) -> Object { self[key] as? Object ?? [:] }
    func list(_ key: String) -> [Object] { self[key] as? [Object] ?? [] }
}
extension NSLocking {
    func locked<T>(_ work: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try work() }
}
func stamp() -> Int64 { Int64(Date().timeIntervalSince1970 * 1e9) }
func normalized(_ path: String) -> String { URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path }
func exists(_ path: String) -> Bool { var value = stat(); return lstat(path, &value) == 0 }
func fileStat(_ path: String) throws -> stat {
    var value = stat()
    guard lstat(path, &value) == 0 else { throw DBError.io(errno) }
    return value
}
func isDirectory(_ path: String) -> Bool { (try? fileStat(path)).map { $0.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR) } ?? false }
func isLink(_ path: String) -> Bool { (try? fileStat(path)).map { $0.st_mode & UInt16(S_IFMT) == UInt16(S_IFLNK) } ?? false }
func mounted(_ path: String) -> Bool {
    var a = stat(), b = stat()
    guard stat(path, &a) == 0, stat(URL(fileURLWithPath: path).deletingLastPathComponent().path, &b) == 0 else { return false }
    return a.st_dev != b.st_dev || (a.st_dev == b.st_dev && a.st_ino == b.st_ino)
}
func freeBytes(_ path: String) -> Int64 {
    ((try? nativeFM.attributesOfFileSystem(forPath: path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
}
func privateDirectory(_ url: URL) throws {
    try nativeFM.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
}

struct DBError: LocalizedError {
    let message: String
    let reason: String
    init(_ message: String, _ reason: String = "failed") { self.message = message; self.reason = reason }
    var errorDescription: String? { message }
    var retryable: Bool { ["busy", "disk_not_ready", "app_running"].contains(reason) }
    static func io(_ code: Int32) -> DBError {
        if code == EPERM || code == EACCES { return DBError("macOS 拒绝访问，请给盘桥开启完全磁盘访问权限。", "authorization") }
        return DBError("文件操作失败（系统错误 \(code)）；数据保留，请查看任务详情。")
    }
}

func readObject(_ url: URL, fallback: Object? = nil) throws -> Object {
    if !exists(url.path), let fallback { return fallback }
    do {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let object = value as? Object else { throw DBError("\(url.lastPathComponent) 格式错误，已停止操作。") }
        return object
    } catch let error as DBError { throw error }
    catch {
        let error = error as NSError
        if error.code == NSFileReadNoPermissionError || (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EPERM) {
            throw DBError.io(EPERM)
        }
        throw DBError("\(url.lastPathComponent) 无法读取，未覆盖现有文件。")
    }
}

func writeObject(_ value: Object, to url: URL) throws {
    try privateDirectory(url.deletingLastPathComponent())
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    let fd = Darwin.open(temp.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard fd >= 0 else { throw DBError.io(errno) }
    defer { close(fd); unlink(temp.path) }
    try data.withUnsafeBytes { buffer in
        var position = 0
        while position < buffer.count {
            let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: position), buffer.count - position)
            guard count > 0 else { throw DBError.io(errno) }; position += count
        }
    }
    guard fsync(fd) == 0, rename(temp.path, url.path) == 0 else { throw DBError.io(errno) }
}

final class NativeStore {
    let root: URL
    var config: Object
    var state: Object
    init(_ root: URL) throws {
        self.root = root
        config = try readObject(root.appendingPathComponent("config.json"), fallback: ["version": 1, "apps": Object()])
        state = try readObject(root.appendingPathComponent("state.json"), fallback: ["version": 1, "apps": Object()])
        guard config.n("version") == 1, state.n("version") == 1,
              config["apps"] is Object, state["apps"] is Object else { throw DBError("迁移记录版本或格式不受支持，未覆盖任何记录。") }
    }
    var apps: Object { get { config.o("apps") } set { config["apps"] = newValue } }
    var records: Object { get { state.o("apps") } set { state["apps"] = newValue } }
    func save() throws {
        try writeObject(config, to: root.appendingPathComponent("config.json"))
        try writeObject(state, to: root.appendingPathComponent("state.json"))
    }
    func updateRecord(_ key: String, _ record: Object) throws { var rows = records; rows[key] = record; records = rows; try save() }
    func lock(_ label: String, name: String = ".operation.lock") throws -> NativeLock {
        try NativeLock(root.appendingPathComponent(name), label: label)
    }
}

final class NativeLock {
    private var fd: Int32 = -1
    init(_ url: URL, label: String) throws {
        try privateDirectory(url.deletingLastPathComponent())
        fd = Darwin.open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw DBError.io(errno) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd); fd = -1
            let owner = (try? readObject(url)) ?? [:]
            let elapsed = max(0, (stamp() - owner.n("started_ns")) / 1_000_000_000)
            let operation = owner.s("operation", "另一个任务"), name = actionNames[operation] ?? operation
            throw DBError("「\(name)」正在执行（已用 \(elapsed) 秒），完成后将自动继续。", "busy")
        }
        let data = try JSONSerialization.data(withJSONObject: ["pid": getpid(), "operation": label, "started_ns": stamp()])
        _ = ftruncate(fd, 0); _ = lseek(fd, 0, SEEK_SET)
        data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
    }
    deinit { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
}

final class NativeTask {
    let id: String
    let runtime: URL?
    let guardLock = NSRecursiveLock()
    var row: Object
    var stopped = false
    var lastWrite = 0.0
    var stageStarted = Date()
    var onChange: ((Object) -> Void)?
    init(_ action: String, values: Object = [:], runtime: URL? = nil, id: String = UUID().uuidString) {
        self.id = id; self.runtime = runtime
        row = ["id": id, "action": action, "values": values, "phase": "queued", "label": "等待执行", "created_ns": stamp(), "updated_ns": stamp(), "pid": getpid()]
        emit(true)
    }
    func check() throws { if guardLock.locked({ stopped }) { throw DBError("已在安全检查点停止；原件与已复制部分保留，可继续任务。", "stopped") } }
    func cancel() { guardLock.locked { stopped = true } }
    func activate() { guardLock.locked { row["phase"] = "running"; row["started_ns"] = stamp(); emit(true) } }
    func identify(_ key: String, _ name: String) { guardLock.locked { row["app_id"] = key; row["app_name"] = name; emit(true) } }
    func retryAs(_ action: String, values: Object) { guardLock.locked { row["retry"] = ["action": action, "values": values]; emit(true) } }
    func begin(_ label: String, total: Int64 = 0, files: Int64 = 0) throws {
        try check()
        guardLock.locked { stageStarted = Date(); row.merge(["phase": "running", "label": label, "total": total, "done": Int64(0), "files": Int64(0), "file_total": files, "note": ""]) { _, b in b }; emit(true) }
    }
    func waiting(_ message: String) { guardLock.locked { row["phase"] = "waiting"; row["note"] = message; emit(true) } }
    func advance(_ bytes: Int64 = 0, files: Int64 = 0) throws {
        try check()
        guardLock.locked { row["done"] = row.n("done") + bytes; row["files"] = row.n("files") + files; emit() }
    }
    func absolute(_ bytes: Int64, files: Int64) {
        guardLock.locked { row["done"] = max(row.n("done"), bytes); row["files"] = max(row.n("files"), files); emit() }
    }
    func finish(_ result: Any) { guardLock.locked { row["phase"] = "complete"; row["result"] = result; row["finished_ns"] = stamp(); emit(true) } }
    func fail(_ error: Error) {
        guardLock.locked { row["phase"] = (error as? DBError)?.reason == "stopped" ? "stopped" : "failed"; row["message"] = error.localizedDescription; row["reason"] = (error as? DBError)?.reason ?? "failed"; row["finished_ns"] = stamp(); emit(true) }
    }
    func snapshot() -> Object { guardLock.locked { row } }
    func merge(_ values: Object) { guardLock.locked { row.merge(values) { _, b in b }; emit(true) } }
    func emit(_ force: Bool = false) {
        guard let runtime else { return }
        let now = Date().timeIntervalSince1970
        if !force && now - lastWrite < 0.2 { return }; lastWrite = now
        row["updated_ns"] = stamp()
        let seconds = max(0.001, Date().timeIntervalSince(stageStarted))
        row["rate"] = Double(row.n("done")) / seconds
        row["elapsed"] = max(0, Double((row["finished_ns"] as? NSNumber)?.int64Value ?? stamp()) - Double(row.n("started_ns", row.n("created_ns")))) / 1e9
        do { try writeObject(row, to: runtime.appendingPathComponent("tasks/\(id).json")) }
        catch { NSLog("DiskBridge: task status write failed") }
        if publicTaskAction(row.s("action")) || (row.s("action") == "automatic" && row.o("values").b("internal")) {
            var brief = row; brief.removeValue(forKey: "result"); brief.removeValue(forKey: "values")
            try? writeObject(brief, to: runtime.appendingPathComponent("history/\(id).json"))
        }
        onChange?(row)
    }
}

struct CommandResult { let data: Data; let error: String; let code: Int32 }
class NativeSystem {
    private lazy var modernImages: Bool = {
        guard let result = try? command("/usr/sbin/diskutil", ["image", "attach", "--help"], timeout: 10) else { return false }
        return result.code == 0 && String(decoding: result.data, as: UTF8.self).contains("--mountPoint")
    }()
    func command(_ executable: String, _ args: [String], timeout: Double = 120, task: NativeTask? = nil,
                 stderrLine: ((String) -> Void)? = nil) throws -> CommandResult {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, b in b }
        process.standardOutput = output; process.standardError = errors
        let ioLock = NSLock(), done = DispatchGroup()
        var stdout = Data(), stderr = Data()
        try process.run()
        done.enter(); DispatchQueue.global().async { let data = output.fileHandleForReading.readDataToEndOfFile(); ioLock.locked { stdout = data }; done.leave() }
        done.enter(); DispatchQueue.global().async {
            var pending = Data()
            while true {
                let block = errors.fileHandleForReading.availableData
                if block.isEmpty { break }
                ioLock.locked { if stderr.count < 65_536 { stderr.append(block.prefix(65_536 - stderr.count)) } }
                if let stderrLine {
                    pending.append(block)
                    while let index = pending.firstIndex(of: 10) {
                        let line = String(decoding: pending[..<index], as: UTF8.self); pending.removeSubrange(...index); stderrLine(line)
                    }
                }
            }
            done.leave()
        }
        let start = Date()
        var interruption: Error?
        while process.isRunning {
            do { try task?.check() } catch { interruption = error; process.terminate(); break }
            if Date().timeIntervalSince(start) > timeout { interruption = DBError("系统操作超时；未强制卸载或覆盖，请查看任务状态。", "timeout"); process.terminate(); break }
            Thread.sleep(forTimeInterval: 0.08)
        }
        if process.isRunning {
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            guard !process.isRunning else { throw DBError("系统子进程尚未退出，请先检查任务，暂不切换数据。", "busy") }
        }
        process.waitUntilExit(); done.wait()
        if let interruption { throw interruption }
        let result = ioLock.locked { CommandResult(data: stdout, error: String(decoding: stderr, as: UTF8.self), code: process.terminationStatus) }
        return result
    }
    func run(_ executable: String, _ args: [String], timeout: Double = 120, task: NativeTask? = nil, stderrLine: ((String) -> Void)? = nil) throws -> Data {
        let result = try command(executable, args, timeout: timeout, task: task, stderrLine: stderrLine)
        guard result.code == 0 else {
            if result.error.lowercased().contains("operation not permitted") || result.error.lowercased().contains("permission denied") { throw DBError.io(EPERM) }
            throw DBError("\(URL(fileURLWithPath: executable).lastPathComponent) 执行失败（\(result.code)）；数据与保留副本未被自动清理。")
        }
        return result.data
    }
    func plist(_ executable: String, _ args: [String]) throws -> Object {
        let data = try run(executable, args)
        guard let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? Object else { throw DBError("系统磁盘信息格式异常。") }
        return object
    }
    func diskInfo(_ path: String) throws -> Object { try plist("/usr/sbin/diskutil", ["info", "-plist", path]) }
    func isMountPoint(_ path: String) -> Bool { mounted(path) }
    func validateDestinationRole(_ info: Object) throws {
        guard info.s("FilesystemType").lowercased() == "apfs" else { return }
        let container = info.s("APFSContainerReference")
        let listing = try plist("/usr/sbin/diskutil", ["apfs", "list", "-plist"] + (container.isEmpty ? [] : [container]))
        let volumes = listing.list("Containers").flatMap { $0.list("Volumes") }
        guard let volume = volumes.first(where: { $0.s("APFSVolumeUUID").lowercased() == info.s("VolumeUUID").lowercased() }),
              let roles = volume["Roles"] as? [String] else {
            throw DBError("无法确认目标 APFS 卷的用途，请重新选择外置数据盘。", "invalid_destination")
        }
        guard roles.isEmpty else {
            throw DBError("\(info.s("VolumeName", "所选磁盘")) 是系统或专用用途卷，不能作为迁移目标。请选择外置数据盘。", "invalid_destination")
        }
    }
    func checkDestinationDirectory(_ root: String, folder: String) throws {
        let folder = try relativeFolder(folder), root = normalized(root)
        var created: [String] = []
        defer { for path in created.reversed() { _ = rmdir(path) } }
        do {
            guard !isLink(root), isDirectory(root) else { throw DBError("目标磁盘路径不是普通目录。", "invalid_destination") }
            let device = try fileStat(root).st_dev
            var path = root
            for component in folder.split(separator: "/") {
                path += "/" + component
                if !exists(path) {
                    guard mkdir(path, 0o700) == 0 else { throw DBError("无法创建目标目录。") }
                    created.append(path)
                }
                guard !isLink(path), isDirectory(path), try fileStat(path).st_dev == device else {
                    throw DBError("目标目录包含符号链接、其他挂载卷或非目录文件，请选择普通目录。", "invalid_destination")
                }
            }
            let probe = path + "/.diskbridge-write-check-" + UUID().uuidString
            let fd = Darwin.open(probe, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw DBError("无法写入目标目录。") }
            defer { close(fd); unlink(probe) }
            var byte: UInt8 = 0
            guard Darwin.write(fd, &byte, 1) == 1, fsync(fd) == 0 else { throw DBError("目标目录写入检查失败。") }
        } catch let error as DBError where error.reason == "invalid_destination" { throw error }
        catch {
            throw DBError("无法写入目标目录 \(root)/\(folder)。请检查所选磁盘、目录权限及剩余空间；尚未切换原数据。", "destination_unwritable")
        }
    }
    func volume(_ uuid: String) throws -> Object {
        let info: Object
        do { info = try diskInfo(uuid) } catch let error as DBError where error.reason == "authorization" { throw error }
        catch { throw DBError("等待连接目标外置硬盘；不会用同名硬盘替代。", "disk_not_ready") }
        guard info.s("VolumeUUID").lowercased() == uuid.lowercased() else { throw DBError("目标硬盘 UUID 不匹配。") }
        try validateDestinationRole(info)
        let path = info.s("MountPoint")
        guard !path.isEmpty, mounted(path) else { throw DBError("目标外置硬盘尚未挂载。", "disk_not_ready") }
        guard !info.b("Internal", true), info.s("BusProtocol") != "Disk Image", info.b("WritableVolume", info.b("Writable")),
              try fileStat(path).st_dev != fileStat("/System/Volumes/Data").st_dev else { throw DBError("目标必须是可写的外置物理盘。") }
        let capacity = ((try? nativeFM.attributesOfFileSystem(forPath: path)[.systemSize]) as? NSNumber)?.int64Value ?? 0
        return ["uuid": uuid, "name": info.s("VolumeName", URL(fileURLWithPath: path).lastPathComponent), "path": path, "device": info.s("DeviceIdentifier"), "free": freeBytes(path), "capacity": capacity, "filesystem": info.s("FilesystemType", "APFS")]
    }
    func volumes(onVolume: ((Object) -> Void)? = nil) throws -> [Object] {
        var result: [Object] = []
        for name in try nativeFM.contentsOfDirectory(atPath: "/Volumes").sorted() {
            let path = "/Volumes/" + name
            guard !isLink(path), mounted(path), let info = try? diskInfo(path), !info.s("VolumeUUID").isEmpty,
                  let value = try? volume(info.s("VolumeUUID")) else { continue }
            result.append(value); onVolume?(value)
        }
        return result
    }
    func dataBytes(_ paths: [String], task: NativeTask) throws -> Int64 {
        var amount: Int64 = 0
        for path in paths {
            try task.check()
            let data: Data
            do { data = try run("/usr/bin/du", ["-skx", path], timeout: 120, task: task) }
            catch let error as DBError where error.reason == "authorization" {
                throw DBError("部分数据目录受系统或文件权限保护，暂时无法读取完整大小；可在权限或应用状态变化后重试。", "measurement_unavailable")
            }
            guard let word = String(decoding: data, as: UTF8.self).split(whereSeparator: { $0.isWhitespace }).first,
                  let kib = Int64(word), kib >= 0, kib <= (Int64.max - amount) / 1024 else { throw DBError("无法读取应用数据占用。") }
            amount += kib * 1024
        }
        return amount
    }
    func dataCandidates(_ app: Object) -> [Object] { candidatesFor(app, system: self) }
    func running(_ app: Object) -> Bool {
        let bundle = app.s("bundle_id")
        if !bundle.isEmpty && NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundle }) { return true }
        guard let output = try? run("/bin/ps", ["-axo", "comm="]) else { return false }
        return String(decoding: output, as: UTF8.self).split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix(app.s("app_path") + "/Contents/") }
    }
    func requireStopped(_ app: Object) throws { if running(app) { throw DBError("请用 ⌘Q 完全退出 \(app.s("name")) 及其他账号窗口。", "app_running") } }
    func imageAt(_ target: String) throws -> String? {
        let info = try plist("/usr/bin/hdiutil", ["info", "-plist"])
        return info.list("images").first { $0.list("system-entities").contains { $0.s("mount-point") == target } }?.s("image-path")
    }
    func attach(_ image: String, _ target: String, task: NativeTask, readOnly: Bool = false) throws {
        let args = modernImages
            ? ["image", "attach", "--plist", "--mountPoint", target, "--nobrowse"] + (readOnly ? ["--readOnly"] : []) + [image]
            : ["attach", image, "-mountpoint", target, "-nobrowse", "-noautoopen", "-plist"] + (readOnly ? ["-readonly"] : [])
        let data = try run(modernImages ? "/usr/sbin/diskutil" : "/usr/bin/hdiutil", args, task: task)
        let value = (try PropertyListSerialization.propertyList(from: data, format: nil) as? Object) ?? [:]
        guard value.list("system-entities").contains(where: { $0.s("mount-point") == target }) else { throw DBError("系统返回的挂载路径不符。") }
    }
    func detach(_ path: String) throws { _ = try run("/usr/bin/hdiutil", ["detach", path]) }
    func createImage(_ path: String, capacity: Int64, label: String, task: NativeTask) throws {
        guard !exists(path) else { throw DBError("目标镜像已经存在，未覆盖。") }
        try privateDirectory(URL(fileURLWithPath: path).deletingLastPathComponent())
        _ = try run("/usr/bin/hdiutil", ["create", "-size", "\(capacity)g", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-volname", label, "-nospotlight", path], timeout: 180, task: task)
    }
    func openApplication(_ path: String) throws { _ = try run("/usr/bin/open", ["-a", path], timeout: 15) }
    func checkAuthorization(_ store: NativeStore) throws {
        let home = nativeFM.homeDirectoryForCurrentUser.path
        var paths = [home + "/Library/Mail", home + "/Library/Safari", home + "/Library/Application Support/com.apple.TCC"]
        paths += store.apps.keys.filter { store.records.o($0).s("phase") != "rolled_back" }.map { store.apps.o($0).s("mount_point") }
        for path in Set(paths) where !path.isEmpty {
            do { _ = try nativeFM.contentsOfDirectory(atPath: path) }
            catch {
                let error = error as NSError
                if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { continue }
                throw DBError("盘桥原生后台无法访问受保护的数据目录，请为盘桥开启完全磁盘访问权限。", "authorization")
            }
        }
    }
}

func relativeFolder(_ value: String) throws -> String {
    let parts = value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !value.hasPrefix("/"), !value.trimmingCharacters(in: .whitespaces).isEmpty, !parts.isEmpty,
          !parts.contains(".."), !parts.contains("."), !value.contains("\0") else { throw DBError("请输入硬盘内的相对目录，例如 Cache/QQ。") }
    return parts.joined(separator: "/")
}
func sourcePath(_ value: String) throws -> String {
    let path = normalized(value), url = URL(fileURLWithPath: normalized(value))
    let home = nativeFM.homeDirectoryForCurrentUser.path
    guard value.hasPrefix("/"), url.resolvingSymlinksInPath().path == path,
          !["/", home, home + "/Library", home + "/Documents", "/Volumes"].contains(path), url.pathComponents.count >= 5 else {
        throw DBError("数据路径范围过大或包含软链接，请选择应用的具体数据目录。")
    }
    guard path.range(of: #"/Library/Containers/[^/]+/Data/SystemData(?:/|$)"#, options: .regularExpression) == nil else {
        throw DBError("SystemData 由 macOS 管理，不能作为应用数据迁移。请选择应用自己的具体数据目录。")
    }
    return path
}

func inventory(_ root: String, task: NativeTask) throws -> Object {
    try task.begin("统计数据目录")
    var entries: Object = [:]
    func walk(_ directory: String, _ prefix: String) throws {
        for name in try nativeFM.contentsOfDirectory(atPath: directory) {
            if prefix.isEmpty && ignoredVolumeItems.contains(name) { continue }
            try task.check()
            let relative = prefix.isEmpty ? name : prefix + "/" + name
            let path = directory + "/" + name, value = try fileStat(path), type = value.st_mode & UInt16(S_IFMT)
            if type == UInt16(S_IFLNK) { entries[relative] = ["type": "link", "target": try nativeFM.destinationOfSymbolicLink(atPath: path)] }
            else if type == UInt16(S_IFDIR) { entries[relative] = ["type": "dir", "mode": Int(value.st_mode & 0o7777)]; try walk(path, relative) }
            else if type == UInt16(S_IFREG) { entries[relative] = ["type": "file", "size": value.st_size, "mode": Int(value.st_mode & 0o7777)] }
            else { throw DBError("目录包含套接字、管道或设备文件，请确认应用及辅助进程已退出。") }
            try task.advance(files: 1)
        }
    }
    guard isDirectory(root), !isLink(root) else { throw DBError("数据目录不存在或类型异常。") }
    try walk(root, ""); return entries
}
func totals(_ manifest: Object) -> Object {
    let files = manifest.values.compactMap { $0 as? Object }.filter { $0.s("type") == "file" }
    return ["entries": manifest.count, "files": files.count, "bytes": files.reduce(Int64(0)) { $0 + $1.n("size") }]
}
func hashTree(_ root: String, task: NativeTask, label: String = "SHA-256 校验") throws -> Object {
    var manifest = try inventory(root, task: task)
    let counts = totals(manifest); try task.begin(label, total: counts.n("bytes"), files: counts.n("files"))
    for key in manifest.keys.sorted() {
        var entry = manifest.o(key)
        guard entry.s("type") == "file" else { continue }
        let path = root + "/" + key, before = try fileStat(path)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        var hash = SHA256()
        do {
            while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { try task.check(); hash.update(data: data); try task.advance(Int64(data.count)) }
            try handle.close()
        } catch { try? handle.close(); throw error }
        let after = try fileStat(path)
        guard before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw DBError("校验期间数据发生变化，请退出应用后重试。") }
        entry["sha256"] = hash.finalize().map { String(format: "%02x", $0) }.joined(); manifest[key] = entry
        try task.advance(files: 1)
    }
    return manifest
}
func requireEqual(_ a: Object, _ b: Object) throws {
    guard NSDictionary(dictionary: a).isEqual(to: b) else { throw DBError("完整性校验未通过；未切换工作数据，原件和副本保留。") }
}
