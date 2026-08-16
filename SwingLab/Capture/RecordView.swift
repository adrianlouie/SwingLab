import SwiftUI
import AVFoundation

/// Live camera preview backed by AVCaptureVideoPreviewLayer.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// In-app slow-motion recording screen with an alignment guide.
struct RecordView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = CameraRecorder()
    let onVideoCaptured: (URL) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch recorder.state {
            case .idle:
                ProgressView("Starting camera…").tint(.white).foregroundStyle(.white)
            case .denied:
                permissionDeniedView
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding()
            case .ready, .recording:
                CameraPreview(session: recorder.session)
                    .ignoresSafeArea()
                alignmentGuide
                controls
            }
        }
        .onAppear { recorder.requestAccessAndConfigure() }
        .onDisappear { recorder.stopSession() }
    }

    /// A subtle center column + ground line to help frame the golfer.
    private var alignmentGuide: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { p in
                p.move(to: CGPoint(x: w / 2, y: h * 0.12))
                p.addLine(to: CGPoint(x: w / 2, y: h * 0.88))
                p.move(to: CGPoint(x: w * 0.15, y: h * 0.85))
                p.addLine(to: CGPoint(x: w * 0.85, y: h * 0.85))
            }
            .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        }
        .allowsHitTesting(false)
    }

    private var controls: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                if recorder.activeFrameRate > 0 {
                    Text("\(Int(recorder.activeFrameRate)) FPS")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding()

            Spacer()

            Button {
                if recorder.isRecording {
                    Haptics.impact()
                    recorder.stopRecording { url in
                        if let url {
                            onVideoCaptured(url)
                        }
                        dismiss()
                    }
                } else {
                    Haptics.impact()
                    recorder.startRecording()
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 76, height: 76)
                    RoundedRectangle(cornerRadius: recorder.isRecording ? 6 : 32)
                        .fill(.red)
                        .frame(width: recorder.isRecording ? 32 : 62,
                               height: recorder.isRecording ? 32 : 62)
                        .animation(.spring(duration: 0.25), value: recorder.isRecording)
                }
            }
            .padding(.bottom, 40)
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.largeTitle)
                .foregroundStyle(.white)
            Text("Camera access is off")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Enable it in Settings → SwingLab → Camera to record swings in-app. You can still import videos from your library.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
