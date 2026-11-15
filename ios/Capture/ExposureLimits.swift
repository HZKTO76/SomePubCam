import Foundation

/// ExposureLimits.java (P27 / P212a): what the camera really gives a manual exposure request of one lens and RAW size, learned
/// from the delivered frames' metadata (EXIF ExposureTime / ISOSpeedRatings). A gain cap needs two results clamped to the same ISO
/// at an exact shutter; a later result above the cap clears it; the shutter cap the same way. Stored per key with the system build
/// and the time (UserDefaults "exposure_limits"); another build or 14 days without a confirmation forget them.
final class ExposureLimits: @unchecked Sendable {
    private static let lock = NSLock()
    private static var modes: [String: ExposureLimits] = [:]
    static let prefsKey = "exposure_limits"
    static let maxAge: TimeInterval = 14 * 24 * 3600
    private static let confirmEvery: TimeInterval = 6 * 3600
    static var fingerprint: String { BuildInfo.machine + " " + ProcessInfo.processInfo.operatingSystemVersionString }

    let key: String
    private let mutex = NSLock()
    private var isoCapValue = Int.max, capCandidate = 0, capVotes = 0
    private var shutterCapValue = Int64.max, shutterCandidate: Int64 = 0, shutterVotes = 0
    private var stored = Date.distantPast

    private init(key: String) { self.key = key }

    static func of(lens: String, width: Int, height: Int, log: (String) -> Void = { _ in }) -> ExposureLimits {
        let key = "\(lens)/\(width)x\(height)"
        lock.lock()
        defer { lock.unlock() }
        if let known = modes[key] { return known }
        let limits = ExposureLimits(key: key)
        limits.load(log: log)
        modes[key] = limits
        return limits
    }

    var isoCap: Int { mutex.lock(); defer { mutex.unlock() }; return isoCapValue }
    var shutterCap: Int64 { mutex.lock(); defer { mutex.unlock() }; return shutterCapValue }

    /// A manual request and its delivered exposure; true when it was given as asked (1.5 % / 2 ISO rounding allowed)
    @discardableResult
    func observe(requestedNs qt: Int64, requestedIso qi: Int, deliveredNs rt: Int64, deliveredIso ri: Int, log: (String) -> Void) -> Bool {
        guard qt > 0, qi > 0, rt > 0, ri > 0 else { return false }
        mutex.lock()
        let isoOk = abs(ri - qi) <= max(2, Int(Double(qi) * 0.015))
        let timeOk = abs(Double(rt) / Double(qt) - 1) <= 0.015
        let before = describe()
        if isoCapValue != .max && Double(ri) > Double(isoCapValue) + max(2, Double(isoCapValue) * 0.015) { isoCapValue = .max }
        var confirm = false
        if isoOk {
            if ri == capCandidate { capVotes = 0 }
        } else if ri < qi && timeOk {
            if ri == isoCapValue { confirm = true }
            capVotes = ri == capCandidate ? capVotes + 1 : 1
            capCandidate = ri
            if capVotes >= 2 { isoCapValue = min(isoCapValue, ri) }
        }
        if shutterCapValue != .max && Double(rt) > Double(shutterCapValue) * 1.015 { shutterCapValue = .max }
        if !timeOk && rt < qt {
            shutterVotes = abs(Double(rt) / Double(max(1, shutterCandidate)) - 1) <= 0.015 ? shutterVotes + 1 : 1
            shutterCandidate = rt
            if shutterVotes >= 2 { shutterCapValue = min(shutterCapValue, rt) }
        }
        let after = describe()
        let changed = before != after
        if changed || (confirm && Date().timeIntervalSince(stored) >= Self.confirmEvery) { save() }
        mutex.unlock()
        if changed { log("honoured exposure " + after) }
        return isoOk && timeOk
    }

    /// The lens's ranges within the learned caps
    func capped(times: ClosedRange<Int64>, isos: ClosedRange<Int>) -> (ClosedRange<Int64>, ClosedRange<Int>) {
        let t = shutterCap, i = isoCap
        let tHigh = t < times.upperBound ? max(times.lowerBound, t) : times.upperBound
        let iHigh = i < isos.upperBound ? max(isos.lowerBound, i) : isos.upperBound
        return (times.lowerBound...tHigh, isos.lowerBound...iHigh)
    }

    private func describe() -> String {
        "\(key): ISO cap \(isoCapValue == .max ? "none" : String(isoCapValue)), shutter cap "
            + (shutterCapValue == .max ? "none" : String(format: "%.3f ms", Double(shutterCapValue) / 1e6))
    }

    var description: String { mutex.lock(); defer { mutex.unlock() }; return describe() }

    private func load(log: (String) -> Void) {
        var all = UserDefaults.standard.dictionary(forKey: Self.prefsKey) as? [String: String] ?? [:]
        guard let line = all[key] else { return }
        let f = line.components(separatedBy: ";")
        let time = f.count == 4 ? Double(f[3]) ?? 0 : 0
        let now = Date().timeIntervalSince1970
        let stale = f.count != 4 ? "unreadable" : f[0] != Self.fingerprint ? "another system build"
            : time <= 0 || now - time > Self.maxAge || time > now + 60 ? "expired" : nil
        if let stale {
            all[key] = nil
            UserDefaults.standard.set(all, forKey: Self.prefsKey)
            log("honoured exposure \(key): stored limits dropped (\(stale))")
            return
        }
        let iso = Int(f[1]) ?? 0, shutter = Int64(f[2]) ?? 0
        if iso > 0 { isoCapValue = iso; capCandidate = iso }
        if shutter > 0 { shutterCapValue = shutter }
        stored = Date(timeIntervalSince1970: time)
        log("honoured exposure \(describe()) (stored \(Int((now - time) / 60)) min ago)")
    }

