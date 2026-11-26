import SwiftUI
import AVFoundation

struct AddMacView: View {
    @EnvironmentObject private var store: MacStore
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var error: String?
    @State private var added: PairedMac?
    @State private var cameraDenied = false

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    VStack(spacing: 20) {
                        if let added {
                            VStack(spacing: 14) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 72)).foregroundStyle(.green)
                                    .symbolEffect(.bounce, value: added.id)
                                Text("\(added.name) gekoppelt").font(.title2.bold())
                                Text("Live-Daten erscheinen, sobald der Mac online ist.").foregroundStyle(.secondary)
                                Button("Fertig") { dismiss() }
                                    .font(.headline).padding(.horizontal, 30).padding(.vertical, 12)
                                    .glassCapsule(tint: .green)
                            }
                            .padding(30)
                            .glassCard()
                        } else {
                            ZStack {
                                if cameraDenied {
                                    VStack(spacing: 10) {
                                        Image(systemName: "camera.fill").font(.largeTitle)
                                        Text("Kamera-Zugriff in den Einstellungen erlauben oder den Link unten einfügen.")
                                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                                    }
                                    .padding()
                                } else {
                                    QRScannerView { code in handle(code) }
                                }
                                RoundedRectangle(cornerRadius: 30, style: .continuous)
                                    .strokeBorder(.white.opacity(0.7), style: StrokeStyle(lineWidth: 3, dash: [26, 14]))
                                    .padding(36)
                                    .allowsHitTesting(false)
                            }
                            .frame(height: 340)
                            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                            .glassCard(cornerRadius: 30)

                            Text("Scanne den QR-Code aus Simplex Suite → Einstellungen → Remote.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Oder Kopplungs-Link einfügen").font(.headline)
                                HStack {
                                    TextField("simplexremote://pair?d=…", text: $link)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .font(.system(.footnote, design: .monospaced))
                                    Button {
                                        if let text = UIPasteboard.general.string { link = text; handle(text) }
                                    } label: { Image(systemName: "doc.on.clipboard") }
                                }
                                .padding(12)
                                .glass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                Button("Koppeln") { handle(link) }
                                    .disabled(link.isEmpty)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .glassCapsule(tint: .purple)
                            }
                            .padding(18)
                            .glassCard()

                            if let error {
                                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(18)
                    .readableWidth(560)
                }
            }
            .navigationTitle("Mac hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
            }
            .onAppear {
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .denied, .restricted: cameraDenied = true
                default: break
                }
            }
        }
    }

    private func handle(_ code: String) {
        guard added == nil else { return }
        guard let payload = PairingPayload(link: code) else {
            error = "Das ist kein gültiger Simplex-Kopplungscode."
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring) { added = store.add(payload) }
    }
}

// MARK: - QR scanner

struct QRScannerView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        let session = AVCaptureSession()
        context.coordinator.session = session
        DispatchQueue.global(qos: .userInitiated).async {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
            output.metadataObjectTypes = [.qr]
            session.startRunning()
        }
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        let session = coordinator.session
        DispatchQueue.global().async { session?.stopRunning() }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onCode: (String) -> Void
        var session: AVCaptureSession?
        private var done = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
                  code.hasPrefix("simplexremote://") else { return }
            done = true
            onCode(code)
        }
    }
}
