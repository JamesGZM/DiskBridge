import SwiftUI
import AppKit
import UserNotifications

struct AppIdentityView: View {
    let app: BridgeApp
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.value.s("app_path"))).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                Text(app.value.b("installed", true) ? app.value.s("version", app.value.s("bundle_id")) : "应用未安装").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.vertical, 3)
    }
}
struct MigrationStatusView: View {
    let app: BridgeApp
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(app.stateName).font(.callout)
            if app.relocated {
                Label(app.value.b("status_cached") ? "核对中" : app.mounted ? "挂载就绪" : "等待挂载", systemImage: app.mounted ? "checkmark.circle" : "clock")
                    .font(.caption).foregroundStyle(app.mounted || app.value.b("status_cached") ? Color.secondary : Color.orange)
                    .help(app.value.s("availability_note"))
            }
        }
    }
}

struct BridgeView: View {
    @ObservedObject var model: BridgeModel
    @State private var managedSelection: String?
    @State private var cleaning: BridgeApp?
    @State private var clearingCopy: Object?
    @State private var showCopyCleanup = false
    @State private var unmounting: BridgeApp?
    @State private var showTaskCleanup = false
    var body: some View {
        NavigationSplitView {
            List(selection: $model.page) {
                Label("应用管理", systemImage: "square.grid.2x2").tag("applications")
                HStack { Label("任务管理", systemImage: "list.bullet.rectangle"); Spacer(); if model.activeCount > 0 { Text("\(model.activeCount)").font(.caption).foregroundStyle(.secondary) } }.tag("tasks")
                Label("已迁移应用", systemImage: "externaldrive").tag("migrated")
                Label("存储设备", systemImage: "externaldrive.connected.to.line.below").tag("storage")
                Label("备份与恢复", systemImage: "clock.arrow.circlepath").tag("recovery")
            }
            .navigationTitle("盘桥")
            .navigationSplitViewColumnWidth(min: 175, ideal: 195, max: 240)
            .safeAreaInset(edge: .bottom) {
                HStack { Button(action: model.openSettings) { Label("设置", systemImage: "gearshape") }.buttonStyle(.plain); Spacer() }.padding(14)
            }
        } detail: {
            VStack(spacing: 0) {
                if !model.error.isEmpty || model.needsAuthorization {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(model.error.isEmpty ? "需要授权盘桥访问应用数据。" : model.error).font(.callout).textSelection(.enabled)
                        Spacer()
                        if model.needsAuthorization { Button("前往授权", action: model.openAuthorization) }
                        Button { model.error = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(12).background(Color.orange.opacity(0.08))
                }
                switch model.page {
                case "tasks": taskManager
                case "migrated": migratedManager
                case "storage": storageManager
                case "recovery": recoveryManager
                default: applicationManager
                }
            }.padding(.top, 20)
        }
        .frame(minWidth: 1000, minHeight: 650)
        .toolbar {
            ToolbarItem { if model.loading { ProgressView().controlSize(.small) } }
            ToolbarItem { Button { model.refresh(forceCatalog: true) } label: { Label("刷新", systemImage: "arrow.clockwise") }.help("手动重新扫描应用；通常直接使用缓存并后台核对") }
        }
        .sheet(item: $model.flow) { flow in WorkflowSheet(model: model, flow: flow) }
        .sheet(item: $cleaning) { app in OriginalCleanupSheet(model: model, app: app) }
        .sheet(isPresented: $showCopyCleanup) { if let copy = clearingCopy { RetainedCleanupSheet(model: model, copy: copy) } }
        .confirmationDialog("清理已结束的任务记录？", isPresented: $showTaskCleanup) {
            Button("清理已结束任务", role: .destructive) { model.clearTasks() }
        } message: { Text("清理已完成、失败及已停止的任务列表记录。进行中的任务、应用迁移配置、数据和原件备份均保留。") }
        .confirmationDialog("安全卸载应用数据？", isPresented: Binding(get: { unmounting != nil }, set: { if !$0 { unmounting = nil } })) {
            if let app = unmounting { Button("卸载 \(app.name) 数据卷") { model.perform("unmount", app: app, values: ["confirmed": true]); unmounting = nil } }
        } message: { Text("请先完全退出应用。盘桥会保留挂载点保护，等待你重新挂载后再使用应用。") }
        .onAppear { model.refresh() }
    }
    var applicationManager: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                TextField("搜索名称、缩写或拼音", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Picker("筛选", selection: $model.filter) { Text("全部").tag("all"); Text("未迁移").tag("unmigrated"); Text("已迁移").tag("migrated") }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Spacer()
                Menu {
                    Picker("排序方式", selection: $model.sortField) { Text("名称").tag("name"); Text("数据大小 · 大到小").tag("size"); Text("安装时间 · 最近优先").tag("installed") }
                } label: { Label("排序", systemImage: "arrow.up.arrow.down") }
                Button { model.send("request_sizes") } label: { Label(model.measuringSizes ? "后台读取中" : "读取数据大小", systemImage: "arrow.clockwise") }.disabled(model.measuringSizes)
            }.padding(.horizontal, 18)
            Table(model.visibleApps, selection: $model.selection, sortOrder: $model.tableSort) {
                TableColumn("应用", sortUsing: ApplicationSort("name")) { app in Button { model.beginFlow(app) } label: { AppIdentityView(app: app).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain) }.width(min: 185, ideal: 240)
                TableColumn("迁移状态") { app in MigrationStatusView(app: app) }.width(min: 100, ideal: 120, max: 150)
                TableColumn("数据大小", sortUsing: ApplicationSort("size")) { app in
                    HStack(spacing: 5) {
                        if app.value.s("size_status") == "reading" { ProgressView().controlSize(.mini) }
                        Text(app.value["bytes"] is NSNumber ? formattedBytes(app.value["bytes"]) : app.value.b("own") ? "—" : app.value.s("size_status") == "reading" ? "读取中…" : app.value.s("size_status") == "not_found" ? "未发现数据" : app.value.s("size_status") == "unknown" ? "暂无法读取" : "待统计")
                    }.monospacedDigit().help(app.value.s("size_note", "后台逐项读取可迁移数据，不包含应用本体。"))
                }.width(min: 105, ideal: 125, max: 155)
                TableColumn("安装时间", sortUsing: ApplicationSort("installed")) { app in
                    Text(app.installedDate.map { $0.formatted(date: .numeric, time: .shortened) } ?? "未知").font(.callout).help(app.value.s("installed_date_source", "系统未提供安装时间。"))
                }.width(min: 140, ideal: 165, max: 190)
                TableColumn("目标硬盘 / 目录") { app in Text(model.appDestination(app)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            .alternatingRowBackgrounds(.enabled)
            .contextMenu {
                if let app = model.apps.first(where: { $0.id == model.selection }) {
                    Button(app.migrated ? "还原到内置硬盘…" : app.pending ? "应用验收…" : app.incomplete ? "继续任务…" : "迁移到外置硬盘…") { model.beginFlow(app) }
                    Button("统计数据大小") { model.perform("estimate", app: app) }
                    if app.migrated { Button("查看应用设置") { managedSelection = app.id; model.page = "migrated" } }
                }
            }
            HStack {
                Text("\(model.visibleApps.count) 个应用").foregroundStyle(.secondary)
                Spacer()
                if let app = model.apps.first(where: { $0.id == model.selection }) {
                    Button(app.migrated ? "还原…" : app.pending ? "验收…" : app.incomplete ? "继续任务…" : "迁移…") { model.beginFlow(app) }.buttonStyle(.borderedProminent)
                }
            }.padding(.horizontal, 18)
            Divider()
            HStack(spacing: 22) {
                let moved = model.migratedApps.reduce(Int64(0)) { $0 + $1.value.n("bytes") }
                let backups = model.apps.reduce(Int64(0)) { $0 + $1.value.n("backup_bytes") }
                Text("已迁移数据 \(formattedBytes(NSNumber(value: moved)))")
                Text("原件备份 \(formattedBytes(NSNumber(value: backups)))")
                Spacer(); Text("迁移与原件清理是独立操作")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 12)
        }
    }
    var migratedManager: some View {
        HSplitView {
            List(selection: $managedSelection) {
                ForEach(model.migratedApps) { app in
                    VStack(alignment: .leading, spacing: 4) {
                        AppIdentityView(app: app)
                        Text(app.stateName).font(.caption).foregroundStyle(app.pending ? Color.orange : Color.secondary)
                    }.tag(app.id)
                }
            }.frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let app = model.migratedApps.first(where: { $0.id == managedSelection }) ?? model.migratedApps.first {
                        AppIdentityView(app: app).font(.title3)
                        if app.pending {
                            GroupBox("迁移完成，待验收") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("数据已迁移到外置硬盘。请打开应用检查旧记录与附件，确认正常后启用自动挂载。")
                                    Button("检查并验收…") { model.beginFlow(app) }.buttonStyle(.borderedProminent)
                                }.padding(8)
                            }
                        }
                        GroupBox("存储位置") {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(app.value.b("status_cached") ? "正在核对挂载状态" : app.mounted ? "全部数据目录挂载就绪" : "等待硬盘或挂载", systemImage: app.mounted ? "checkmark.circle" : "clock")
                                if !app.value.s("availability_note").isEmpty { Text(app.value.s("availability_note")).font(.caption).foregroundStyle(.secondary) }
                                ForEach(app.paths.indices, id: \.self) { index in
                                    let path = app.paths[index]
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(model.destination(path)).fontWeight(.medium)
                                        Text(path.s("source")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                        HStack { Text(formattedBytes(path["bytes"])).font(.caption); Spacer(); Button("在 Finder 中查看") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path.s("source"))]) } }
                                    }
                                    if index < app.paths.count - 1 { Divider() }
                                }
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        GroupBox(app.pending ? "自动化 · 验收后可用" : "自动化") {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("自动挂载", isOn: Binding(get: { app.value.b("auto_mount") }, set: { model.setting(app, "auto_mount", $0) }))
                                Toggle("挂载后自动打开应用", isOn: Binding(get: { app.value.b("auto_open") }, set: { model.setting(app, "auto_open", $0) }))
                                Text("默认不自动打开。开启后仅在挂载成功时打开一次；主动退出应用后不会再次打开。请避免与应用自身的开机启动重复。").font(.caption).foregroundStyle(.secondary)
                            }.padding(8).disabled(app.pending)
                        }
                        GroupBox("原件备份与空间") {
                            VStack(alignment: .leading, spacing: 10) {
                                LabeledContent("外置数据量", value: formattedBytes(app.value["bytes"]))
                                LabeledContent("原件备份", value: formattedBytes(app.value["backup_bytes"]))
                                LabeledContent("清理时确认释放", value: formattedBytes(app.value["released_bytes"]))
                                if app.value["released_bytes"] is NSNull { Text("旧迁移未记录磁盘可用空间变化，不将迁移数据量当作已释放空间。").font(.caption).foregroundStyle(.secondary) }
                                if app.value.b("can_delete_original") { Button("清理原件备份…", role: .destructive) { cleaning = app } }
                            }.padding(8)
                        }
                        HStack { Button("挂载就绪后打开") { model.openApp(app) }; Button("立即挂载") { model.perform("mount", app: app) }; Spacer(); Button("安全卸载…") { unmounting = app }; if app.migrated { Button("还原到内置硬盘…") { model.beginFlow(app) } } }
                    } else { ContentUnavailableView("没有已迁移应用", systemImage: "externaldrive", description: Text("完成迁移与应用验收后，会显示在这里。")) }
                    Button("管理历史备份与外置副本…") { model.page = "recovery" }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    var recoveryManager: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                    let unfinished = model.apps.filter { $0.incomplete || $0.pending }
                    GroupBox("待恢复或验收") {
                        VStack(alignment: .leading, spacing: 12) {
                            if unfinished.isEmpty { Label("没有需要恢复或验收的应用", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                            ForEach(unfinished) { app in
                                HStack { AppIdentityView(app: app); Spacer(); Text(app.stateName).foregroundStyle(.secondary); Button(app.pending ? "验收…" : "继续任务…") { model.beginFlow(app) } }
                            }
                            Button("查看任务记录") { model.page = "tasks" }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !model.retained.isEmpty {
                        GroupBox("还原后保留的外置副本") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(model.retained.indices, id: \.self) { index in
                                    let copy = model.retained[index]
                                    HStack {
                                        VStack(alignment: .leading) { Text(copy.s("name")); Text(copy.s("folder")).font(.caption).foregroundStyle(.secondary) }
                                        Spacer(); Text(formattedBytes(copy["bytes"])).font(.caption)
                                        Button("清理…", role: .destructive) { clearingCopy = copy; showCopyCleanup = true }
                                    }
                                }
                            }.padding(8)
                        }
                    }
                    let oldBackups = model.archivedBackups + model.apps.filter { $0.value.s("phase") == "rolled_back" && $0.value.b("can_delete_original") }
                    if !oldBackups.isEmpty {
                        GroupBox("历史原件备份") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("还原或再次迁移后保留的内置原件，可单独核验并清理。").font(.caption).foregroundStyle(.secondary)
                                ForEach(oldBackups) { app in
                                    HStack { Text(app.name); Spacer(); Text(formattedBytes(app.value["backup_bytes"])); Button("清理…", role: .destructive) { cleaning = app } }
                                }
                            }.padding(8)
                        }
                    }
                    if model.retained.isEmpty && oldBackups.isEmpty {
                        ContentUnavailableView("没有保留的历史副本", systemImage: "archivebox", description: Text("原件备份和还原后留下的外置副本会在这里集中管理；清理始终需要单独确认。"))
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    var storageManager: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.disksLoading { HStack { ProgressView().controlSize(.small); Text("正在后台读取存储设备…").foregroundStyle(.secondary) } }
                else if model.knownDisks.isEmpty { ContentUnavailableView("连接外置硬盘", systemImage: "externaldrive.badge.plus", description: Text("连接可写的外置硬盘后，可在迁移流程中选择；默认目录为 Cache/应用名称。")) }
                ForEach(model.knownDisks.indices, id: \.self) { index in
                    let disk = model.knownDisks[index]
                    let current = model.disks.first { $0.s("uuid").lowercased() == disk.s("uuid").lowercased() }
                    let related = model.relatedApps(disk.s("uuid"))
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Image(systemName: "externaldrive.fill").font(.title2).foregroundStyle(.secondary)
                                Text(disk.s("name")).font(.headline); Spacer()
                                Label(current == nil ? (model.disksLoading ? "读取中" : "未连接") : "已连接", systemImage: current == nil ? (model.disksLoading ? "clock" : "eject") : "checkmark.circle").foregroundStyle(current == nil ? Color.secondary : Color.green)
                            }
                            if let current {
                                let capacity = current.d("capacity"), free = current.d("free")
                                if capacity > 0 { ProgressView(value: max(0, capacity - free), total: capacity) }
                                LabeledContent("可用空间", value: formattedBytes(current["free"]) + " / " + formattedBytes(current["capacity"]))
                                LabeledContent("格式", value: current.s("filesystem").uppercased())
                                Button("在 Finder 中打开") { NSWorkspace.shared.open(URL(fileURLWithPath: current.s("path"))) }
                            }
                            LabeledContent("当前关联应用", value: "\(related.count) 个")
                            ForEach(related) { app in HStack { AppIdentityView(app: app); Spacer(); Text(app.stateName).foregroundStyle(.secondary); if app.migrated { Button("应用设置") { managedSelection = app.id; model.page = "migrated" } } } }
                            Text("磁盘标识：" + disk.s("uuid")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("拔盘前先退出相关应用并安全卸载数据，再通过 Finder 推出硬盘。离线时保留迁移状态与原路径保护。").font(.callout).foregroundStyle(.secondary)
            }.padding(22)
        }
    }
    var taskManager: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("任务筛选", selection: $model.taskFilter) { Text("全部").tag("all"); Text("进行中").tag("active"); Text("已完成").tag("complete"); Text("需处理").tag("attention") }.pickerStyle(.segmented).labelsHidden().frame(width: 340)
                Spacer()
                Button("清理已结束任务…", systemImage: "trash") { showTaskCleanup = true }
                    .disabled(model.clearingTasks || !model.tasks.contains { !$0.active })
                Button("挂载全部") { model.send("mount", visible: true) { _ in model.refresh() } }
            }.padding(.horizontal, 18)
            HSplitView {
                List(selection: $model.selectedTask) {
                    ForEach(model.visibleTasks) { task in
                        HStack(alignment: .top, spacing: 8) {
                            if task.phase == "running" { ProgressView().controlSize(.small) }
                            else { Image(systemName: task.phase == "complete" ? "checkmark.circle" : task.attention ? "exclamationmark.circle" : "clock").foregroundStyle(task.attention ? Color.orange : Color.secondary) }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title).fontWeight(.medium)
                                Text(task.value.s("app_name", task.value.s("label"))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(task.stateName).font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5).tag(task.id)
                            .contextMenu { if !task.active { Button("清理此任务记录", role: .destructive) { model.clearTasks(task.id) }.disabled(model.clearingTasks) } }
                    }
                }.frame(minWidth: 240, idealWidth: 280, maxWidth: 350)
                ScrollView { TaskDetailView(model: model).padding(24).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
    }
}