    private func save() {
        var all = UserDefaults.standard.dictionary(forKey: Self.prefsKey) as? [String: String] ?? [:]
        if isoCapValue == .max && shutterCapValue == .max {
            all[key] = nil
        } else {
            stored = Date()
            all[key] = "\(Self.fingerprint);\(isoCapValue == .max ? 0 : isoCapValue);\(shutterCapValue == .max ? 0 : shutterCapValue);"
                + String(Int64(stored.timeIntervalSince1970))
        }
        UserDefaults.standard.set(all, forKey: Self.prefsKey)
    }
}

/// «Мерцание ламп» «Авто» on the iPhone: Android takes the camera's measured mains (MainsFlicker); AVFoundation reports none, so the
/// flicker frequency comes from the region the phone is set to (60 Hz mains: 120 Hz flicker; 50 Hz: 100 Hz). Japan has both: none.
/// The region is the user's setting, not where the phone is.
enum MainsRegion {
    static let sixtyHertz: Set<String> = [
        "US", "CA", "MX", "GT", "BZ", "SV", "HN", "NI", "CR", "PA", "CU", "DO", "HT", "PR", "BS", "TT", "CO", "VE", "EC", "PE",
        "GY", "SR", "BR", "KR", "TW", "PH", "SA", "LR", "BM", "KY", "GU", "AS", "VI", "MP", "FM", "MH", "PW", "AI", "AG", "MS",
        "KN", "VG", "TC", "AW", "CW", "BQ", "SX",
    ]

    static var region: String? { Locale.current.region?.identifier }

    /// 100 / 120 Hz, 0 unknown
    static var flickerHz: Int {
        guard let r = region?.uppercased(), !r.isEmpty, r != "JP" else { return 0 }
        return sixtyHertz.contains(r) ? 120 : 100
    }
}

/// CaptureController.drainZslNormalFrames (P27 / P77) on the iPhone's N frames: the newest frame's measured exposure x ISO is the
/// reference; the frames within 0.05 EV of it stay, and only when fewer than min(N, 8) do frames down to 0.5 EV darker fill in,
/// the brightest first; a brighter frame never; frames of the reference exposure behind a gap of more than max(500 ms, 4 x the
/// shutter) are another moment and go (with the darker ones older than that). The iPhone's lenses have no gyro selection here
/// (Android: the steadiest of 2 x N without OIS).
enum NormalSelect {
    static let maxGapNs: Int64 = 500_000_000

    struct Frame {
        let index: Int
        let timestampNs: Int64
        let exposureNs: Int64
        let iso: Int
    }

    /// The indices kept (in capture order) and the log
    static func select(_ frames: [Frame], requested: Int) -> (keep: [Int], log: [String]) {
        guard let base = frames.max(by: { $0.timestampNs < $1.timestampNs }) else { return ([], []) }
        func product(_ f: Frame) -> Double { Double(f.exposureNs) * Double(f.iso) }
        let ref = product(base)
        guard ref > 0 else { return (frames.map(\.index), []) }
        var exact: [Frame] = [], darker: [Frame] = [], rest: [Frame] = []
        for f in frames {
            let ev = log2(max(product(f), 1) / ref)
            if abs(ev) <= 0.05 { exact.append(f) } else if ev >= -0.5 && ev < 0 { darker.append(f) } else { rest.append(f) }
        }
        exact.sort { $0.timestampNs > $1.timestampNs }
        var log: [String] = []
        let gap = max(maxGapNs, 4 * base.exposureNs)
        var stale = 0
        for i in 1..<max(1, exact.count) where exact[i - 1].timestampNs - exact[i].timestampNs > gap {
            stale = exact.count - i
            rest += exact[i...]
            exact.removeSubrange(i...)
            break
        }
        if stale > 0, let last = exact.last {
            let oldest = last.timestampNs - gap
            rest += darker.filter { $0.timestampNs < oldest }
            darker.removeAll { $0.timestampNs < oldest }
            log.append("N frames: \(stale) at the newest exposure dropped: older than a gap of more than \(gap / 1_000_000) ms")
        }
        var keep = Array(exact.prefix(max(1, requested)))
        rest += exact.dropFirst(keep.count)
        let fill = min(max(1, requested), 8)
        var widened = 0
        if keep.count < fill {
            darker.sort { product($0) > product($1) }
            for f in darker {
                if keep.count < fill { keep.append(f); widened += 1 } else { rest.append(f) }
            }
        } else {
            rest += darker
        }
        log.append("N frames: tier1=\(keep.count - widened) tier2=\(widened) requested=\(requested) exact=\(exact.count) darker=\(darker.count)")
        if !rest.isEmpty {
            let evs = rest.map { log2(max(product($0), 1) / ref) }
            log.append(String(format: "N frames: %ld not used (exposure %+.2f..%+.2f EV from the newest frame)", rest.count,
                              evs.min() ?? 0, evs.max() ?? 0))
        }
        return (keep.map(\.index).sorted(), log)
    }
}
