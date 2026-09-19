import SwiftUI
import UIKit

// Exact Host visuals; bindings/actions select local or remote behavior.
struct CameraSliderRow: View {
    let label: String
    @Binding var enabled: Bool
    @Binding var value: Float
    let range: ClosedRange<Float>
    let center: Float
    let step: Float
    var body: some View {
        HStack(spacing: 16) {
            Toggle(label, isOn: $enabled).labelsHidden().fixedSize().tint(.blue)
                .onChange(of: enabled) { _, _ in FaceTrackHaptics.tap() }
            NativeMagneticSlider(value: $value, range: range, defaultValue: center, step: step)
                .accessibilityLabel(label + " adjustment")
        }.background(Color.clear)
    }
}

struct CameraSettingRow: View {
    let title: String
    let value: String
    let icon: String
    var angle: Angle = .zero
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).rotationEffect(angle)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CameraToolStrip: View {
    @Binding var panel: ToolPanel?
    @Binding var focused: ToolPanel?
    var angle: Angle = .zero
    var body: some View {
        HStack(spacing: 8) {
            ForEach(ToolPanel.allCases) { tool in
                Button {
                    withAnimation(.interpolatingSpring(stiffness: 300, damping: 20)) {
                        if focused == tool { panel = panel == tool ? nil : tool }
                        else { focused = tool; panel = nil }
                    }
                } label: {
                    Image(systemName: tool.icon).font(.system(size: 17, weight: .semibold)).rotationEffect(angle)
                        .frame(width: 44, height: 44)
                        .glassCapsule(tint: panel == tool ? .white.opacity(0.55) : .clear)
                        .scaleEffect(focused == nil ? 1 : focused == tool ? (panel == tool ? 1.3 : 1.15) : (panel == nil ? 0.9 : 0.8))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .foregroundStyle(panel == tool ? Color.black : Color.white)
                .blur(radius: panel != nil && panel != tool ? 1.5 : 0)
                .opacity(panel != nil && panel != tool ? 0.55 : 1)
                .zIndex(focused == tool ? 1 : 0)
                .shadow(color: .white.opacity(panel == tool ? 0.3 : 0), radius: 8)
                .accessibilityLabel(tool.rawValue)
                .accessibilityAddTraits(panel == tool ? .isSelected : [])
                .accessibilityHint(focused == tool ? "Double tap to \(panel == tool ? "close" : "open") menu" : "Double tap to focus")
            }
        }.padding(.bottom, 20)
    }
}

struct CameraSubjectChoices: View {
    let selected: String
    let select: (SubjectMode) -> Void
    var body: some View {
        HStack(spacing: 8) {
            ForEach(SubjectMode.allCases, id: \.self) { mode in
                Button { select(mode) } label: {
                    Text(mode.rawValue).font(.subheadline.weight(.medium)).padding(.horizontal, 16).frame(minHeight: 44)
                        .glassCapsule(tint: selected == mode.rawValue ? .white.opacity(0.18) : .clear)
                }
            }
        }
    }
}

struct CameraBackgroundThumbnail: View {
    let image: UIImage?
    let selected: Bool
    let favorite: Bool
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo") }
        }.frame(width: 80, height: 64).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topTrailing) { if favorite { Image(systemName: "star.fill").font(.caption).padding(4) } }
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.blue : Color.clear, lineWidth: 2))
    }
}
