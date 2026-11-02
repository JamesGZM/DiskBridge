import XCTest
@testable import DiskBridge

final class RegressionTests: XCTestCase {
    func testNativeRegressionSuite() throws { try NativeTests.run() }

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
