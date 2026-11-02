import Foundation
import CryptoKit

func applicationKey(_ bundle: String) -> String {
    let readable = bundle.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    let hash = SHA256.hash(data: Data(bundle.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    return "app_" + String(readable.prefix(40)) + "_" + hash
}
func applicationFingerprint(_ path: String) -> String? {
    guard let directory = try? fileStat(path), let info = try? fileStat(path + "/Contents/Info.plist") else { return nil }
    return "\(directory.st_dev):\(directory.st_ino):\(directory.st_mtimespec.tv_sec):\(directory.st_mtimespec.tv_nsec):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
}
func applicationRootStamps() -> Object {
    let roots = ["/Applications", nativeFM.homeDirectoryForCurrentUser.path + "/Applications", "/System/Applications"]
    return Dictionary(uniqueKeysWithValues: roots.map { path -> (String, Any) in
        guard let value = try? fileStat(path) else { return (path, "missing") }
        return (path, "\(value.st_dev):\(value.st_ino):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec)")
    })
}
func applicationMetadata(_ path: String) -> Object? {
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let fingerprint = applicationFingerprint(url.path)
    guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
          let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? Object,
          !info.s("CFBundleIdentifier").isEmpty, !info.b("LSBackgroundOnly") else { return nil }
    let bundle = info.s("CFBundleIdentifier")
    let localized = Bundle(url: url)?.localizedInfoDictionary ?? [:]
    let name = localized.s("CFBundleDisplayName", localized.s("CFBundleName", info.s("CFBundleDisplayName", info.s("CFBundleName", url.deletingPathExtension().lastPathComponent))))
    let aliases = Set([name, info.s("CFBundleDisplayName"), info.s("CFBundleName"), localized.s("CFBundleName"), url.deletingPathExtension().lastPathComponent, info.s("CFBundleExecutable")]).filter { !$0.isEmpty }.sorted()
    let dates = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
    let installed = dates?.addedToDirectoryDate ?? dates?.creationDate
    let own = bundle == "com.local.appdatamount.statusbar" || bundle == "com.local.diskbridge"
    let system = path.hasPrefix("/System/") || bundle.hasPrefix("com.apple.")
    return ["id": applicationKey(bundle), "name": name, "bundle_id": bundle, "app_path": url.path,
            "version": info.s("CFBundleShortVersionString"), "bundle_name": info.s("CFBundleName"), "installed": true,
            "file_name": url.deletingPathExtension().lastPathComponent, "executable_name": info.s("CFBundleExecutable"),
            "default_folder": "Cache/" + url.deletingPathExtension().lastPathComponent,
            "aliases": aliases, "search_terms": Array(Set(aliases.flatMap(applicationSearchTerms))),
            "sort_name": applicationSearchText(name.applyingTransform(.toLatin, reverse: false) ?? name),
            "installed_at": installed.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "installed_date_source": dates?.addedToDirectoryDate == nil ? "应用目录创建时间，可能不同于首次安装时间" : "系统记录的添加到目录时间",
            "catalog_signature": fingerprint ?? "", "system": system, "own": own]
}

func candidatesFor(_ app: Object, system: NativeSystem = NativeSystem(), homeRoot: String? = nil) -> [Object] {
    let home = homeRoot ?? nativeFM.homeDirectoryForCurrentUser.path
    var paths: [(String, String, Bool)] = []
    let names = Set([app.s("name"), app.s("file_name"), app.s("bundle_name"), app.s("executable_name"), app.s("bundle_id")]).filter { !$0.isEmpty && !$0.contains("/") }
    for name in names.sorted() {
        paths.append((home + "/Library/Application Support/" + name, "按应用标识发现", false))
        paths.append((home + "/Documents/" + name, "应用文稿目录", false))
    }
    let support = home + "/Library/Application Support"
    let identifiers = app.s("bundle_id").split(separator: ".").map(String.init)
    let providers = Set(identifiers.dropFirst().dropLast().map(applicationSearchText))
    let dataNames = Set(names.map(applicationSearchText).filter { !$0.isEmpty })
    func matchesDataName(_ name: String) -> Bool {
        let name = applicationSearchText(name)
        return dataNames.contains { base in
            if name == base { return true }
            return name.hasPrefix(base) && name.dropFirst(base.count).first?.isNumber == true
        }
    }
    for parent in (try? nativeFM.contentsOfDirectory(atPath: support)) ?? [] where !parent.hasPrefix(".") {
        if matchesDataName(parent) { paths.append((support + "/" + parent, "按应用名称与版本发现", false)) }
        if providers.contains(applicationSearchText(parent)) {
            for child in (try? nativeFM.contentsOfDirectory(atPath: support + "/" + parent)) ?? [] where !child.hasPrefix(".") && matchesDataName(child) {
                paths.append((support + "/" + parent + "/" + child, "按应用标识发现厂商目录中的数据", false))
            }
        }
    }
    let container = home + "/Library/Containers/" + app.s("bundle_id") + "/Data"
    for child in (try? nativeFM.contentsOfDirectory(atPath: container)) ?? [] {
        if !["Library", "Documents", "tmp", "Caches", "Cache", "Logs", ".Trash", "SystemData", "Desktop", "Downloads", "Movies", "Music", "Pictures"].contains(child),
           !child.hasPrefix(".com.apple."), !child.contains(".AppDataMount-"), !child.contains(".original-before-") {
            paths.append((container + "/" + child, "属于该应用容器的数据目录", false))
        }
    }
    for base in [container + "/Library/Application Support", container + "/Documents"] {
        for child in (try? nativeFM.contentsOfDirectory(atPath: base)) ?? [] {
            if !child.hasPrefix("."), !child.contains(".AppDataMount-"), !["Caches", "Cache", "Logs", "CrashReporter"].contains(child) {
                paths.append((base + "/" + child, "属于该应用的容器", false))
            }
        }
    }
    if let result = try? system.command("/usr/bin/codesign", ["-d", "--entitlements", ":-", app.s("app_path")], timeout: 10),
       let entitlements = (try? PropertyListSerialization.propertyList(from: result.data, format: nil)) as? Object {
        for group in entitlements["com.apple.security.application-groups"] as? [String] ?? [] where !group.contains("/") && group != ".." {
            let base = home + "/Library/Group Containers/" + group
            for child in (try? nativeFM.contentsOfDirectory(atPath: base)) ?? [] where !child.hasPrefix(".") && !["Library", "Caches", "Logs"].contains(child) {
                paths.append((base + "/" + child, "应用声明的共享容器，可能由多个应用共用", true))
            }
        }
    }
    var seen = Set<String>()
    return paths.sorted { $0.0.count < $1.0.count }.compactMap { path, label, shared in
        guard !seen.contains(path), isDirectory(path), !isLink(path) else { return nil }
        if seen.contains(where: { path.hasPrefix($0 + "/") }) { return nil }
        seen.insert(path); return ["path": path, "label": label, "shared": shared, "recommended": !shared]
    }
}

func discoverApplications(system: NativeSystem, task: NativeTask, cached: [Object] = [], searchRoots: [String]? = nil) throws -> [Object] {
    try task.begin("读取本机应用列表")
    let roots = searchRoots ?? ["/Applications", nativeFM.homeDirectoryForCurrentUser.path + "/Applications", "/System/Applications"]
    var paths: Set<String> = []
    for root in roots {
        guard let enumerator = nativeFM.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
        for case let url as URL in enumerator {
            if url.pathExtension == "app" { paths.insert(url.path); enumerator.skipDescendants() }
        }
    }
    if let result = try? system.command("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle'"], timeout: 6), result.code == 0 {
        paths.formUnion(String(decoding: result.data, as: UTF8.self).split(separator: "\n").map(String.init))
    }
    let devices = Set([try fileStat("/").st_dev, try fileStat("/System/Volumes/Data").st_dev])
    let skip: Set<String> = ["node_modules", "Pods", "DerivedData", "target", ".git", ".Trash", ".gradle", ".npm", ".venv", "Caches", "Cache", "__pycache__", "nt_data", "MiniApp"]
    var result: [String: Object] = [:], previous: [String: Object] = [:]
    for app in cached { previous[app.s("app_path")] = app }
    for path in paths.sorted() {
        try task.check()
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath(), parts = url.pathComponents
        guard url.pathExtension == "app", !parts.dropLast().contains(where: { $0.hasSuffix(".app") || skip.contains($0) }),
              !path.hasPrefix("/System/Library/"), !path.hasPrefix("/Library/Apple/"),
              let value = try? fileStat(url.path), devices.contains(value.st_dev) || path.hasPrefix("/System/") else { continue }
        let saved = previous[url.path], signature = applicationFingerprint(url.path)
        guard let app = (signature != nil && saved?.s("catalog_signature") == signature ? saved : applicationMetadata(url.path)) else { continue }
        if result[app.s("bundle_id")] == nil { result[app.s("bundle_id")] = app; try task.advance(files: 1) }
    }
    return result.values.sorted { $0.s("name").localizedStandardCompare($1.s("name")) == .orderedAscending }
}
