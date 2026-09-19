import SwiftUI
import PhotosUI
import UIKit

enum ToolPanel: String, Identifiable, CaseIterable, Equatable {
    case faceTrack = "FaceTrack", background = "Background", exposure = "AE", whiteBalance = "WB", settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .faceTrack: return "viewfinder"
        case .background: return "person.crop.rectangle"
        case .exposure: return "sun.max"
        case .whiteBalance: return "thermometer.sun"
        case .settings: return "gearshape"
        }
    }
    static var allCases: [ToolPanel] { [.faceTrack, .background, .exposure, .whiteBalance, .settings] }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = 26) -> some View {
        facePullGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func glassCapsule(tint: Color = .clear) -> some View {
        facePullGlass(in: Capsule(), tint: tint)
    }
}

struct NativeMagneticSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let defaultValue: Float
    let step: Float
    @State private var lastRaw: Float?
    @State private var snapped = false

    var body: some View {
        Slider(value: Binding(get: { value }, set: { raw in
                let crossed = lastRaw.map { ($0 - defaultValue) * (raw - defaultValue) < 0 } ?? false
                let near = abs(raw - defaultValue) < (range.upperBound - range.lowerBound) * 0.025
                let shouldSnap = near || (crossed && !snapped)
                if shouldSnap && !snapped { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
                let next = shouldSnap ? defaultValue : min(range.upperBound, max(range.lowerBound, (raw / step).rounded() * step))
                if next != value && !shouldSnap { FaceTrackHaptics.selection() }
                value = next; snapped = shouldSnap; lastRaw = raw
        }), in: range, onEditingChanged: { editing in
            if editing { FaceTrackHaptics.tap() }
            else { lastRaw = nil; snapped = false }
        })
        .tint(.blue)
        .environment(\.colorScheme, .dark)
        .frame(height: 48)
    }
}

struct CameraScreen: View {
    @StateObject private var camera = CameraModel()
    @Environment(\.scenePhase) private var phase
    @State private var panel: ToolPanel?
    @State private var focusedTool: ToolPanel?
    @State private var showConnection = false
    @State private var showRecentBackground = false
    @State private var photo: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var iconAngle: Angle = .zero
    @State private var showPhotoPicker = false
    @State private var showPresets = false
    @State private var presetName = ""
    @State private var editingPreset: UUID?
    @State private var namePreset = false
    @AppStorage("framingGrid") private var showGrid = false
    @AppStorage("appMode") private var appMode = "host"

