import Foundation
import AppKit
import Darwin
#if SWIFT_PACKAGE
@testable import DiskBridge
#endif

final class FixtureSystem: NativeSystem {
    let drive: String
    var isRunning = false, opens = 0
    var device = "fixture-device", boot = "fixture-boot"
    init(_ drive: String) { self.drive = drive }
    override func volume(_ uuid: String) throws -> Object {
        guard uuid == "FIXTURE" else { throw DBError("wrong UUID", "disk_not_ready") }
        return ["uuid": uuid, "path": drive, "free": Int64(10_000_000_000_000), "name": "Fixture"]
    }
    override func running(_ app: Object) -> Bool { isRunning }
    override func diskInfo(_ path: String) throws -> Object { ["DeviceIdentifier": device] }
    override func requireStopped(_ app: Object) throws { if isRunning { throw DBError("fixture running", "app_running") } }
    override func openApplication(_ path: String) throws { opens += 1 }
    override func command(_ executable: String, _ args: [String], timeout: Double = 120, task: NativeTask? = nil, stderrLine: ((String) -> Void)? = nil) throws -> CommandResult {
        if executable == "/usr/sbin/sysctl" { return CommandResult(data: Data(boot.utf8), error: "", code: 0) }
        if executable == "/usr/bin/codesign" { return CommandResult(data: try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.application-groups": ["group.org.native.fixture"]], format: .xml, options: 0), error: "", code: 0) }
        return try super.command(executable, args, timeout: timeout, task: task, stderrLine: stderrLine)
    }
}
final class InfoSystem: NativeSystem {
    var info: Object = [:]
    override func diskInfo(_ path: String) throws -> Object { info }
}
final class FaultSystem: NativeSystem {
    var failTarget = "", failed = false
    override func attach(_ image: String, _ target: String, task: NativeTask, readOnly: Bool = false) throws {
        if target == failTarget && !failed { failed = true; throw DBError("injected activation failure") }
        try super.attach(image, target, task: task, readOnly: readOnly)
    }
    override func command(_ executable: String, _ args: [String], timeout: Double = 120, task: NativeTask? = nil, stderrLine: ((String) -> Void)? = nil) throws -> CommandResult {
        let result = try super.command(executable, args, timeout: timeout, task: task, stderrLine: stderrLine)
        if executable == "/usr/bin/hdiutil" {
            print("fixture hdiutil \(args.first ?? "") exit=\(result.code)")
            if result.code != 0 { print(args); print(result.error) }
        }
        return result
    }
}

enum TestFailure: Error { case assertion(String) }
func expect(_ value: @autoclosure () throws -> Bool, _ message: String = "assertion failed") throws { if try !value() { throw TestFailure.assertion(message) } }
func expectFailure(_ body: () throws -> Void, reason: String? = nil) throws {
    do { try body() } catch { if let reason { try expect((error as? DBError)?.reason == reason, "unexpected failure reason") }; return }
    throw TestFailure.assertion("operation unexpectedly succeeded")
}

#if !SWIFT_PACKAGE
@main
#endif
struct NativeTests {
    static var count = 0
    static func test(_ name: String, _ body: () throws -> Void) throws {
        do { try body(); count += 1; print("✓ \(name)") }
        catch { fputs("FAILED: \(name): \(error)\n", stderr); throw error }
    }
    static func makeApp(_ at: URL, bundle: String = "org.native.fixture", name: String = "Fixture") throws -> Object {
        try privateDirectory(at.appendingPathComponent("Contents"))
        let info: Object = ["CFBundleIdentifier": bundle, "CFBundleName": name, "CFBundleShortVersionString": "1.0", "CFBundleExecutable": name]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: at.appendingPathComponent("Contents/Info.plist"))
        return applicationMetadata(at.path)!
    }
    static func main() {
        setbuf(stdout, nil)
        do { try run() } catch { fputs("Native test run failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        let args = CommandLine.arguments
        func argument(_ key: String) -> String? { guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }; return args[i + 1] }
        let work = URL(fileURLWithPath: argument("--workdir") ?? ProcessInfo.processInfo.environment["DISKBRIDGE_TEST_WORKDIR"] ?? NSTemporaryDirectory()).resolvingSymlinksInPath()
        try privateDirectory(work)
        let base = work.appendingPathComponent("DiskBridge-Tests-" + UUID().uuidString)
        try privateDirectory(base); defer { try? nativeFM.removeItem(at: base) }
        let root = base.appendingPathComponent("tool"), drive = base.appendingPathComponent("drive"), source = base.appendingPathComponent("data/source")
        try privateDirectory(root); try privateDirectory(drive); try privateDirectory(source)
        try Data("abc".utf8).write(to: source.appendingPathComponent("message.txt"))
        let metadata = try makeApp(base.appendingPathComponent("Fixture.app"))
        let profile: Object = ["name": "Fixture", "app_path": metadata.s("app_path"), "bundle_id": metadata.s("bundle_id"), "mount_point": source.path,
                               "volume_uuid": "FIXTURE", "folder": "Cache/Fixture", "capacity_gib": 1, "enabled": false]
        let system = FixtureSystem(drive.path)
        let store = try NativeStore(root); try store.save()
        let engine = NativeEngine(store, system: system)
        try test("atomic JSON remains private") { try writeObject(["value": 3], to: base.appendingPathComponent("atomic.json")); try expect(fileStat(base.appendingPathComponent("atomic.json").path).st_mode & 0o777 == 0o600) }
        try test("concurrent atomic writers have independent temporary files") {
            let lock = NSLock(); var errors = 0
            DispatchQueue.concurrentPerform(iterations: 24) { i in do { try writeObject(["value": i], to: base.appendingPathComponent("shared.json")) } catch { lock.locked { errors += 1 } } }
            try expect(errors == 0); try expect((0..<24).contains(Int(try readObject(base.appendingPathComponent("shared.json")).n("value"))))
        }
        try test("invalid config is not replaced") {
            let broken = base.appendingPathComponent("broken"); try privateDirectory(broken); try Data("broken".utf8).write(to: broken.appendingPathComponent("config.json"))
            try expectFailure { _ = try NativeStore(broken) }; try expect(try Data(contentsOf: broken.appendingPathComponent("config.json")) == Data("broken".utf8))
        }
        try test("version one legacy record loads without rewriting") {
            let before = try Data(contentsOf: root.appendingPathComponent("config.json")); _ = try NativeStore(root)
            try expect(before == Data(contentsOf: root.appendingPathComponent("config.json")))
        }
        for path in ["../x", "/Volumes/ExampleDrive", "", ".", "Cache/../../x"] { try test("relative directory rejects \(path)") { try expectFailure { _ = try relativeFolder(path) } } }
        try test("relative directory preserves unicode and spaces") { try expect(relativeFolder("Cache/应用 数据") == "Cache/应用 数据") }
        for path in ["/", nativeFM.homeDirectoryForCurrentUser.path, nativeFM.homeDirectoryForCurrentUser.path + "/Library"] { try test("broad source rejected") { try expectFailure { _ = try sourcePath(path) } } }
        try test("source symlink rejected") {
            let link = base.appendingPathComponent("linked"); try nativeFM.createSymbolicLink(at: link, withDestinationURL: source)
            try expectFailure { _ = try sourcePath(link.path) }
        }
        try test("operation lock names its owner") {
            let lock = try store.lock("fixture migration")
            try expectFailure({ _ = try NativeStore(root).lock("second") }, reason: "busy"); withExtendedLifetime(lock) {}
        }
        try test("scheduler lock does not hold operation lock") {
            let scheduler = try NativeLock(base.appendingPathComponent("runtime/agent.lock"), label: "scheduler")
            let operation = try store.lock("manual"); withExtendedLifetime((scheduler, operation)) {}
        }
        try test("SHA-256 matches the standard abc digest") {
            let manifest = try hashTree(source.path, task: NativeTask("test"))
            try expect(manifest.o("message.txt").s("sha256") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        }
        try test("same-size content changes fail verification") {
            let first = try hashTree(source.path, task: NativeTask("test")); try Data("xyz".utf8).write(to: source.appendingPathComponent("message.txt"))
            let second = try hashTree(source.path, task: NativeTask("test")); try expectFailure { try requireEqual(first, second) }
        }
        try test("unicode and dangling symlinks survive inventory") {
            try Data("text".utf8).write(to: source.appendingPathComponent("中文 空格.txt")); try nativeFM.createSymbolicLink(atPath: source.appendingPathComponent("dangling").path, withDestinationPath: "missing")
            let manifest = try inventory(source.path, task: NativeTask("test")); try expect(manifest.o("dangling").s("target") == "missing"); try expect(manifest.o("中文 空格.txt").n("size") == 4)
        }
        try test("task cancellation stops at a checkpoint") { let task = NativeTask("test"); task.cancel(); try expectFailure({ try task.begin("copy") }, reason: "stopped") }
        try test("task progress contains real byte counts") { let task = NativeTask("test"); try task.begin("copy", total: 100); try task.advance(25); try expect(task.snapshot().n("done") == 25 && task.snapshot().n("total") == 100) }
        try test("copy preserves file modes links and contents") {
            let destination = base.appendingPathComponent("copy")
            try NativeSystem().copy(source.path, destination.path, task: NativeTask("copy"), label: "copy")
            try requireEqual(hashTree(source.path, task: NativeTask("hash")), hashTree(destination.path, task: NativeTask("hash")))
        }
        try test("arbitrary application identity is discovered without recipes") { try expect(metadata.s("id") == applicationKey("org.native.fixture")); try expect(metadata.s("bundle_id") == "org.native.fixture") }
        try test("generic container children are found without name matching") {
            let home = base.appendingPathComponent("home")
            let support = home.appendingPathComponent("Library/Containers/org.native.fixture/Data/Library/Application Support/CompletelyDifferentData")
            let documents = home.appendingPathComponent("Library/Containers/org.native.fixture/Data/Documents/AccountArchive")
            let shared = home.appendingPathComponent("Library/Group Containers/group.org.native.fixture/SharedFiles")
            try privateDirectory(support); try privateDirectory(documents); try privateDirectory(shared)
            let candidates = candidatesFor(metadata, system: system, homeRoot: home.path)
            try expect(candidates.contains { $0.s("path") == support.path }); try expect(candidates.contains { $0.s("path") == documents.path })
            try expect(candidates.contains { $0.s("path") == shared.path && $0.b("shared") })
        }
        try test("configure keeps auto open disabled by default") { try engine.configure("fixture", profile: profile); try expect(!store.apps.o("fixture").b("auto_open")) }
        try test("overlapping application directories rejected") {
            var overlapping = profile; overlapping["mount_point"] = source.appendingPathComponent("nested").path; overlapping["folder"] = "Cache/Other"
            try expectFailure { try engine.configure("other", profile: overlapping) }
        }
        try test("duplicate image directory rejected") { var other = profile; other["mount_point"] = base.appendingPathComponent("other-source").path; try expectFailure { try engine.configure("other", profile: other) } }
        try test("unrelated local data cannot be covered") {
            var records = store.records; records["fixture"] = ["id": String(repeating: "a", count: 32), "phase": "active", "source": source.path, "guard_inode": 0]; store.records = records; try store.save()
            try expectFailure { _ = try engine.mount("fixture") }; try expect(exists(source.appendingPathComponent("message.txt").path))
        }
        try test("immutable empty guard blocks accidental writes") {
            let guardPath = base.appendingPathComponent("guard").path
            let inode = try engine.makeGuard(guardPath); try expect(engine.guardMatches(guardPath, inode: inode))
            try expectFailure { try Data("no".utf8).write(to: URL(fileURLWithPath: guardPath + "/unexpected")) }
            try engine.removeGuard(guardPath, inode: inode); try expect(!exists(guardPath))
        }
        try test("wrong guard inode is never removed") {
            let guardPath = base.appendingPathComponent("guard2").path; let inode = try engine.makeGuard(guardPath)
            try expectFailure { try engine.removeGuard(guardPath, inode: inode + 1) }; try engine.removeGuard(guardPath, inode: inode)
        }
        let service = try NativeService(root: root, runtime: base.appendingPathComponent("runtime"), system: system)
        service.cachedApplications = [metadata]; service.catalogDate = Date(); service.catalogRoots = applicationRootStamps()
        try test("restore requires explicit confirmation") { try expectFailure { _ = try service.execute("rollback", values: ["app_id": "fixture"], task: NativeTask("rollback")) } }
        try test("original cleanup requires exact phrase") { try expectFailure { _ = try service.execute("delete_original", values: ["app_id": "fixture", "phrase": "wrong"], task: NativeTask("delete")) } }
        try test("unknown commands cannot execute code") { try expectFailure { _ = try service.execute("shell", values: ["command": "echo anything"], task: NativeTask("test")) } }
        try test("expired preview cannot create a migration") { try expectFailure { _ = try service.execute("migrate", values: ["plan_id": "missing"], task: NativeTask("test")) } }
        try test("parent and nested selected sources are rejected") { let nested = source.appendingPathComponent("nested"); try privateDirectory(nested); try expectFailure { _ = try service.validateSources([source.path, nested.path], app: metadata, sharedConfirmed: false) } }
        try test("manual and automatic settings remain independent") {
            _ = try service.execute("app_settings", values: ["app_id": "fixture", "auto_mount": false, "auto_open": false], task: NativeTask("settings"))
            try expect(!NativeStore(root).apps.o("fixture").b("enabled"))
        }
        try test("mounted location is separate from migrated status") {
            let summary = try service.overview(NativeTask("overview"), includeCatalog: false)
            try expect(summary.list("apps").first?.s("migration_state") == "migrated"); try expect(summary.list("apps").first?.b("mounted") == false)
        }
        try test("launch before migration complete is refused") {
            let current = try NativeStore(root); var record = current.records.o("fixture"); record["phase"] = "copying"; try current.updateRecord("fixture", record)
            let result = try service.execute("prepare_launch", values: ["app_id": "fixture"], task: NativeTask("launch")) as? Object
            try expect(result?.o("fixture").b("ok") == false); try expect(system.opens == 0)
        }
        try test("external copy cleanup cannot delete active data") { try expectFailure { _ = try service.deleteRetained(["copy_id": "fixture", "phrase": deletionConfirmation], task: NativeTask("delete")) } }
        let infoSystem = InfoSystem(); infoSystem.info = ["VolumeUUID": "EXPECTED", "MountPoint": "/", "Internal": false, "WritableVolume": true]
        try test("startup filesystem is not an external destination") { try expectFailure { _ = try infoSystem.volume("EXPECTED") } }
        try test("same-named disk with wrong UUID is refused") { try expectFailure { _ = try infoSystem.volume("OTHER") } }
        try test("command arguments are not interpreted by a shell") {
            let text = "$(not-an-executable)"; let data = try NativeSystem().run("/bin/echo", [text]); try expect(String(decoding: data, as: UTF8.self).contains(text))
        }
        let model = BridgeModel(root: root, runtime: base.appendingPathComponent("model"))
        try test("clicking migrated app only opens restore preview") { model.beginFlow(BridgeApp(value: ["id": "fixture", "name": "Fixture", "migration_state": "migrated"])); try expect(model.flow?.kind == "restore"); try expect(model.callbacks.isEmpty) }
        try test("interrupted app requires a recovery confirmation") { model.beginFlow(BridgeApp(value: ["id": "fixture", "name": "Fixture", "migration_state": "incomplete"])); try expect(model.flow?.kind == "recover"); try expect(model.callbacks.isEmpty) }
        try test("unmigrated filter excludes interrupted and pending migrations") {
            model.apps = ["unmigrated", "incomplete", "pending", "migrated"].map { BridgeApp(value: ["id": $0, "name": $0, "migration_state": $0]) }
            model.filter = "unmigrated"; try expect(model.visibleApps.map(\.id) == ["unmigrated"])
        }
        let autoStore = try NativeStore(root)
        var autoApps = autoStore.apps, autoRecords = autoStore.records
        autoRecords["fixture"] = ["phase": "active"]; autoStore.records = autoRecords; try autoStore.save()
        try test("automatic opening is off for an accepted app by default") {
            try service.automaticOpen("fixture", keys: ["fixture"], store: autoStore); try expect(system.opens == 0)
        }
        var autoApp = autoApps.o("fixture"); autoApp["auto_open"] = true; autoApps["fixture"] = autoApp; autoStore.apps = autoApps; try autoStore.save()
        try test("automatic opening runs once per mount cycle") {
            try service.automaticOpen("fixture", keys: ["fixture"], store: autoStore)
            try service.automaticOpen("fixture", keys: ["fixture"], store: autoStore); try expect(system.opens == 1)
        }
        try test("an already running app is not reopened after user quits") {
            system.device = "fixture-second-device"; system.isRunning = true
            try service.automaticOpen("fixture", keys: ["fixture"], store: autoStore)
            system.isRunning = false
            try service.automaticOpen("fixture", keys: ["fixture"], store: autoStore); try expect(system.opens == 1)
        }
        try test("a new mount cycle permits one automatic opening") {
            system.device = "fixture-third-device"; try service.automaticOpen("fixture", keys: ["fixture"], store: autoStore); try expect(system.opens == 2)
        }
        try test("a reboot permits opening even if a device number is reused") {
            system.boot = "fixture-second-boot"
            let next = try NativeService(root: root, runtime: service.runtime, system: system)
            try next.automaticOpen("fixture", keys: ["fixture"], store: autoStore); try expect(system.opens == 3)
        }
        let archiveID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let original = source.path + ".AppDataMount-original-" + String(archiveID.prefix(12))
        try system.copy(source.path, original, task: NativeTask("fixture"), label: "fixture")
        let archiveRecord: Object = ["id": archiveID, "phase": "rolled_back", "source": source.path, "original": original]
        let archiveStore = try NativeStore(root)
        archiveStore.state["archives"] = [archiveID: ["app": profile, "record": archiveRecord]]; try archiveStore.save()
        try writeObject(hashTree(original, task: NativeTask("fixture")), to: engine.manifest(archiveRecord, "original-manifest.json"))
        try test("previous migration original backups remain discoverable") { try expect(service.archivedBackups(NativeStore(root)).count == 1) }
        try test("archived original cleanup requires a fresh confirmation") {
            try expectFailure { _ = try service.execute("delete_archived_original", values: ["app_id": archiveID, "phrase": "wrong"], task: NativeTask("fixture")) }; try expect(exists(original))
        }
        try test("verified archived cleanup preserves current working data") {
            _ = try service.execute("delete_archived_original", values: ["app_id": archiveID, "phrase": deletionConfirmation], task: NativeTask("fixture"))
            try expect(!exists(original) && exists(source.appendingPathComponent("message.txt").path)); try expect(service.archivedBackups(NativeStore(root)).isEmpty)
        }
        try test("missing authorization proactively requests guidance once per launch") {
            var requests = 0; model.onAuthorizationRequired = { requests += 1 }
            model.authorization(true); model.authorization(true)
            try expect(requests == 1 && model.needsAuthorization && model.authorizationChecked)
            model.authorization(false); try expect(!model.needsAuthorization)
        }
        try test("offline configured disks remain listed in storage management") {
            model.apps = [BridgeApp(value: ["id": "fixture", "migration_state": "migrated", "paths": [["volume_uuid": "OFFLINE", "folder": "Cache/Fixture"]]])]
            model.disks = []; try expect(model.knownDisks.contains { $0.s("uuid") == "OFFLINE" })
        }
        try test("partial manual mounting is persisted as failure") {
            let id = service.submit("mount", values: ["app_id": "fixture"])
            let deadline = Date().addingTimeInterval(10)
            while service.stateLock.locked({ service.active[id] != nil }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            let row = try readObject(service.runtime.appendingPathComponent("tasks/\(id).json"))
            try expect(row.s("phase") == "failed"); try expect(!row.o("results").o("fixture").b("ok"))
        }
        if let uuid = argument("--volume-uuid") ?? ProcessInfo.processInfo.environment["DISKBRIDGE_TEST_VOLUME_UUID"] { try integration(uuid: uuid, work: work) }
        try writeObject(["passed": true, "tests": count, "native": true, "python_executed": false], to: work.appendingPathComponent("native-tests-result.json"))
        print("\(count) native checks passed.")
    }

    static func integration(uuid: String, work: URL) throws {
        let system = FaultSystem(), disk = try system.volume(uuid)
        let fixture = work.appendingPathComponent("DiskBridge-Integration-" + UUID().uuidString)
        let root = fixture.appendingPathComponent("tool"), runtime = fixture.appendingPathComponent("runtime")
        let tag = ".DiskBridge-Tests-" + UUID().uuidString
        let external = URL(fileURLWithPath: disk.s("path")).appendingPathComponent("Cache/" + tag)
        try privateDirectory(fixture); try privateDirectory(root)
        let sourceA = fixture.appendingPathComponent("data/alpha"), sourceB = fixture.appendingPathComponent("data/beta")
        try privateDirectory(sourceA); try privateDirectory(sourceB)
        try Data(repeating: 42, count: 512 * 1024).write(to: sourceA.appendingPathComponent("database.bin"))
        try Data("原始消息".utf8).write(to: sourceB.appendingPathComponent("中文 空格.txt"))
        try nativeFM.createSymbolicLink(atPath: sourceB.appendingPathComponent("relative-link").path, withDestinationPath: "中文 空格.txt")
        let app = try makeApp(fixture.appendingPathComponent("UnseenApp.app"), bundle: "org.diskbridge.integration." + UUID().uuidString, name: "Native Fixture")
        let store = try NativeStore(root); try store.save()
        let service = try NativeService(root: root, runtime: runtime, system: system)
        service.cachedApplications = [app]; service.catalogDate = Date()
        func call(_ action: String, _ values: Object = [:]) throws -> Object {
            let task = NativeTask(action, values: values, runtime: runtime); task.activate()
            do {
                let lock = ["migrate", "recover", "rollback", "confirm", "unmount", "delete_original", "delete_retained"].contains(action) ? try NativeStore(root).lock("integration " + action) : nil
                defer { withExtendedLifetime(lock) {} }
                let result = try service.execute(action, values: values, task: task)
                task.finish(result); return result as? Object ?? [:]
            } catch { task.fail(error); throw error }
        }
        func idle() throws {
            let deadline = Date().addingTimeInterval(25)
            while service.stateLock.locked({ !service.active.isEmpty }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            try expect(service.stateLock.locked { service.active.isEmpty }, "automatic task did not finish")
        }
        defer {
            let deadline = Date().addingTimeInterval(10)
            while service.stateLock.locked({ !service.active.isEmpty }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            var safe = true
            if let store = try? NativeStore(root) {
                for record in store.records.values.compactMap({ $0 as? Object }) {
                    let copy = root.appendingPathComponent("records/\(record.s("id"))/copy-volume").path
                    for path in [record.s("source"), copy] where path.hasPrefix(fixture.path + "/") {
                        if mounted(path) { do { try system.detach(path) } catch { safe = false } }
                        if !mounted(path), let value = try? fileStat(path), value.st_flags & UInt32(UF_IMMUTABLE) != 0 { _ = chflags(path, value.st_flags & ~UInt32(UF_IMMUTABLE)) }
                    }
                }
            }
            if CommandLine.arguments.contains("--keep-fixtures") {
                print("retained test fixture: \(fixture.path)")
                print("retained external fixture: \(external.path)")
            } else if safe { try? nativeFM.removeItem(at: fixture); if external.lastPathComponent == tag && external.deletingLastPathComponent().path == disk.s("path") + "/Cache" { try? nativeFM.removeItem(at: external) } }
            try? writeObject(["fixture_cleanup_complete": safe && !exists(fixture.path) && !exists(external.path)], to: work.appendingPathComponent("native-integration-cleanup.json"))
        }
        let values: Object = ["app_id": app.s("id"), "sources": [sourceA.path, sourceB.path], "volume_uuid": uuid, "folder": "Cache/" + tag]
        let plan = try call("plan", values)
        try test("native multi-directory preview records exact scope") { try expect(plan.list("profiles").count == 2); try expect(plan.n("files") == 2) }
        system.failTarget = sourceB.path
        try test("activation failure preserves original and both verified copies") {
            try expectFailure { _ = try call("migrate", ["plan_id": plan.s("plan_id")]) }
            try expect(isDirectory(sourceB.path) && !mounted(sourceB.path)); try expect(exists(sourceB.appendingPathComponent("中文 空格.txt").path))
        }
        _ = try call("recover", ["app_id": app.s("id")])
        try test("native recovery mounts every selected directory") { try expect(mounted(sourceA.path) && mounted(sourceB.path)) }
        try test("multi-directory acceptance is required before automation") {
            let store = try NativeStore(root)
            try expect(groupKeys(store, app.s("id")).allSatisfy { !store.apps.o($0).b("enabled") && store.records.o($0).s("phase") == "active_unconfirmed" })
        }
        _ = try call("confirm", ["app_id": app.s("id")]); try idle()
        _ = try call("unmount", ["app_id": app.s("id"), "confirmed": true])
        try test("cold unmounted guards reject empty database creation") { try expectFailure { try Data("no".utf8).write(to: sourceA.appendingPathComponent("should-fail")) } }
        let mountedResult = try call("mount", ["app_id": app.s("id")])
        try test("native manual mount restores all guarded paths") { try expect(mountedResult.o(app.s("id")).b("ok")); try expect(mounted(sourceA.path) && mounted(sourceB.path)) }
        try Data("挂载后新增消息".utf8).write(to: sourceB.appendingPathComponent("new-message.txt"))
        _ = try call("rollback", ["app_id": app.s("id"), "confirmed": true])
        try test("native restore preserves newly written data") { try expect(!mounted(sourceA.path) && !mounted(sourceB.path)); try expect(String(data: Data(contentsOf: sourceB.appendingPathComponent("new-message.txt")), encoding: .utf8) == "挂载后新增消息") }
        _ = try call("delete_original", ["app_id": app.s("id"), "phrase": deletionConfirmation])
        try test("independent original cleanup leaves working data") { try expect(exists(sourceA.appendingPathComponent("database.bin").path)); try expect(exists(sourceB.appendingPathComponent("new-message.txt").path)) }
        let second = try call("plan", values)
        try test("restored applications can migrate again without overwriting retained images") { try expect(second.b("retained_copy_preserved")); try expect(second.s("destination") != plan.s("destination")) }
        _ = try call("migrate", ["plan_id": second.s("plan_id")]); _ = try call("confirm", ["app_id": app.s("id")]); try idle()
        _ = try call("rollback", ["app_id": app.s("id"), "confirmed": true])
        let copies = try service.retainedCopies(NativeStore(root))
        try test("old rounds remain visible as retained copies") { try expect(copies.count == 4 && copies.contains { $0.b("archived") }) }
        for copy in copies { _ = try call("delete_retained", ["copy_id": copy.s("id"), "archived": copy.b("archived"), "phrase": deletionConfirmation]) }
        try test("read-only identity checks protect retained image cleanup") { try expect(service.retainedCopies(NativeStore(root)).isEmpty); try expect(exists(sourceB.appendingPathComponent("new-message.txt").path)) }
    }
}
