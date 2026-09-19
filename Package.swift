// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "FaceTrackCore", platforms: [.macOS(.v12)],
    products: [.library(name: "FaceTrackCore", targets: ["FaceTrackCore"])],
    targets: [.target(name: "FaceTrackCore", path: ".",
                      exclude: ["ArchivedAudio", "Tests", "UITests", "USB", "ThirdParty", "README.md", "NOTICE.md", "DEVICE-TESTS.md", "project.yml", "FaceTrackCam/Assets", "FaceTrackCam/CameraModel.swift", "FaceTrackCam/CameraScreen.swift", "FaceTrackCam/FaceTrackCamApp.swift", "FaceTrackCam/FrameProcessor.swift", "FaceTrackCam/MijickControls.swift", "FaceTrackCam/ProcessedPreview.swift"],
                      sources: ["Core", "FaceTrackCam/StreamServer.swift"]),
              .testTarget(name: "FaceTrackCoreTests", dependencies: ["FaceTrackCore"], path: "Tests")])
