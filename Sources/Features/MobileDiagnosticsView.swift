import SwiftUI

struct MobileDiagnosticsView: View {
    @EnvironmentObject private var model: HarborModel
    @State private var all = true
    @State private var from = Date()
    @State private var to = Date()
    @State private var preparing = false
    @State private var archive: URL?
    @State private var error = ""
    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("全部现存日志"), isOn: $all)
                if !all {
                    DatePicker(L10n.text("开始日期"), selection: $from, displayedComponents: .date)
                    DatePicker(L10n.text("结束日期"), selection: $to, in: from..., displayedComponents: .date)
                }
                Button(L10n.text("准备导出")) {
                    preparing = true; error = ""; archive = nil
                    Task {
                        do {
                            let calendar = Calendar.current
                            archive = try await MobileDiagnostics.shared.export(from: all ? nil : calendar.startOfDay(for: from),
                                to: all ? nil : calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)), summary: model.diagnostics)
                        } catch { self.error = L10n.text("导出失败，请重试。") }
                        preparing = false
                    }
                }.disabled(preparing || (!all && from > to))
                if preparing { ProgressView() }
                if let archive { ShareLink(item: archive) { Label(L10n.text("导出脱敏诊断"), systemImage: "square.and.arrow.up") } }
                if !error.isEmpty { Text(error) }
            } footer: { Text(L10n.text("日志默认持续记录，保留 14 天或 64 MiB。导出包含 JSONL 和可读文本，不包含账号、凭据或媒体内容。")) }
        }.navigationTitle(L10n.text("诊断"))
    }
}
