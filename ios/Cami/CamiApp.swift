import AVFoundation
import SwiftUI
import UIKit

@main
struct CamiApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @StateObject private var streamer = Streamer()
    @State private var zoom = 1.0
    @State private var exposure = 0.0

    var body: some View {
        ZStack(alignment: .bottom) {
            Preview(layer: streamer.previewLayer).ignoresSafeArea()
            VStack(spacing: 12) {
                Label(streamer.connected ? "Conectado a Linux" : "Esperando conexión (puerto 5000)",
                      systemImage: streamer.connected ? "checkmark.circle.fill" : "cable.connector")
                Picker("Cámara", selection: cameraSelection) {
                    ForEach(streamer.cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
                Text(streamer.mode).font(.caption.monospacedDigit())
                HStack { Text("Zoom"); Slider(value: $zoom, in: 1...5) }
                    .onChange(of: zoom) { streamer.setZoom(zoom) }
                HStack { Text("Exposición"); Slider(value: $exposure, in: -2...2) }
                    .onChange(of: exposure) { streamer.setExposure(Float(exposure)) }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true // a locked phone stops the camera
            streamer.start()
        }
    }

    private var cameraSelection: Binding<String?> {
        Binding(get: { streamer.camera?.uniqueID }, set: { id in
            guard let device = streamer.cameras.first(where: { $0.uniqueID == id }) else { return }
            zoom = 1
            exposure = 0
            streamer.select(device)
        })
    }
}

struct Preview: UIViewRepresentable {
    let layer: CALayer
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.layer.addSublayer(layer)
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.forEach { $0.frame = bounds }
    }
}
