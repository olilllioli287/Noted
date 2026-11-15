// Noted: 設定頁裡「同時輸出時對齊延遲」那一段。
// 本檔是 FineTuneKit（GPL-3.0）的一部分。
import SwiftUI

public struct OutputAlignmentSettings: View {
    @ObservedObject private var module = FineTuneModule.shared

    public init() {}

    public var body: some View {
        Toggle("對齊輸出裝置延遲", isOn: Binding(get: { module.alignmentEnabled }, set: { module.alignmentEnabled = $0 }))
        Text("這項設定保留供多裝置路由使用；目前輸出裝置採單選。")
            .font(.caption).foregroundStyle(.secondary)
        let rows = module.alignmentRows
        if rows.isEmpty {
            Text("目前輸出裝置採單選，沒有需要對齊的多裝置延遲。")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(row.name)
                        Spacer()
                        Text(detail(row)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack {
                        Text("微調").font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { row.trimMs }, set: { module.setAlignmentTrim(uid: row.id, ms: ($0 / 5).rounded() * 5) }),
                               in: FineTuneModule.alignmentTrimRange)
                        Text(String(format: "%+.0f 毫秒", row.trimMs)).monospacedDigit().frame(width: 72, alignment: .trailing)
                        Button("歸零") { module.setAlignmentTrim(uid: row.id, ms: 0) }.disabled(row.trimMs == 0)
                    }
                }
                .disabled(!module.alignmentEnabled)
            }
            Text("裝置回報的延遲不一定準。聽到兩聲（回音）時：哪個裝置先響，就把它的微調往右拉（更晚），拉到兩聲疊成一聲。可以用 tools/align-click.swift 播每秒一聲的短音來對。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func detail(_ row: FineTuneModule.AlignmentRow) -> String {
        let reported = row.reportedMs.map { String(format: "系統回報 %.0f 毫秒", $0) } ?? "系統沒有回報延遲"
        return reported + String(format: "，現在加 %.0f 毫秒", row.delayMs)
    }
}
