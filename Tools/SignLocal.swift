import Foundation

let fm = FileManager.default
struct SigningError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw SigningError(message: message) }
}
func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardOutput = output; process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    // Signing diagnostics may contain certificate owners; never print them.
    try require(process.terminationStatus == 0, "Local signing command failed: " + URL(fileURLWithPath: executable).lastPathComponent)
    return String(decoding: data, as: UTF8.self)
}
func bundleID(_ app: URL) throws -> String? {
    let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    return (try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["CFBundleIdentifier"] as? String
}
func requirement(_ app: URL) throws -> String {
    let output = try run("/usr/bin/codesign", ["--display", "--requirements", "-", app.path])
    let lines = output.components(separatedBy: .newlines).map { $0.hasPrefix("# ") ? String($0.dropFirst(2)) : $0 }
    guard let line = lines.first(where: { $0.hasPrefix("designated => ") }) else {
        throw SigningError(message: "Missing designated requirement.")
    }
    return String(line.dropFirst("designated => ".count))
}

do {
    let project = URL(fileURLWithPath: fm.currentDirectoryPath), source = project.appendingPathComponent("dist/盘桥.app")
    try require(try bundleID(source) == "com.local.diskbridge", "Build the DiskBridge app first, from the repository root.")
    let configured = ProcessInfo.processInfo.environment["DISKBRIDGE_LOCAL_SIGN_IDENTITY"]
    let listing = try run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
    let expression = try NSRegularExpression(pattern: #"(?m)^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+\"(?:Apple Development|Developer ID Application):[^\"]+\""#)
    let identities = expression.matches(in: listing, range: NSRange(listing.startIndex..., in: listing)).compactMap { match -> String? in
        guard let range = Range(match.range(at: 1), in: listing) else { return nil }; return String(listing[range])
    }
    let identity: String
    if let configured {
        guard let found = identities.first(where: { $0.caseInsensitiveCompare(configured) == .orderedSame }) else {
            throw SigningError(message: "The configured signing fingerprint is not an available developer identity.")
        }
        identity = found
    } else {
        try require(identities.count == 1, "Set DISKBRIDGE_LOCAL_SIGN_IDENTITY to an existing developer certificate fingerprint when multiple or no identities are found.")
        identity = identities[0]
    }
    let workspace = project.appendingPathComponent(".build/local-install")
    try fm.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let stage = workspace.appendingPathComponent("stage-" + UUID().uuidString + ".app")
    try fm.copyItem(at: source, to: stage)
    func sign(_ app: URL) throws {
        _ = try run("/usr/bin/codesign", ["--force", "--sign", identity, "--options", "runtime", "--timestamp=none", app.path])
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }
    try sign(stage)
    let current = try requirement(stage)
    try require(!current.contains("cdhash"), "Signing identity still depends on a particular build hash.")
    if CommandLine.arguments.count > 1 {
        let previous = URL(fileURLWithPath: CommandLine.arguments[1])
        try require(try bundleID(previous) == "com.local.diskbridge", "Previous app has a different identity.")
        let previousIdentity = try requirement(previous)
        if !previousIdentity.contains("cdhash") { try require(current == previousIdentity, "Existing developer-signed app uses a different identity.") }
        let copy = workspace.appendingPathComponent("identity-check-" + UUID().uuidString + ".app")
        try fm.copyItem(at: previous, to: copy); try sign(copy)
        let older = try requirement(copy)
        try require(current == older, "Designated requirements changed across versions.")
        _ = try run("/usr/bin/codesign", ["--verify", "--strict", "-R", "=" + older, stage.path])
        print("Stable signing identity across versions: verified.")
    }
    let destination = workspace.appendingPathComponent("盘桥.app")
    if fm.fileExists(atPath: destination.path) { try fm.moveItem(at: destination, to: workspace.appendingPathComponent("previous-" + UUID().uuidString + ".app")) }
    try fm.moveItem(at: stage, to: destination)
    print("Local signed app: .build/local-install/盘桥.app")
    print("Public dist artifacts were not modified. No certificate or key was exported.")
} catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
