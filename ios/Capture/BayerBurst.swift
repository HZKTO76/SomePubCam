import AVFoundation
import ImageIO

/// A series of Bayer RAW frames for the SHDR merge (Android: the N frames of the burst, then the plan's ultrashort and bracketed
/// frames, HybridPlan), in capture order with each frame's capture role and measured exposure (the merge's frame rules pick from
/// them: Engine/post/HybridSelect.hpp).
/// A burst handed from the capture to its processing (CameraModel.enqueue -> process -> BurstProcessor): take() leaves the box
/// empty, so the one who took it is the planes' only owner and can release them.
final class BurstHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var held: BayerBurst?
    init(_ burst: BayerBurst) { held = burst }
    var burst: BayerBurst? { lock.lock(); defer { lock.unlock() }; return held }
    func take() -> BayerBurst? { lock.lock(); defer { lock.unlock() }; let b = held; held = nil; return b }
}

struct BayerBurst {
    var width = 0, height = 0, cfa = 0
    var frames: [NchFrame] = []
    var dng = Data()          // the DNG of frame `dngFrame`: levels, noise profile, colour, orientation (the whole frame)
    var dngFrame = 0          // the newest N frame (the base's metadata, as Android's from the base), else the first
    var processed: Data?      // the camera's own HEIC of the first request, for its EXIF
    var report: [String] = []
    var front = false         // the front camera: the photo is mirrored as Android's Parameters.mirror
    var lens = ""             // the capture device's uniqueID (LensShading's key)
    /// The NCH file the planes are written to as they arrive (BurstProcessor finishes it); nil: written after the capture
    var stream: NchStream?
    /// ZoomController's residual at the press (the digital crop over the module's own zoom): SabreCrop's window before the merge and
    /// the photo's crop after it (P576 / P226). 1: no crop.
    var zoom = 1.0
    /// «16:9» (Wide169, P118): the frames' rows before the cut (0: whole frames) and its first row
    var fullHeight = 0, firstRow = 0
}

extension FourCharCode {
    /// Camera2 / DNG CFA order of a 14-bit Bayer pixel format: 0 RGGB, 1 GRBG, 2 GBRG, 3 BGGR.
    var bayerCFA: Int? {
        switch self {
        case kCVPixelFormatType_14Bayer_RGGB: return 0
        case kCVPixelFormatType_14Bayer_GRBG: return 1
        case kCVPixelFormatType_14Bayer_GBRG: return 2
        case kCVPixelFormatType_14Bayer_BGGR: return 3
        default: return nil
        }
    }
}

