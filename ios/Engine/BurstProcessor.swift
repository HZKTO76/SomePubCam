import Foundation
import ImageIO

import simd
import UniformTypeIdentifiers

/// A Bayer burst through the Android photo route as ported (Engine/post/ShotRun.hpp, ScamGL on the GPU): NCH transport → the SHDR
/// merge → the post pipeline («Why тон», the Android nodes and shaders) with the shot's parameters from its DNG → HEIC.
enum BurstProcessor {
    struct Result {
        let heic: Data?         // the photo in «Формат фото» (JPEG or HEIC); none for «Только RAW»
        let uti: String
        let log: [String]
        /// P165: the shot's merged DNG as Android saves it - with the photo as its preview (P620) and the gallery developer's record
        /// at its end (P665); nil when none was asked or made (the camera's DNG of the reference frame is saved then)
        var dng: Data? = nil
    }

    /// P165: the facts of the shot's files for the merged DNG (dngFacts of SCAMShot.processBurst) from the photo's properties
    /// (ShotExif.apply's EXIF / TIFF) and the shot's record: the make and the phone, the build's hardware model, the app, the time as
    /// text, the lens.
    static func dngFacts(metadata: [String: Any], shot: ShotExif) -> [String: Any] {
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let make = (tiff[kCGImagePropertyTIFFMake as String] as? String) ?? "Apple"
        let model = (tiff[kCGImagePropertyTIFFModel as String] as? String) ?? ""
        var facts: [String: Any] = [
            "make": make, "model": model, "device": ShotExif.device(make: make, model: model) ?? model, "buildModel": BuildInfo.machine,
            "software": ShotExif.software, "dateTime": ShotExif.dateTime(shot.time), "subSec": ShotExif.subSec(shot.time),
            "offset": ShotExif.offset(shot.time), "facing": shot.facing ?? "", "cameraID": shot.cameraID ?? "",
            "filmRecipe": shot.filmRecipe ?? "", "frames": shot.frames, "physicalId": -1,
        ]
        let fNumber = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue ?? shot.fNumber
        if fNumber > 0 { facts["fNumber"] = fNumber }
        let focal = (exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue ?? shot.focalLength
        if focal > 0 { facts["focalLength"] = focal }
        let focal35 = (exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber)?.intValue ?? shot.focal35
        if focal35 > 0 { facts["focal35"] = focal35 }
        return facts
    }

    /// The last burst is kept as an NCH file (Documents/Bursts, Files app) to replay it against the Android merge.
    static var lastBurstURL: URL {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Bursts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = staleStreamsRemoved
        return folder.appendingPathComponent("last.nch")
    }

    /// NchStream files of an earlier run that never reached the merge (the app ended during a shot): removed once a launch
    private static let staleStreamsRemoved: Bool = {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Bursts", isDirectory: true)
        for f in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where f.hasPrefix("shot-") && f.hasSuffix(".nch") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(f))
        }
        return true
    }()

    /// The facts beside the last burst (NchWriter.writeFacts: the frames' capture roles and exposures, the zoom, the 16:9 cut)
    static var lastFactsURL: URL { lastBurstURL.appendingPathExtension("json") }

    /// zoom: the press's digital zoom over the module's own (ZoomController.processingResidual; nil: the burst's, BayerBurst.zoom) -
    /// SabreCrop's window of the frames before the merge and the photo's crop after the pipeline (Engine/post/ShotRun.hpp).
    /// dngFacts (P165): the facts for the merged DNG (dngFacts(metadata:shot:)), nil when no RAW is saved.
    /// rawOnly («Только RAW», pref_save_raw_key 2): the merge and its DNG only (ScamProcessor returns after the DNG): no photo.
    /// How many times the frames' codes exceed the DNG's levels (1, 2, 4, ... ; nil when it cannot be told): the 14-bit buffer's full
    /// scale against the DNG's white.
    /// The data floor (Parameters.refineBlackLevel's plain path, P114): on the darkest frame of the series (the lowest exposure x ISO:
    /// ScamProcessor.refineBlackFromDarkestFrame - it has the most sites at the floor), per CFA site the 32 x 32 blocks of the site's
    /// plane sampled every fourth row and column (BlockScan), a block with a sample under a quarter of the declared black left out
    /// (padding / a masked strip); the third lowest block mean of a site, the lowest of the four sites. nil without one.
    static func blackFloor(_ burst: BayerBurst, black: [Float]) -> Float? {
        let w = burst.width, h = burst.height, bs = 32, bw = w / 2 / bs, bh = h / 2 / bs
        guard bw > 0, bh > 0, w >= 128, h >= 128 else { return nil }
        let darkest = burst.frames.min(by: { Double($0.exposureNs) * Double($0.iso) < Double($1.exposureNs) * Double($1.iso) })
        guard let frame = burst.frames.contains(where: { $0.exposureNs <= 0 || $0.iso == 0 }) ? burst.frames.first : darkest,
              frame.raw.count >= w * h * 2 else { return nil }
        let reportedMin = black.min() ?? 0
        let paddingBelow: Float = reportedMin > 4 ? reportedMin * 0.25 : -1
        var floor = Float.greatestFiniteMagnitude
        frame.raw.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            let v = p.bindMemory(to: UInt16.self)
            for c in 0..<4 {
                let ox = c % 2, oy = c / 2
                var s1 = Float.greatestFiniteMagnitude, s2 = s1, s3 = s1
                for by in 0..<bh {
                    for bx in 0..<bw {
                        var sum = 0, low = false
                        for y in stride(from: 0, to: bs, by: 4) {
                            let row = ((by * bs + y) * 2 + oy) * w + bx * bs * 2 + ox
                            for x in stride(from: 0, to: bs, by: 4) {
                                let s = Int(UInt16(littleEndian: v[row + x * 2]))
                                sum += s
                                if Float(s) < paddingBelow { low = true }
                            }
                        }
                        if low { continue }
                        let mean = Float(sum) / Float((bs / 4) * (bs / 4))
                        if mean < s1 { s3 = s2; s2 = s1; s1 = mean } else if mean < s2 { s3 = s2; s2 = mean } else if mean < s3 { s3 = mean }
                    }
                }
                floor = min(floor, s3)
            }
        }
        return floor == .greatestFiniteMagnitude ? nil : floor
    }

    static func bufferScale(_ burst: BayerBurst, info: DngInfo, log: (String) -> Void) -> Float? {
        let black = info.black.reduce(0, +) / 4
        guard info.white > black + 16, let first = burst.frames.first else { return nil }
        // the frames are AVFoundation's 14-bit Bayer buffers (BayerBurst takes only those): the DNG's white against the buffer's
        // full scale gives the whole extra bits. (A noise slope measured on a frame pair is no measure of it: hand shake between the
        // frames adds texture to the difference - 18-20x on a shaken series instead of 4x.)
        let r = 16383 / info.white
        let k: Float = r >= 1.5 ? Float(1 << min(4, max(0, Int(log2(r).rounded())))) : 1
        // the check in the log: the darkest 0.1 % of the sites sit at the black level (x k), the brightest at most at the white (x k)
        var samples: [UInt16] = []
        first.raw.withUnsafeBytes { p in
            let v = p.bindMemory(to: UInt16.self)
            var i = 0
            while i < v.count { samples.append(v[i]); i += 97 }
        }
        samples.sort()
        let dark = samples.isEmpty || black <= 0 ? 0 : Float(samples[samples.count / 1000]) / black
        let top = samples.last.map { Float($0) / info.white } ?? 0
        log("frame codes against the DNG levels (\(black) / \(info.white)): 14-bit buffer -> levels x\(Int(k))"
            + " (darkest sites / black \(String(format: "%.2f", dark)), brightest / white \(String(format: "%.2f", top)))")
        return k
    }

    /// SCAM Lab on the iPhone (ScamLabFragment's «пересклейка»): the last kept series (Documents/Bursts/last.nch and its lab files)
    /// merged and processed again with the settings as they are now; the photo in «Формат фото», no watermark, no DNG
    static func relab() throws -> Result {
        var log: [String] = []
        let started = Date()
        let fm = FileManager.default
        guard fm.fileExists(atPath: lastBurstURL.path), let dng = try? Data(contentsOf: lastBurstURL.appendingPathExtension("dng")) else {
            throw EngineError.decode(Lang.t("Нет сохранённой серии: снимите кадр SHDR", "No kept series: take an SHDR shot"))
        }
        let metadata = (try? Data(contentsOf: lastBurstURL.appendingPathExtension("meta")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let lab = (try? Data(contentsOf: lastBurstURL.appendingPathExtension("lab")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard let shaders = Bundle.main.url(forResource: "shaders", withExtension: nil) else {
            throw EngineError.decode("the pipeline's shaders are missing from the app")
        }
        let extra: [String: Any] = (lab["lscKey"] as? String).flatMap { LensShading.wire($0) }.map { ["ios_lsc_map": ["s", $0]] } ?? [:]
        let photo: SCAMPhoto
        do {
            photo = try SCAMShot.processBurst(atPath: lastBurstURL.path, dng: dng, settings: PostSettings.json(extra: extra), faces: [],
                                              facesDetected: false, front: lab["front"] as? Bool ?? false, dngFacts: nil, rawOnly: false,
                                              shaders: shaders.path)
        } catch let error as NSError {
            log += (error.userInfo["log"] as? [String]) ?? []
            throw error
        }
        log += photo.log
        log.append("lab: merge \(Int(photo.mergeMilliseconds)) ms, post \(Int(photo.postMilliseconds)) ms, photo \(photo.width)x\(photo.height)")
        let format = ShotProcessor.photoFormat
        var encodeLog: [String] = []
        let data = try ShotProcessor.encode(rgba: photo.rgba, width: photo.width, height: photo.height, metadata: metadata, format: format,
                                            gainMap: ShotProcessor.GainMap(photo: photo), log: { encodeLog.append($0) })
        log += encodeLog
        log.append("lab: the series merged again in \(ms(since: started)) ms, \(data.count) bytes")
        return Result(heic: data, uti: format.type.identifier, log: log)
    }

    static func process(_ burst: BayerBurst, metadata: [String: Any], zoom: Double? = nil, dngFacts: [String: Any]? = nil,
                        rawOnly: Bool = false) throws -> Result {
        guard MetalEngine.shared != nil else { throw EngineError.noDevice }
        guard burst.frames.count >= 1, burst.width >= 64, burst.height >= 64 else { throw EngineError.decode("empty burst") }
        var log = burst.report
        let started = Date()
        var info = DngInfo(dng: burst.dng)
        log += info.notes.map { "dng: " + $0 }
        var frames = burst.frames
        // the frames' own scale: AVFoundation's 14-bit Bayer buffer ('rgg4') against the DNG's levels of the same photo (12-bit
        // 528 / 4095 on the iPad and the iPhones) - the levels go to the buffer's units
        if let k = Self.bufferScale(burst, info: info, log: { log.append($0) }), k != 1 {
            info.black = info.black.map { $0 * k }
            info.white *= k
        }
        // P558 (Parameters.clipWhiteToPlateau): the reference frame's clip plateau under the declared white is the white - else
        // the blown areas never reach it (no clip flags, the fast merge's highlight path and its ultrashort frames off)
        if let first = frames.first {
            let h = RawWhite.histogram(first.raw, width: burst.width, height: burst.height)
            let (white, plateau) = RawWhite.of(info.white, black: info.black, histogram: h)
            if white != info.white {
                log.append("RAW white level from data: the frame clips at \(plateau) under the white \(Int(info.white)) (P558)")
                info.white = white
            } else {
                var top = 0, seen = 0
                for v in stride(from: h.values.count - 1, to: 0, by: -1) { seen += h.values[v]; if seen >= 4 { top = v; break } }
                log.append("RAW white level: \(Int(info.white)) kept (top sample \(top), plateau \(plateau))")
            }
        }
        // «Чёрный из данных» (pref_raw_black_from_data, Parameters.refineBlackLevel / applyBlackFloor): the darkest frame's data
        // floor (blackFloor) below the declared black by more than ~1 DN of a 10-bit range is the black
        if PostSettings.bool("pref_raw_black_from_data", true), let floor = Self.blackFloor(burst, black: info.black),
           info.black.contains(where: { $0 > floor + max(1, info.white / 1023) }) {
            let before = info.black
            info.black = info.black.map { $0 > floor + max(1, info.white / 1023) ? floor : $0 }
            log.append("RAW black level from data: \(before) -> \(info.black) (data floor \(floor))")
        }
        // «Калибровка виньетирования» armed: this series (an evenly lit plain surface) becomes its lens's shading map
        let lscKey = LensShading.key(lens: burst.lens, width: burst.width, height: burst.height)
        if LensShading.armed {
            LensShading.armed = false
            let note: String
            do {
                let map = try LensShading.measure(burst, frames: frames, black: info.black, white: info.white)
                try LensShading.save(map, key: lscKey)
                let corner = map.gains[1]
                note = Lang.t("Виньетирование откалибровано", "Vignetting calibrated")
                log.append("lens shading: calibrated \(map.width)x\(map.height) for \(lscKey), green corner gain \(String(format: "%.2f", corner))")
            } catch {
                note = Lang.t("Калибровка не удалась: ", "Calibration failed: ") + error.localizedDescription
                log.append("lens shading: calibration refused: \(error.localizedDescription)")
            }
            Task { @MainActor in MessageCenter.shared.info(note) }
        }
        let blackMean = info.black.reduce(0, +) / 4
        // the frame the DNG is (the series' first); the noise of the others is its profile at their ISO (Camera2 gives each frame its
        // own SENSOR_NOISE_PROFILE; the iPhone's DNG profile is the first frame's)
        let iso0 = Float(max(frames[0].iso, 1))
        var source = "DNG NoiseProfile at each frame's ISO"
        var noise = info.noise
        let normals = frames.indices.filter { frames[$0].role == NchWriter.roleNormal }
        if noise == nil, normals.count >= 2,
           let estimate = NoiseEstimate.fromPair(frames[normals[0]].raw, frames[normals[1]].raw, width: burst.width, height: burst.height,
                                                 cfa: burst.cfa, black: blackMean, white: info.white) {
            // the pair's ISO is the first N frame's: scaled to the DNG frame's
            let k = iso0 / Float(max(frames[normals[0]].iso, 1))
            noise = (estimate.0 * k, estimate.1 * k * k)
            source = "estimated from N frames \(normals[0]) / \(normals[1])"
        }
        let (slope, offset) = noise ?? (1e-4, 1e-6)
        if noise == nil { source = "fallback (no profile, one frame)" }
        for i in frames.indices {
            let k = Float(frames[i].iso) / iso0
            frames[i].noiseSlope = slope * k
            frames[i].noiseOffset = offset * k * k
        }
        // «Профиль модели шума» other than «Авто» (ScamHybridBurst.noiseFor): the profile at each frame's ISO, the planes' mean; the
        // iPhone tells no analogue ISO range, so the digital gain is taken as 1 (Android: SENSOR_MAX_ANALOG_SENSITIVITY)
        if let profile = NoiseModelProfile.active() {
            for i in frames.indices {
                let iso = max(1, Int(frames[i].iso))
                (frames[i].noiseSlope, frames[i].noiseOffset) = profile.mean(iso: iso, analogueIso: iso)
            }
            source = "settings profile \(profile.id) at each frame's ISO"
        }
        let shotZoom = max(1, zoom ?? burst.zoom)
        let roles = frames.map(\.role)
        log.append("burst \(burst.width)x\(burst.height) cfa=\(burst.cfa) frames=\(frames.count) (N \(roles.filter { $0 == NchWriter.roleNormal }.count),"
                   + " bracketed \(roles.filter { $0 == NchWriter.roleBracketed }.count), ultrashort \(roles.filter { $0 == NchWriter.roleUltrashort }.count))"
                   + " black=\(info.black) white=\(info.white) noise \(source): S=\(slope) O=\(offset) neutral=\(info.neutral)"
                   + " orientation=\(info.orientation) zoom=\(String(format: "%.3f", shotZoom))")

        let nch = lastBurstURL
        let writeStarted = Date()
        // the frames in capture order; the merge's frame table (the base, roles, ratios, noise, orderMs: ScamHybridBurst's rules) and
        // the zoom's window are ShotRun's (Engine/post/HybridSelect.hpp, SabreCrop.hpp), from these facts
        if let stream = burst.stream, stream.planes == frames.count, (try? stream.finish(cfa: burst.cfa, white: info.white, black: info.black, frames: frames)) != nil {
            // the planes went to the flash during the capture (NchStream): the header now, then the file becomes last.nch
            try? FileManager.default.removeItem(at: nch)
            try FileManager.default.moveItem(at: stream.url, to: nch)
            log.append("burst streamed to the flash during the capture")
        } else {
            burst.stream?.discard()
            // a new file, not the old one rewritten in place: a series kept by «Сохранять RAW-серию» is a link to it (RawBurstKeep)
            try? FileManager.default.removeItem(at: nch)
            try NchWriter.write(to: nch, width: burst.width, height: burst.height, cfa: burst.cfa, white: info.white, black: info.black,
                                frames: frames)
        }
        try NchWriter.writeFacts(to: lastFactsURL, frames: frames, zoom: shotZoom, fullHeight: burst.fullHeight, firstRow: burst.firstRow)
        log.append("burst written to \(nch.lastPathComponent) in \(ms(since: writeStarted)) ms")
        // SCAM Lab (iOS): what merging this series again needs beside it - the reference frame's DNG, the photo's metadata, the lens
        try? burst.dng.write(to: lastBurstURL.appendingPathExtension("dng"), options: .atomic)
        if let plist = try? PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0) {
            try? plist.write(to: lastBurstURL.appendingPathExtension("meta"), options: .atomic)
        }
        if let lab = try? JSONSerialization.data(withJSONObject: ["lscKey": lscKey, "front": burst.front, "frames": frames.count,
                                                                  "width": burst.width, "height": burst.height, "time": Date().timeIntervalSince1970]) {
            try? lab.write(to: lastBurstURL.appendingPathExtension("lab"), options: .atomic)
        }
        // «Сохранять RAW-серию» (ScamNeuralClient's keep-burst): the series and its sidecars kept beside last.nch (before the merge,
        // as the worker keeps it: a merge that fails leaves it too)
        if RawBurstKeep.on { RawBurstKeep.keep(nch, time: started, log: { log.append($0) }) }
        // «Сохранять этапы обработки» (ScamDiagnostics): the post nodes' outputs and the shot's log in a folder of the shot
        let diagnostics = rawOnly && dngFacts != nil ? nil : ShotDiagnostics.folder(started)
        defer { if let diagnostics { ShotDiagnostics.finish(diagnostics, log: log, facts: lastFactsURL) } }
        guard let shaders = Bundle.main.url(forResource: "shaders", withExtension: nil) else {
            throw EngineError.decode("the pipeline's shaders are missing from the app")
        }
        // «Портрет»: the faces for the post pipeline (Android: Camera2's face detection, Parameters.portraitFaces)
        var faces = PortraitFaces.Faces()
        if PortraitFaces.enabled {
            let faceStarted = Date()
            faces = PortraitFaces.detect(burst, dngOrientation: info.orientation, black: blackMean, white: info.white)
            log.append("portrait: \(faces.note) in \(ms(since: faceStarted)) ms")
        }
        let photo: SCAMPhoto
        do {
            // the stored lens shading map of this lens and frame size (used where the DNG has none)
            var extra: [String: Any] = LensShading.wire(lscKey).map { ["ios_lsc_map": ["s", $0]] } ?? [:]
            if let diagnostics { extra.merge(ShotDiagnostics.extra(diagnostics)) { _, new in new } }
            photo = try Perf.interval("merge + post") {
                try SCAMShot.processBurst(atPath: nch.path, dng: burst.dng, settings: PostSettings.json(extra: extra),
                                          faces: faces.boxes.map { NSNumber(value: $0) }, facesDetected: faces.detected, front: burst.front,
                                          dngFacts: dngFacts, rawOnly: rawOnly && dngFacts != nil, shaders: shaders.path)
            }
        } catch let error as NSError {
            log += (error.userInfo["log"] as? [String]) ?? []
            if diagnostics != nil { log.append("failed: \(error.localizedDescription)") }
            throw error
        }
        log += photo.log
        if rawOnly && dngFacts != nil {
            log.append("RAW processing finished: merge \(Int(photo.mergeMilliseconds)) ms, DNG \(photo.mergedDng?.count ?? 0) bytes, \(memoryFootprint())")
            return Result(heic: nil, uti: UTType.heic.identifier, log: log, dng: photo.mergedDng)
        }
        log.append("merge \(Int(photo.mergeMilliseconds)) ms, post \(Int(photo.postMilliseconds)) ms, photo \(photo.width)x\(photo.height), \(memoryFootprint())")
        let format = ShotProcessor.photoFormat
        // P628: the watermark on the finished photo (upright, after every crop and resize) before its encoding; the Ultra HDR gain
        // map is left as the pipeline made it, as ScamProcessor does
        var rgba = photo.rgba
        // «Отметка ES / L на фото»: whether the ultrashort and long frames went into this photo, or a short code why not
        // the counts after the frame rules (ShotRun: «frames sent: ultrashort s of c, long s of c»), as ScamHybridBurst hands them on
        var es = frames.filter { $0.role == NchWriter.roleUltrashort }.count, long = frames.filter { $0.role == NchWriter.roleBracketed }.count
        var esSent = es, longSent = long
        if let line = photo.log.first(where: { $0.hasPrefix("frames sent: ") }) {
            let n = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if n.count == 4 { (esSent, es, longSent, long) = (n[0], n[1], n[2], n[3]) }
        }
        let plan = burst.report.first(where: { $0.hasPrefix("hybrid normal-back:") || $0.hasPrefix("hybrid plan:") })
            ?? (HybridPlan.oneExposure ? HybridPlan.offDescription : nil)
        let stamp = MergeStamp.lines(plan: plan, esCaptured: es, esSent: esSent, longCaptured: long, longSent: longSent,
                                     report: photo.log.joined(separator: "\n"), ettr: MergeStamp.ettrLine(burst.report))
        log.append("merge stamp: " + stamp.joined(separator: " | "))
        if MergeStamp.on { MergeStamp.draw(&rgba, width: photo.width, height: photo.height, lines: stamp) }
        var watermarkRecord: SCAMWatermarkRecord?
        if PhotoWatermark.on() {
            // P633: the pixels under it kept (WatermarkPatch) for the gallery's editor to take it off
            watermarkRecord = PhotoWatermark.applyRecorded(&rgba, width: photo.width, height: photo.height, metadata: metadata, dng: burst.dng,
                                                           shotTime: started, log: { log.append($0) }).record
        }
        var encodeLog: [String] = []
        var heic = try Perf.interval("encode") {
            try ShotProcessor.encode(rgba: rgba, width: photo.width, height: photo.height, metadata: metadata, format: format,
                                     gainMap: ShotProcessor.GainMap(photo: photo), log: { encodeLog.append($0) })
        }
        log += encodeLog
        // P633: the record at the very end of the file (WatermarkStore), as PhotoOutput appends it to Android's files
        if let watermarkRecord { heic = PhotoWatermark.appendRecord(watermarkRecord, to: heic, log: { log.append($0) }) }
        // P620: the photo as saved becomes the merged DNG's preview (not a mirrored front camera's), then P665's record, the file's
        // last part
        var dng: Data?
        if var merged = photo.mergedDng {
            if !photo.mirrored {
                let previewStarted = Date()
                if let withPreview = SCAMShot.dng(merged, preview: rgba, width: photo.width, height: photo.height,
                                                  rotation: photo.dngRotation, software: ShotExif.software) {
                    log.append("DNG preview in \(ms(since: previewStarted)) ms, DNG \(merged.count) -> \(withPreview.count) bytes")
                    merged = withPreview
                } else {
                    log.append("DNG preview not written (the DNG stays without one)")
                }
            }
            if let record = photo.developRecord {
                merged.append(record)
                log.append("develop record appended to the DNG: \(record.count) bytes")
            }
            dng = merged
        }
        log.append("burst processed in \(ms(since: started)) ms, HEIC \(heic.count) bytes, \(memoryFootprint())")
        return Result(heic: heic, uti: format.type.identifier, log: log, dng: dng)
    }
}
