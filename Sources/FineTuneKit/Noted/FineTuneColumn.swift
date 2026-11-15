// Noted: 瀏海面板左欄的精簡音量面板。上游的完整面板寬 470～560 點，左欄只有約 320 點，所以另外寫一個。
// 本檔是 FineTuneKit（GPL-3.0）的一部分。
import AppKit
import SwiftUI

/// 左欄：上半是輸出裝置（單選），下半是各 App 音量。
/// EQ、AutoEQ、每 App 路由、輸入裝置在上游原本的完整面板裡（`FineTuneModule.toggleFullPanel`）。
public struct FineTuneColumn: View {
    @ObservedObject private var module = FineTuneModule.shared
    private let fg: Color
    private let accent: Color
    private let isLight: Bool
    /// 科幻藍風格：裝置開關畫成發光的斜切角方塊、滑塊畫成菱形（數值跟 Noted 的 HUDLook 同一組）
    private let hud: Bool

    public init(fg: Color, accent: Color, isLight: Bool, hud: Bool = false) {
        self.fg = fg
        self.accent = accent
        self.isLight = isLight
        self.hud = hud
    }

    public var body: some View {
        Group {
            switch module.state {
            case .running:
                if let engine = module.engine, let monitor = engine.deviceVolumeMonitor as? DeviceVolumeMonitor {
                    ColumnBody(engine: engine, monitor: monitor, fg: fg, accent: accent, hud: hud)
                        .allowsHitTesting(!module.isDryRun)
                }
            case .standby:
                notice("獨立版 FineTune 還在執行", "兩邊同時控制會把聲音播兩次。結束它之後，這一欄會自己接手。")
            case .off:
                notice("音量功能已關閉", "可以在設定裡打開。")
            }
        }
        .environment(\.colorScheme, isLight ? .light : .dark)
    }

