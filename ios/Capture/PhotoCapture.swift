import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Owns the AVCapturePhotoOutput (AVCam PhotoCapture). Used only from the CaptureService actor.
final class PhotoCapture {
    let output = AVCapturePhotoOutput()
    // Delegates finish on AVFoundation's queue, so the table that keeps them alive is locked.
    private let lock = NSLock()
    private var inFlight: [Int64: NSObject] = [:]

    private func keep(_ id: Int64, _ delegate: NSObject?) {
        lock.lock()
        inFlight[id] = delegate
        lock.unlock()
    }

    /// Called with the session already configured for `device`.
    func updateConfiguration(for device: AVCaptureDevice, fullResolution: Bool) {
        let dims = device.activeFormat.supportedMaxPhotoDimensions
        if let largest = dims.max(by: { $0.megapixels < $1.megapixels }) {
            output.maxPhotoDimensions = fullResolution ? largest : (Self.standard(in: dims) ?? largest)
        }
        output.maxPhotoQualityPrioritization = .quality
        if output.isResponsiveCaptureSupported { output.isResponsiveCaptureEnabled = true }
        if output.isFastCapturePrioritizationSupported { output.isFastCapturePrioritizationEnabled = false }
        if output.isZeroShutterLagSupported { output.isZeroShutterLagEnabled = true }
    }

    /// Largest size up to ~12.6 MP: the binned output of a 48 MP quad sensor.
    static func standard(in dims: [CMVideoDimensions]) -> CMVideoDimensions? {
        dims.filter { $0.megapixels <= 12.7 }.max(by: { $0.megapixels < $1.megapixels })
    }

    var supportsFullResolution: Bool {
        (output.maxPhotoDimensions.megapixels) > 12.7
    }

    /// The system's capture sound can be kept silent (iOS 18; not where the region requires it): CameraSounds plays the app's
    /// own shutter sound once per shot instead (Android: one sound at the press, not one per frame of the series).
    var suppressesShutterSound: Bool {
        if #available(iOS 18.0, *) { return output.isShutterSoundSuppressionSupported }
        return false
    }

    /// Every request without the system's capture sound where that is allowed.
    func silence(_ settings: AVCapturePhotoSettings) {
        if #available(iOS 18.0, *), output.isShutterSoundSuppressionSupported { settings.isShutterSoundSuppressionEnabled = true }
    }

    /// FlashMode Auto: the scene is metered for the flash (isFlashScene) while it is chosen on a lens with a flash unit.
    func monitorFlashScene(_ on: Bool) {
        if on, output.supportedFlashModes.contains(.auto) {
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .auto
            output.photoSettingsForSceneMonitoring = settings
        } else {
            output.photoSettingsForSceneMonitoring = nil
        }
    }

    var isFlashScene: Bool { output.isFlashScene }

    /// Settings in order of preference; the next one is tried when AVFoundation raises on the previous one.
    func candidateSettings(for request: PhotoRequest, device: AVCaptureDevice) -> [(AVCapturePhotoSettings, String)] {
        // «Формат фото» and its quality (PhotoEncoding): the camera encodes the photo in the chosen codec at its quality (HEIC: HEVC
        // where the camera has it), so its own photo is written once (CameraPhotoFinish); each kind of request again without the
        // quality where AVFoundation refuses it
        let format = PhotoEncoding.current()
        let codecs = output.availablePhotoCodecTypes
        let codec: AVVideoCodecType = format.type == .heic && codecs.contains(.hevc) ? .hevc
            : codecs.contains(.jpeg) ? .jpeg : codecs.contains(.hevc) ? .hevc : .jpeg
        let quality = min(1, max(0.01, format.quality))
        let processedWithQuality: [String: Any] = [AVVideoCodecKey: codec, AVVideoCompressionPropertiesKey: [AVVideoQualityKey: quality]]
        let processed: [String: Any] = [AVVideoCodecKey: codec]
        let qualityLabel = " q\(Int((quality * 100).rounded()))"
        let bayer = output.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        let proRAW = output.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        var raws: [(OSType, String)] = []
        switch request.raw {
        case .off: break
        case .bayer:
            if let bayer { raws.append((bayer, "bayer \(bayer.fourCC)")) }
            if let proRAW { raws.append((proRAW, "proraw \(proRAW.fourCC) (fallback)")) }
        case .proRAW:
            if let proRAW { raws.append((proRAW, "proraw \(proRAW.fourCC)")) }
        }
        var result: [(AVCapturePhotoSettings, String)] = []
        for (type, label) in raws {
            for (processedFormat, q) in [(processedWithQuality, qualityLabel), (processed, "")] {
                guard let settings = Self.made({ AVCapturePhotoSettings(rawPixelFormatType: type, processedFormat: processedFormat) }) else { continue }
                // ProRAW: the least of Apple's own processing (no multi-frame fusion, the lightest denoise the camera allows)
                let proraw = AVCapturePhotoOutput.isAppleProRAWPixelFormat(type)
                configure(settings, request: request, priority: proraw ? .speed : .balanced)
                if proraw {
                    settings.isAutoRedEyeReductionEnabled = false
                    if output.isContentAwareDistortionCorrectionSupported { settings.isAutoContentAwareDistortionCorrectionEnabled = false }
                }
                result.append((settings, "\(label) + \(codec.rawValue)\(q) priority=\(settings.photoQualityPrioritization.rawValue)"))
            }
        }
        for (processedFormat, q) in [(processedWithQuality, qualityLabel), (processed, "")] {
            guard let plain = Self.made({ AVCapturePhotoSettings(format: processedFormat) }) else { continue }
            configure(plain, request: request, priority: .quality)
            result.append((plain, codec.rawValue + q + (request.raw == .off ? "" : " (no RAW)")))
        }
        return result
    }

