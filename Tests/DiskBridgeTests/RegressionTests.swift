import XCTest
@testable import DiskBridge

private final class RoleFixtureSystem: NativeSystem {
    var listing: Object = [:]
    override func plist(_ executable: String, _ args: [String]) throws -> Object { listing }
}

private class MountedFixtureSystem: NativeSystem {
    let drive: String, source: String
    var attached = true, wrongImage = false, opens = 0
    init(drive: String, source: String) { self.drive = drive; self.source = source }
    override func volume(_ uuid: String) throws -> Object { ["uuid": uuid, "path": drive, "name": "Fixture"] }
    override func isMountPoint(_ path: String) -> Bool { attached && path == source }
    override func imageAt(_ target: String) throws -> String? { drive + (wrongImage ? "/Other" : "/Cache/Fixture/Data.sparsebundle") }
    override func diskInfo(_ path: String) throws -> Object { ["DeviceIdentifier": "fixture-device"] }
    override func openApplication(_ path: String) throws { opens += 1 }
    override func running(_ app: Object) -> Bool { false }
}

private final class MeasurementFixtureSystem: MountedFixtureSystem {
    let secondStarted = DispatchSemaphore(value: 0), releaseSecond = DispatchSemaphore(value: 0)
    var calls = 0, ranOnMain = false
    override func checkAuthorization(_ store: NativeStore) throws {}
    override func dataCandidates(_ app: Object) -> [Object] { [] }
    override func dataBytes(_ paths: [String], task: NativeTask) throws -> Int64 {
        calls += 1; ranOnMain = ranOnMain || Thread.isMainThread
        if calls == 2 { secondStarted.signal(); _ = releaseSecond.wait(timeout: .now() + 5) }
        try task.check(); return Int64(calls * 1024)
    }
}

private final class StreamingDiskSystem: NativeSystem {
    override func volumes(onVolume: ((Object) -> Void)? = nil) throws -> [Object] {
        let values: [Object] = [["uuid": "one", "name": "First"], ["uuid": "two", "name": "Second"]]
        values.forEach { onVolume?($0) }; return values
    }
}

private final class CatalogFixtureSystem: NativeSystem {
    var discoveries = 0
    override func command(_ executable: String, _ args: [String], timeout: Double = 120, task: NativeTask? = nil, stderrLine: ((String) -> Void)? = nil) throws -> CommandResult {
        if executable == "/usr/bin/mdfind" { discoveries += 1; return CommandResult(data: Data(), error: "", code: 0) }
        if executable == "/usr/sbin/sysctl" { return CommandResult(data: Data("fixture-boot".utf8), error: "", code: 0) }
        return try super.command(executable, args, timeout: timeout, task: task, stderrLine: stderrLine)
    }
}
private final class DeniedMeasurementSystem: NativeSystem {
    override func command(_ executable: String, _ args: [String], timeout: Double = 120, task: NativeTask? = nil, stderrLine: ((String) -> Void)? = nil) throws -> CommandResult {
        CommandResult(data: Data(), error: "Permission denied", code: 1)
    }
}

final class RegressionTests: XCTestCase {
    func testNativeRegressionSuite() throws { try NativeTests.run() }

