import AVFoundation
import Network
import VideoToolbox

/// Captures the camera at its best 16:9 mode, encodes HEVC and serves it as a raw Annex B
/// stream to one TCP client on port 5000 (USB through usbmuxd/iproxy, or Wi-Fi).
final class Streamer: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var connected = false
    @Published var cameras: [AVCaptureDevice] = []
    @Published var camera: AVCaptureDevice?
    @Published var mode = ""
    @Published var stats = ""

    let session = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()

    private let queue = DispatchQueue(label: "cami.video")
    private let output = AVCaptureVideoDataOutput()
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservers: [NSKeyValueObservation] = []
    private var listener: NWListener?
    private var client: NWConnection?
    private var inFlight = 0
    private var encoder: VTCompressionSession?
    private var encoderSize = (Int32(0), Int32(0))
    private var fps = 60.0
    private var needKeyframe = true
    private var statsStart = Date()
    private var captured = 0, sent = 0, networkDrops = 0
    private var cameraDrops: [String: Int] = [:]

    override init() {
        super.init()
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect
    }

    func start() {
        listen()
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if granted { self.queue.async { self.configure() } }
        }
    }

    func select(_ device: AVCaptureDevice) { queue.async { self.use(device) } }

    func setZoom(_ zoom: CGFloat) {
        configureCamera { $0.videoZoomFactor = min(max(zoom, $0.minAvailableVideoZoomFactor), $0.maxAvailableVideoZoomFactor) }
    }

    func setExposure(_ bias: Float) {
        configureCamera { $0.setExposureTargetBias(min(max(bias, $0.minExposureTargetBias), $0.maxExposureTargetBias), completionHandler: nil) }
    }

    // MARK: Capture

    private func configure() {
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .unspecified
        ).devices
        session.beginConfiguration()
        session.sessionPreset = .inputPriority // the format comes from bestFormat(of:), not a preset
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        DispatchQueue.main.async { self.cameras = found }
        if let first = found.first { use(first) }
        session.startRunning()
    }

    private func use(_ device: AVCaptureDevice) {
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) { session.addInput(input) }
        var mode = ""
        if case let (format, rate)? = Self.bestFormat(of: device), (try? device.lockForConfiguration()) != nil {
            device.activeFormat = format
            // Fixed rate: in low light the camera would otherwise drop below 60 fps to expose longer.
            device.activeVideoMinFrameDuration = rate.minFrameDuration
            device.activeVideoMaxFrameDuration = rate.minFrameDuration
            device.unlockForConfiguration()
            // The sensor's own pixel format: any other one costs a 4K conversion on every frame.
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: CMFormatDescriptionGetMediaSubType(format.formatDescription)]
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            fps = rate.maxFrameRate
            mode = "\(size.width)×\(size.height) · \(Int(fps.rounded())) fps"
        }
        session.commitConfiguration()
        encoderSize = (0, 0) // rebuild the encoder for the new frame rate
        DispatchQueue.main.async {
            self.camera = device
            self.mode = mode
            self.followRotation(of: device)
        }
    }

    /// Highest 16:9 resolution that reaches 60 fps, then the highest frame rate.
    /// A camera that can't do 60 fps at all falls back to its largest mode.
    static func bestFormat(of device: AVCaptureDevice) -> (AVCaptureDevice.Format, AVFrameRateRange)? {
        let eightBit = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        let candidates = device.formats.compactMap { format -> (AVCaptureDevice.Format, AVFrameRateRange, (Int, Int32, Double, Int))? in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard eightBit.contains(CMFormatDescriptionGetMediaSubType(format.formatDescription)),
                  size.width * 9 == size.height * 16,
                  let rate = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return nil }
            let rank = (rate.maxFrameRate >= 59.9 ? 1 : 0, size.width * size.height, rate.maxFrameRate, format.isVideoBinned ? 0 : 1)
            return (format, rate, rank)
        }
        return candidates.max(by: { $0.2 < $1.2 }).map { ($0.0, $0.1) }
    }

    private func configureCamera(_ change: @escaping (AVCaptureDevice) -> Void) {
        queue.async {
            guard let device = (self.session.inputs.first as? AVCaptureDeviceInput)?.device,
                  (try? device.lockForConfiguration()) != nil else { return }
            change(device)
            device.unlockForConfiguration()
        }
    }

    /// Keeps the image level however the phone is held.
    private func followRotation(of device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotation = coordinator
        rotationObservers = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] c, _ in
                let angle = c.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { rotate(self?.previewLayer.connection, angle) }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] c, _ in
                let angle = c.videoRotationAngleForHorizonLevelCapture
                // Landscape only: turning to portrait would change the resolution, and the
                // v4l2 device can't change format while a video call is reading it.
                guard angle.truncatingRemainder(dividingBy: 180) == 0 else { return }
                self?.queue.async { rotate(self?.output.connection(with: .video), angle) }
            },
        ]
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        captured += 1
        updateStats()
        guard client != nil, let frame = CMSampleBufferGetImageBuffer(sample) else { return }
        // Dropping before the encoder keeps its reference chain intact, so no keyframe is needed to recover.
        // ponytail: plain drop while the link is backed up; add bitrate adaptation if Wi-Fi gets choppy
        if inFlight > 4 { networkDrops += 1; return }
        let size = (Int32(CVPixelBufferGetWidth(frame)), Int32(CVPixelBufferGetHeight(frame)))
        if encoder == nil || encoderSize != size { makeEncoder(size) }
        guard let encoder else { return }
        let options = needKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        needKeyframe = false
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: frame, presentationTimeStamp: sample.presentationTimeStamp,
                                        duration: .invalid, frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, encoded in
            guard status == noErr, let encoded, let data = Streamer.annexB(encoded) else { return }
            self?.queue.async { self?.send(data) }
        }
    }

    /// Frames the camera produced but never delivered, keyed by Apple's reason (FrameWasLate, OutOfBuffers...).
    func captureOutput(_ output: AVCaptureOutput, didDrop sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        let reason = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) as? String
        cameraDrops[reason ?? "?", default: 0] += 1
    }

    /// One line per second on screen: where frames are lost, if anywhere.
    private func updateStats() {
        let elapsed = -statsStart.timeIntervalSinceNow
        guard elapsed >= 1 else { return }
        var parts = [String(format: "cámara %.0f · enviado %.0f fps", Double(captured) / elapsed, Double(sent) / elapsed)]
        if networkDrops > 0 { parts.append("red \(networkDrops)") }
        parts += cameraDrops.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        if let device = (session.inputs.first as? AVCaptureDeviceInput)?.device {
            parts.append("mín \(Int((1 / device.activeVideoMaxFrameDuration.seconds).rounded())) fps")
            parts.append("temp \(device.systemPressureState.level.rawValue)")
        }
        parts.append("rot \(Int(output.connection(with: .video)?.videoRotationAngle ?? 0))°")
        let text = parts.joined(separator: " · ")
        DispatchQueue.main.async { self.stats = text }
        statsStart = Date()
        captured = 0
        sent = 0
        networkDrops = 0
        cameraDrops = [:]
    }

    // MARK: Encoding

    private func makeEncoder(_ size: (Int32, Int32)) {
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        var session: VTCompressionSession?
        // HEVC: iOS only encodes 4K60 in HEVC, and it's sharper than H.264 at the same bitrate.
        VTCompressionSessionCreate(allocator: nil, width: size.0, height: size.1, codecType: kCMVideoCodecType_HEVC,
                                   encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard let session else { return }
        let bitrate = Double(size.0) * Double(size.1) * fps / 10 // ~50 Mbps at 4K60, ~12 Mbps at 1080p60
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // Emit each frame as soon as it's encoded: held frames add latency and pin capture buffers.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 0))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 1))
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
        encoderSize = size
        needKeyframe = true
    }

    static let startCode = Data([0, 0, 0, 1])

    /// VPS/SPS/PPS go in front of every frame (~100 bytes) so the receiver can join at any keyframe.
    static func annexB(_ sample: CMSampleBuffer) -> Data? {
        guard let format = sample.formatDescription, let avcc = try? sample.dataBuffer?.dataBytes() else { return nil }
        var out = Data()
        var count = 0
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        for i in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var length = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                               parameterSetSizeOut: &length, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let pointer { out += startCode; out.append(pointer, count: length) }
        }
        return out + avccToAnnexB(avcc)
    }

    /// VideoToolbox emits 4-byte length-prefixed NAL units; a raw .h264 stream needs start codes instead.
    static func avccToAnnexB(_ avcc: Data) -> Data {
        var out = Data()
        var i = avcc.startIndex
        while i + 4 <= avcc.endIndex {
            let length = avcc[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            let end = min(i + 4 + length, avcc.endIndex)
            out += startCode + avcc[(i + 4)..<end]
            i = end
        }
        return out
    }

    // MARK: Network

    private func listen() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        guard let listener = try? NWListener(using: NWParameters(tls: nil, tcp: tcp), on: 5000) else { return }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        client?.cancel()
        client = connection
        inFlight = 0
        needKeyframe = true
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.disconnect(connection)
            default: break
            }
        }
        connection.start(queue: queue)
        // The receiver never sends anything; a completed read means it hung up.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, done, error in
            if done || error != nil { connection.cancel() }
        }
        DispatchQueue.main.async { self.connected = true }
    }

    private func disconnect(_ connection: NWConnection) {
        guard client === connection else { return }
        client = nil
        DispatchQueue.main.async { self.connected = false }
    }

    private func send(_ data: Data) {
        guard let connection = client else { return }
        inFlight += 1
        sent += 1
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self, self.client === connection else { return }
            self.inFlight -= 1
        })
    }
}

private func rotate(_ connection: AVCaptureConnection?, _ angle: CGFloat) {
    if let connection, connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
}
