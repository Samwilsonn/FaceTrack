import SwiftUI
import PhotosUI
import UIKit

private enum RemotePanel: String, CaseIterable, Identifiable {
    case face = "FaceTrack", background = "Background", exposure = "AE", whiteBalance = "WB", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .face: "viewfinder"
        case .background: "person.crop.rectangle"
        case .exposure: "sun.max"
        case .whiteBalance: "thermometer.sun"
        case .settings: "gearshape"
        }
    }
}

private struct RemoteItem: Identifiable {
    let id: String
    let name: String
    let thumbnail: UIImage?
}

struct RemoteScreen: View {
    @AppStorage("appMode") private var mode = "host"
    @StateObject private var peer = PeerControl(role: .remote)
    @StateObject private var preview = RemotePreviewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var previewEnabled = false
    @State private var code = ""
    @State private var panel: RemotePanel?
    @State private var focusedPanel: RemotePanel?
    @State private var photo: PhotosPickerItem?
    @State private var showPhotoPicker = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().onTapGesture { withAnimation(.spring()) { panel = nil; focusedPanel = nil } }
            VStack(spacing: 16) {
                HStack {
                    Button { mode = "host" } label: { Label("Host", systemImage: "camera") }
                    Spacer()
                    Label(peer.authorized ? "Connected" : peer.connected ? "Pair" : "Discovering", systemImage: peer.authorized ? "wifi" : "wifi.slash")
                        .foregroundStyle(peer.authorized ? Color.green : Color.secondary)
                }.font(.subheadline.weight(.medium))
                Spacer()
                if peer.authorized {
                    if previewEnabled && scenePhase == .active {
                        RemotePreviewView(decoder: preview.decoder)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .overlay(alignment: .topLeading) { Text(preview.status).font(.caption).padding(8) }
                    }
                    if let panel { controls(panel).contentShape(Rectangle()).onTapGesture {} }
                    HStack(spacing: 8) {
                        ForEach(RemotePanel.allCases) { item in
                            Button { withAnimation(.interpolatingSpring(stiffness: 300, damping: 20)) {
                                if focusedPanel == item { panel = panel == item ? nil : item }
                                else { focusedPanel = item; panel = nil }
                            } } label: {
                                Image(systemName: item.symbol).font(.system(size: 18, weight: .semibold))
                                    .frame(width: 44, height: 44)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .background(panel == item ? Color.white.opacity(0.55) : .clear, in: Capsule())
                                    .foregroundStyle(panel == item ? Color.black : Color.white)
                                    .scaleEffect(panel == item ? 1.3 : focusedPanel == item ? 1.15 : focusedPanel == nil ? 1 : panel == nil ? 0.9 : 0.8)
                                    .frame(width: 44, height: 44)
                            }
                            .blur(radius: panel != nil && panel != item ? 1.5 : 0)
                            .opacity(panel != nil && panel != item ? 0.55 : 1)
                            .zIndex(focusedPanel == item ? 1 : 0)
                            .accessibilityLabel(item.rawValue)
                        }
                    }
                    Button {
                        peer.command("stream", value: !(peer.state["streaming"] as? Bool ?? false))
                    } label: {
                        Circle().fill(peer.state["streaming"] as? Bool == true ? Color.red : Color.white)
                            .frame(width: 64, height: 64).overlay(Circle().stroke(.white, lineWidth: 3))
                    }.accessibilityLabel(peer.state["streaming"] as? Bool == true ? "Stop stream" : "Start stream")
                } else {
                    pairing
                }
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
        .buttonStyle(LiquidGlassButtonStyle())
        .onChange(of: previewConfiguration) { syncPreview() }
        .onChange(of: peer.authorized) { requestPreview() }
        .onChange(of: scenePhase) { requestPreview() }
        .onDisappear {
            if peer.authorized { peer.command("livePreview", value: false) }
            previewEnabled = false
            preview.stop()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photo, matching: .images)
        .task(id: photo) {
            guard let photo, let data = try? await photo.loadTransferable(type: Data.self) else { return }
            peer.command("uploadBackground", value: data.base64EncodedString())
            self.photo = nil
        }
    }

    private var previewConfiguration: String {
        "\(peer.authorized)-\(peer.state["streaming"] as? Bool ?? false)-\(peer.state["livePreview"] as? Bool ?? false)-" + text("previewName") + text("previewToken")
    }

    private func requestPreview() {
        if peer.authorized { peer.command("livePreview", value: previewEnabled && scenePhase == .active) }
        syncPreview()
    }

    private func syncPreview() {
        preview.configure(enabled: previewEnabled && peer.authorized && scenePhase == .active,
                          host: text("previewName"), token: text("previewToken"),
                          streaming: peer.state["streaming"] as? Bool == true && peer.state["livePreview"] as? Bool == true)
    }

