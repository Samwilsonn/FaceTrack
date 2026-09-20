import Foundation

extension CameraModel {
    func remoteState(includeConnectionDetails: Bool = false) -> [String: Any] {
        let visible = visibleBackgrounds
        let ids = Set(backgrounds.map(\.id))
        remoteThumbnailCache = remoteThumbnailCache.filter { ids.contains($0.key) }
        for asset in visible where remoteThumbnailCache[asset.id] == nil {
            remoteThumbnailCache[asset.id] = asset.thumbnail?.jpegData(compressionQuality: 0.65)?.base64EncodedString() ?? ""
        }
        return ["streaming": streaming, "fps": fps, "thermal": thermal, "viewers": viewers,
         "livePreview": remotePreviewEnabled, "previewName": remotePreviewName,
         "microphone": microphoneEnabled,
         "previewToken": peer.authorized ? remotePreviewToken : "",
         "connection": includeConnectionDetails && peer.authorized ? [
            "wifiURL": wifiH264URL ?? "", "usbURL": usbH264URL,
            "remoteWifiURL": wifiAddress.map { "http://\($0):8080/remote" } ?? "",
            "remoteUSBURL": "http://127.0.0.1:18080/remote", "remotePassword": remoteKey
         ] : [String: String](),
         "lens": selectedCamera, "quality": settings.quality.rawValue, "tracking": settings.tracking,
         "intensity": Double(settings.intensity), "subject": settings.subjectMode.rawValue,
         "exposure": exposure, "exposureLocked": exposureLocked, "temperature": whiteBalanceTemperature,
         "whiteBalanceLocked": whiteBalanceLocked, "background": settings.background.rawValue, "mirror": settings.mirrorStream,
         "ready": ready, "starting": starting, "torch": torch, "hasTorch": hasTorch,
         "frontCamera": frontCamera, "mirrorPreview": mirrorPreview,
         "hasRecentBackgrounds": !recentBackgroundIDs.isEmpty,
         "selectedBackground": selectedBackgroundID?.uuidString ?? "",
         "cameras": cameras.map { ["id": $0.id, "name": $0.name] },
         "qualities": VideoQuality.allCases.map { ["id": $0.rawValue, "name": $0.label] },
         "presets": presets.map { ["id": $0.id.uuidString, "name": $0.name] },
         "backgrounds": visible.map { asset in
            ["id": asset.id.uuidString, "name": "Background", "thumb": remoteThumbnailCache[asset.id] ?? ""]
         }]
    }

    func applyRemote(_ command: [String: Any]) -> String? {
        guard let action = command["action"] as? String else { return "Missing action" }
        let value = command["value"] as? String ?? ""
        switch action {
        case "flipCamera": flipCamera()
        case "torch": toggleTorch()
        case "mirrorPreview":
            guard let flag = command["value"] as? Bool else { return "Expected on/off" }
            mirrorPreview = flag
        case "livePreview":
            guard let flag = command["value"] as? Bool, peer.authorized else { return "Pair a Remote first" }
            setRemotePreviewEnabled(flag)
        case "stream":
            guard let on = command["value"] as? Bool else { return "Expected on/off" }
            if on != (streaming || starting) { toggleStream() }
        case "lens": guard cameras.contains(where: { $0.id == value }) else { return "Unknown lens" }; switchCamera(value)
        case "quality":
            guard !streaming && !starting else { return "Stop streaming before changing quality" }
            guard let quality = VideoQuality(rawValue: value) else { return "Unknown quality" }; settings.quality = quality
        case "tracking", "exposureLocked", "whiteBalanceLocked", "mirror":
            guard let flag = command["value"] as? Bool else { return "Expected on/off" }
            switch action {
            case "tracking": settings.tracking = flag
            case "exposureLocked": exposureLocked = flag
            case "whiteBalanceLocked": whiteBalanceLocked = flag
            default: settings.mirrorStream = flag
            }
        case "microphone":
            guard let flag = command["value"] as? Bool else { return "Expected on/off" }
            setMicrophoneEnabled(flag)
        case "intensity", "exposure", "temperature":
            guard let number = Float(value), number.isFinite else { return "Invalid adjustment" }
            switch action {
            case "intensity": settings.intensity = CGFloat(min(2.2, max(0.8, number)))
            case "exposure": exposure = min(2, max(-2, number))
            default: whiteBalanceLocked = true; whiteBalanceTemperature = min(6500, max(2500, number))
            }
        case "subject":
            guard let mode = SubjectMode(rawValue: value) else { return "Unknown mode" }
            settings.subjectMode = mode
            if mode == .lock { relockSubject() }
        case "background": guard let mode = BackgroundMode(rawValue: value), mode != .custom else { return "Choose a saved background" }; setBackgroundMode(mode)
        case "asset": guard let asset = backgrounds.first(where: { $0.id.uuidString == value }) else { return "Unknown background" }; selectBackground(asset)
        case "clearRecentBackgrounds": clearRecentBackgrounds()
        case "uploadBackground":
            guard let data = Data(base64Encoded: value), data.count <= 8_000_000 else { return "Invalid background image" }
            loadBackground(data)
        case "preset": guard let preset = presets.first(where: { $0.id.uuidString == value }) else { return "Unknown preset" }; applyPreset(preset)
        case "savePreset": guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Enter a name" }; savePreset(name: value)
        case "relock": relockSubject()
        case "wake": wakeFromOLEDSaver()
        default: return "Unknown action"
        }
        return nil
    }
}
