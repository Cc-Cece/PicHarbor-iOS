import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var model: HarborModel
    @AppStorage("activity.source.v2") private var sourceRaw = "all"
    @AppStorage("activity.status.v2") private var statusRaw = "all"
    var source: ActivitySource { ActivitySource(rawValue: sourceRaw) ?? .all }
    var status: ActivityStatus { ActivityStatus(rawValue: statusRaw) ?? .all }
    var batches: [ActivityBatch] { ActivityBatch.make(model.visibleJobs, source: source, status: status) }
    var filtered: [BackupJob] { batches.flatMap(\.matching) }
    var body: some View {
        List {
            Section {
                Picker("备份来源", selection: $sourceRaw) {
                    ForEach(ActivitySource.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented).accessibilityIdentifier("activity.source")
                Picker("任务状态", selection: $statusRaw) {
                    ForEach(ActivityStatus.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented).accessibilityIdentifier("activity.status")
            }
            if batches.isEmpty { ContentUnavailableView("暂无符合条件的任务", systemImage: "clock", description: Text("调整来源或状态筛选，查看其他备份活动。")) }
            ForEach(batches) { batch in
                if batch.isBatch {
                    NavigationLink { ActivityBatchView(id: batch.id, source: source, status: status) } label: { ActivityBatchCard(batch: batch) }
                } else if let job = batch.matching.first { ActivityTaskRow(job: job) }
            }
            if source == .all && status == .all && !model.engine.records.isEmpty {
                Section { NavigationLink("早期验证记录") { LegacyBackupRecordsView() } }
            }
        }.navigationTitle("活动")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ActivityActionsMenu(jobs: filtered) } }
    }
}

struct ActivityBatchCard: View {
    let batch: ActivityBatch
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(.blue).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(batch.title).font(.headline)
                Text(batch.created, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                Text("\(batch.allJobs.count) 项 · 已完成 \(batch.allJobs.filter { $0.state == .completed }.count) 项").font(.caption).foregroundStyle(.secondary)
                if batch.matching.count != batch.allJobs.count { Text("当前筛选 \(batch.matching.count) 项").font(.caption2).foregroundStyle(.secondary) }
            }
        }.padding(.vertical, 6)
    }
}

struct ActivityBatchView: View {
    @EnvironmentObject private var model: HarborModel
    let id: String
    let source: ActivitySource
    let status: ActivityStatus
    var batch: ActivityBatch? { ActivityBatch.make(model.visibleJobs, source: source, status: status).first { $0.id == id } }
    var body: some View {
        List {
            if let batch {
                Section { ActivityBatchCard(batch: batch) }
                Section("\(status.title) · \(batch.matching.count) 项") { ForEach(batch.matching) { ActivityTaskRow(job: $0) } }
            } else { ContentUnavailableView("本批暂无符合筛选的任务", systemImage: "checkmark.circle", description: Text("返回活动页可查看其他状态。")) }
        }.navigationTitle("备份批次").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ActivityActionsMenu(jobs: batch?.matching ?? []) } }
    }
}

struct ActivityTaskRow: View {
    @EnvironmentObject private var model: HarborModel
    let job: BackupJob
    @State private var removing = false
    var body: some View {
        NavigationLink { JobDetailView(id: job.id) } label: { JobRow(job: job) }
            .swipeActions { if job.unfinished { Button("移除", role: .destructive) { removing = true } } }
            .confirmationDialog("移除此任务？", isPresented: $removing, titleVisibility: .visible) {
                Button("停止并移除任务", role: .destructive) { Task { await model.removeUnfinished([job.id]) } }
            } message: { Text("停止并从活动中移除，保留本机及云端照片。同一版本仍可手动重新备份。") }
    }
}

struct ActivityActionsMenu: View {
    @EnvironmentObject private var model: HarborModel
    let jobs: [BackupJob]
    @State private var removal = Set<String>()
    @State private var removing = false
    var body: some View {
        Menu {
            Button("暂停当前结果", systemImage: "pause") { let ids = jobs.filter { $0.state.active || [.queued, .waiting].contains($0.state) }.map(\.id); Task { for id in ids { await model.pause(id) } } }
            Button("继续当前结果", systemImage: "play") { let ids = jobs.filter { [.paused, .failed, .attention].contains($0.state) }.map(\.id); Task { for id in ids { await model.resume(id) } } }
            Button("移除当前结果中的未完成任务", systemImage: "trash", role: .destructive) {
                removal = Set(jobs.filter(\.unfinished).map(\.id)); removing = true
            }.disabled(!jobs.contains(where: \.unfinished))
        } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("activity.menu")
        .confirmationDialog("移除 \(removal.count) 项未完成任务？", isPresented: $removing, titleVisibility: .visible) {
            Button("停止并移除任务", role: .destructive) { let ids = removal; Task { await model.removeUnfinished(ids) } }
        } message: { Text("仅处理当前筛选结果。本机及云端照片保留；自动备份不会重新加入已移除项目的同一版本，仍可手动重新备份。") }
    }
}

private struct LegacyBackupRecordsView: View {
    @EnvironmentObject private var model: HarborModel
    var body: some View {
        List {
            Section { ForEach(model.engine.records) { record in
                VStack(alignment: .leading, spacing: 5) { Text(record.name).lineLimit(1); Text(record.stateLabel).font(.caption).foregroundStyle(.secondary) }
            } } footer: { Text("早期内容观察记录不具有清理资格。") }
        }.navigationTitle("早期验证记录")
    }
}
