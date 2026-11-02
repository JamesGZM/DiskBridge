import Foundation

func git(_ arguments: [String]) throws -> Data {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments; process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "PrivacyCheck", code: 1) }
    return data
}

let root = URL(fileURLWithPath: String(decoding: try git(["rev-parse", "--show-toplevel"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
let files = String(decoding: try git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"]), as: UTF8.self).split(separator: "\0").map(String.init)
let forbiddenNames: Set<String> = ["config.json", "state.json", "signing-identity.txt", ".DS_Store", ".env"]
let forbiddenExtensions: Set<String> = ["p12", "pfx", "pem", "key", "cer", "mobileprovision", "dmg", "zip", "log"]
let rules: [(String, NSRegularExpression)] = try [
    ("personal home path", #"/(?:Users|home)/[^\s/\"']+"#),
    ("literal device identifier", #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#),
    ("credential", #"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{24,})"#),
    ("private key", #"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"#),
    ("personal signing identity", #"Apple Development:[ \t]+[^\s\"']+|Developer ID Application:[ \t]+[^\s\"']+"#)
].map { ($0.0, try NSRegularExpression(pattern: $0.1)) }
let emails = try NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)
var findings = 0
func report(_ path: String, _ line: Int, _ kind: String) {
    print("\(path):\(line): \(kind)"); findings += 1
}
for path in files {
    let url = root.appendingPathComponent(path), parts = path.split(separator: "/")
    if forbiddenNames.contains(url.lastPathComponent) || forbiddenExtensions.contains(url.pathExtension.lowercased()) || parts.contains(where: { ["records", "runtime", "logs"].contains(String($0)) || $0.hasSuffix(".app") }) {
        report(path, 1, "local data or build artifact"); continue
    }
    let data = try Data(contentsOf: url)
    guard let content = String(data: data, encoding: .utf8) else { report(path, 1, "unexpected binary file"); continue }
    for (index, line) in content.components(separatedBy: .newlines).enumerated() {
        let range = NSRange(line.startIndex..., in: line)
        for (kind, expression) in rules where expression.firstMatch(in: line, range: range) != nil { report(path, index + 1, kind) }
        for match in emails.matches(in: line, range: range) {
            guard let matched = Range(match.range, in: line) else { continue }
            let address = line[matched].lowercased()
            if address.range(of: #"^icon_[0-9]+x[0-9]+@2x\.png$"#, options: .regularExpression) != nil { continue }
            if !address.hasSuffix(".invalid") && !address.hasSuffix("@example.com") && !address.hasSuffix("@users.noreply.github.com") {
                report(path, index + 1, "email address")
            }
        }
    }
}
print("Checked \(files.count) project text files; \(findings) findings.")
exit(findings == 0 ? 0 : 1)
