import SwiftUI

struct ActivityView: View {
    var archived = false
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    @AppStorage("activity.source.v2") private var sourceRaw = "all"
    @AppStorage("activity.status.v2") private var statusRaw = "all"
    var source: ActivitySource { ActivitySource(rawValue: sourceRaw) ?? .all }
    var status: ActivityStatus { ActivityStatus(rawValue: statusRaw) ?? .all }
    var batches: [ActivityBatch] { ActivityBatch.make(model.activityJobs(archived: archived), source: source, status: status) }
    var filtered: [BackupJob] { batches.flatMap(\.matching) }
    var body: some View {
        List {
            Section {
                Picker(L10n.text("备份来源"), selection: $sourceRaw) {
                    ForEach(ActivitySource.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented).accessibilityIdentifier("activity.source")
                Picker(L10n.text("任务状态"), selection: $statusRaw) {
                    ForEach(ActivityStatus.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented).accessibilityIdentifier("activity.status")
            }
            if batches.isEmpty { ContentUnavailableView(L10n.text("暂无符合条件的任务"), systemImage: "clock", description: Text(L10n.text("调整来源或状态筛选，查看其他备份活动。"))) }
            ForEach(batches) { batch in
                if batch.isBatch {
                    HStack {
                        if let job = batch.matching.first { AssetThumbnail(assetID: job.assetID) }
                        NavigationLink { ActivityBatchView(id: batch.id, source: source, status: status, archived: archived) } label: { ActivityBatchCard(batch: batch) }.accessibilityIdentifier("activity.batch")
                    }
                } else if let job = batch.matching.first { ActivityTaskRow(job: job) }
            }
            if archived && !model.engine.records.isEmpty {
                Section { NavigationLink { LegacyBackupRecordsView() } label: { Label(L10n.text("旧版记录"), systemImage: "clock.arrow.circlepath") } }
            }
        }.navigationTitle(archived ? L10n.text("归档记录") : L10n.text("活动"))
        .task { await model.autoArchive(force: true) }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ActivityActionsMenu(jobs: filtered, archived: archived) } }
    }
}

struct ActivityBatchCard: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let batch: ActivityBatch
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(.blue).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(batch.title).font(.headline)
                Text(L10n.date(batch.created, time: .short)).font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("{0} 项 · 已完成 {1} 项", [String(describing: batch.allJobs.count), String(describing: batch.allJobs.filter { $0.state == .completed }.count)])).font(.caption).foregroundStyle(.secondary)
                if batch.matching.count != batch.allJobs.count { Text(L10n.text("当前筛选 {0} 项", [String(describing: batch.matching.count)])).font(.caption2).foregroundStyle(.secondary) }
            }
        }.padding(.vertical, 6)
    }
}

struct ActivityBatchView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    let id: String
    let source: ActivitySource
    let status: ActivityStatus
    var archived = false
    var batch: ActivityBatch? { ActivityBatch.make(model.activityJobs(archived: archived), source: source, status: status).first { $0.id == id } }
    var body: some View {
        List {
            if let batch {
                Section { HStack { if let job = batch.matching.first { AssetThumbnail(assetID: job.assetID) }; ActivityBatchCard(batch: batch) } }
                Section(L10n.text("{0} · {1} 项", [String(describing: status.title), String(describing: batch.matching.count)])) { ForEach(batch.matching) { ActivityTaskRow(job: $0) } }
            } else { ContentUnavailableView(L10n.text("本批暂无符合筛选的任务"), systemImage: "checkmark.circle", description: Text(L10n.text("返回活动页可查看其他状态。"))) }
        }.navigationTitle(L10n.text("备份批次")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ActivityActionsMenu(jobs: batch?.matching ?? [], archived: archived) } }
    }
}

struct ActivityTaskRow: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    let job: BackupJob
    @State private var removing = false
    var body: some View {
        HStack {
            AssetThumbnail(assetID: job.assetID)
            NavigationLink { JobDetailView(id: job.id) } label: { JobRow(job: job) }
                .accessibilityIdentifier("activity.task.\(job.id)")
        }
            .swipeActions {
                if job.state == .completed {
                    Button(job.archivedAt == nil ? L10n.text("归档") : L10n.text("取消归档"), systemImage: "archivebox") { Task { await model.archive([job.id], restoring: job.archivedAt != nil) } }.tint(.blue)
                } else if job.unfinished { Button(L10n.text("移除"), role: .destructive) { removing = true } }
            }
            .confirmationDialog(L10n.text("移除此任务？"), isPresented: $removing, titleVisibility: .visible) {
                Button(L10n.text("停止并移除任务"), role: .destructive) { Task { await model.removeUnfinished([job.id]) } }
            } message: { Text(L10n.text("停止并从活动中移除，保留本机及云端照片。同一版本仍可手动重新备份。")) }
    }
}