    private func notice(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.wave.2").font(.system(size: 20)).opacity(0.45)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).opacity(0.6).multilineTextAlignment(.center)
        }
        .foregroundStyle(fg)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ColumnBody: View {
    @Bindable var engine: AudioEngine
    @Bindable var monitor: DeviceVolumeMonitor
    let fg: Color
    let accent: Color
    let hud: Bool

    private var policy: OutputPolicy { engine.outputPolicy }

    /// 列的底：原生是圓角，科幻藍是斜切角加細框
    @ViewBuilder private func rowBackground(_ on: Bool) -> some View {
        if hud {
            HUDChamfer(cut: 6).fill(accent.opacity(on ? 0.1 : 0))
                .overlay(HUDChamfer(cut: 6).stroke(accent.opacity(on ? 0.45 : 0), lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fg.opacity(on ? 0.07 : 0))
        }
    }

    private var devices: [AudioDevice] {
        policy.orderedDevices.filter { !engine.settingsManager.isOutputDeviceHidden($0.uid) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 3) {
                header("輸出", detail: outputSummary)
                ForEach(devices) { device in deviceRow(device) }
                if devices.isEmpty { hint("沒有輸出裝置") }
                if !policy.isArmed {
                    banner("還沒接管：現在只是顯示系統的預設輸出，斷線時不會幫你擋外放。勾選任何一個裝置，或按右邊開始。",
                           action: "照現在這樣開始") { policy.armWithCurrentDefault() }
                }

                header("App", detail: nil).padding(.top, 6)
                if engine.permission.status != .authorized {
                    banner("各 App 音量需要「螢幕與系統錄音」權限。", action: "授權") { engine.permission.request() }
                } else if engine.displayableApps.isEmpty {
                    hint("目前沒有 App 在出聲")
                } else {
                    ForEach(engine.displayableApps) { item in appRow(item) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .foregroundStyle(fg)
    }

    private var outputSummary: String? {
        guard policy.isArmed else { return nil }
        let count = (policy.targets ?? []).count
        return count == 0 ? "全部靜音" : nil
    }

    private func header(_ title: String, detail: String?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).opacity(0.45)
            if let detail {
                Text(detail).font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(accent.opacity(0.22), in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: 18)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5)).opacity(0.5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4).padding(.vertical, 2)
    }

    private func banner(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(text).font(.system(size: 10.5)).opacity(0.75).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action, action: perform).buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(accent.opacity(0.3), in: Capsule())
        }
        .padding(6)
        .background(fg.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: 裝置列

    private func deviceRow(_ device: AudioDevice) -> some View {
        let selected = policy.isSelected(device.uid)
        let tier = engine.outputVolumeBackend(for: device.id)
        let muted = monitor.muteStates[device.id] ?? false
        let gain = monitor.volumes[device.id] ?? 0
        let fraction = VolumeMapping.sliderFraction(forSystemGain: gain, tier: tier)
        let symbol = engine.settingsManager.getDeviceIconOverride(for: device.uid)
        return HStack(spacing: 6) {
            // 裝置圖示本身就是開關（上游 DeviceBadge 的樣子）：啟用是藍底白圖示，沒啟用是灰底。
            // 還沒接管時，預設輸出畫成灰底加藍色虛線圈：只是顯示現況，不是已經勾了。
            Button { policy.toggle(device.uid) } label: {
                OutputToggleBadge(icon: device.icon, symbol: symbol,
                                  state: selected ? (policy.isArmed ? .on : .pending) : .off, fg: fg,
                                  hudAccent: hud ? accent : nil)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(selected ? "按一下取消：這個裝置不出聲" : "按一下啟用：從這個裝置出聲")

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(device.name).font(.system(size: 11.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                    if policy.unmutableDevices.contains(device.uid) {
                        Label("無法靜音", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1)
                    }
                }
                MiniSlider(value: fraction, tint: selected ? accent : fg.opacity(0.4), track: fg.opacity(0.14), diamond: hud) { new in
                    guard !policy.isArmed || selected else { return }
                    monitor.setVolume(for: device.id, to: VolumeMapping.systemGain(forSliderFraction: new, tier: tier))
                }
                .frame(height: 12)
            }

            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 10.5, design: .rounded)).monospacedDigit()
                .opacity(0.65).frame(width: 34, alignment: .trailing)

            Button {
                guard !policy.isArmed || selected else { return }
                monitor.setMute(for: device.id, to: !muted)
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(muted ? Color.red.opacity(0.85) : fg.opacity(0.6))
                    .frame(width: 20, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 沒勾選的裝置一律靜音，這顆按了也會被蓋回去
            .disabled(policy.isArmed && !selected)
            .help(policy.isArmed && !selected ? "沒勾選的裝置一律靜音" : (muted ? "解除靜音" : "靜音"))
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(rowBackground(selected))
        .opacity(selected || !policy.isArmed ? 1 : 0.55)
    }

    // MARK: App 列

    @ViewBuilder private func appRow(_ item: DisplayableApp) -> some View {
        switch item {
        case .active(let app):
            let gain = engine.getVolume(for: app)
            let muted = engine.getMute(for: app)
            appRowView(icon: app.icon, name: app.name, fraction: VolumeMapping.gainToSlider(gain), muted: muted, dim: false,
                       onVolume: { engine.setVolume(for: app, to: VolumeMapping.sliderToGain($0)) },
                       onMute: { engine.setMute(for: app, to: !muted) })
        case .pinnedInactive(let info):
            let id = info.persistenceIdentifier
            let gain = engine.getVolumeForInactive(identifier: id)
            let muted = engine.getMuteForInactive(identifier: id)
            appRowView(icon: Self.icon(forBundleID: info.bundleID), name: info.displayName,
                       fraction: VolumeMapping.gainToSlider(gain), muted: muted, dim: true,
                       onVolume: { engine.setVolumeForInactive(identifier: id, to: VolumeMapping.sliderToGain($0)) },
                       onMute: { engine.setMuteForInactive(identifier: id, to: !muted) })
        }
    }

    private static func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func appRowView(icon: NSImage?, name: String, fraction: Double, muted: Bool, dim: Bool,
                            onVolume: @escaping (Double) -> Void, onMute: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Group {
                if let icon { Image(nsImage: icon).resizable().scaledToFit() } else { Image(systemName: "app.dashed") }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.system(size: 11.5)).lineLimit(1)
                MiniSlider(value: fraction, tint: accent, track: fg.opacity(0.14), diamond: hud, onChange: onVolume)
                    .frame(height: 12)
            }
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 10.5, design: .rounded)).monospacedDigit()
                .opacity(0.65).frame(width: 34, alignment: .trailing)
            Button(action: onMute) {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(muted ? Color.red.opacity(0.85) : fg.opacity(0.6))
                    .frame(width: 20, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(muted ? "解除靜音" : "靜音")
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .opacity(dim ? 0.6 : 1)
    }
}

/// 輸出裝置的開關：圓底上放裝置圖示，啟用時藍底白圖示（照上游 `DeviceBadge` 的畫法，縮小配合左欄的列高）。
struct OutputToggleBadge: View {
    enum State { case on, pending, off }
    let icon: NSImage?
    let symbol: String?
    let state: State
    let fg: Color
    /// 有給＝科幻藍風格，用這個顏色畫發光的斜切角方塊
    var hudAccent: Color?

    static let size: CGFloat = 24
    private static let glyph: CGFloat = 15
    /// 固定用系統藍：需求是「有啟用就藍色的符號」，不跟著系統強調色變
    private static let blue = Color(nsColor: .systemBlue)

    var body: some View {
        if let hudAccent { hudBody(hudAccent) } else { macBody }
    }

    private func hudBody(_ c: Color) -> some View {
        ZStack {
            switch state {
            case .on:
                HUDChamfer(cut: 6).fill(LinearGradient(colors: [c.opacity(0.95), c.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: c.opacity(0.8), radius: 4)
                HUDChamfer(cut: 6).stroke(Color.white.opacity(0.7), lineWidth: 1)
            case .pending:
                HUDChamfer(cut: 6).fill(c.opacity(0.1))
                HUDChamfer(cut: 6).stroke(c, style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2.5]))
            case .off:
                HUDChamfer(cut: 6).fill(c.opacity(0.06))
                HUDChamfer(cut: 6).stroke(c.opacity(0.35), lineWidth: 1)
            }
            glyph.foregroundStyle(state == .on ? Color(red: 0.02, green: 0.08, blue: 0.14) : c.opacity(0.75))
        }
        .frame(width: Self.size, height: Self.size)
    }

    private var glyph: some View {
        Group {
            if let symbol {
                Image(systemName: symbol).resizable().scaledToFit()
            } else if let icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "speaker.wave.2.fill").resizable().scaledToFit()
            }
        }
        .frame(width: Self.glyph, height: Self.glyph)
    }

    private var macBody: some View {
        ZStack {
            switch state {
            case .on:
                Circle().fill(LinearGradient(colors: [Self.blue, Self.blue.opacity(0.78)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
            case .pending:
                Circle().fill(fg.opacity(0.14))
                Circle().strokeBorder(Self.blue, style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2.5]))
            case .off:
                Circle().fill(fg.opacity(0.14))
            }
            glyph.foregroundStyle(state == .on ? Color.white : fg.opacity(0.6))
        }
        .frame(width: Self.size, height: Self.size)
    }
}

/// 斜切角方塊（左上、右下各切一角）。科幻藍風格用；形狀自己畫，不含任何圖片。
struct HUDChamfer: Shape {
    var cut: CGFloat = 6
    func path(in r: CGRect) -> Path {
        let c = min(cut, r.width / 2, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.closeSubpath()
        return p
    }
}

/// 細細的一條滑桿：拖曳，或點一下跳到那個位置。
private struct MiniSlider: View {
    let value: Double
    let tint: Color
    let track: Color
    /// 科幻藍：滑塊畫成菱形、軌道更細
    var diamond = false
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let x = CGFloat(min(max(value, 0), 1)) * w
            ZStack(alignment: .leading) {
                if diamond {
                    Rectangle().fill(track).frame(height: 1)
                    Rectangle().fill(tint).frame(width: max(x, 0), height: 2).shadow(color: tint.opacity(0.7), radius: 2)
                    Rectangle().fill(tint).frame(width: 7, height: 7).rotationEffect(.degrees(45))
                        .overlay(Rectangle().stroke(Color.white.opacity(0.8), lineWidth: 0.8).frame(width: 7, height: 7).rotationEffect(.degrees(45)))
                        .frame(width: 9, height: 9)
                        .offset(x: min(max(x - 4.5, 0), w - 9))
                } else {
                    Capsule().fill(track).frame(height: 3)
                    Capsule().fill(tint).frame(width: max(x, 0), height: 3)
                    Circle().fill(Color.white).frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                        .offset(x: min(max(x - 4.5, 0), w - 9))
                }
            }
            .frame(width: w, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                onChange(Double(min(max(g.location.x / w, 0), 1)))
            })
        }
    }
}