    var body: some View {
        GeometryReader { layout in
          ZStack {
            preview
                .contentShape(Rectangle()).onTapGesture { dismissTools() }
            if showGrid { framingGrid.allowsHitTesting(false) }
            VStack(spacing: 8) {
                topBar
                Spacer(minLength: 0)
                if let panel {
                    panelContent(panel).padding(.horizontal, panel == .settings ? 0 : 24)
                        .contentShape(Rectangle()).onTapGesture {}
                        .padding(.bottom, panel == .background ? 14 : 0)
                        .opacity(camera.streaming ? 0.55 : 1)
                        .transition(.asymmetric(insertion: .scale(scale: 0.95, anchor: .bottom).combined(with: .opacity), removal: .scale(scale: 0.95, anchor: .bottom).combined(with: .opacity)))
                }
                controls
            }
            .padding(.top, layout.safeAreaInsets.top)
            .padding(.bottom, layout.safeAreaInsets.bottom)
            .padding(.leading, layout.safeAreaInsets.leading)
            .padding(.trailing, layout.safeAreaInsets.trailing)
            .background(Color.clear)
          }
          .ignoresSafeArea(.container)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .statusBarHidden().fontDesign(.default).tint(.white)
        .environment(\.colorScheme, .dark)
        .buttonStyle(LiquidGlassButtonStyle())
        .onAppear { camera.activate(); updateIconAngle() }
        .onDisappear { camera.deactivate() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in updateIconAngle() }
        .onChange(of: phase) { _, value in
            if value == .active { camera.activate() } else if value == .background { camera.deactivate() }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photo, matching: .images)
        .alert(editingPreset == nil ? "Save preset" : "Rename preset", isPresented: $namePreset) {
            TextField("Name", text: $presetName)
            Button("Save") {
                if let id = editingPreset { camera.renamePreset(id, name: presetName) }
                else { camera.savePreset(name: presetName) }
            }
            Button("Cancel", role: .cancel) {}
        }

        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: showRecentBackground)
        .animation(.easeInOut(duration: 0.25), value: camera.streaming)
        .alert("FacePull", isPresented: Binding(get: { camera.error != nil }, set: { if !$0 { camera.error = nil } })) {
            if camera.permissionDenied { Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } }
            Button("OK", role: .cancel) { camera.error = nil }
        } message: { Text(camera.error ?? "") }
        .task(id: photo) {
            guard let selected = photo else { return }
            loadingPhoto = true; defer { if !Task.isCancelled { loadingPhoto = false } }
            do {
                if let data = try await selected.loadTransferable(type: Data.self), !Task.isCancelled { camera.loadBackground(data) }
            } catch { if !Task.isCancelled { camera.error = "Photo could not be loaded." } }
        }
        .overlay { if camera.dimmed { dimOverlay } }
        .persistentSystemOverlays(camera.dimmed ? .hidden : .automatic)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Image(systemName: camera.battery.map { $0 <= 20 ? "battery.25" : "battery.100" } ?? "battery.100")
                .font(.system(size: 19, weight: .medium)).rotationEffect(iconAngle).accessibilityLabel("Battery")
            Spacer(minLength: 0)
            Menu {
                Button("Auto · 30s", systemImage: camera.oledSaverEnabled ? "checkmark" : "moon.zzz") {
                    camera.oledSaverEnabled = true
                }
                Button("Off", systemImage: camera.oledSaverEnabled ? "moon" : "checkmark") {
                    camera.oledSaverEnabled = false
                }
            } label: {
                Image(systemName: camera.oledSaverEnabled ? "moon.fill" : "moon")
                    .font(.system(size: 17, weight: .semibold)).rotationEffect(iconAngle)
                    .frame(width: 44, height: 44)
                    .glassCapsule()
            }
            .onChange(of: camera.oledSaverEnabled) { _, _ in FaceTrackHaptics.tap() }
            .foregroundStyle(camera.oledSaverEnabled ? Color("mijick-background-yellow") : .white)
            .accessibilityLabel("OLED saver")
            .accessibilityIdentifier("camera.oled")
            .accessibilityValue(camera.oledSaverEnabled ? "Auto, 30 seconds" : "Off")
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if camera.ready {
                    ProcessedPreview(frames: camera.preview,
                        mirrored: camera.frontCamera && camera.mirrorPreview != camera.settings.mirrorStream,
                        paused: camera.dimmed)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Image(systemName: camera.permissionDenied ? "camera.fill" : "camera")
                        .font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            CameraToolStrip(panel: $panel, focused: $focusedTool, angle: iconAngle)
            HStack {
                MijickRoundButton(icon: "mijick-icon-light", active: camera.torch, label: "Toggle torch", rotation: iconAngle) { camera.toggleTorch() }
                    .disabled(!camera.ready || !camera.hasTorch).opacity(camera.hasTorch ? 1 : 0.3)
                Spacer()
                StreamButton(active: camera.streaming, starting: camera.starting) { camera.toggleStream() }
                    .disabled(!camera.ready && !camera.streaming && !camera.starting)
                Spacer()
                MijickRoundButton(icon: "mijick-icon-change-camera", label: "Switch camera", rotation: iconAngle) { camera.flipCamera() }
                    .disabled(!camera.ready)
            }
            .padding(.horizontal, 24)
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }



    private func pillScale(for tool: ToolPanel) -> CGFloat {
        guard let focusedTool else { return 1 }
        if focusedTool == tool { return panel == tool ? 1.3 : 1.15 }
        return panel == nil ? 0.9 : 0.8
    }

    private func dismissTools() {
        withAnimation(.interpolatingSpring(stiffness: 300, damping: 20)) {
            panel = nil; focusedTool = nil; showRecentBackground = false
        }
    }

    @ViewBuilder
    private func panelContent(_ panel: ToolPanel) -> some View {
        switch panel {
        case .faceTrack: trackingPanel
        case .background: backgroundPanel
        case .exposure: exposurePanel
        case .whiteBalance: whiteBalancePanel
        case .settings: settingsPanel
        }
    }

    private var trackingPanel: some View {
        VStack(spacing: 8) {
        sliderRow("Face tracking", enabled: $camera.settings.tracking,
            value: Binding(get: { Float(camera.settings.intensity) }, set: { camera.settings.intensity = CGFloat($0) }),
            range: 0.8...2.2, center: 1.8, step: 0.1)
            HStack(spacing: 8) {
                ForEach(SubjectMode.allCases, id: \.self) { mode in
                    Button {
                        camera.settings.subjectMode = mode
                        if mode == .lock { camera.relockSubject() }
                        panel = .faceTrack; focusedTool = .faceTrack
                    } label: {
                        Text(mode.rawValue).font(.subheadline.weight(.medium)).padding(.horizontal, 16).frame(minHeight: 44)
                            .glassCapsule(tint: camera.settings.subjectMode == mode ? .white.opacity(0.18) : .clear)
                    }
                }
            }
        }
    }