    func testCatalogCacheSurvivesServiceRestartAndOnlyReparsesChangedMetadata() throws {
        let base = nativeFM.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? nativeFM.removeItem(at: base) }
        let app = try NativeTests.makeApp(base.appendingPathComponent("Fixture.app")), runtime = base.appendingPathComponent("runtime")
        let system = CatalogFixtureSystem(), service = try NativeService(root: base, runtime: runtime, system: system)
        try service.saveCatalog([app], roots: applicationRootStamps())
        let next = try NativeService(root: base, runtime: runtime, system: system)
        XCTAssertEqual(next.cachedApplications.count, 1)
        XCTAssertEqual(try next.applicationList(NativeTask("catalog")).first?.s("version"), "1.0")
        XCTAssertEqual(system.discoveries, 0)
        let plist = base.appendingPathComponent("Fixture.app/Contents/Info.plist")
        var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! Object
        info["CFBundleShortVersionString"] = "2.0"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist, options: .atomic)
        XCTAssertEqual(try next.applicationList(NativeTask("catalog")).first?.s("version"), "2.0")
        XCTAssertEqual(system.discoveries, 0)
        XCTAssertEqual(try NativeService(root: base, runtime: runtime, system: system).cachedApplications.first?.s("version"), "2.0")
    }

    func testCatalogDiscoveryReusesUnchangedAppsAndRemovesDeletedEntries() throws {
        let base = nativeFM.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? nativeFM.removeItem(at: base) }
        var first = try NativeTests.makeApp(base.appendingPathComponent("First.app"), bundle: "org.fixture.first")
        first["reuse_marker"] = true
        _ = try NativeTests.makeApp(base.appendingPathComponent("Second.app"), bundle: "org.fixture.second")
        let system = CatalogFixtureSystem()
        let found = try discoverApplications(system: system, task: NativeTask("catalog"), cached: [first], searchRoots: [base.path])
        XCTAssertEqual(found.count, 2); XCTAssertTrue(found.first { $0.s("bundle_id") == "org.fixture.first" }?.b("reuse_marker") == true)
        try nativeFM.removeItem(at: base.appendingPathComponent("First.app"))
        let updated = try discoverApplications(system: system, task: NativeTask("catalog"), cached: found, searchRoots: [base.path])
        XCTAssertEqual(updated.map { $0.s("bundle_id") }, ["org.fixture.second"])
    }

    func testAppSnapshotRestoresTheListImmediatelyWithoutClaimingAMountIsReady() throws {
        let base = nativeFM.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? nativeFM.removeItem(at: base) }
        let row: Object = ["id":"fixture", "name":"Fixture", "managed":true, "migration_state":"migrated", "mounted":true, "bytes":4096, "installed_at":100]
        try writeObject(["version":1, "apps":[row]], to:base.appendingPathComponent("app-list.json"))
        let model = BridgeModel(root:base,runtime:base)
        XCTAssertEqual(model.apps.count,1); XCTAssertEqual(model.apps[0].value.n("bytes"),4096)
        XCTAssertEqual(model.apps[0].value.n("installed_at"),100)
        XCTAssertFalse(model.apps[0].mounted); XCTAssertTrue(model.apps[0].value.b("status_cached"))
        XCTAssertTrue(model.callbacks.isEmpty)
        model.mergeOverviewApps([row])
        XCTAssertTrue(model.apps[0].mounted); XCTAssertFalse(model.apps[0].value.b("status_cached"))
    }

    func testGenericDiscoveryFindsVendorVersionAndContainerDataWithoutRecipes() throws {
        let base = nativeFM.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? nativeFM.removeItem(at: base) }
        let provider = base.appendingPathComponent("Library/Application Support/Vendor/Editor2026.1")
        let other = base.appendingPathComponent("Library/Application Support/Vendor/OtherProduct")
        let hidden = base.appendingPathComponent("Library/Containers/org.vendor.editor/Data/.vendor-data")
        let systemData = base.appendingPathComponent("Library/Containers/org.vendor.editor/Data/SystemData")
        try privateDirectory(provider); try privateDirectory(other); try privateDirectory(hidden); try privateDirectory(systemData)
        let app: Object = ["name":"Editor", "file_name":"Editor", "bundle_id":"org.vendor.editor", "app_path":base.appendingPathComponent("Editor.app").path]
        let candidates = candidatesFor(app, system: FixtureSystem(base.path), homeRoot: base.path).map { $0.s("path") }
        XCTAssertTrue(candidates.contains(provider.path)); XCTAssertTrue(candidates.contains(hidden.path))
        XCTAssertFalse(candidates.contains(other.path)); XCTAssertFalse(candidates.contains(provider.deletingLastPathComponent().path))
        XCTAssertFalse(candidates.contains(systemData.path))
        XCTAssertThrowsError(try sourcePath(systemData.resolvingSymlinksInPath().path))
        XCTAssertThrowsError(try sourcePath(systemData.resolvingSymlinksInPath().appendingPathComponent("Nested").path))
    }

    func testUndiscoveredDataIsUnknownRatherThanZero() throws {
        let (base, store, _, _) = try mountedFixture()
        defer { try? nativeFM.removeItem(at: base) }
        let system = MeasurementFixtureSystem(drive: base.path, source: base.path)
        let service = try NativeService(root: store.root, runtime: base.appendingPathComponent("measurements"), system: system)
        let app: Object = ["id":"missing", "name":"Missing", "migration_state":"unmigrated", "data_location":"internal"]
        let result = try service.measureApplication("missing", app: app, task: NativeTask("estimate"))
        XCTAssertEqual(result.s("status"), "not_found"); XCTAssertNil(result["bytes"]); XCTAssertEqual(system.calls, 0)
        XCTAssertNil(service.scheduleMeasurements([app]))
        try service.saveMeasurement("missing", row: ["status":"unknown", "location":"internal", "measured_ns":stamp()])
        XCTAssertNil(service.scheduleMeasurements([app]))
    }

    func testOneProtectedDirectoryDoesNotMisdiagnoseTheEntireAppAuthorization() {
        XCTAssertThrowsError(try DeniedMeasurementSystem().dataBytes(["/fixture"], task: NativeTask("estimate"))) { error in
            XCTAssertEqual((error as? DBError)?.reason, "measurement_unavailable")
            XCTAssertFalse(error.localizedDescription.contains("开启完全磁盘"))
        }
    }

    func testFuzzySearchUsesNamesInsteadOfCommonApplicationDirectory() throws {
        let app = BridgeApp(value: ["id": "fixture", "name": "DingTalk", "aliases": ["钉钉", "DingTalk"], "app_path": "/Applications/DingTalk.app", "bundle_id": "org.fixture.chat"])
        for query in [" T ", "DT", "dgtlk", "Ding Talk", "钉", "dingding", "dd", "org.fixture", "/Applications/DingTalk"] {
            XCTAssertTrue(app.matches(query), query)
        }
        XCTAssertFalse(app.matches("xyz"))
        let other = BridgeApp(value: ["id": "preview", "name": "Preview", "app_path": "/Applications/Preview.app"])
        XCTAssertFalse(other.matches("T")); XCTAssertTrue(other.matches("/Applications/Preview"))
    }

    func testNameSizeAndInstallationSortingHaveStableDefaults() throws {
        let apps = [
            BridgeApp(value: ["id": "b", "name": "App 10", "bytes": 30, "installed_at": 100]),
            BridgeApp(value: ["id": "a", "name": "App 2", "bytes": 10, "installed_at": 200]),
            BridgeApp(value: ["id": "c", "name": "Alpha", "bytes": NSNull(), "installed_at": NSNull()])
        ]
        XCTAssertEqual(apps.sorted(using: ApplicationSort("name")).map(\.id), ["c", "a", "b"])
        XCTAssertEqual(apps.sorted(using: ApplicationSort("size")).map(\.id), ["b", "a", "c"])
        XCTAssertEqual(apps.sorted(using: ApplicationSort("installed")).map(\.id), ["a", "b", "c"])
        let base = nativeFM.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? nativeFM.removeItem(at: base) }
        let metadata = try NativeTests.makeApp(base.appendingPathComponent("Fixture.app"))
        XCTAssertNotNil(metadata["installed_at"] as? NSNumber)
        let model = BridgeModel(root: base, runtime: base.appendingPathComponent("runtime"))
        XCTAssertEqual(model.sortField, "name")
        model.tableSort = [ApplicationSort("installed")]; XCTAssertEqual(model.sortField, "installed")
        XCTAssertEqual(model.tableSort.first?.order, .reverse)
    }

    func testRestoredAppsDoNotRemainAssociatedAndUnusedHistoryIsHidden() throws {
        let base = nativeFM.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = BridgeModel(root: base, runtime: base)
        model.diskHistory = ["old": ["uuid": "old", "name": "Recovery"], "drive": ["uuid": "drive", "name": "External"]]
        let restored = BridgeApp(value: ["id": "restored", "migration_state": "unmigrated", "phase": "rolled_back", "paths": [["volume_uuid": "drive", "phase": "rolled_back", "folder": "Cache/Fixture"]]])
        let migrated = BridgeApp(value: ["id": "active", "migration_state": "migrated", "paths": [["volume_uuid": "drive", "phase": "active", "folder": "Cache/Other"]]])
        model.apps = [restored, migrated]
        XCTAssertEqual(model.relatedApps("DRIVE").map(\.id), ["active"])
        XCTAssertEqual(model.knownDisks.map { $0.s("uuid") }, ["drive"])
        XCTAssertEqual(model.appDestination(restored), "本机")
        model.apps = [restored]; XCTAssertTrue(model.knownDisks.isEmpty)
        model.applyDisks([["uuid": "drive", "name": "External"]])
        XCTAssertEqual(model.knownDisks.count, 1); XCTAssertTrue(model.relatedApps("drive").isEmpty)
    }

    func testDiskResultsArePublishedBeforeTheWholeRequestFinishes() throws {
        let base = nativeFM.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? nativeFM.removeItem(at: base) }
        let service = try NativeService(root: base, runtime: base.appendingPathComponent("runtime"), system: StreamingDiskSystem())
        let task = NativeTask("disks", runtime: service.runtime)
        var snapshots: [[String]] = []
        task.onChange = { row in if let partial = row["result"] as? [Object] { snapshots.append(partial.map { $0.s("uuid") }) } }
        let result = try service.execute("disks", values: [:], task: task) as! [Object]
        XCTAssertEqual(snapshots, [["one"], ["one", "two"]]); XCTAssertEqual(result.count, 2)
    }

    func testRepeatedStatusUpdatesDoNotDuplicateRowsOrLoseInstallationMetadata() {
        let base = nativeFM.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = BridgeModel(root: base, runtime: base)
        model.apps = [BridgeApp(value: ["id": "one", "name": "One", "installed_at": 100, "managed": false])]
        for _ in 0..<3 { model.mergeOverviewApps([["id": "one", "name": "One", "managed": false]]) }
        XCTAssertEqual(model.apps.count, 1); XCTAssertEqual(model.apps[0].value.n("installed_at"), 100)
    }

    func testSizeScanRunsInBackgroundAndPublishesEachAppIndependently() throws {
        let (base, store, _, _) = try mountedFixture()
        let system = MeasurementFixtureSystem(drive: base.appendingPathComponent("drive").path, source: store.apps.o("fixture").s("mount_point"))
        let service = try NativeService(root: store.root, runtime: base.appendingPathComponent("measurements"), system: system)
        defer { system.releaseSecond.signal(); while service.stateLock.locked({ service.measurementsRunning }) { Thread.sleep(forTimeInterval: 0.02) }; try? nativeFM.removeItem(at: base) }
        var apps = store.apps, records = store.records
        var first = records.o("fixture"); first["phase"] = "rolled_back"; records["fixture"] = first
        var second = apps.o("fixture"); second["mount_point"] = base.appendingPathComponent("second").path
        apps["second"] = second; var record = first; record["source"] = second["mount_point"]; records["second"] = record
        store.apps = apps; store.records = records; try store.save()
        let before = try Data(contentsOf: store.root.appendingPathComponent("state.json"))
        let rows: [Object] = ["fixture", "second"].map { ["id": $0, "name": $0, "managed": true, "migration_state": "unmigrated", "data_location": "internal"] }
        let lock = try store.lock("recover"); defer { withExtendedLifetime(lock) {} }
        XCTAssertNotNil(service.scheduleMeasurements(rows))
        XCTAssertEqual(system.secondStarted.wait(timeout: .now() + 5), .success)
        let partial = try readObject(service.runtime.appendingPathComponent("sizes.json"))
        XCTAssertEqual(partial.o("fixture").n("bytes"), 1024)
        XCTAssertEqual(partial.o("second").s("status"), "reading"); XCTAssertNil(partial.o("second")["bytes"])
        let model = BridgeModel(root: store.root, runtime: service.runtime); model.apps = rows.map { BridgeApp(value: $0) }
        model.applyMeasurements(partial)
        XCTAssertEqual(model.apps[0].value.n("bytes"), 1024); XCTAssertNil(model.apps[1].value["bytes"])
        XCTAssertFalse(system.ranOnMain)
        system.releaseSecond.signal()
        let deadline = Date().addingTimeInterval(5)
        while service.stateLock.locked({ service.measurementsRunning }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(service.measurementsRunning)
        let completed = try readObject(service.runtime.appendingPathComponent("sizes.json"))
        model.applyMeasurements(completed); XCTAssertEqual(model.apps[1].value.n("bytes"), 2048)
        XCTAssertNil(service.scheduleMeasurements(rows))
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent("state.json")), before)
    }

    private func mountedFixture() throws -> (URL, NativeStore, MountedFixtureSystem, NativeService) {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("source"), drive = base.appendingPathComponent("drive")
        try privateDirectory(source); try privateDirectory(drive)
        let store = try NativeStore(base.appendingPathComponent("metadata"))
        let profile: Object = ["name": "Fixture", "bundle_id": "org.fixture.app", "app_path": "/Applications/Fixture.app", "mount_point": source.path,
                               "volume_uuid": "FIXTURE", "folder": "Cache/Fixture", "capacity_gib": 128, "enabled": true, "auto_open": false]
        store.apps = ["fixture": profile]
        store.records = ["fixture": ["id": "fixture-record", "phase": "active", "source": source.path, "user_confirmed": true]]
        try store.save(); try writeObject(["id": "fixture-record"], to: source.appendingPathComponent(volumeMarker))
        let system = MountedFixtureSystem(drive: drive.path, source: source.path)
        return (base, store, system, try NativeService(root: store.root, runtime: base.appendingPathComponent("runtime"), system: system))
    }

    func testReadyMountDoesNotWaitForAnotherMigration() throws {
        let (base, store, system, service) = try mountedFixture()
        defer { try? nativeFM.removeItem(at: base) }
        let before = try Data(contentsOf: store.root.appendingPathComponent("state.json"))
        let lock = try store.lock("recover")
        defer { withExtendedLifetime(lock) {} }
        let automatic = try service.mountApplications(task: NativeTask("automatic"), requested: "", automatic: true)
        XCTAssertTrue(automatic.o("fixture").b("ok")); XCTAssertFalse(automatic.o("fixture").b("launch_pending"))
        XCTAssertTrue(try service.mountApplications(task: NativeTask("mount"), requested: "fixture", automatic: false).o("fixture").b("ok"))
        system.wrongImage = true
        XCTAssertFalse(try service.mountApplications(task: NativeTask("automatic"), requested: "", automatic: true).o("fixture").b("ok"))
        system.wrongImage = false; system.attached = false
        let waiting = try service.mountApplications(task: NativeTask("automatic"), requested: "", automatic: true).o("fixture")
        XCTAssertFalse(waiting.b("ok")); XCTAssertEqual(waiting.s("reason"), "busy")
        XCTAssertFalse(waiting.s("message").contains("recover")); XCTAssertTrue(waiting.s("message").contains("继续任务"))
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent("state.json")), before)
    }

    func testWaitingToOpenDoesNotMisreportAMountedApp() throws {
        let (base, store, system, service) = try mountedFixture()
        defer { try? nativeFM.removeItem(at: base) }
        var apps = store.apps, app = apps.o("fixture"); app["auto_open"] = true; apps["fixture"] = app; store.apps = apps; try store.save()
        do {
            let lock = try store.lock("recover")
            defer { withExtendedLifetime(lock) {} }
            let result = try service.mountApplications(task: NativeTask("automatic"), requested: "", automatic: true).o("fixture")
            XCTAssertTrue(result.b("ok")); XCTAssertTrue(result.b("launch_pending")); XCTAssertEqual(system.opens, 0)
        }
        XCTAssertTrue(try service.mountApplications(task: NativeTask("automatic"), requested: "", automatic: true).o("fixture").b("ok"))
        XCTAssertEqual(system.opens, 1)
        let lock = try store.lock("recover")
        defer { withExtendedLifetime(lock) {} }
        XCTAssertFalse(try service.mountApplications(task: NativeTask("automatic"), requested: "", automatic: true).o("fixture").b("launch_pending"))
        XCTAssertEqual(system.opens, 1)
    }

    func testAcceptanceDoesNotScheduleMountingAndPendingAppsRemainVisible() throws {
        let (base, store, _, service) = try mountedFixture()
        defer { try? nativeFM.removeItem(at: base) }
        var record = store.records.o("fixture"); record["phase"] = "active_unconfirmed"; record["user_confirmed"] = false
        try store.updateRecord("fixture", record)
        _ = try service.execute("confirm", values: ["app_id": "fixture"], task: NativeTask("confirm"))
        XCTAssertFalse(service.automaticRunning); XCTAssertTrue(service.active.isEmpty)
        XCTAssertTrue(try NativeStore(store.root).records.o("fixture").b("user_confirmed"))
        let model = BridgeModel(root: store.root, runtime: service.runtime)
        model.apps = ["pending", "migrated", "unmigrated", "incomplete"].map { BridgeApp(value: ["id": $0, "migration_state": $0]) }
        XCTAssertEqual(model.migratedApps.map(\.id), ["pending", "migrated"])
        model.filter = "migrated"; XCTAssertEqual(Set(model.visibleApps.map(\.id)), ["pending", "migrated"])
        let pending = model.migratedApps[0]; model.beginFlow(pending)
        XCTAssertEqual(model.flow?.kind, "accept"); XCTAssertFalse(pending.migrated)
        XCTAssertEqual(deletionConfirmation, "确认删除")
    }

    func testAutomaticReconnectOnlyTracksConfiguredAcceptedDrives() throws {
        let (base, store, _, service) = try mountedFixture()
        defer { try? nativeFM.removeItem(at: base) }
        let drive: Object = ["uuid": "fixture", "device": "fixture-device"], unrelated: Object = ["uuid": "other", "device": "other-device"]
        let initial = service.automaticConnectionTokens(store, volumes: [drive])
        XCTAssertEqual(initial.count, 1)
        XCTAssertEqual(initial, service.automaticConnectionTokens(store, volumes: [unrelated, drive]))
        XCTAssertTrue(service.automaticConnectionTokens(store, volumes: [unrelated]).isEmpty)
        XCTAssertNotEqual(initial, service.automaticConnectionTokens(store, volumes: [["uuid": "fixture", "device": "new-device"]]))
        store.config["automatic_mount"] = false
        XCTAssertTrue(service.automaticConnectionTokens(store, volumes: [drive]).isEmpty)
    }

    func testScopedAutomaticRequestDoesNotCheckOtherApps() throws {
        let (base, store, _, service) = try mountedFixture()
        defer { try? nativeFM.removeItem(at: base) }
        var apps = store.apps, other = apps.o("fixture"); other["mount_point"] = base.appendingPathComponent("unmounted-other").path
        apps["other"] = other; store.apps = apps
        var records = store.records, record = records.o("fixture"); record["source"] = other["mount_point"]; records["other"] = record; store.records = records; try store.save()
        service.scheduleAutomatic(appIDs: ["fixture"])
        let deadline = Date().addingTimeInterval(5)
        while service.stateLock.locked({ service.automaticRunning }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(service.automaticRunning)
        let result = try readObject(service.runtime.appendingPathComponent("automatic.json"))
        XCTAssertEqual(result.s("phase"), "complete"); XCTAssertEqual(Set(result.o("results").keys), ["fixture"])
    }

    func testTaskCleanupPreservesRunningTasksAndMigrationRecords() throws {
        let (base, store, _, service) = try mountedFixture()
        defer { try? nativeFM.removeItem(at: base) }
        let beforeConfig = try Data(contentsOf: store.root.appendingPathComponent("config.json")), beforeState = try Data(contentsOf: store.root.appendingPathComponent("state.json"))
        var ids: [String: String] = [:]
        for phase in ["complete", "failed", "stopped", "interrupted", "queued", "running", "waiting"] {
            let id = UUID().uuidString; ids[phase] = id
            let row: Object = ["id": id, "phase": phase, "action": "migrate"]
            try writeObject(row, to: service.runtime.appendingPathComponent("history/\(id).json"))
            try writeObject(row, to: service.runtime.appendingPathComponent("tasks/\(id).json"))
        }
        let lock = try store.lock("recover")
        defer { withExtendedLifetime(lock) {} }
        let excluded = ids["stopped"]!, busy = ids["interrupted"]!
        service.active[busy] = NativeTask("migrate", id: busy)
        let result = try service.execute("clear_tasks", values: ["exclude_ids": [excluded]], task: NativeTask("clear")) as! Object
        XCTAssertEqual(Set(result["removed_ids"] as! [String]), [ids["complete"]!, ids["failed"]!])
        for phase in ["queued", "running", "waiting", "stopped", "interrupted"] {
            XCTAssertTrue(exists(service.runtime.appendingPathComponent("history/\(ids[phase]!).json").path))
        }
        _ = try service.execute("clear_tasks", values: ["task_id": excluded], task: NativeTask("clear"))
        XCTAssertFalse(exists(service.runtime.appendingPathComponent("history/\(excluded).json").path))
        XCTAssertThrowsError(try service.clearTaskHistory(["task_id": "../config"]))
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent("config.json")), beforeConfig)
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent("state.json")), beforeState)
        XCTAssertTrue(exists(systemMarkerPath(store)))
    }

    private func systemMarkerPath(_ store: NativeStore) -> String { store.apps.o("fixture").s("mount_point") + "/" + volumeMarker }

    func testSystemAPFSVolumesAreNotMigrationDestinations() throws {
        let system = RoleFixtureSystem()
        let info: Object = ["FilesystemType": "apfs", "APFSContainerReference": "fixture-container", "VolumeUUID": "fixture-volume"]
        func listing(_ volume: Object) -> Object { ["Containers": [["Volumes": [volume]]]] }
        for role in ["Recovery", "System", "Data", "Preboot", "VM", "Backup"] {
            system.listing = listing(["APFSVolumeUUID": "fixture-volume", "Roles": [role]])
            XCTAssertThrowsError(try system.validateDestinationRole(info)) { error in
                XCTAssertEqual((error as? DBError)?.reason, "invalid_destination")
            }
        }
        system.listing = listing(["APFSVolumeUUID": "FIXTURE-VOLUME", "Roles": [String]()])
        XCTAssertNoThrow(try system.validateDestinationRole(info))
        system.listing = listing(["APFSVolumeUUID": "other", "Roles": [String]()])
        XCTAssertThrowsError(try system.validateDestinationRole(info))
        system.listing = listing(["APFSVolumeUUID": "fixture-volume"])
        XCTAssertThrowsError(try system.validateDestinationRole(info))
        XCTAssertNoThrow(try system.validateDestinationRole(["FilesystemType": "exfat"]))
    }

    func testDestinationWriteCheckCleansUpAndRejectsUnsafePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let system = NativeSystem()
        try system.checkDestinationDirectory(root.path, folder: "Cache/Fixture/Data")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        let cache = root.appendingPathComponent("Cache")
        try privateDirectory(cache)
        try Data("keep".utf8).write(to: cache.appendingPathComponent("existing"))
        try system.checkDestinationDirectory(root.path, folder: "Cache")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), ["existing"])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: cache)
        XCTAssertThrowsError(try system.checkDestinationDirectory(root.path, folder: "link/Fixture"))
        XCTAssertThrowsError(try system.checkDestinationDirectory(root.path, folder: "../outside"))
        XCTAssertThrowsError(try system.checkDestinationDirectory(root.path, folder: "Cache/existing/Fixture"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cache.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path) }
        XCTAssertThrowsError(try system.checkDestinationDirectory(root.path, folder: "Cache/Fixture")) { error in
            XCTAssertEqual((error as? DBError)?.reason, "destination_unwritable")
        }
    }

    func testConnectedExternalDestination() throws {
        guard let uuid = ProcessInfo.processInfo.environment["DISKBRIDGE_TEST_DESTINATION_UUID"] else {
            throw XCTSkip("Set DISKBRIDGE_TEST_DESTINATION_UUID to check a connected test drive.")
        }
        let system = NativeSystem(), disk = try system.volume(uuid)
        XCTAssertTrue(try system.volumes().contains { $0.s("uuid") == uuid })
        let folder = ".diskbridge-check-" + UUID().uuidString
        try system.checkDestinationDirectory(disk.s("path"), folder: folder + "/Data")
        XCTAssertFalse(exists(disk.s("path") + "/" + folder))
        for candidate in try system.volumes() { try system.validateDestinationRole(system.diskInfo(candidate.s("uuid"))) }
    }

    func testDataLocationIsPortableAndPreservesExistingRecords() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try privateDirectory(home)
        defer { try? FileManager.default.removeItem(at: home) }
        let runtime = home.appendingPathComponent("Library/Application Support/DiskBridge/runtime")
        let expected = home.appendingPathComponent("Library/Application Support/DiskBridge")
        XCTAssertEqual(try NativeInstaller.dataRoot(home: home, runtime: runtime).path, expected.path)
        let previous = home.appendingPathComponent("PreviousData")
        try NativeStore(previous).save()
        try writeObject(["root": previous.path], to: runtime.appendingPathComponent("settings.json"))
        XCTAssertEqual(try NativeInstaller.dataRoot(home: home, runtime: runtime).path, previous.path)
        let explicit = home.appendingPathComponent("ExplicitData")
        XCTAssertEqual(try NativeInstaller.dataRoot(home: home, runtime: runtime, explicit: explicit.path).path, explicit.path)
    }

    func testMissingRememberedRecordsDoNotSilentlyStartEmpty() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try privateDirectory(home)
        defer { try? FileManager.default.removeItem(at: home) }
        let runtime = home.appendingPathComponent("runtime")
        try writeObject(["root": home.appendingPathComponent("MissingData").path], to: runtime.appendingPathComponent("settings.json"))
        XCTAssertThrowsError(try NativeInstaller.dataRoot(home: home, runtime: runtime))
        try writeObject(["root": "/"], to: runtime.appendingPathComponent("settings.json"))
        XCTAssertThrowsError(try NativeInstaller.dataRoot(home: home, runtime: runtime))
    }
}