    /// Settings AVFoundation accepts (an exception from their initialiser: nil, the next candidate then)
    private static func made(_ make: () -> AVCapturePhotoSettings) -> AVCapturePhotoSettings? {
        var settings: AVCapturePhotoSettings?
        if let reason = SCAMObjC.catchException({ settings = make() }) {
            SessionLog.w("PhotoCapture", "photo settings refused: \(reason)")
            return nil
        }
        return settings
    }

    private func configure(_ settings: AVCapturePhotoSettings, request: PhotoRequest, priority: AVCapturePhotoOutput.QualityPrioritization) {
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        if request.flash != .off, output.supportedFlashModes.contains(request.flash) { settings.flashMode = request.flash }
        silence(settings)
        let level = min(priority.rawValue, output.maxPhotoQualityPrioritization.rawValue)
        settings.photoQualityPrioritization = AVCapturePhotoOutput.QualityPrioritization(rawValue: level) ?? .balanced
        if let preview = settings.availablePreviewPhotoPixelFormatTypes.first {
            settings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: preview]
        }
    }

    func capture(_ request: PhotoRequest, device: AVCaptureDevice) async throws -> CapturedPhoto {
        var notes: [String] = []
        var lastError: Error = CameraError.setupFailed
        for (settings, label) in candidateSettings(for: request, device: device) {
            let started = Date()
            do {
                var photo = try await capture(settings, exif: request.exif)
                photo.report.insert("capture \(label) flash=\(settings.flashMode.rawValue) zoom=\(device.videoZoomFactor) in \(Int(Date().timeIntervalSince(started) * 1000)) ms", at: 0)
                photo.report.insert(contentsOf: notes, at: 0)
                return photo
            } catch CameraError.captureException(let reason) {
                notes.append("capture \(label) refused: \(reason)")
                lastError = CameraError.captureException(reason)
            }
        }
        notes.forEach { SessionLog.w("PhotoCapture", $0) }
        throw lastError
    }

    private func capture(_ settings: AVCapturePhotoSettings, exif: ShotExif?) async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            let id = settings.uniqueID
            let delegate = PhotoCaptureDelegate(exif: exif) { [weak self] result in
                self?.keep(id, nil)
                continuation.resume(with: result)
            }
            keep(id, delegate)
            if let reason = SCAMObjC.catchException({ self.output.capturePhoto(with: settings, delegate: delegate) }) {
                keep(id, nil)
                continuation.resume(throwing: CameraError.captureException(reason))
            }
        }
    }

    /// Every photo of one request (a bracket of RAW frames), in delivery order. With `timeout` (CaptureController's series timeout)
    /// the photos delivered by then are returned and the later ones of the request dropped (a late frame is left out, the shot goes on).
    func capturePhotos(_ settings: AVCapturePhotoSettings, timeout: TimeInterval? = nil) async throws -> [AVCapturePhoto] {
        try await withCheckedThrowingContinuation { continuation in
            let id = settings.uniqueID
            let delegate = BurstCaptureDelegate(release: { [weak self] in self?.keep(id, nil) }) { result in
                continuation.resume(with: result)
            }
            keep(id, delegate)
            if let reason = SCAMObjC.catchException({ self.output.capturePhoto(with: settings, delegate: delegate) }) {
                keep(id, nil)
                delegate.deliver(.failure(CameraError.captureException(reason)))
                return
            }
            if let timeout {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak delegate] in
                    delegate?.expire(after: timeout)
                }
            }
        }
    }

    func setVideoRotationAngle(_ angle: CGFloat) {
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    /// The front lens's photo mirrored, as its viewfinder (Android Parameters.mirror: the front camera's photo is mirrored)
    func setMirrored(_ mirrored: Bool) {
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }
}

