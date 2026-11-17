import AVFoundation
import CoreVideo
import ImageIO

/// «Спорт» under lamps (Android MotionShutter P111 / P212d): whether the mains light flickers where the camera is, so the mode's
/// shutter ceiling may round to whole half periods (10 / 8.3 ms: no row bands) only then - and keep 1/250 s outdoors.
/// Evidence, latched for the lens's session:
/// - «Мерцание ламп» set by hand: that frequency.
/// - the camera's own exposure: its settled shutter a whole number of half periods (the AE's anti-banding) on two settles.
/// - the viewfinder's frames at a shutter under a half period against a band-free frame of the AE (a shutter of two half periods or
///   more): rows banded by more than 4 % (a sinusoid over the rows, the scene cancelled in the ratio) on two frames latch it,
///   six frames without bands clear it; no verdict within 1.5 s of the short frames latches it (Android's MotionShutter).
/// The frequency of a latched flicker: the AE's vote, else the region's mains (MainsRegion).
final class FlickerWatch: @unchecked Sendable {
    static let shared = FlickerWatch()

    enum Verdict: Equatable { case unknown, present(Int), absent }

    static let bandMax = 0.04, rssRatioMax = 0.5
    static let bandHits = 2, bandMisses = 6
    static let waitNs: UInt64 = 1_500_000_000
    static let bands = 48

    private let lock = NSLock()
    private var verdictValue = Verdict.unknown
    private var checking = false
    private var checkStartNs: UInt64 = 0
    /// The band-free window: the camera's exposure without the ceiling this long after the check starts
    static let referenceNs: UInt64 = 600_000_000
    private var hits = 0, misses = 0
    private var reference: (profile: [Double], atNs: UInt64)?
    private var settle: [Double] = []
    private var votes = [100: 0, 120: 0]
    private var rotationValue: CGFloat = 0
    /// Told (any thread) when the verdict changed: the ceiling is applied again
    var onVerdict: (@Sendable () -> Void)?

    var verdict: Verdict {
        lock.lock(); defer { lock.unlock() }
        return verdictValue
    }

    /// The frames are wanted: «Спорт» with «Мерцание ламп» on «Авто» and no verdict yet
    var wanted: Bool {
        lock.lock(); defer { lock.unlock() }
        return checking && verdictValue == .unknown
    }

    /// The video connection's rotation (the renderer's frames are upright as the preview: at 90 / 270 the sensor's rows are columns)
    func setRotation(_ angle: CGFloat) {
        lock.lock(); rotationValue = angle; lock.unlock()
    }

    /// A new lens session: no evidence
    func reset() {
        lock.lock()
        verdictValue = .unknown
        checking = false
        hits = 0; misses = 0
        reference = nil
        settle = []
        votes = [100: 0, 120: 0]
        lock.unlock()
    }

