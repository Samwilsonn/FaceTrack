import CoreGraphics

/// Both native preview surfaces use the same orientation/aspect-fill policy.
enum PreviewGeometry {
    static func rotatesToPortrait(source: CGSize, viewport: CGSize) -> Bool {
        viewport.height > viewport.width && source.width > source.height
    }
}
