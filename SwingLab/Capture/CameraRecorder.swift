import Foundation
import AVFoundation
import UIKit

/// AVFoundation recorder configured for the highest frame rate the back
/// camera supports (120/240 fps where available) so swing frames are crisp.
final class CameraRecorder: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case ready
        case recording
        case denied
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var isRecording = false
    @Published var activeFrameRate: Double = 0

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "swinglab.camera")
    private var finishHandler: ((URL?) -> Void)?

    func requestAccessAndConfigure() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.state = .denied }
                return
            }
            self.sessionQueue.async { self.configureSession() }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.state = .failed("The back camera isn't available on this device.") }
            return
        }
        session.addInput(input)

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        session.commitConfiguration()

        configureHighestFrameRate(device: device)

        session.startRunning()
        DispatchQueue.main.async { self.state = .ready }
    }

    /// Picks the format with the highest max frame rate at 1080p-or-better
    /// and locks the device to it.
    private func configureHighestFrameRate(device: AVCaptureDevice) {
        var bestFormat: AVCaptureDevice.Format?
        var bestRate: Double = 0

        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.height >= 720 else { continue }
            for range in format.videoSupportedFrameRateRanges where range.maxFrameRate > bestRate {
                bestRate = range.maxFrameRate
                bestFormat = format
            }
        }

        guard let format = bestFormat, bestRate > 30 else {
            DispatchQueue.main.async { self.activeFrameRate = 30 }
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(bestRate))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.activeFrameRate = bestRate }
        } catch {
            DispatchQueue.main.async { self.activeFrameRate = 30 }
        }
    }

    func startRecording() {
        sessionQueue.async { [weak self] in
            guard let self, !self.movieOutput.isRecording else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("swing-\(UUID().uuidString).mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            DispatchQueue.main.async {
                self.isRecording = true
                self.state = .recording
            }
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        finishHandler = completion
        sessionQueue.async { [weak self] in
            self?.movieOutput.stopRecording()
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }
}

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.state = .ready
            self.finishHandler?(error == nil ? outputFileURL : nil)
            self.finishHandler = nil
        }
    }
}