    private var pairing: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right").font(.system(size: 44))
            Text("Connect to FacePull Host").font(.headline)
            ForEach(peer.discovered, id: \.displayName) { host in
                Button(host.displayName) { peer.connect(host) }
                    .frame(maxWidth: .infinity).padding(12).background(.ultraThinMaterial, in: Capsule())
            }
            if peer.connected && !peer.authorized {
                TextField("Six-digit code on Host", text: $code).keyboardType(.numberPad)
                    .textContentType(.oneTimeCode).padding(12).background(.ultraThinMaterial, in: Capsule())
                Button("Pair") { peer.pair(code: code) }
                    .disabled(code.count != 6)
                    .padding(12).background(.ultraThinMaterial, in: Capsule())
            }
            if let error = peer.error { Text(error).font(.caption).foregroundStyle(.orange) }
            if peer.discovered.isEmpty { Text("Keep both iPhones on the same local network.").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func controls(_ panel: RemotePanel) -> some View {
        switch panel {
        case .face:
            VStack(spacing: 8) {
                adjustment("Face follow", action: "intensity", enabled: "tracking", range: 0.8...2.2, defaultValue: 1.8, step: 0.1)
                HStack {
                    choice("Lock me", selected: text("subject") == "Lock me") { peer.command("subject", value: "Lock me") }
                    choice("Auto widen", selected: text("subject") == "Auto widen") { peer.command("subject", value: "Auto widen") }
                    Button("Relock") { peer.command("relock") }.padding(10).background(.ultraThinMaterial, in: Capsule())
                }
            }
        case .background:
            VStack(spacing: 8) {
                HStack {
                    choice("Off", selected: text("background") == "Off") { peer.command("background", value: "Off") }
                    choice("Portrait", selected: text("background") == "Blur") { peer.command("background", value: "Blur") }
                    Button("Photos", systemImage: "photo.badge.plus") { showPhotoPicker = true }
                }
                Button("Clear recents", role: .destructive) { peer.command("clearRecentBackgrounds") }
                    .disabled(peer.state["hasRecentBackgrounds"] as? Bool != true)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(items("backgrounds"), id: \.id) { item in
                            Button { peer.command("asset", value: item.id) } label: {
                                Group { if let image = item.thumbnail { Image(uiImage: image).resizable().scaledToFill() } else { Image(systemName: "photo") } }
                                    .frame(width: 80, height: 64).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(text("selectedBackground") == item.id && text("background") == "Custom" ? Color.blue : Color.clear, lineWidth: 2))
                            }
                        }
                    }
                }.frame(maxHeight: 52)
            }
        case .exposure:
            adjustment("Exposure", action: "exposure", enabled: "exposureLocked", range: -2...2, defaultValue: 0, step: 0.1)
        case .whiteBalance:
            adjustment("White balance", action: "temperature", enabled: "whiteBalanceLocked", range: 2500...6500, defaultValue: 4500, step: 50)
        case .settings:
            ScrollView {
                VStack(spacing: 8) {
                    Toggle("Live Preview", isOn: Binding(get: { previewEnabled }, set: {
                        FaceTrackHaptics.tap(); previewEnabled = $0; requestPreview()
                    })).tint(.blue).padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    Menu {
                        ForEach(items("cameras"), id: \.id) { item in
                            Button(item.name) { peer.command("lens", value: item.id) }
                        }
                    } label: { row("Lens", value: items("cameras").first(where: { $0.id == text("lens") })?.name ?? "Camera", icon: "camera") }
                    Menu {
                        ForEach(items("qualities"), id: \.id) { item in
                            Button(item.name) { peer.command("quality", value: item.id) }
                        }
                    } label: { row("Quality", value: text("quality"), icon: "video") }
                    Toggle("Mirror stream", isOn: Binding(get: { peer.state["mirror"] as? Bool ?? false },
                        set: { FaceTrackHaptics.tap(); peer.command("mirror", value: $0) })).tint(.blue).padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    Toggle("Microphone", isOn: Binding(get: { peer.state["microphone"] as? Bool ?? false },
                        set: { FaceTrackHaptics.tap(); peer.command("microphone", value: $0) })).tint(.blue).padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    ForEach(items("presets"), id: \.id) { item in
                        Button { peer.command("preset", value: item.id) } label: { row(item.name, value: "Apply", icon: "slider.horizontal.3") }
                    }
                }
            }.frame(maxHeight: 240)
        }
    }

    private func adjustment(_ title: String, action: String, enabled: String,
                            range: ClosedRange<Float>, defaultValue: Float, step: Float) -> some View {
        HStack(spacing: 16) {
            Toggle(title, isOn: Binding(get: { peer.state[enabled] as? Bool ?? false },
                set: { FaceTrackHaptics.tap(); peer.command(enabled, value: $0) })).labelsHidden().tint(.blue)
            NativeMagneticSlider(value: Binding(get: { (peer.state[action] as? NSNumber).map { Float(truncating: $0) } ?? defaultValue },
                set: {
                    if action == "temperature" { peer.command("whiteBalanceLocked", value: true) }
                    peer.command(action, value: String(format: "%.2f", $0))
                }),
                range: range, defaultValue: defaultValue, step: step)
                .accessibilityLabel(title + " adjustment")
        }.padding(12).background(.ultraThinMaterial, in: Capsule())
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.subheadline.weight(.medium)).padding(12)
            .foregroundStyle(selected ? Color.blue : Color.white).background(.ultraThinMaterial, in: Capsule()) }
    }

    private func row(_ title: String, value: String, icon: String) -> some View {
        HStack { Image(systemName: icon); Text(title); Spacer(); Text(value).foregroundStyle(.secondary) }
            .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func text(_ key: String) -> String { peer.state[key] as? String ?? "" }
    private func items(_ key: String) -> [RemoteItem] {
        (peer.state[key] as? [[String: String]] ?? []).compactMap { (item: [String: String]) -> RemoteItem? in
            guard let id = item["id"], let name = item["name"] else { return nil }
            let image = item["thumb"].flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0) }
            return RemoteItem(id: id, name: name, thumbnail: image)
        }
    }
}
