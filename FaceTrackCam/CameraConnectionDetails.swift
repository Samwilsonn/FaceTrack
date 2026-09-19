import SwiftUI
import UIKit

/// One connection section for Host and its authenticated Remote; never builds
/// URLs from the Remote phone's own network address or credentials.
struct CameraConnectionDetails: View {
    let viewers: Int
    let wifiURL: String
    let usbURL: String
    let remoteWifiURL: String
    let remoteUSBURL: String
    let remotePassword: String
    let fps: Int
    let thermal: String
    let streaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Viewers", value: "\(viewers)")
            if !wifiURL.isEmpty { urlRow("Wi‑Fi · H.264", wifiURL) }
            if !usbURL.isEmpty { urlRow("USB · H.264", usbURL) }
            if !remoteWifiURL.isEmpty { urlRow("Remote · Wi-Fi", remoteWifiURL) }
            if !remoteUSBURL.isEmpty { urlRow("Remote · USB", remoteUSBURL) }
            if !remotePassword.isEmpty { urlRow("Remote password", remotePassword) }
            Text("\(fps) fps · \(thermal)").font(.caption)
        }.background(Color.clear)
    }

    private func urlRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.caption2.monospaced()).lineLimit(2).textSelection(.enabled)
            }
            Spacer()
            Button { UIPasteboard.general.string = value } label: {
                Image(systemName: "doc.on.doc").frame(width: 34, height: 34)
            }.disabled(!streaming)
        }.padding(8).liquidGlass(cornerRadius: 16)
    }
}
