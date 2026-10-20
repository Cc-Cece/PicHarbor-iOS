import SwiftUI

struct PipelineAdvancedView: View {
    @EnvironmentObject private var model: HarborModel
    @ObservedObject private var language = LanguagePreferences.shared
    @State private var custom = false
    @State private var fields = ["1", "2", "4", "2", "1", "512"]
    private var titles: [String] { [L10n.text("准备照片"), L10n.text("上传检查"), L10n.text("文件上传"), L10n.text("保存与配对"), L10n.text("云端确认"), L10n.text("缓存上限（MB）")] }
    var body: some View {
        Form {
            Section { Toggle(L10n.text("使用自定义配置"), isOn: $custom) }
            if custom {
                Section {
                    ForEach(0..<6, id: \.self) { index in
                        HStack {
                            Text(titles[index]); Spacer()
                            TextField(titles[index], text: $fields[index]).keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing).frame(width: 90).accessibilityIdentifier("pipeline.field.\(index)")
                        }
                    }
                } footer: { Text(L10n.text("准备照片 1–3，上传检查、保存与配对、云端确认 1–4，文件上传 1–12，缓存 128–8192 MB。")) }
            }
            Section {
                Button(L10n.text("应用设置")) { apply() }.disabled(model.switching || model.updatingNetwork || !model.initialized)
            } footer: { Text(L10n.text("资源紧张时会自动降低并发。减少数量不会中断已开始的上传。单个大文件可能超过缓存上限。")) }
            Section {
                Button(L10n.text("恢复自动管理")) {
                    custom = false
                    var settings = model.settings; settings.pipelineMode = .automatic; settings.pipelineOverrides = nil; model.settings = settings
                    Task { await model.saveSettings() }
                }
            }
        }.navigationTitle(L10n.text("高级配置")).navigationBarTitleDisplayMode(.inline)
        .onAppear {
            custom = model.settings.pipelineMode == .custom
            let value = model.settings.pipelineOverrides ?? PipelineProfiles.recommended(model.pipelineDevice)
            fields = [value.preparation, value.lookup, value.upload, value.commit, value.confirmation, value.bufferMB].map(String.init)
        }
    }
    private func apply() {
        var settings = model.settings
        if custom {
            let values = fields.compactMap(Int.init)
            guard values.count == 6 else { model.notice = L10n.text("请输入范围内的整数。"); return }
            let value = PipelineLimits(preparation: values[0], lookup: values[1], upload: values[2], commit: values[3], confirmation: values[4], bufferMB: values[5])
            guard value.valid else { model.notice = L10n.text("请输入范围内的整数。"); return }
            settings.pipelineMode = .custom; settings.pipelineOverrides = value
        } else { settings.pipelineMode = .automatic }
        model.settings = settings
        Task { await model.saveSettings() }
    }
}

struct PipelineActivitySummary: View {
    @EnvironmentObject private var model: HarborModel
    @ObservedObject private var language = LanguagePreferences.shared
    var ids: Set<String>?
    var body: some View {
        let counts = model.pipelineActivity(ids: ids)
        if counts.values.contains(where: { $0 > 0 }) {
            Text(L10n.text("准备中 {0} · 上传中 {1} · 确认中 {2}", [String((counts[.preparation] ?? 0) + (counts[.lookup] ?? 0)), String(counts[.upload] ?? 0), String((counts[.commit] ?? 0) + (counts[.confirmation] ?? 0))]))
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("pipeline.activity")
        }
    }
}