/// AVCam PhotoCaptureDelegate: collects the processed photo and the RAW of one request.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<CapturedPhoto, Error>) -> Void
    private var processed: Data?
    private var processedUTI = UTType.heic.identifier
    private var rawFile: URL?
    private var report: [String] = []
    private var failure: Error?
    private let started = Date()
    private let exif: ShotExif?

    init(exif: ShotExif?, completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        self.exif = exif
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        report.append("resolved photo=\(resolvedSettings.photoDimensions.text) raw=\(resolvedSettings.rawPhotoDimensions.text)"
            + " preview=\(resolvedSettings.previewDimensions.text) count=\(resolvedSettings.expectedPhotoCount)")
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { failure = error; return }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue ?? 0
        let exposure = (exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? 0
        if photo.isRawPhoto {
            var line = "raw at \(ms) ms"
            if let buffer = photo.pixelBuffer {
                line += " buffer=\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) \(CVPixelBufferGetPixelFormatType(buffer).fourCC)"
                    + " row=\(CVPixelBufferGetBytesPerRow(buffer))"
            }
            line += " iso=\(iso) exposure=\(String(format: "%.5f", exposure))"
            if let data = photo.fileDataRepresentation() {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("SCAM_\(UUID().uuidString).dng")
                do {
                    try data.write(to: url)
                    rawFile = url
                    line += " dng=\(data.count) bytes"
                } catch {
                    line += " dng write failed: \(error.localizedDescription)"
                }
            }
            report.append(line)
        } else {
            // the shot's facts in the camera's own photo (ShotExif: time, ISO, lens, Software, description)
            if let facts = self.exif, let data = photo.fileDataRepresentation(with: ShotExifCustomizer(facts)) {
                processed = data
            } else {
                processed = photo.fileDataRepresentation()
            }
            report.append("processed at \(ms) ms \(photo.resolvedSettings.photoDimensions.text) \(processed?.count ?? 0) bytes"
                + " iso=\(iso) exposure=\(String(format: "%.5f", exposure))")
            if let type = processed.flatMap(Self.uti) { processedUTI = type }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error = error ?? failure {
            if let rawFile { try? FileManager.default.removeItem(at: rawFile) }
            completion(.failure(error))
            return
        }
        guard processed != nil || rawFile != nil else {
            completion(.failure(CameraError.setupFailed))
            return
        }
        completion(.success(CapturedPhoto(processed: processed, processedUTI: processedUTI, rawFile: rawFile, report: report)))
    }

    private static func uti(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceGetType(source) as String?
    }
}

/// Collects the photos of a bracket request.
private final class BurstCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let lock = NSLock()
    private var completion: ((Result<[AVCapturePhoto], Error>) -> Void)?
    private let release: () -> Void
    private var photos: [AVCapturePhoto] = []
    private var failure: Error?

    init(release: @escaping () -> Void, completion: @escaping (Result<[AVCapturePhoto], Error>) -> Void) {
        self.release = release
        self.completion = completion
    }

    /// The request's result, once
    func deliver(_ result: Result<[AVCapturePhoto], Error>) {
        lock.lock()
        let c = completion
        completion = nil
        lock.unlock()
        c?(result)
    }

    /// The timeout: the photos so far (none: the request failed)
    func expire(after seconds: TimeInterval) {
        lock.lock()
        let c = completion
        completion = nil
        let got = photos
        lock.unlock()
        guard let c else { return }
        SessionLog.w("PhotoCapture", "request timed out after \(Int(seconds * 1000)) ms: \(got.count) photo(s) delivered, the rest dropped")
        c(got.isEmpty ? .failure(CameraError.captureException("timed out")) : .success(got))
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard completion != nil else { return } // after the timeout: a late frame, dropped
        if let error { failure = error; return }
        photos.append(photo)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        lock.lock()
        let got = photos, failed = error ?? failure
        lock.unlock()
        if let failed, got.isEmpty {
            deliver(.failure(failed))
        } else {
            deliver(.success(got))
        }
        release()
    }
}