struct ActivityActionsMenu: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    let jobs: [BackupJob]
    var archived = false
    @State private var removal = Set<String>()
    @State private var removing = false
    @State private var archives = false
    @State private var selecting = false
    var body: some View {
        Menu {
            if !archived { Section {
                Button(L10n.text("暂停任务"), systemImage: "pause") { let ids = jobs.filter { $0.state.active || [.queued, .waiting].contains($0.state) }.map(\.id); Task { for id in ids { await model.pause(id) } } }.disabled(!jobs.contains { $0.state.active || [.queued, .waiting].contains($0.state) })
                Button(L10n.text("继续任务"), systemImage: "play") { let ids = jobs.filter { [.paused, .failed, .attention].contains($0.state) }.map(\.id); Task { for id in ids { await model.resume(id) } } }.disabled(!jobs.contains { [.paused, .failed, .attention].contains($0.state) })
            } }
            Section {
            Button(archived ? L10n.text("选择取消归档") : L10n.text("选择归档"), systemImage: "checkmark.circle") { selecting = true }.disabled(!jobs.contains { $0.state == .completed })
            Button(archived ? L10n.text("取消归档全部") : L10n.text("归档已完成"), systemImage: "archivebox") {
                let ids = Set(jobs.filter { $0.state == .completed }.map(\.id))
                Task { await model.archive(ids, restoring: archived) }
            }.disabled(!jobs.contains { $0.state == .completed })
            }
            if !archived { Section { Button(L10n.text("已归档"), systemImage: "archivebox.fill") { archives = true } } }
            if !archived {
            Section { Button(L10n.text("移除未完成"), systemImage: "trash", role: .destructive) {
                removal = Set(jobs.filter(\.unfinished).map(\.id)); removing = true
            }.disabled(!jobs.contains(where: \.unfinished)) }
            }
        } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("activity.menu")
        .sheet(isPresented: $archives) {
            NavigationStack { ActivityView(archived: true).toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("关闭")) { archives = false } } } }
        }
        .sheet(isPresented: $selecting) {
            NavigationStack { ActivityArchiveSelectionView(ids: Set(jobs.filter { $0.state == .completed }.map(\.id)), restoring: archived).toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { selecting = false } } } }
        }
        .confirmationDialog(L10n.text("移除 {0} 项未完成任务？", [String(describing: removal.count)]), isPresented: $removing, titleVisibility: .visible) {
            Button(L10n.text("停止并移除任务"), role: .destructive) { let ids = removal; Task { await model.removeUnfinished(ids) } }
        } message: { Text(L10n.text("仅处理当前筛选结果。本机及云端照片保留；自动备份不会重新加入已移除项目的同一版本，仍可手动重新备份。")) }
    }
}

struct ActivityArchiveSelectionView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    @Environment(\.dismiss) private var dismiss
    let ids: Set<String>
    let restoring: Bool
    @State private var selected = Set<String>()
    var jobs: [BackupJob] { model.activityJobs(archived: restoring).filter { ids.contains($0.id) && $0.state == .completed } }
    var body: some View {
        List {
            Section {
                Button(L10n.text("全选")) { selected = Set(jobs.map(\.id)) }
                Button(L10n.text("取消全选")) { selected = [] }
                Button(restoring ? L10n.text("取消归档所选") : L10n.text("归档所选")) {
                    let values = selected; Task { await model.archive(values, restoring: restoring); dismiss() }
                }.disabled(selected.isEmpty)
            }
            ForEach(jobs) { job in
                HStack {
                    AssetThumbnail(assetID: job.assetID)
                    Button {
                        if !selected.insert(job.id).inserted { selected.remove(job.id) }
                    } label: {
                        HStack { JobRow(job: job); Image(systemName: selected.contains(job.id) ? "checkmark.circle.fill" : "circle") }
                    }.buttonStyle(.plain)
                }
            }
        }.navigationTitle(restoring ? L10n.text("取消归档") : L10n.text("归档记录"))
    }
}

private struct LegacyBackupRecordsView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    var body: some View {
        List {
            Section { ForEach(model.engine.records) { record in
                HStack { AssetThumbnail(assetID: ""); VStack(alignment: .leading, spacing: 5) { Text(record.name).lineLimit(1).truncationMode(.middle); Text(record.stateLabel).font(.caption).foregroundStyle(.secondary) } }
            } } footer: { Text(L10n.text("历史记录未关联本机照片，不用于空间清理。")) }
        }.navigationTitle(L10n.text("旧版记录"))
    }
}