    private var exposurePanel: some View {
        sliderRow("Exposure lock", enabled: $camera.exposureLocked, value: $camera.exposure,
                  range: -2...2, center: 0, step: 0.1)
    }

    private var whiteBalancePanel: some View {
        sliderRow("White balance lock", enabled: $camera.whiteBalanceLocked,
            value: Binding(get: { camera.whiteBalanceTemperature }, set: {
                camera.whiteBalanceLocked = true
                camera.whiteBalanceTemperature = $0
            }), range: 2500...6500, center: 4500, step: 50)
    }

    private func sliderRow(_ label: String, enabled: Binding<Bool>, value: Binding<Float>,
                           range: ClosedRange<Float>, center: Float, step: Float) -> some View {
        CameraSliderRow(label: label, enabled: enabled, value: value, range: range, center: center, step: step)
    }

    private var backgroundPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                backgroundChoice(.off, "Off")
                backgroundChoice(.blur, "Portrait")
                backgroundChoice(.custom, "Custom")
            }
            if showRecentBackground {
                backgroundLibrary
            }
        }.background(Color.clear)
    }

    private func backgroundChoice(_ mode: BackgroundMode, _ title: String) -> some View {
        Button {
            if mode == .custom {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { showRecentBackground = true }
            } else {
                camera.setBackgroundMode(mode); showRecentBackground = false
            }
        } label: {
            Text(title).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 48)
                .glassCapsule()
                .contentShape(Capsule())
        }.foregroundStyle(camera.settings.background == mode ? Color.blue : .white)
    }

    private var backgroundLibrary: some View {
        VStack(spacing: 8) {
            HStack {
                Button { photo = nil; showPhotoPicker = true } label: {
                    Label("Photos", systemImage: "photo.badge.plus").padding(12).glassCapsule()
                }.disabled(loadingPhoto)
                Spacer()
                Button("Clear recents", role: .destructive) { camera.clearRecentBackgrounds() }
                    .padding(12).glassCapsule().disabled(camera.recentBackgroundIDs.isEmpty)
            }
            if !camera.visibleBackgrounds.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(camera.visibleBackgrounds) { asset in
                            Button { camera.selectBackground(asset) } label: {
                                Group {
                                    if let image = asset.thumbnail { Image(uiImage: image).resizable().scaledToFill() }
                                    else { Image(systemName: "photo") }
                                }.frame(width: 80, height: 64).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay(alignment: .topTrailing) { if asset.favorite { Image(systemName: "star.fill").font(.caption).padding(4) } }
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(camera.selectedBackgroundID == asset.id && camera.settings.background == .custom ? .blue : .clear, lineWidth: 2))
                            }.accessibilityLabel("Saved background")
                            .contextMenu {
                                Button(asset.favorite ? "Unfavorite" : "Favorite", systemImage: "star") { camera.favoriteBackground(asset) }
                                Button("Remove", systemImage: "trash", role: .destructive) { camera.removeBackground(asset) }
                            }
                        }
                    }.padding(4)
                }.frame(height: 72)
            }
        }.transition(.scale(scale: 0.95, anchor: .bottom).combined(with: .opacity))
    }

    private var framingGrid: some View {
        GeometryReader { geometry in
            Path { path in
                for index in 1...2 {
                    let x = geometry.size.width * CGFloat(index) / 3
                    let y = geometry.size.height * CGFloat(index) / 3
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }.stroke(.white.opacity(0.22), lineWidth: 0.5)
        }
    }

    private var settingsPanel: some View {
        ScrollView {
            VStack(spacing: 8) {
                Menu {
                    ForEach(camera.cameras) { choice in
                        Button(choice.name) { camera.switchCamera(choice.id) }
                    }
                } label: { settingRow("Lens", camera.cameras.first(where: { $0.id == camera.selectedCamera })?.name ?? "Front", "camera") }
                    .padding(8).liquidGlass(cornerRadius: 16)
                Menu {
                    ForEach(VideoQuality.allCases) { quality in
                        Button(quality.label) { camera.settings.quality = quality }
                    }
                } label: { settingRow("Quality", camera.settings.quality.label, "sparkles.tv") }
                    .padding(8).liquidGlass(cornerRadius: 16).disabled(camera.streaming || camera.starting)
                Toggle("Grid", isOn: $showGrid).tint(.blue).padding(8).liquidGlass(cornerRadius: 16)
                    .onChange(of: showGrid) { _, _ in FaceTrackHaptics.tap() }
                Toggle("Mirror selfie", isOn: $camera.mirrorPreview).tint(.blue).padding(8).liquidGlass(cornerRadius: 16)
                    .onChange(of: camera.mirrorPreview) { _, _ in FaceTrackHaptics.tap() }
                Toggle("Mirror stream", isOn: $camera.settings.mirrorStream).tint(.blue).padding(8).liquidGlass(cornerRadius: 16)
                    .onChange(of: camera.settings.mirrorStream) { _, _ in FaceTrackHaptics.tap() }
                Toggle("Connection haptics", isOn: $camera.connectionAlerts).tint(.blue).padding(8).liquidGlass(cornerRadius: 16)
                    .onChange(of: camera.connectionAlerts) { _, _ in FaceTrackHaptics.tap() }
                Toggle("Microphone", isOn: Binding(get: { camera.microphoneEnabled }, set: { camera.setMicrophoneEnabled($0) }))
                    .tint(.blue).padding(8).liquidGlass(cornerRadius: 16)
                LabeledContent("Remote pairing", value: camera.peer.pairingCode)
                    .padding(12).liquidGlass(cornerRadius: 16)
                Button { camera.stopStream(); appMode = "remote" } label: {
                    Label("Use as Remote Control", systemImage: "iphone.gen3.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12).liquidGlass(cornerRadius: 16)
                }
                Button { withAnimation(.spring()) { showPresets.toggle() } } label: {
                    Label("Presets", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading).padding(12).liquidGlass(cornerRadius: 16)
                }
                if showPresets { presetsPanel }
                Button {
                    withAnimation(.spring()) { showConnection.toggle() }
                } label: {
                    HStack { Text("Connect"); Spacer(); Image(systemName: "network").rotationEffect(iconAngle) }
                        .frame(minHeight: 32)
                }.padding(8).liquidGlass(cornerRadius: 16)
                if showConnection { connectionDetails }
            }.padding(.vertical, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .background(Color.clear)
    }



    private func settingRow(_ title: String, _ value: String, _ icon: String) -> some View {
        CameraSettingRow(title: title, value: value, icon: icon, angle: iconAngle)
    }

    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Viewers", value: "\(camera.viewers)")
            if let url = camera.wifiH264URL { compactURLRow("Wi‑Fi · H.264", url) }
            compactURLRow("USB · H.264", camera.usbH264URL)
            if let host = camera.wifiAddress { compactURLRow("Remote · Wi-Fi", "http://\(host):8080/remote") }
            compactURLRow("Remote · USB", "http://127.0.0.1:18080/remote")
            compactURLRow("Remote password", camera.remoteKey)
            Text("\(camera.fps) fps · \(camera.thermal)").font(.caption)
        }
        .background(Color.clear)
    }

    private var presetsPanel: some View {
        VStack(spacing: 8) {
            Button("Save current setup") { editingPreset = nil; presetName = ""; namePreset = true }
                .padding(12).glassCapsule()
            ForEach(camera.presets) { preset in
                HStack {
                    Button(preset.name) { camera.applyPreset(preset) }.frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        Button("Rename") { editingPreset = preset.id; presetName = preset.name; namePreset = true }
                        Button("Delete", role: .destructive) { camera.deletePreset(preset.id) }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                }.padding(.horizontal, 12).liquidGlass(cornerRadius: 16)
            }
            if camera.streaming { Text("Quality stays unchanged while live.").font(.caption) }
        }
    }

    private func compactURLRow(_ title: String, _ url: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.caption).foregroundStyle(.secondary); Text(url).font(.caption2.monospaced()).lineLimit(2).textSelection(.enabled) }
            Spacer()
            Button { UIPasteboard.general.string = url } label: { Image(systemName: "doc.on.doc").frame(width: 34, height: 34) }.disabled(!camera.streaming)
        }.padding(8).liquidGlass(cornerRadius: 16)
    }

    private var dimOverlay: some View {
        Color.black.ignoresSafeArea().contentShape(Rectangle()).onTapGesture { FaceTrackHaptics.tap(); camera.wakeFromOLEDSaver() }
            .accessibilityLabel("OLED saver active. Tap to wake.")
    }

    private func updateIconAngle() {
        switch UIDevice.current.orientation {
        case .landscapeLeft: iconAngle = .degrees(90)
        case .landscapeRight: iconAngle = .degrees(-90)
        default: iconAngle = .zero
        }
    }
}
