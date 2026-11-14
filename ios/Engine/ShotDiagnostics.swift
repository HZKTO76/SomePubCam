import Foundation

/// «Сохранять RAW-серию» (pref_keep_raw_burst, P191; scam_dev.txt "keep_burst" over it, PreferenceKeys.scamDevSwitch): every SHDR
/// shot keeps its RAW series. Android's worker writes Download/SCAMERA/scam_burst-<time>.bin; the iPhone's series is already the
/// NCH file the merge reads (Documents/Bursts/last.nch, the lab's), so a shot's series is that file and its sidecars (.json frame
/// facts, .dng reference frame, .meta photo metadata, .lab lens facts) kept under Documents/Bursts/scam_rawburst-<time>.nch, as
/// hard links (no copy of the bytes; a copy where a link is refused). last.nch stays the lab's; the next shot's last.nch is a
/// new file (BurstProcessor removes the old one first), so a kept series is never overwritten.
enum RawBurstKeep {
    static var on: Bool {
        if let dev = HybridPlan.dev["keep_burst"] { return dev != 0 }
        return StoredPrefs.bool("pref_keep_raw_burst", false)
    }

    static let sidecars = ["json", "dng", "meta", "lab"]

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// `nch` and its sidecars under scam_rawburst-<time>.nch beside it (a second shot in the same second: -2, -3, ...); the
    /// kept file's name, nil when nothing was kept. One log line.
    @discardableResult
    static func keep(_ nch: URL, time: Date, log: (String) -> Void) -> URL? {
        let fm = FileManager.default
        let folder = nch.deletingLastPathComponent()
        let base = "scam_rawburst-" + stamp.string(from: time)
        var target = folder.appendingPathComponent(base + ".nch")
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base)-\(n).nch")
            n += 1
        }
        guard place(nch, at: target) else {
            log("RAW series not kept: \(target.lastPathComponent) could not be written")
            return nil
        }
        var kept = [target.lastPathComponent]
        for ext in sidecars {
            let from = nch.appendingPathExtension(ext)
            guard fm.fileExists(atPath: from.path) else { continue }
            if place(from, at: target.appendingPathExtension(ext)) { kept.append(ext) }
        }
        log("RAW series kept («Сохранять RAW-серию»): Bursts/" + kept.joined(separator: " + ."))
        return target
    }

    /// A hard link of `from` at `to`, else a copy
    private static func place(_ from: URL, at to: URL) -> Bool {
        let fm = FileManager.default
        if (try? fm.linkItem(at: from, to: to)) != nil { return true }
        return (try? fm.copyItem(at: from, to: to)) != nil
    }
}

/// «Сохранять этапы обработки» (pref_scam_hybrid_diagnostics; scam_dev "hybrid_diagnostics" over it, PreferenceKeys.hybridSwitch):
/// Android's ScamDiagnostics writes a shot's job folder (README.txt, frames.txt, the stages' sampled previews as PNG / PFM with
/// stages.txt) and zips it to Documents/SCAMERA/Dumps. The iPhone writes Documents/SCAMERA/diagnostics/<shot time>/: every post
/// node's output as an 8-bit PNG (at most 1024 px a side, every n-th texel of every n-th row as ScamDiagnostics samples them;
/// linear stages with gamma 1/2.2), stages.txt (Bridge/ScamShot.mm through PostPipeline.afterNode), the shot's log, the frames'
/// facts and a README. Off: nothing is asked of the pipeline (no hook, no cost). The settings json carries the folder as
/// "ios_diagnostics_dir": Settings::fromJson keeps the Android key off for every shot (the lab's rule).
enum ShotDiagnostics {
    static var on: Bool { HybridPlan.on("diagnostics", false) }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SCAMERA", isDirectory: true).appendingPathComponent("diagnostics", isDirectory: true)
    }

    /// The shot's folder when diagnostics are on (made now), else nil
    static func folder(_ time: Date) -> URL? {
        guard on else { return nil }
        let dir = root.appendingPathComponent(stamp.string(from: time), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            SessionLog.w("Diagnostics", "folder not made: \(error.localizedDescription)")
            return nil
        }
    }

    /// The settings json's extra line that asks the bridge for the stage dumps
    static func extra(_ dir: URL) -> [String: Any] { ["ios_diagnostics_dir": ["s", dir.path]] }

    /// The shot's log, its frames' facts (the burst's sidecar) and the README beside the stages
    static func finish(_ dir: URL, log: [String], facts: URL?) {
        let readme = "SCAM diagnostic capture (iOS)\nbuild: \(ShotExif.software) on \(BuildInfo.machine)\n"
            + "NN-<node>.png: each post node's output in pipeline order, at most 1024 px a side (every n-th texel of every n-th row,"
            + " nearest), the texture's rows as the pipeline holds them (sensor orientation before Rotate); linear stages with gamma"
            + " 1/2.2, the tone's and later stages as they are, values clipped to 0..1.\n"
            + "stages.txt: each stage's size, format and value range. log.txt: the shot's processing log. frames.json: the burst's"
            + " frames (roles, exposures, ISO), the zoom and the 16:9 cut.\n"
        try? readme.write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        try? (log.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        if let facts, FileManager.default.fileExists(atPath: facts.path) {
            let to = dir.appendingPathComponent("frames.json")
            try? FileManager.default.removeItem(at: to)
            try? FileManager.default.copyItem(at: facts, to: to)
        }
        SessionLog.i("Diagnostics", "stages written to Documents/SCAMERA/diagnostics/\(dir.lastPathComponent)")
    }
}