struct TaskDetailView: View {
    @ObservedObject var model: BridgeModel
    var body: some View {
        let row = model.taskDetail, phase = row.s("phase"), active = ["queued", "running", "waiting"].contains(phase)
        VStack(alignment: .leading, spacing: 18) {
            if row.isEmpty { ContentUnavailableView("任务管理", systemImage: "list.bullet.rectangle", description: Text("选择一个任务查看阶段、结果与恢复操作。关闭窗口后，任务继续在后台执行。")) }
            else {
                Text(actionNames[row.s("action")] ?? "后台任务").font(.title2.weight(.semibold))
                if !row.s("app_name").isEmpty { Text(row.s("app_name")).foregroundStyle(.secondary) }
                Text(row.s("label", "排队中")).font(.headline)
                if active {
                    if row.n("total") > 0 { ProgressView(value: min(row.d("done"), row.d("total")), total: row.d("total")) }
                    else { ProgressView().progressViewStyle(.linear) }
                } else { Label(phase == "complete" ? "任务已完成" : phase == "stopped" ? "已安全停止" : phase == "interrupted" ? "上次任务中断" : "任务未完成", systemImage: phase == "complete" ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(phase == "complete" ? .green : .orange) }
                let elapsed = row.d("elapsed") + (active ? max(0, Date().timeIntervalSince1970 - row.d("updated_ns") / 1e9) : 0)
                Text("已用 \(Int(elapsed)) 秒").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                if row.n("total") > 0 {
                    LabeledContent("已处理", value: formattedBytes(row["done"]) + " / " + formattedBytes(row["total"]))
                    LabeledContent("速度", value: formattedBytes(row["rate"]) + "/秒")
                    if row.d("rate") > 0 && active { Text("预计剩余 \(Int(max(0, (row.d("total") - row.d("done")) / row.d("rate")))) 秒").font(.caption).foregroundStyle(.secondary) }
                }
                if row.n("path_total") > 1 { Text((row.s("action") == "scan_sizes" ? "应用 " : "数据目录 ") + "\(row.n("path_index")) / \(row.n("path_total"))").font(.caption).foregroundStyle(.secondary) }
                if !row.s("note").isEmpty { Text(row.s("note")).foregroundStyle(.secondary).textSelection(.enabled) }
                if !row.s("message").isEmpty { Text(row.s("message")).foregroundStyle(.orange).textSelection(.enabled) }
                let results = row.o("results")
                ForEach(results.keys.sorted(), id: \.self) { key in
                    let item = results.o(key)
                    VStack(alignment: .leading, spacing: 4) {
                        Label(item.s("name", key) + " · " + item.s("message"), systemImage: item.b("ok") ? "checkmark.circle" : "clock").font(.callout)
                        if !item.s("launch_note").isEmpty { Text(item.s("launch_note")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                HStack {
                    if active { Button("安全停止") { model.send("cancel", ["task_id": row.s("id")]) } }
                    else if ["failed", "stopped", "interrupted"].contains(phase) && !row.s("action").hasPrefix("delete_") {
                        Button("重试 / 继续") { model.send("retry_task", ["task_id": row.s("id")]) { response in if !response.o("result").s("task_id").isEmpty { model.selectedTask = response.o("result").s("task_id") } } }
                    }
                    if row.s("reason") == "authorization" { Button("前往授权", action: model.openAuthorization) }
                }
                if let app = model.apps.first(where: { $0.id == row.s("group_id", row.s("app_id")) }), app.pending {
                    Divider(); Text("等待应用验收").font(.headline)
                    Text("打开应用检查旧记录、图片、附件和搜索。确认正常后才加入自动挂载。").foregroundStyle(.secondary)
                    HStack { Button("挂载后打开应用") { model.openApp(app) }; Button("记录正常，完成迁移") { model.perform("confirm", app: app) }.buttonStyle(.borderedProminent) }
                }
            }
        }
    }
}

struct WorkflowSheet: View {
    @ObservedObject var model: BridgeModel
    let flow: BridgeFlow
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Image(nsImage: NSWorkspace.shared.icon(forFile: flow.app.value.s("app_path"))).resizable().frame(width: 40, height: 40); Text((flow.kind == "restore" ? "还原 " : flow.kind == "accept" ? "验收 " : flow.kind == "recover" ? "继续 " : "迁移 ") + flow.app.name).font(.title2.weight(.semibold)) }
            if !model.error.isEmpty { Text(model.error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if flow.kind == "accept" {
                Text("请检查全部选中目录对应的旧记录、附件和搜索。确认后加入自动挂载，原件备份不会自动清理。")
                HStack { Button("挂载就绪后打开") { model.openApp(flow.app) }; Button("记录正常，完成迁移") { dismiss(); model.perform("confirm", app: flow.app) }.buttonStyle(.borderedProminent) }
            } else if flow.kind == "recover" {
                Text("盘桥会根据已保存的阶段核对数据，继续迁移或还原。已有副本与原件保留，请先完全退出应用。")
                Button("检查并继续任务") { dismiss(); model.perform("recover", app: flow.app) }.buttonStyle(.borderedProminent)
            } else if let plan = model.plan {
                if flow.kind == "restore" {
                    LabeledContent("待还原数据", value: formattedBytes(plan["bytes"]))
                    LabeledContent("内置硬盘可用", value: formattedBytes(plan["free"]))
                    ForEach(plan["paths"] as? [String] ?? [], id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    Text("将同步外置盘的最新数据并校验，再切回内置硬盘。外置副本与原件备份默认保留，之后可以单独清理。").foregroundStyle(.secondary)
                    if !plan.b("enough_space") { Text("内置硬盘空间不足，不能开始还原。").foregroundStyle(.orange) }
                } else {
                    LabeledContent("数据量", value: formattedBytes(plan["bytes"]))
                    LabeledContent("文件数量", value: "\(plan.n("files"))")
                    Text("选中的迁移范围").font(.headline)
                    ForEach(plan["sources"] as? [String] ?? [], id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    Text("外置目标").font(.headline); Text(plan.s("destination")).font(.caption).textSelection(.enabled)
                    if plan.b("retained_copy_preserved") { Text("目标目录已有保留副本，本轮使用独立子目录，旧副本不动。").font(.caption).foregroundStyle(.secondary) }
                    Text("先复制并完整校验所有目录，再切换挂载。内置原件保留；验收与原件清理是后续独立操作。").foregroundStyle(.secondary)
                }
            } else if flow.kind == "restore" {
                Text("请先完全退出应用，并确认外置盘已连接、数据已挂载。盘桥会先核对所需空间，再由你确认开始还原。")
            } else {
                Picker("目标硬盘", selection: $model.targetDisk) {
                    Text("选择外置硬盘").tag("")
                    ForEach(model.disks.indices, id: \.self) { index in let disk = model.disks[index]; Text(disk.s("name") + " · 可用 " + formattedBytes(disk["free"])).tag(disk.s("uuid")) }
                }
                TextField("外置盘内的目录", text: $model.targetFolder).textFieldStyle(.roundedBorder)
                HStack { Text("选择要迁移的数据目录").font(.headline); Spacer(); Button("添加目录…", action: model.addSources) }
                Text("依据应用标识、实际容器与共享组发现，不使用应用白名单。请核对范围，多账号数据目录可一并选择。").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.candidates.isEmpty { Text("尚未发现具体目录，可以手动添加。").foregroundStyle(.secondary) }
                        ForEach(model.candidates.indices, id: \.self) { index in let item = model.candidates[index]
                            Toggle(isOn: Binding(get: { model.chosenSources.contains(item.s("path")) }, set: { if $0 { model.chosenSources.insert(item.s("path")) } else { model.chosenSources.remove(item.s("path")) } })) {
                                VStack(alignment: .leading, spacing: 3) { Text(item.s("path")).font(.callout).textSelection(.enabled); Text(item.s("label")).font(.caption).foregroundStyle(item.b("shared") ? Color.orange : Color.secondary) }
                            }.toggleStyle(.checkbox)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 100, maxHeight: 240)
                if model.candidates.contains(where: { $0.b("shared") && model.chosenSources.contains($0.s("path")) }) { Toggle("我确认共享目录的范围，了解它可能影响其他应用", isOn: $model.sharedConfirmed).toggleStyle(.checkbox) }
                Text("请先用 ⌘Q 完全退出应用及其他账号窗口。").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                if model.planBusy { ProgressView().controlSize(.small); Text("正在核对数据与容量…").font(.caption).foregroundStyle(.secondary) }
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                if ["migrate", "restore"].contains(flow.kind) {
                    if model.plan == nil {
                        Button(flow.kind == "restore" ? "核对还原空间" : "查看迁移预览", action: model.preview)
                            .disabled(model.planBusy || (flow.kind == "migrate" && (model.chosenSources.isEmpty || model.targetDisk.isEmpty || model.targetFolder.isEmpty)))
                    } else {
                        Button("返回修改") { model.plan = nil }
                        Button(flow.kind == "restore" ? "开始还原" : "开始迁移", action: model.startPlan).buttonStyle(.borderedProminent)
                            .disabled(flow.kind == "restore" && !(model.plan?.b("enough_space") ?? false))
                    }
                }
            }
        }.padding(26).frame(width: 650)
    }
}

struct OriginalCleanupSheet: View {
    @ObservedObject var model: BridgeModel
    let app: BridgeApp
    @Environment(\.dismiss) var dismiss
    @State private var phrase = ""
    var expected: String { deletionConfirmation }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("清理 \(app.name) 原件备份").font(.title2.weight(.semibold))
            Text("清理前会核对备份内容与身份。请先完全退出应用；当前工作数据继续保留。删除后不能从盘桥撤销。")
            ForEach(app.paths.filter { $0.b("original_retained") }.indices, id: \.self) { index in Text(app.paths.filter { $0.b("original_retained") }[index].s("original")).font(.caption).textSelection(.enabled) }
            Text("请输入：" + expected); TextField("确认短语", text: $phrase)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("确认删除", role: .destructive) { dismiss(); model.perform(app.value.b("archived") ? "delete_archived_original" : "delete_original", app: app, values: ["phrase": phrase]) }.disabled(phrase != expected) }
        }.padding(26).frame(width: 570)
    }
}
struct RetainedCleanupSheet: View {
    @ObservedObject var model: BridgeModel
    let copy: Object
    @Environment(\.dismiss) var dismiss
    @State private var phrase = ""
    var expected: String { deletionConfirmation }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("清理还原后保留的副本").font(.title2.weight(.semibold))
            Text(copy.s("name") + " · " + formattedBytes(copy["bytes"]))
            Text(copy.s("folder")).font(.caption).textSelection(.enabled)
            Text("会先只读核对镜像身份，正在使用的工作卷不能清理。此操作永久删除该外置副本，不影响已还原的工作数据。")
            Text("请输入：" + expected); TextField("确认短语", text: $phrase)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("确认删除", role: .destructive) { dismiss(); model.send("delete_retained", ["copy_id": copy.s("id"), "archived": copy.b("archived"), "phrase": phrase], visible: true) { _ in model.refresh() } }.disabled(phrase != expected) }
        }.padding(26).frame(width: 550)
    }
}

