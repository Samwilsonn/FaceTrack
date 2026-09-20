import SwiftUI
import PhotosUI
import UIKit

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
    @State private var panel: ToolPanel?
    @State private var focusedPanel: ToolPanel?
    @State private var showConnection = false
    @State private var showRecentBackground = false
    @State private var photo: PhotosPickerItem?
    @State private var showPhotoPicker = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().onTapGesture { withAnimation(.spring()) { panel = nil; focusedPanel = nil } }
            if previewEnabled && peer.authorized && scenePhase == .active {
                RemotePreviewView(decoder: preview.decoder,
                    mirrored: peer.state["frontCamera"] as? Bool == true && (peer.state["mirrorPreview"] as? Bool ?? true) != (peer.state["mirror"] as? Bool ?? false)).ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring()) { panel = nil; focusedPanel = nil } }
            }
            VStack(spacing: 8) {
                HStack {
                    Button { mode = "host" } label: { Label("Host", systemImage: "camera") }
                    Spacer()
                    Label(peer.authorized ? "Connected" : peer.connected ? "Pair" : "Discovering", systemImage: peer.authorized ? "wifi" : "wifi.slash")
                        .foregroundStyle(peer.authorized ? Color.green : Color.secondary)
                }.font(.subheadline.weight(.medium))
                Spacer()
                if peer.authorized {
                    if let panel { controls(panel).padding(.horizontal, panel == .settings ? 0 : 24).contentShape(Rectangle()).onTapGesture {} }
                    VStack(spacing: 0) {
                    CameraToolStrip(panel: $panel, focused: $focusedPanel)
                    HStack {
                    MijickRoundButton(icon: "mijick-icon-light", active: peer.state["torch"] as? Bool == true, label: "Toggle torch") { peer.command("torch") }
                        .disabled(peer.state["hasTorch"] as? Bool != true).opacity(peer.state["hasTorch"] as? Bool == true ? 1 : 0.3)
                    Spacer()
                    StreamButton(active: peer.state["streaming"] as? Bool == true, starting: peer.state["starting"] as? Bool == true) {
                        peer.command("stream", value: !(peer.state["streaming"] as? Bool ?? false))
                    }
                    Spacer()
                    MijickRoundButton(icon: "mijick-icon-change-camera", label: "Switch camera") { peer.command("flipCamera") }
                    }.padding(.horizontal, 24)
                    }.padding(.horizontal, 16)
                } else {
                    pairing
                }
            }
            .padding(.bottom, 8)
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
    private func controls(_ panel: ToolPanel) -> some View {
        switch panel {
        case .faceTrack:
            VStack(spacing: 8) {
                adjustment("Face follow", action: "intensity", enabled: "tracking", range: 0.8...2.2, defaultValue: 1.8, step: 0.1)
                CameraSubjectChoices(selected: text("subject")) { mode in
                    peer.command("subject", value: mode.rawValue)
                }
            }
        case .background:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    choice("Off", selected: text("background") == "Off") { peer.command("background", value: "Off"); showRecentBackground = false }
                    choice("Portrait", selected: text("background") == "Blur") { peer.command("background", value: "Blur"); showRecentBackground = false }
                    choice("Custom", selected: text("background") == "Custom") { withAnimation(.spring()) { showRecentBackground = true } }
                }
                if showRecentBackground {
                HStack {
                    Button("Photos", systemImage: "photo.badge.plus") { showPhotoPicker = true }.padding(12).glassCapsule()
                    Spacer()
                Button("Clear recents", role: .destructive) { peer.command("clearRecentBackgrounds") }
                    .padding(12).glassCapsule()
                    .disabled(peer.state["hasRecentBackgrounds"] as? Bool != true)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(items("backgrounds"), id: \.id) { item in
                            Button { peer.command("asset", value: item.id) } label: {
                                Group { if let image = item.thumbnail { Image(uiImage: image).resizable().scaledToFill() } else { Image(systemName: "photo") } }
                                    .frame(width: 80, height: 64).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(text("selectedBackground") == item.id && text("background") == "Custom" ? Color.blue : Color.clear, lineWidth: 2))
                            }
                        }
                    }.padding(4)
                }.frame(height: 72)
                }
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
                    })).tint(.blue).padding(8).liquidGlass(cornerRadius: 16)
                    Menu {
                        ForEach(items("cameras"), id: \.id) { item in
                            Button(item.name) { peer.command("lens", value: item.id) }
                        }
                    } label: { row("Lens", value: items("cameras").first(where: { $0.id == text("lens") })?.name ?? "Camera", icon: "camera") }
                    Menu {
                        ForEach(items("qualities"), id: \.id) { item in
                            Button(item.name) { peer.command("quality", value: item.id) }
                        }
                    } label: { row("Quality", value: items("qualities").first(where: { $0.id == text("quality") })?.name ?? text("quality"), icon: "sparkles.tv") }
                        .disabled(peer.state["streaming"] as? Bool == true || peer.state["starting"] as? Bool == true)
                    Toggle("Mirror selfie", isOn: Binding(get: { peer.state["mirrorPreview"] as? Bool ?? true },
                        set: { FaceTrackHaptics.tap(); peer.command("mirrorPreview", value: $0) })).tint(.blue).padding(8).liquidGlass(cornerRadius: 16)
                    Toggle("Mirror stream", isOn: Binding(get: { peer.state["mirror"] as? Bool ?? false },
                        set: { FaceTrackHaptics.tap(); peer.command("mirror", value: $0) })).tint(.blue).padding(8).liquidGlass(cornerRadius: 16)
                    Toggle("Microphone", isOn: Binding(get: { peer.state["microphone"] as? Bool ?? false },
                        set: { FaceTrackHaptics.tap(); peer.command("microphone", value: $0) })).tint(.blue).padding(8).liquidGlass(cornerRadius: 16)
                    ForEach(items("presets"), id: \.id) { item in
                        Button { peer.command("preset", value: item.id) } label: { row(item.name, value: "Apply", icon: "slider.horizontal.3") }
                    }
                    Button { withAnimation(.spring()) { showConnection.toggle() } } label: {
                        HStack { Text("Connect"); Spacer(); Image(systemName: "network") }.frame(minHeight: 32)
                    }.padding(8).liquidGlass(cornerRadius: 16)
                    if showConnection {
                        CameraConnectionDetails(viewers: peer.state["viewers"] as? Int ?? 0,
                            wifiURL: connectionValue("wifiURL"), usbURL: connectionValue("usbURL"),
                            remoteWifiURL: connectionValue("remoteWifiURL"), remoteUSBURL: connectionValue("remoteUSBURL"),
                            remotePassword: connectionValue("remotePassword"), fps: peer.state["fps"] as? Int ?? 0,
                            thermal: text("thermal"), streaming: peer.state["streaming"] as? Bool == true)
                    }
                }
            }.frame(maxHeight: .infinity).padding(.horizontal, 16)
        }
    }

    private func adjustment(_ title: String, action: String, enabled: String,
                            range: ClosedRange<Float>, defaultValue: Float, step: Float) -> some View {
        CameraSliderRow(label: title,
            enabled: Binding(get: { peer.state[enabled] as? Bool ?? false }, set: { peer.command(enabled, value: $0) }),
            value: Binding(get: { (peer.state[action] as? NSNumber).map { Float(truncating: $0) } ?? defaultValue },
                set: {
                    if action == "temperature" { peer.command("whiteBalanceLocked", value: true) }
                    peer.command(action, value: String(format: "%.2f", $0))
                }),
                range: range, center: defaultValue, step: step)
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 48)
            .glassCapsule().contentShape(Capsule()) }
            .foregroundStyle(selected ? Color.blue : Color.white)
    }

    private func row(_ title: String, value: String, icon: String) -> some View {
        CameraSettingRow(title: title, value: value, icon: icon)
            .padding(8).liquidGlass(cornerRadius: 16)
    }

    private func text(_ key: String) -> String { peer.state[key] as? String ?? "" }
    private func connectionValue(_ key: String) -> String {
        guard peer.authorized else { return "" }
        return (peer.state["connection"] as? [String: String])?[key] ?? ""
    }
    private func items(_ key: String) -> [RemoteItem] {
        (peer.state[key] as? [[String: String]] ?? []).compactMap { (item: [String: String]) -> RemoteItem? in
            guard let id = item["id"], let name = item["name"] else { return nil }
            let image = item["thumb"].flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0) }
            return RemoteItem(id: id, name: name, thumbnail: image)
        }
    }
}