    /// «Спорт» on (Авто) or off: the frames' check runs while on and undecided
    func setChecking(_ on: Bool) {
        lock.lock()
        let changed = checking != on
        checking = on
        let starts = on && changed && verdictValue == .unknown
        if starts { checkStartNs = DispatchTime.now().uptimeNanoseconds; hits = 0; misses = 0 }
        lock.unlock()
        if changed { ViewfinderRenderer.shared.analysisChanged() }
        // the band-free window's end: the ceiling on (the short frames the check reads)
        if starts {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .nanoseconds(Int(Self.referenceNs) + 50_000_000)) { [weak self] in
                self?.onVerdict?()
            }
        }
    }

    /// The check's first moments: no ceiling yet (CaptureService.applyMotionCeiling), the AE's own frames are the reference
    var holdsReference: Bool {
        lock.lock(); defer { lock.unlock() }
        return checking && verdictValue == .unknown && DispatchTime.now().uptimeNanoseconds - checkStartNs < Self.referenceNs
    }

    /// The camera's exposure of a frame (the AE free, not at a ceiling): its settled shutter votes
    func aeShutter(ns: Int64, capNs: Int64) {
        guard ns > 0 else { return }
        let s = Double(ns)
        if capNs > 0, s >= Double(capNs) * 0.97 { return }   // held at the ceiling: the AE did not choose it
        lock.lock()
        settle.append(s)
        if settle.count > 8 { settle.removeFirst(settle.count - 8) }
        let settled = settle.count == 8 && (settle.max()! - settle.min()!) <= 0.02 * s
        var latched: Verdict?
        if settled, s >= 9_000_000, verdictValue == .unknown {
            for hz in [100, 120] {
                let half = 1e9 / Double(hz)
                let k = (s / half).rounded()
                if k >= 1, abs(s / (k * half) - 1) < 0.01 {
                    votes[hz, default: 0] += 1
                    settle.removeAll()
                    if votes[hz, default: 0] >= 2 { latched = .present(hz) }
                    break
                }
            }
        }
        if let latched { verdictValue = latched }
        lock.unlock()
        if let latched { report(latched, "the camera's exposure settled on whole half periods twice") }
    }

    /// One viewfinder frame (the renderer's queue) with its exposure
    func frame(_ sampleBuffer: CMSampleBuffer, pixels: CVPixelBuffer, fallbackExposureNs: Int64, capNs: Int64) {
        var ns = fallbackExposureNs
        if let exif = CMGetAttachment(sampleBuffer, key: kCGImagePropertyExifDictionary, attachmentModeOut: nil) as? [String: Any],
           let t = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue, t > 0 {
            ns = Int64((t * 1e9).rounded())
        }
        guard ns > 0 else { return }
        aeShutter(ns: ns, capNs: capNs)
        lock.lock()
        let active = checking && verdictValue == .unknown
        let rotation = rotationValue
        let start = checkStartNs
        lock.unlock()
        guard active, let profile = Self.profile(pixels, alongColumns: Int(rotation.rounded()) % 180 != 0) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let regionHz = HybridPlan.antibandingHz > 0 ? HybridPlan.antibandingHz : 100
        if ns >= 19_000_000 {   // two half periods or more: the bands integrate away - the reference
            lock.lock(); reference = (profile, now); lock.unlock()
            return
        }
        guard Double(ns) <= 0.9e9 / Double(regionHz) else { return }   // not shorter than a half period: no bands to see
        lock.lock()
        let ref = reference
        lock.unlock()
        var decided: Verdict?
        var note = ""
        if let ref, now - ref.atNs <= 4_000_000_000 {
            let (amp, ratio) = Self.bandFit(profile, ref.profile)
            lock.lock()
            if amp >= Self.bandMax && ratio <= Self.rssRatioMax { hits += 1 } else { misses += 1 }
            if hits >= Self.bandHits { decided = .present(regionHz) } else if misses >= Self.bandMisses { decided = .absent }
            if let d = decided, verdictValue == .unknown { verdictValue = d } else { decided = nil }
            note = String(format: "rows: %d banded / %d clean frames (last amp %.1f %%, rss ratio %.2f)", hits, misses, 100 * amp, ratio)
            lock.unlock()
        }
        if decided == nil, now - start >= Self.referenceNs + Self.waitNs {
            lock.lock()
            if verdictValue == .unknown { verdictValue = .present(regionHz); decided = verdictValue }
            lock.unlock()
            note = "no verdict from the frames in 1.5 s" + (ref == nil ? " (no band-free frame of the camera's exposure)" : "")
        }
        if let decided { report(decided, note) }
    }

    private func report(_ v: Verdict, _ why: String) {
        switch v {
        case .present(let hz): SessionLog.i("Capture", "mains flicker \(hz) Hz latched: \(why)")
        case .absent: SessionLog.i("Capture", "no mains flicker: \(why)")
        case .unknown: return
        }
        ViewfinderRenderer.shared.analysisChanged()
        onVerdict?()
    }

    /// The mean level of `bands` bands along the sensor's rows (the centre 60 % across, every 8th sample): the green of the
    /// renderer's BGRA frames (the luma plane of a planar one), nil for another layout
    static func profile(_ pixels: CVPixelBuffer, alongColumns: Bool) -> [Double]? {
        let planar = CVPixelBufferGetPlaneCount(pixels) >= 1
        guard planar || CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixels, 0) : CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let w = planar ? CVPixelBufferGetWidthOfPlane(pixels, 0) : CVPixelBufferGetWidth(pixels)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pixels, 0) : CVPixelBufferGetHeight(pixels)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) : CVPixelBufferGetBytesPerRow(pixels)
        let step = planar ? 1 : 4, channel = planar ? 0 : 1
        guard w >= 64, h >= 64 else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let along = alongColumns ? w : h, across = alongColumns ? h : w
        let a0 = across / 5, a1 = across - across / 5
        var sums = [Double](repeating: 0, count: bands), counts = [Int](repeating: 0, count: bands)
        for i in Swift.stride(from: 0, to: along, by: 2) {
            let b = i * bands / along
            var s = 0, n = 0
            for j in Swift.stride(from: a0, to: a1, by: 8) {
                s += Int(alongColumns ? p[j * stride + i * step + channel] : p[i * stride + j * step + channel])
                n += 1
            }
            sums[b] += Double(s); counts[b] += n
        }
        return (0..<bands).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : 0 }
    }

    /// ln(frame / reference) per band (the edge bands left out) fitted by a quadratic trend alone and with a sinusoid of 1 .. 8
    /// cycles over the frame: the best sinusoid's amplitude and its residual against the trend's
    static func bandFit(_ frame: [Double], _ ref: [Double]) -> (amp: Double, ratio: Double) {
        var u: [Double] = [], y: [Double] = []
        let n = min(frame.count, ref.count)
        for k in 1..<max(1, n - 1) where frame[k] > 4 && ref[k] > 4 {
            u.append((Double(k) + 0.5) / Double(n))
            y.append(log(frame[k] / ref[k]))
        }
        guard u.count >= 16 else { return (0, 1) }
        let trend = residual(u.map { [1, $0, $0 * $0] }, y)
        guard let base = trend.rss, base > 1e-12 else { return (0, 1) }
        var best = (amp: 0.0, ratio: 1.0)
        for c in Swift.stride(from: 1.0, through: 8.0, by: 0.1) {
            let w = 2 * Double.pi * c
            let r = residual(u.map { [1, $0, $0 * $0, cos(w * $0), sin(w * $0)] }, y)
            guard let rss = r.rss else { continue }
            let ratio = rss / base
            if ratio < best.ratio { best = (hypot(r.coef[3], r.coef[4]), ratio) }
        }
        return best
    }

    /// Least squares of y on the rows of x (normal equations, Gaussian elimination): the coefficients and the residual sum
    static func residual(_ x: [[Double]], _ y: [Double]) -> (coef: [Double], rss: Double?) {
        let m = x.first?.count ?? 0
        var a = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: m)
        for (row, v) in zip(x, y) {
            for i in 0..<m {
                for j in 0..<m { a[i][j] += row[i] * row[j] }
                a[i][m] += row[i] * v
            }
        }
        for c in 0..<m {
            var piv = c
            for r in c..<m where abs(a[r][c]) > abs(a[piv][c]) { piv = r }
            guard abs(a[piv][c]) > 1e-12 else { return ([], nil) }
            a.swapAt(c, piv)
            for r in 0..<m where r != c {
                let f = a[r][c] / a[c][c]
                for j in c...m { a[r][j] -= f * a[c][j] }
            }
        }
        let coef = (0..<m).map { a[$0][m] / a[$0][$0] }
        var rss = 0.0
        for (row, v) in zip(x, y) {
            var e = v
            for j in 0..<m { e -= coef[j] * row[j] }
            rss += e * e
        }
        return (coef, rss)
    }
}
