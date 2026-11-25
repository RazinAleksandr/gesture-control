import AVFoundation
import Vision
import CoreMedia
import QuartzCore

/// Webcam capture + Apple Vision hand-pose detection (on-device).
/// `onHand` is called on the camera queue for every processed frame (nil = no hand).
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let frameQueue = DispatchQueue(label: "gc.camera.frames", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "gc.camera.session")
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()

    var onHand: ((HandFrame?) -> Void)?
    private(set) var deviceName = ""
    private(set) var fps: Double = 0
    private(set) var visionMs: Double = 0
    private var fpsWindowStart = CACurrentMediaTime()
    private var fpsFrames = 0

    static func authorize(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    static func allDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    /// Prefers a device whose name contains `preferred`, else the built-in camera.
    static func pickDevice(preferred: String?) -> AVCaptureDevice? {
        let devs = allDevices()
        if let pref = preferred?.lowercased(), !pref.isEmpty,
           let d = devs.first(where: { $0.localizedName.lowercased().contains(pref) }) {
            return d
        }
        return devs.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devs.first
    }

    func configure(preferred: String?) throws {
        guard let dev = Camera.pickDevice(preferred: preferred) else {
            throw NSError(domain: "gc", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("Camera not found", "Камера не найдена", "未找到摄像头")])
        }
        deviceName = dev.localizedName
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else {
            throw NSError(domain: "gc", code: 2, userInfo: [NSLocalizedDescriptionKey: tr("Could not connect the camera", "Не удалось подключить камеру", "无法连接摄像头")])
        }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        out.setSampleBufferDelegate(self, queue: frameQueue)
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
    }

    func start() { sessionQueue.async { self.session.startRunning() } }
    func stop() { sessionQueue.async { self.session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t0 = CACurrentMediaTime()
        var frame: HandFrame? = nil
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        do {
            try handler.perform([handRequest])
            if let obs = handRequest.results?.first, obs.confidence > 0.3 {
                let pts = try obs.recognizedPoints(.all)
                var points: [Joint: CGPoint] = [:]
                var conf: [Joint: Float] = [:]
                for (j, rp) in pts {
                    // Vision: origin bottom-left, not mirrored → ours: top-left, mirrored.
                    points[j] = CGPoint(x: 1 - rp.location.x, y: 1 - rp.location.y)
                    conf[j] = rp.confidence
                }
                frame = HandFrame(time: t0, points: points, confidences: conf)
            }
        } catch {
            // keep frame = nil
        }
        let t1 = CACurrentMediaTime()
        visionMs = visionMs * 0.9 + (t1 - t0) * 1000 * 0.1
        fpsFrames += 1
        if t1 - fpsWindowStart >= 1 {
            fps = Double(fpsFrames) / (t1 - fpsWindowStart)
            fpsFrames = 0
            fpsWindowStart = t1
        }
        onHand?(frame)
    }
}
