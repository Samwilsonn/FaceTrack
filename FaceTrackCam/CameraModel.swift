import SwiftUI
import AVFoundation
import CoreImage
import ImageIO
import Darwin
import AVFAudio

struct CameraChoice: Identifiable {
    let id: String
    let name: String
    let front: Bool
}

// Published properties and public actions belong to the main thread. Capture, device
// configuration and Vision state belong exclusively to captureQueue.
final class CameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var settings = ProcessingSettings() { didSet { updateSettings() } }
    @Published var mirrorPreview = true
    @Published private(set) var cameras: [CameraChoice] = []
    @Published private(set) var selectedCamera = ""
    @Published private(set) var frontCamera = false
    @Published private(set) var ready = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var starting = false
    @Published private(set) var streaming = false
    @Published private(set) var viewers = 0
    private var h264Viewers = 0
    @Published private(set) var streamStarted: Date?
    @Published private(set) var token = CameraLibrary.stableSecret("streamKey")
    let remoteKey = CameraLibrary.stableSecret("remoteKey")
    @Published var connectionAlerts = true
    @Published private(set) var microphoneEnabled = false
    private var microphoneRequest = 0
    @Published private(set) var backgrounds: [BackgroundAsset] = CameraLibrary.load("backgrounds.json", fallback: [])
    @Published private(set) var recentBackgroundIDs: [UUID] = CameraLibrary.load("recents.json", fallback: [])
    @Published private(set) var presets: [CameraPreset] = CameraLibrary.load("presets.json", fallback: [])
    @Published private(set) var selectedBackgroundID: UUID?
    private var backgroundRequest = UUID()
    @Published private(set) var wifiAddress: String?
    @Published private(set) var battery: Int?
    @Published private(set) var thermal = "Normal"
    @Published private(set) var fps = 0
    @Published private(set) var hasBackground = false
    @Published private(set) var hasTorch = false
    @Published private(set) var torch = false
    @Published var exposure: Float = 0 { didSet { configureExposure() } }
    @Published var exposureLocked = false { didSet { configureExposure() } }
    @Published var whiteBalanceTemperature: Float = 4500 { didSet { configureWhiteBalance() } }
    @Published var whiteBalanceLocked = false { didSet { configureWhiteBalance() } }
    @Published var error: String?
    @Published private(set) var dimmed = false { didSet { applyDimming() } }
    @Published var oledSaverEnabled = false {
        didSet {
            oledState.setAuto(oledSaverEnabled, now: ProcessInfo.processInfo.systemUptime)
            syncOLEDSaver()
        }
    }

    func wakeFromOLEDSaver() {
        oledState.wake()
        syncOLEDSaver()
    }

    let preview = PreviewFrames()
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "cam.capture", qos: .userInitiated)
    private let processor = FrameProcessor()
    private let server = StreamServer()
    private let rtsp = H264RTSPServer()
    let peer = PeerControl(role: .host)
    @Published private(set) var remotePreviewEnabled = false
    private(set) var remotePreviewToken = UUID().uuidString
    var remotePreviewName: String { rtsp.previewName }
    var remoteThumbnailCache: [UUID: String] = [:]
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var desiredActive = false
    private var observers: [NSObjectProtocol] = []
    private var monitor: Timer?
    private var remoteStateTimer: Timer?
    private var oledTimer: Timer?
    private var oledState = OLEDSaverState()
    private var previousBrightness: CGFloat?
    private var previousIdleTimer: Bool?
    private var nextFrameTime: TimeInterval = 0
    private var statsTime: TimeInterval = 0
    private var statsFrames = 0
    private var lastErrorTime: TimeInterval = 0
    private var orientation: AVCaptureVideoOrientation = .portrait

    override init() {
        super.init()
        if !FileManager.default.fileExists(atPath: CameraLibrary.directory.appendingPathComponent("recents.json").path) {
            recentBackgroundIDs = backgrounds.map(\.id)
            persistRecents()
        }
        server.onRemoteState = { [weak self] in self?.remoteState() ?? [:] }
        server.onRemoteCommand = { [weak self] command in self?.applyRemote(command) }
        peer.onCommand = { [weak self] command in self?.applyRemote(command) }
        peer.onDisconnect = { [weak self] in
            self?.setRemotePreviewEnabled(false)
            self?.remotePreviewToken = UUID().uuidString
        }
        rtsp.onError = { [weak self] message in self?.error = message }
        rtsp.onMicrophoneFailure = { [weak self] in self?.setMicrophoneEnabled(false) }
        rtsp.onStatus = { [weak self] running, error in
            guard let self else { return }
            self.starting = false
            if running && !self.streaming { self.streamStarted = Date() }
            self.streaming = running
            if !running { self.streamStarted = nil }
            self.oledState.setStreaming(running, now: ProcessInfo.processInfo.systemUptime)
            self.syncOLEDSaver()
            self.updateIdleTimer()
            if let error { self.error = error }
        }
        rtsp.onViewers = { [weak self] count in
            guard let self else { return }
            self.h264Viewers = count
            self.updateViewers()
        }
        server.onStatus = { [weak self] status in
            guard let self else { return }
            if let error = status.error { self.error = error }
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        monitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateMonitor()
        }
        remoteStateTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.peer.authorized else { return }
            self.peer.publish(self.remoteState(includeConnectionDetails: true))
        }
        observe(UIDevice.orientationDidChangeNotification, object: nil) { [weak self] _ in self?.updateOrientation() }
        observe(.AVCaptureSessionWasInterrupted, object: session) { [weak self] _ in
            self?.ready = false; self?.stopStream(); self?.error = "Camera interrupted. Return to the app to resume the preview."
        }
        observe(.AVCaptureSessionInterruptionEnded, object: session) { [weak self] _ in
            guard let self, self.desiredActive else { return }; self.activate()
        }
        observe(.AVCaptureSessionRuntimeError, object: session) { [weak self] notification in
            guard let self else { return }
            self.ready = false; self.stopStream()
            self.error = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Camera stopped. Tap Retry."
        }
        observe(AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance()) { [weak self] notification in
            guard let self,
                  let kind = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  kind == AVAudioSession.InterruptionType.began.rawValue else { return }
            self.setMicrophoneEnabled(false)
        }
        updateMonitor()
    }

    deinit {
        monitor?.invalidate()
        remoteStateTimer?.invalidate()
        oledTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        server.stop()
        rtsp.stop()
        let session = session
        captureQueue.async { if session.isRunning { session.stopRunning() } }
    }

    private func observe(_ name: Notification.Name, object: Any?, action: @escaping (Notification) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main, using: action))
    }

    func activate() {
        desiredActive = true
#if targetEnvironment(simulator)
        // Exercise the real Metal preview/layout in UI tests without camera hardware.
        if ProcessInfo.processInfo.arguments.contains("--layout-test") {
            preview.put(CIImage(color: CIColor(red: 0.2, green: 0.45, blue: 0.65))
                .cropped(to: CGRect(origin: .zero, size: settings.outputSize)))
            ready = true
            return
        }
#endif
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: permissionDenied = false; discoverAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.desiredActive else { return }
                    if granted { self.discoverAndStart() }
                    else { self.permissionDenied = true; self.error = "Allow camera access in Settings to use FaceTrackCam." }
                }
            }
        default: permissionDenied = true; error = "Allow camera access in Settings to use FaceTrackCam."
        }
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        microphoneRequest &+= 1
        let request = microphoneRequest
        guard enabled else {
            microphoneEnabled = false
            rtsp.setMicrophoneEnabled(false)
            if !streaming { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            return
        }
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: enableMicrophoneSession()
        case .undetermined: AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.microphoneRequest == request else { return }
                if granted { self.enableMicrophoneSession() }
                else { self.microphoneEnabled = false; self.rtsp.setMicrophoneEnabled(false) }
            }
        }
        case .denied: microphoneEnabled = false; rtsp.setMicrophoneEnabled(false)
        @unknown default: microphoneEnabled = false; rtsp.setMicrophoneEnabled(false)
        }
    }

    func setRemotePreviewEnabled(_ enabled: Bool) {
        remotePreviewEnabled = enabled
        rtsp.setPreviewEnabled(enabled, token: remotePreviewToken)
    }

    private func enableMicrophoneSession() {
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .videoRecording, options: [.allowBluetooth, .mixWithOthers])
            try audio.setPreferredSampleRate(48_000)
            try audio.setPreferredIOBufferDuration(0.005)
            try audio.setActive(true)
            microphoneEnabled = true
            rtsp.setMicrophoneEnabled(true)
        } catch {
            microphoneEnabled = false
            rtsp.setMicrophoneEnabled(false)
            report("Microphone could not be enabled.")
        }
    }

    func deactivate() {
        desiredActive = false; ready = false
        stopStream()
        captureQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.preview.put(nil)
            if let device = self.device, device.hasTorch, (try? device.lockForConfiguration()) != nil {
                device.torchMode = .off; device.unlockForConfiguration()
            }
        }
        torch = false
    }

    private func discoverAndStart() {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .unspecified).devices
        cameras = devices.map { CameraChoice(id: $0.uniqueID, name: $0.localizedName, front: $0.position == .front) }
        guard let choice = devices.first(where: { $0.uniqueID == selectedCamera }) ?? devices.first(where: { $0.position == .front }) ?? devices.first else {
            error = "No camera is available on this device."; return
        }
        updateOrientation()
        switchCamera(choice.uniqueID)
    }

    func switchCamera(_ id: String) {
        ready = false
        let bias = exposure
        let locked = exposureLocked
        let temperature = whiteBalanceTemperature
        let whiteBalanceIsLocked = whiteBalanceLocked
        let preset: AVCaptureSession.Preset = settings.quality == .ultra ? .hd1920x1080 : .hd1280x720
        captureQueue.async {
            if self.device?.uniqueID == id && self.session.isRunning {
                DispatchQueue.main.async { self.ready = self.desiredActive }
                return
            }
            guard let candidate = AVCaptureDevice(uniqueID: id) else { self.report("The selected lens is unavailable."); return }
            do {
                let input = try AVCaptureDeviceInput(device: candidate)
                self.session.beginConfiguration()
                if self.session.canSetSessionPreset(preset) { self.session.sessionPreset = preset }
                let oldInputs = self.session.inputs
                oldInputs.forEach(self.session.removeInput)
                guard self.session.canAddInput(input) else {
                    oldInputs.filter(self.session.canAddInput).forEach(self.session.addInput)
                    self.session.commitConfiguration(); self.report("Could not switch cameras."); return
                }
                self.session.addInput(input)
                if self.session.outputs.isEmpty {
                    self.output.alwaysDiscardsLateVideoFrames = true
                    let yuv = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    let pixelFormat = self.output.availableVideoPixelFormatTypes.contains(yuv) ? yuv : kCVPixelFormatType_32BGRA
                    self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
                    self.output.setSampleBufferDelegate(self, queue: self.captureQueue)
                    guard self.session.canAddOutput(self.output) else {
                        self.session.commitConfiguration(); self.report("Video output is unavailable."); return
                    }
                    self.session.addOutput(self.output)
                }
                self.device = candidate
                self.applyOrientation()
                self.session.commitConfiguration()
                try candidate.lockForConfiguration()
                if candidate.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                    candidate.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                    candidate.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                }
                if candidate.isFocusModeSupported(.continuousAutoFocus) { candidate.focusMode = .continuousAutoFocus }
                if candidate.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { candidate.whiteBalanceMode = .continuousAutoWhiteBalance }
                if candidate.hasTorch { candidate.torchMode = .off }
                candidate.unlockForConfiguration()
                self.applyExposure(bias: bias, locked: locked)
                self.applyWhiteBalance(temperature: temperature, locked: whiteBalanceIsLocked)
                self.processor.reset(); self.preview.put(nil)
                if !self.session.isRunning { self.session.startRunning() }
                let running = self.session.isRunning
                DispatchQueue.main.async {
                    self.selectedCamera = id; self.frontCamera = candidate.position == .front
                    self.hasTorch = candidate.hasTorch; self.torch = false
                    self.ready = running && self.desiredActive
                    if !running { self.error = "Camera could not start. Tap Retry." }
                }
            } catch { self.report("Camera error: \(error.localizedDescription)") }
        }
    }

    func flipCamera() {
        if let next = cameras.first(where: { $0.front != frontCamera }) { switchCamera(next.id) }
    }

    private func updateSettings() {
        let snapshot = settings
        captureQueue.async {
            let preset: AVCaptureSession.Preset = snapshot.quality == .ultra ? .hd1920x1080 : .hd1280x720
            if self.session.sessionPreset != preset && self.session.canSetSessionPreset(preset) {
                self.session.beginConfiguration()
                self.session.sessionPreset = preset
                self.session.commitConfiguration()
                self.processor.reset()
            }
            if self.processor.settings.format != snapshot.format { self.processor.reset() }
            self.processor.settings = snapshot
        }
    }

    func relockSubject() { captureQueue.async { self.processor.relockRequested = true } }

    func setBackgroundMode(_ mode: BackgroundMode) {
        backgroundRequest = UUID()
        settings.background = mode
    }

    func loadBackground(_ data: Data) {
        let request = UUID(); backgroundRequest = request
        captureQueue.async {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1920, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
                self.report("This photo could not be opened. Choose another image."); return
            }
            do {
                let asset = BackgroundAsset(id: UUID())
                try FileManager.default.createDirectory(at: CameraLibrary.directory, withIntermediateDirectories: true)
                guard let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.9) else { return }
                try jpeg.write(to: asset.url, options: .atomic)
                DispatchQueue.main.async {
                    self.backgrounds.insert(asset, at: 0); self.persistLibrary()
                    self.markRecent(asset.id)
                    if self.backgroundRequest == request { self.selectBackground(asset) }
                }
            } catch { self.report("Background could not be saved: \(error.localizedDescription)") }
        }
    }

    func selectBackground(_ asset: BackgroundAsset) {
        let request = UUID(); backgroundRequest = request
        captureQueue.async {
            guard let image = CIImage(contentsOf: asset.url) else { self.report("Saved background is unavailable."); return }
            DispatchQueue.main.async {
                guard self.backgroundRequest == request else { return }
                self.captureQueue.async { self.processor.background = image }
                self.selectedBackgroundID = asset.id; self.hasBackground = true; self.settings.background = .custom
                self.markRecent(asset.id)
            }
        }
    }

    func favoriteBackground(_ asset: BackgroundAsset) {
        if let index = backgrounds.firstIndex(where: { $0.id == asset.id }) { backgrounds[index].favorite.toggle(); persistLibrary() }
    }

    func removeBackground(_ asset: BackgroundAsset) {
        backgroundRequest = UUID()
        if selectedBackgroundID == asset.id { clearBackground() }
        backgrounds.removeAll { $0.id == asset.id }
        recentBackgroundIDs.removeAll { $0 == asset.id }
        try? FileManager.default.removeItem(at: asset.url)
        persistLibrary()
        persistRecents()
    }

    func clearRecentBackgrounds() {
        recentBackgroundIDs.removeAll()
        persistRecents()
        let retained = Set(presets.compactMap(\.backgroundID) + [selectedBackgroundID].compactMap { $0 })
        let unused = backgrounds.filter { !$0.favorite && !retained.contains($0.id) }
        for asset in unused { removeBackground(asset) }
    }

    var visibleBackgrounds: [BackgroundAsset] {
        let favorites = backgrounds.filter(\.favorite)
        let recents = recentBackgroundIDs.compactMap { id in backgrounds.first { $0.id == id && !$0.favorite } }
        return favorites + recents
    }

    private func markRecent(_ id: UUID) {
        recentBackgroundIDs.removeAll { $0 == id }
        recentBackgroundIDs.insert(id, at: 0)
        persistRecents()
    }

    private func persistRecents() {
        do { try CameraLibrary.save(recentBackgroundIDs, name: "recents.json") }
        catch { self.error = "Recent backgrounds could not be saved." }
    }

    private func persistLibrary() {
        do { try CameraLibrary.save(backgrounds, name: "backgrounds.json") }
        catch { self.error = "Background library could not be saved." }
    }

    func savePreset(name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        guard !name.isEmpty else { return }
        presets.append(CameraPreset(name: name, settings: settings, cameraID: selectedCamera, mirrorPreview: mirrorPreview,
            exposure: exposure, exposureLocked: exposureLocked, temperature: whiteBalanceTemperature,
            whiteBalanceLocked: whiteBalanceLocked, backgroundID: selectedBackgroundID, oledSaver: oledSaverEnabled,
            grid: UserDefaults.standard.bool(forKey: "framingGrid")))
        persistPresets()
    }

    func renamePreset(_ id: UUID, name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        guard !name.isEmpty, let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].name = name; persistPresets()
    }

    func deletePreset(_ id: UUID) { presets.removeAll { $0.id == id }; persistPresets() }

    private func persistPresets() {
        do { try CameraLibrary.save(presets, name: "presets.json") }
        catch { self.error = "Preset could not be saved." }
    }

    func applyPreset(_ preset: CameraPreset) {
        var restored = preset.settings
        if streaming || starting { restored.quality = settings.quality }
        if restored.background == .custom {
            restored.background = .off
            if let asset = backgrounds.first(where: { $0.id == preset.backgroundID }) { selectBackground(asset) }
        } else { backgroundRequest = UUID() }
        settings = restored; mirrorPreview = preset.mirrorPreview
        exposure = preset.exposure; exposureLocked = preset.exposureLocked
        whiteBalanceTemperature = preset.temperature; whiteBalanceLocked = preset.whiteBalanceLocked
        oledSaverEnabled = preset.oledSaver
        UserDefaults.standard.set(preset.grid, forKey: "framingGrid")
        if cameras.contains(where: { $0.id == preset.cameraID }), preset.cameraID != selectedCamera { switchCamera(preset.cameraID) }
    }

    func clearBackground() {
        backgroundRequest = UUID(); selectedBackgroundID = nil
        settings.background = .off; hasBackground = false
        captureQueue.async { self.processor.background = nil }
    }

    private func configureExposure() {
        let bias = exposure, locked = exposureLocked
        captureQueue.async { self.applyExposure(bias: bias, locked: locked) }
    }

    private func applyExposure(bias: Float, locked: Bool) {
        guard let device else { return }
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            let mode: AVCaptureDevice.ExposureMode = locked ? .locked : .continuousAutoExposure
            if device.isExposureModeSupported(mode) { device.exposureMode = mode }
            device.setExposureTargetBias(max(device.minExposureTargetBias, min(device.maxExposureTargetBias, bias)))
        } catch { report("Exposure could not be changed: \(error.localizedDescription)") }
    }

    private func configureWhiteBalance() {
        let temperature = whiteBalanceTemperature
        let locked = whiteBalanceLocked
        captureQueue.async { self.applyWhiteBalance(temperature: temperature, locked: locked) }
    }

    private func applyWhiteBalance(temperature: Float, locked: Bool) {
        guard let device else { return }
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            guard device.isWhiteBalanceModeSupported(.locked) else { return }
            if !locked, device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
                return
            }
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: 0)
            var gains = device.deviceWhiteBalanceGains(for: values)
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1), maxGain)
            device.setWhiteBalanceModeLocked(with: gains)
        } catch { report("White balance could not be changed: \(error.localizedDescription)") }
    }

    func toggleTorch() {
        let on = !torch
        captureQueue.async {
            guard let device = self.device, device.hasTorch, device.isTorchAvailable else { self.report("Torch is unavailable on this lens."); return }
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                if on { try device.setTorchModeOn(level: 0.5) } else { device.torchMode = .off }
                DispatchQueue.main.async { self.torch = on }
            } catch { self.report(error.localizedDescription) }
        }
    }

    private func updateOrientation() {
        let newOrientation: AVCaptureVideoOrientation = .landscapeRight
        captureQueue.async {
            guard self.orientation != newOrientation else { return }
            self.orientation = newOrientation; self.applyOrientation(); self.processor.reset()
        }
    }

    private func applyOrientation() {
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoOrientationSupported { connection.videoOrientation = orientation }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
        }
    }

    func toggleStream() {
        if streaming || starting { stopStream(); return }
        guard ProcessInfo.processInfo.thermalState != .critical else { error = "Let the phone cool down before starting a stream."; return }
        guard ready else { error = "Wait for the camera preview before starting."; return }
        starting = true
        rtsp.start(token: token, size: settings.outputSize, frameRate: settings.quality.frameRate)
        server.start(token: token, remoteToken: remoteKey)
    }

    func stopStream() {
        starting = false
        oledState.setStreaming(false, now: ProcessInfo.processInfo.systemUptime)
        syncOLEDSaver()
        server.stop()
        rtsp.stop()
    }

    var wifiH264URL: String? { wifiAddress.map { "rtsp://\($0):8554/facepull?token=\(token)" } }
    var usbH264URL: String { "rtsp://127.0.0.1:18554/facepull?token=\(token)" }

    private func updateMonitor() {
        let level = UIDevice.current.batteryLevel
        battery = level < 0 ? nil : Int((level * 100).rounded())
        wifiAddress = Self.localAddress()
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "Normal"
        case .fair: thermal = "Warm"
        case .serious: thermal = "Hot · reduced FPS"
        case .critical:
            thermal = "Too hot"
            if streaming || starting { stopStream(); error = "Streaming stopped so the phone can cool down." }
        @unknown default: thermal = "Unknown"
        }
    }

    private func updateViewers() {
        let count = h264Viewers
        if connectionAlerts && streaming && count != viewers {
            UINotificationFeedbackGenerator().notificationOccurred(count > viewers ? .success : .warning)
        }
        viewers = count
    }

    private func updateIdleTimer() {
        if streaming {
            if previousIdleTimer == nil { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled }
            UIApplication.shared.isIdleTimerDisabled = true
        } else if let previous = previousIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = previous; previousIdleTimer = nil
        }
    }

    private func syncOLEDSaver() {
        oledTimer?.invalidate()
        oledTimer = nil
        if dimmed != oledState.dimmed { dimmed = oledState.dimmed }
        guard let deadline = oledState.deadline else { return }
        let timer = Timer(timeInterval: max(0.001, deadline - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.oledState.advance(to: ProcessInfo.processInfo.systemUptime)
            self.syncOLEDSaver()
        }
        oledTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applyDimming() {
        if dimmed {
            if previousBrightness == nil { previousBrightness = UIScreen.main.brightness }
            UIScreen.main.brightness = 0
        } else if let previous = previousBrightness { UIScreen.main.brightness = previous; previousBrightness = nil }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        autoreleasepool {
            let time = ProcessInfo.processInfo.systemUptime
            let thermal = ProcessInfo.processInfo.thermalState
            let requested = processor.settings.quality.frameRate
            let limit: Double = thermal == .critical ? 5 : thermal == .serious ? min(15, requested) : requested
            guard time + 0.001 >= nextFrameTime, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            nextFrameTime = max(time, nextFrameTime + 1 / limit)
            do {
                let processingStarted = ProcessInfo.processInfo.systemUptime
                let image = try processor.process(buffer, time: time)
                StreamDiagnostics.sample("Frame processing", milliseconds: (ProcessInfo.processInfo.systemUptime - processingStarted) * 1000)
                // CIImage retains its source buffer. Keep only the latest preview;
                // each encoder owns its own bounded admission instead of forcing a
                // GPU readback and a second upload on the capture queue.
                preview.put(image)
                let captureTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let hostTime = session.masterClock.map {
                    CMSyncConvertTime(captureTime, from: $0, to: CMClockGetHostTimeClock())
                } ?? captureTime
                rtsp.offer(image, time: hostTime)
                statsFrames += 1
                if time - statsTime >= 1 {
                    let value = statsTime == 0 ? 0 : Int((Double(statsFrames) / (time - statsTime)).rounded())
                    statsFrames = 0; statsTime = time
                    DispatchQueue.main.async { self.fps = value }
                }
            } catch {
                if time - lastErrorTime > 10 { lastErrorTime = time; report("Frame processing failed: \(error.localizedDescription)") }
            }
        }
    }

    private func report(_ message: String) { DispatchQueue.main.async { self.error = message } }

    private static func localAddress() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }
        var cursor = addresses
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