extension PhotoCapture {
    /// The SHDR series: manual exposure bracket requests of up to `maxBracketedCapturePhotoCount` frames at the camera AE's present
    /// shutter and ISO (the viewfinder's exposure, as Android's ring frames; ETTR's boost when on) until `count` N frames arrived, the
    /// N frames selected as Android's ring (NormalSelect), then in the same series the plan's ultrashort (Bento) and bracketed
    /// (Shasta) frames as manual exposure brackets (HybridPlan from the newest N frame's measured exposure and its clipping / shadows;
    /// ultrashort first, as Android takes them). Every frame is after the press: AVFoundation gives no RAW ring.
    func captureBayerBurst(count: Int, device: AVCaptureDevice, pressed: Date) async throws -> BayerBurst {
        guard let bayer = output.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) else {
            throw CameraError.captureException("Bayer RAW is not available on this lens / zoom")
        }
        var burst = BayerBurst()
        burst.front = device.position == .front
        burst.lens = device.uniqueID
        let wide = Wide169.on
        let started = Date()
        let maxBracket = output.maxBracketedCapturePhotoCount
        let perRequest = max(1, min(count, maxBracket))
        let stabilized = output.isLensStabilizationDuringBracketedCaptureSupported
        let format = device.activeFormat
        burst.report.append(String(format: "capture: %@ %@, maxBracketedCapturePhotoCount %ld, shutter %.4f..%.1f ms, ISO %.0f..%.0f, "
                                   + "frame range %.2f..%.2f fps, OIS in brackets %@, flicker %ld Hz (%@), photo %dx%d",
                                   BuildInfo.machine, device.localizedName, maxBracket, format.minExposureDuration.seconds * 1e3,
                                   format.maxExposureDuration.seconds * 1e3, format.minISO, format.maxISO,
                                   1 / device.activeVideoMaxFrameDuration.seconds, 1 / device.activeVideoMinFrameDuration.seconds,
                                   stabilized ? "on" : "not supported", HybridPlan.antibandingHz,
                                   StoredPrefs.string("pref_antibanding_hz_key", "-1") == "-1" ? "auto: region \(MainsRegion.region ?? "?")" : "set",
                                   output.maxPhotoDimensions.width, output.maxPhotoDimensions.height))
        var log: [String] = []
        let limits = ExposureLimits.of(lens: device.uniqueID, width: Int(output.maxPhotoDimensions.width),
                                       height: Int(output.maxPhotoDimensions.height), log: { log.append($0) })
        var clock = BurstClock()
        let ettr = await ettrExposure(bayer: bayer, device: device, burst: &burst)
        // the camera AE's exposure of this moment, read once: every N frame of the series at it
        let aeNs = Int64((device.exposureDuration.seconds * 1e9).rounded())
        let tLow = Int64((format.minExposureDuration.seconds * 1e9).rounded(.up))
        let tHigh = Int64((format.maxExposureDuration.seconds * 1e9).rounded(.down))
        let nNs = min(max(ettr?.ns ?? aeNs, tLow), max(tLow, tHigh))
        let nIso = min(max(ettr.map { Float($0.iso) } ?? device.iso, format.minISO), format.maxISO)
        let nIsoInt = Int(nIso.rounded())
        burst.report.append(String(format: "N plan: %ld frames at %.3f ms * ISO %ld (%@), %ld a request", count, Double(nNs) / 1e6, nIsoInt,
                                   ettr != nil ? "ETTR" : "the camera AE's present exposure", perRequest))
        var lost = 0, requests = 0
        var lastN: AVCapturePhoto?
        let maxRequests = (count + perRequest - 1) / perRequest + 2
        while burst.frames.count < count && requests < maxRequests {
            requests += 1
            let n = min(perRequest, count - burst.frames.count)
            let bracket = (0..<n).map { _ in
                AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                    exposureDuration: CMTime(value: nNs, timescale: 1_000_000_000), iso: nIso)
            }
            let first = burst.frames.isEmpty
            func request(withProcessed: Bool) -> AVCapturePhotoBracketSettings {
                let processed: [String: Any]? = withProcessed ? [AVVideoCodecKey: AVVideoCodecType.hevc] : nil
                let settings = AVCapturePhotoBracketSettings(rawPixelFormatType: bayer, processedFormat: processed, bracketedSettings: bracket)
                settings.maxPhotoDimensions = output.maxPhotoDimensions
                if stabilized { settings.isLensStabilizationEnabled = true }
                // one shutter sound for the whole series (CameraSounds), not the system's per request
                silence(settings)
                return settings
            }
            // CaptureController's series timeout: 4 s + 3 x the request's exposures
            let timeout = 4 + 3 * Double(nNs) * Double(n) / 1e9
            let requestStarted = Date()
            var photos: [AVCapturePhoto]
            do {
                photos = try await capturePhotos(request(withProcessed: first), timeout: timeout)
            } catch CameraError.captureException(let reason) where first {
                // a RAW + HEIC bracket refused: RAW only (the EXIF then comes from the DNG)
                burst.report.append("burst request with HEIC refused (\(reason)), RAW only")
                photos = try await capturePhotos(request(withProcessed: false), timeout: timeout)
            } catch where !first {
                // the shot fails only without a frame (P27): the N frames so far are merged
                burst.report.append("burst request \(n) frames failed (\(error.localizedDescription)), \(burst.frames.count) N frames kept")
                lost += n
                break
            }
            let raws = photos.filter(\.isRawPhoto)
            burst.report.append("burst request \(n) frames in \(ms(since: requestStarted)) ms" + (raws.count < n ? ", \(n - raws.count) lost" : ""))
            lost += max(0, n - raws.count)
            for photo in photos {
                if photo.isRawPhoto {
                    let (ns, iso) = Self.measured(photo)
                    limits.observe(requestedNs: nNs, requestedIso: nIsoInt, deliveredNs: ns, deliveredIso: iso, log: { log.append($0) })
                    lastN = photo
                }
                try append(photo, to: &burst, clock: &clock, role: NchWriter.roleNormal, wide: wide)
            }
            if raws.isEmpty { break }
        }
        burst.report.append("N delivered: " + Self.exposures(burst.frames))
        let delivered = burst.frames.count
        // Android's ring selection on the delivered N frames (the camera may give another exposure than asked)
        let selection = NormalSelect.select(burst.frames.enumerated().map {
            NormalSelect.Frame(index: $0.offset, timestampNs: $0.element.timestampNs, exposureNs: $0.element.exposureNs, iso: Int($0.element.iso))
        }, requested: count)
        burst.report += selection.log
        if selection.keep.count < burst.frames.count {
            burst.frames = selection.keep.map { burst.frames[$0] }
            burst.stream?.discard() // the planes of the frames left out are in it: the NCH is written after the capture
            burst.stream = nil
        }
        // the base's metadata (Android: levels, neutral, matrices, noise of the base): the newest N frame's DNG, the base's
        // candidates are the newest N (HybridSelect)
        if let lastN, burst.frames.count > 1, let newest = burst.frames.indices.max(by: { burst.frames[$0].timestampNs < burst.frames[$1].timestampNs }),
           burst.frames[newest].timestampNs == Self.stampNs(lastN), newest != 0, let dng = lastN.fileDataRepresentation() {
            burst.dng = dng
            burst.dngFrame = newest
            burst.report.append("metadata (DNG) of N frame \(newest), the newest")
        }
        lastN = nil
        let normals = burst.frames.count
        var extras = ExtrasTally()
        if normals > 0, let plan = extrasPlan(for: burst, device: device, limits: limits) {
            burst.report.append(plan.description)
            extras.planned = plan.requests.count
            if !plan.requests.isEmpty {
                await captureExtras(plan, bayer: bayer, device: device, perRequest: max(1, maxBracket), stabilized: stabilized,
                                    limits: limits, burst: &burst, clock: &clock, wide: wide, tally: &extras, log: &log)
            }
        }
        let lastFrameMs = ms(since: pressed)
        burst.report += log
        finish(&burst)
        let es = burst.frames.filter { $0.role == NchWriter.roleUltrashort }.count
        let l = burst.frames.filter { $0.role == NchWriter.roleBracketed }.count
        let n = burst.frames.filter { $0.role == NchWriter.roleNormal }.count
        burst.report.append("capture summary: N \(n) of \(count) (\(lost) lost, \(delivered - normals) left out), "
                            + "ES \(es), L \(l) (planned \(extras.planned): \(extras.lost) lost, \(extras.reassigned) reassigned, \(extras.dropped) dropped), "
                            + "press -> last frame \(lastFrameMs) ms" + (ettr != nil ? " (ETTR meter frame first)" : ""))
        burst.report.append("burst \(burst.frames.count) frames (\(normals) N, \(burst.frames.count - normals) ultrashort / bracketed) in \(ms(since: started)) ms, per request \(perRequest)"
                            + (burst.fullHeight > 0 ? ", 16:9 rows \(burst.firstRow)..<\(burst.firstRow + burst.height) of \(burst.fullHeight)" : ""))
        return burst
    }

    struct ExtrasTally {
        var planned = 0, lost = 0, reassigned = 0, dropped = 0
    }

    /// The frames' measured exposures, grouped: "20 x 10.000ms*ISO100"
    static func exposures(_ frames: [NchFrame]) -> String {
        var groups: [(ns: Int64, iso: UInt32, n: Int)] = []
        for f in frames {
            if let i = groups.firstIndex(where: { $0.ns == f.exposureNs && $0.iso == f.iso }) { groups[i].n += 1 }
            else { groups.append((f.exposureNs, f.iso, 1)) }
        }
        return groups.map { String(format: "%ld x %.3fms*ISO%u", $0.n, Double($0.ns) / 1e6, $0.iso) }.joined(separator: ", ")
    }

    static func stampNs(_ photo: AVCapturePhoto) -> Int64 { photo.timestamp.convertScale(1_000_000_000, method: .default).value }

    /// HybridPlan.build from the newest N frame (CaptureController: the newest ring frame's exposure, zslClipFraction's shares), the
    /// lens's ranges as SENSOR_INFO_EXPOSURE_TIME_RANGE / SENSITIVITY_RANGE; nil in «Движение», with «HDR кадры» off or «Oldstyle».
    private func extrasPlan(for burst: BayerBurst, device: AVCaptureDevice, limits: ExposureLimits) -> HybridPlan.Plan? {
        guard !HybridPlan.oneExposure, let newest = burst.frames.max(by: { $0.timestampNs < $1.timestampNs }) else { return nil }
        var levels = Self.bufferLevels(DngInfo(dng: burst.dng))
        // P558: the frame's clip plateau under the declared white is the white (the clip share is counted against it)
        levels.white = RawWhite.of(levels.white, black: levels.black,
                                   histogram: RawWhite.histogram(newest.raw, width: burst.width, height: burst.height)).white
        let measure = FrameMeasure.shares(newest.raw, width: burst.width, height: burst.height, black: levels.black, white: levels.white)
        let format = device.activeFormat
        let tLow = Int64((format.minExposureDuration.seconds * 1e9).rounded(.up)), tHigh = Int64((format.maxExposureDuration.seconds * 1e9).rounded(.down))
        let iLow = Int(format.minISO.rounded(.up)), iHigh = Int(format.maxISO.rounded(.down))
        guard tLow > 0, tHigh >= tLow, iLow > 0, iHigh >= iLow else { return nil }
        // ExposureLimits: what this lens really gave manual requests before
        let (times, isos) = limits.capped(times: tLow...tHigh, isos: iLow...iHigh)
        return HybridPlan.build(nShutterNs: newest.exposureNs, nIso: Int(newest.iso), clip: measure.clip, shadow: measure.shadow,
                                deepShadow: measure.deep, times: times,
                                isos: HybridPlan.rawIsos(isos, nIso: Int(newest.iso)))
    }

    /// The plan's frames as manual exposure brackets (AVCaptureManualExposureBracketedStillImageSettings: the plan's shutter and ISO),
    /// RAW only, at most `perRequest` a request. Each delivered frame keeps the role its measured exposure gives (HybridPlan.classify);
    /// a refused request never costs the shot (P27): its N frames stay.
    private func captureExtras(_ plan: HybridPlan.Plan, bayer: OSType, device: AVCaptureDevice, perRequest: Int, stabilized: Bool,
                               limits: ExposureLimits, burst: inout BayerBurst, clock: inout BurstClock, wide: Bool,
                               tally: inout ExtrasTally, log: inout [String]) async {
        let format = device.activeFormat
        var pending = plan.requests[...]
        var number = 0
        while !pending.isEmpty {
            let chunk = Array(pending.prefix(perRequest))
            pending = pending.dropFirst(chunk.count)
            let bracket = chunk.map { r in
                AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                    exposureDuration: CMTime(value: r.shutterNs, timescale: 1_000_000_000),
                    iso: min(max(Float(r.iso), format.minISO), format.maxISO))
            }
            let settings = AVCapturePhotoBracketSettings(rawPixelFormatType: bayer, processedFormat: nil, bracketedSettings: bracket)
            settings.maxPhotoDimensions = output.maxPhotoDimensions
            if stabilized { settings.isLensStabilizationEnabled = true }
            silence(settings)
            let timeout = 4 + 3 * chunk.reduce(0) { $0 + Double($1.shutterNs) } / 1e9
            let requestStarted = Date()
            let photos: [AVCapturePhoto]
            do {
                photos = try await capturePhotos(settings, timeout: timeout)
            } catch {
                tally.lost += chunk.count + pending.count
                burst.report.append("hybrid: \(chunk.count + pending.count) ultrashort / bracketed frame(s) refused (\(error.localizedDescription)), the N frames merged alone")
                return
            }
            let raws = photos.filter(\.isRawPhoto)
            tally.lost += max(0, chunk.count - raws.count)
            burst.report.append("burst request \(chunk.count) ultrashort / bracketed frames in \(ms(since: requestStarted)) ms"
                                + (raws.count < chunk.count ? ", \(chunk.count - raws.count) lost" : ""))
            var used = Set<Int>()
            for (k, photo) in raws.enumerated() {
                let at = photo.sequenceCount >= 1 && photo.sequenceCount <= chunk.count ? photo.sequenceCount - 1 : min(k, chunk.count - 1)
                if used.contains(at) { // a duplicate: dropped alone
                    tally.dropped += 1
                    burst.report.append("hybrid: a duplicate of frame \(at + 1) of the request dropped")
                    continue
                }
                used.insert(at)
                let request = chunk[at]
                let (exposureNs, iso) = Self.measured(photo)
                limits.observe(requestedNs: request.shutterNs, requestedIso: request.iso, deliveredNs: exposureNs, deliveredIso: iso,
                               log: { log.append($0) })
                number += 1
                var report = burst.report
                let classified = HybridPlan.classify(request, exposureNs: exposureNs, iso: iso, plan: plan, log: { report.append($0) })
                burst.report = report
                burst.report.append(String(format: "extra %ld %@: plan %.3fms*ISO%ld -> %.3fms*ISO%ld (x%.3f of N) %@", number, request.role.name,
                                           Double(request.shutterNs) / 1e6, request.iso, Double(exposureNs) / 1e6, iso,
                                           Double(exposureNs) * Double(iso) / (Double(plan.nShutterNs) * Double(plan.nIso)),
                                           classified.map { $0 == request.role ? $0.name : "reassigned " + $0.name } ?? "dropped"))
                guard let role = classified else {
                    tally.dropped += 1
                    continue
                }
                if role != request.role { tally.reassigned += 1 }
                do {
                    try append(photo, to: &burst, clock: &clock, role: role.rawValue, wide: wide)
                } catch {
                    tally.dropped += 1
                    burst.report.append("hybrid: \(request.role.name) frame left out (\(error.localizedDescription))")
                }
            }
        }
    }

    /// FlashMode.Shot (P590): a flash shot is never a series of frames exposed before the press - one fresh Bayer frame with the
    /// flash firing (the camera meters with its pre-flash), merged as a one-frame shot. Nil when this lens / zoom refuses a RAW
    /// frame with the flash (the caller takes the camera's own flash photo then).
    func captureFlashFrame(device: AVCaptureDevice, flash: AVCaptureDevice.FlashMode) async throws -> BayerBurst? {
        guard let bayer = output.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }),
              output.supportedFlashModes.contains(flash) else { return nil }
        let settings = AVCapturePhotoSettings(rawPixelFormatType: bayer, processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc])
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        settings.flashMode = flash
        silence(settings)
        var burst = BayerBurst()
        burst.front = device.position == .front
        let started = Date()
        let photos: [AVCapturePhoto]
        do {
            photos = try await capturePhotos(settings)
        } catch CameraError.captureException(let reason) {
            SessionLog.w("PhotoCapture", "flash RAW frame refused: \(reason)")
            return nil
        }
        var clock = BurstClock()
        for photo in photos { try append(photo, to: &burst, clock: &clock, role: NchWriter.roleNormal, wide: Wide169.on) }
        guard !burst.frames.isEmpty else { return nil }
        finish(&burst)
        burst.report.append("flash shot: 1 frame (flash \(flash.rawValue)) in \(ms(since: started)) ms")
        return burst
    }

    /// The DNG's levels in the 14-bit buffer's units (BurstProcessor.bufferScale: 528 / 4095 x 4 on the iPad and the iPhones)
    static func bufferLevels(_ info: DngInfo) -> (black: [Float], white: Float) {
        let r = 16383 / max(info.white, 1)
        let k: Float = r >= 1.5 ? Float(1 << min(4, max(0, Int(log2(r).rounded())))) : 1
        return (info.black.map { $0 * k }, info.white * k)
    }

    /// P356 ETTR on the iPhone («ETTR», pref_ettr): one auto-exposed RAW frame before the series - the brightest channel's tail of
    /// its quads (Ettr.tail) against the white - and the N frames then as manual brackets at its ISO with the shutter longer by the
    /// boost (light, not gain: P377), at most 2 EV and one 30 fps frame; nil: no boost (off, held, under 0.3 EV, refused)
    private func ettrExposure(bayer: OSType, device: AVCaptureDevice, burst: inout BayerBurst) async -> (ns: Int64, iso: Int)? {
        guard EttrMeter.enabled, device.exposureMode != .custom, !HybridPlan.oneExposure else { return nil }
        let meter = AVCapturePhotoBracketSettings(rawPixelFormatType: bayer, processedFormat: nil,
                                                  bracketedSettings: [AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias: 0)])
        meter.maxPhotoDimensions = output.maxPhotoDimensions
        silence(meter)
        guard let photo = try? await capturePhotos(meter).first(where: { $0.isRawPhoto }), let buffer = photo.pixelBuffer,
              let dng = photo.fileDataRepresentation() else {
            burst.report.append("ETTR: the metering frame was refused, no boost")
            return nil
        }
        let (baseNs, baseIso) = Self.measured(photo)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer) & ~1, h = CVPixelBufferGetHeight(buffer) & ~1, row = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var levels = Self.bufferLevels(DngInfo(dng: dng))
        // P558: a frame clipping under the declared white is at its white there (else a blown sky reads as headroom)
        levels.white = RawWhite.of(levels.white, black: levels.black,
                                   histogram: RawWhite.histogram(base, rowBytes: row, width: w, height: h)).white
        let share = HybridPlan.bentoMode > 0 ? 0.005 : 0.001
        let tail = EttrMeter.tail(base, width: w, height: h, rowBytes: row, black: levels.black, white: levels.white, share: share)
        let format = device.activeFormat
        let maxNs = Int64((format.maxExposureDuration.seconds * 1e9).rounded(.down))
        let wanted = EttrMeter.boost(tail)
        // at most one frame of the 30 fps viewfinder (Android: one ring frame), never shorter than the AE's own shutter
        let frameCap = max(baseNs, Int64(33_333_333))
        let ns = HybridPlan.flickerSafe(min(maxNs, frameCap, HybridPlan.round(Double(baseNs) * pow(2, wanted))), baseNs)
        let ev = log2(Double(ns) / Double(max(baseNs, 1)))
        burst.report.append(String(format: "ETTR: tail %.3f of white (top %.1f%%), boost %.2f EV wanted, %.2f EV: shutter %.3f -> %.3f ms at ISO %ld",
                                   tail, share * 100, wanted, ev, Double(baseNs) / 1e6, Double(ns) / 1e6, baseIso))
        return ev >= EttrMeter.minStep ? (ns, baseIso) : nil
    }

    /// The first frame's exposure and time the others are relative to
    struct BurstClock {
        var t0: Double?
        var exposure0: Double = 0
    }

    /// The photo's measured exposure (EXIF ExposureTime in ns, ISOSpeedRatings) as Camera2's SENSOR_EXPOSURE_TIME / SENSITIVITY
    static func measured(_ photo: AVCapturePhoto) -> (exposureNs: Int64, iso: Int) {
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        var iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue ?? 0
        var time = (exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? 0
        // a manual bracket's own request when the metadata has none
        if let manual = photo.bracketSettings as? AVCaptureManualExposureBracketedStillImageSettings {
            if time <= 0, manual.exposureDuration.isNumeric { time = manual.exposureDuration.seconds }
            if iso <= 0 { iso = Double(manual.iso) }
        }
        if iso <= 0 { iso = 100 }
        if time <= 0 { time = 0.01 }
        return (Int64((time * 1e9).rounded()), Int(iso.rounded()))
    }

    /// A delivered photo into the burst: the processed one's bytes kept for the EXIF, a Bayer frame copied from its 14-bit buffer
    /// (with «16:9» its centred rows, Wide169: every frame of the series the same cut), with its role, measured exposure and time.
    private func append(_ photo: AVCapturePhoto, to burst: inout BayerBurst, clock: inout BurstClock, role: Int, wide: Bool) throws {
        if !photo.isRawPhoto {
            burst.processed = photo.fileDataRepresentation()
            return
        }
        guard let buffer = photo.pixelBuffer else { return }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard let cfa = format.bayerCFA else { throw CameraError.captureException("RAW format \(format.fourCC) is not 14-bit Bayer") }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let fullW = w & ~1, fullH = h & ~1
        let rows = wide && fullW > fullH ? Wide169.rows(fullW, fullH) : fullH
        let first = rows < fullH ? Wide169.firstRow(fullW, fullH) : 0
        if burst.frames.isEmpty {
            burst.width = fullW
            burst.height = rows
            burst.cfa = cfa
            if rows < fullH {
                burst.fullHeight = fullH
                burst.firstRow = first
            }
            burst.dng = photo.fileDataRepresentation() ?? Data()
            burst.report.append("burst frame 0: \(w)x\(h) \(format.fourCC) row=\(row) dng=\(burst.dng.count) bytes")
        }
        // the cut keeps whole 2x2 colour sites: the first row is a multiple of 8, the CFA order is the frame's
        guard fullW == burst.width, rows == burst.height, first == burst.firstRow else { return }
        var raw = Data(count: burst.width * burst.height * 2)
        raw.withUnsafeMutableBytes { dst in
            for y in 0..<burst.height {
                memcpy(dst.baseAddress! + y * burst.width * 2, base + (first + y) * row, burst.width * 2)
            }
        }
        if burst.frames.isEmpty && burst.stream == nil {
            burst.stream = try? NchStream(folder: BurstProcessor.lastBurstURL.deletingLastPathComponent(), width: burst.width, height: burst.height)
        }
        burst.stream?.append(raw)
        let (exposureNs, iso) = Self.measured(photo)
        let product = Double(exposureNs) * Double(iso)
        if clock.exposure0 == 0 { clock.exposure0 = product }
        let stampNs = Self.stampNs(photo)
        let stamp = Double(stampNs) / 1e6
        if clock.t0 == nil { clock.t0 = stamp }
        burst.frames.append(NchFrame(raw: raw, exposure: Float(clock.exposure0 > 0 ? product / clock.exposure0 : 1), iso: UInt32(iso),
                                     noiseSlope: 0, noiseOffset: 0, orderMs: Float(stamp - (clock.t0 ?? stamp)),
                                     role: role, exposureNs: exposureNs, timestampNs: stampNs))
    }

    /// The newest frame is 0 ms, earlier ones negative (as Android's orderMs; the merge's own orderMs come from HybridSelect)
    private func finish(_ burst: inout BayerBurst) {
        if let newest = burst.frames.map(\.orderMs).max() {
            for i in burst.frames.indices { burst.frames[i].orderMs -= newest }
        }
    }
}