struct BridgeSettingsView: View {
    @ObservedObject var model: BridgeModel
    @State private var directory = "Cache"
    var body: some View {
        Form {
            Section("启动与自动挂载") {
                Toggle("登录时启动盘桥", isOn: Binding(get: { model.preferences.b("login_start", true) }, set: { model.preference("login_start", $0) }))
                Toggle("自动挂载已启用的应用", isOn: Binding(get: { model.preferences.b("automatic", true) }, set: { model.preference("automatic", $0) }))
                Text("硬盘晚就绪或应用仍在运行时限时重试。关闭窗口后，已提交任务继续在后台执行。").font(.caption).foregroundStyle(.secondary)
            }
            Section("迁移目录") {
                HStack { TextField("默认目录前缀", text: $directory); Button("保存") { model.preference("default_directory", directory) } }
                Text("默认 Cache/应用名称；每次迁移仍可修改，并明确确认数据范围。").font(.caption).foregroundStyle(.secondary)
            }
            Section("通知") {
                Toggle("迁移完成与异常通知", isOn: Binding(get: { model.preferences.b("notifications") }, set: { enabled in
                    if enabled { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { accepted, _ in DispatchQueue.main.async { if accepted { model.preference("notifications", true) } } } }
                    else { model.preference("notifications", false) }
                }))
                Text("日常成功挂载不反复通知。").font(.caption).foregroundStyle(.secondary)
            }
            Section("原生后台授权") {
                Label(model.authorizationChecked ? (model.needsAuthorization ? "需要授权" : "后台权限检查通过") : "启动时自动检查权限", systemImage: model.authorizationChecked && !model.needsAuthorization ? "checkmark.circle" : "lock.shield")
                Text("盘桥直接管理迁移与挂载，不依赖 Python。系统访问权限授予盘桥本身。")
                HStack { Button("前往授权", action: model.openAuthorization); Button("重新检查", action: model.recheckAuthorization) }
            }
        }.formStyle(.grouped).padding(10).frame(width: 550, height: 470)
            .onAppear { directory = model.preferences.s("default_directory", "Cache") }
    }
}