enum NoiseEstimate {
    /// Variance = slope · x + offset of the normalised signal, from the difference of two frames of one exposure on the green
    /// sites (32×32 tiles; least squares over the tiles). The fallback when the DNG has no NoiseProfile.
    static func fromPair(_ a: Data, _ b: Data, width: Int, height: Int, cfa: Int, black: Float, white: Float) -> (Float, Float)? {
        let range = max(white - black, 1)
        // green sites: RGGB / BGGR at (x + y) odd, GRBG / GBRG at (x + y) even
        let greenOdd = cfa == 0 || cfa == 3
        var xs: [Double] = [], ys: [Double] = []
        a.withUnsafeBytes { pa in
            b.withUnsafeBytes { pb in
                let va = pa.bindMemory(to: UInt16.self), vb = pb.bindMemory(to: UInt16.self)
                var ty = 0
                while ty + 32 <= height {
                    var tx = 0
                    while tx + 32 <= width {
                        var sum = 0.0, sumD = 0.0, sumD2 = 0.0, n = 0.0
                        for y in ty..<(ty + 32) {
                            for x in tx..<(tx + 32) where ((x + y) & 1 == 1) == greenOdd {
                                let i = y * width + x
                                let u = (Double(va[i]) - Double(black)) / Double(range)
                                let v = (Double(vb[i]) - Double(black)) / Double(range)
                                sum += (u + v) * 0.5
                                let d = (u - v) / 2.0.squareRoot()
                                sumD += d
                                sumD2 += d * d
                                n += 1
                            }
                        }
                        let mean = sum / n
                        let variance = sumD2 / n - (sumD / n) * (sumD / n)
                        if mean > 0.002 && mean < 0.8 { xs.append(mean); ys.append(variance) }
                        tx += 32
                    }
                    ty += 32
                }
            }
        }
        guard xs.count >= 16 else { return nil }
        // tiles with texture inflate the variance: the lower half of the variance at each brightness counts (median split)
        let order = ys.indices.sorted { ys[$0] < ys[$1] }.prefix(max(16, ys.count / 2))
        let n = Double(order.count)
        let mx = order.map { xs[$0] }.reduce(0, +) / n, my = order.map { ys[$0] }.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for i in order { sxx += (xs[i] - mx) * (xs[i] - mx); sxy += (xs[i] - mx) * (ys[i] - my) }
        let slope = sxx > 0 ? max(sxy / sxx, 1e-7) : 1e-5
        let offset = max(my - slope * mx, 1e-9)
        return (Float(slope), Float(offset))
    }
}
