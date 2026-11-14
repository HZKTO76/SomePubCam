import Foundation

/// Lens shading for a module whose DNG carries no GainMap (the iPad's): a map measured from a SHDR series of an evenly lit plain
/// surface (the shot after «Калибровка виньетирования» is armed), stored per lens and frame size and handed to the pipeline as
/// "ios_lsc_map" (DngShot.shadingMap: as Android's stored plain map, Parameters.applyStoredShading). The gains are
/// LensShadingMap's: four channels per point (R, the green of the even rows, the green of the odd rows, B), 1 at the centre.
enum LensShading {
    static let armedKey = "scam.lsc.calibrate"
    static let gridW = 17, gridH = 13

    struct Map: Codable {
        var width: Int, height: Int
        var gains: [Float]
        var made: Date
    }

    static var armed: Bool {
        get { UserDefaults.standard.bool(forKey: armedKey) }
        set { UserDefaults.standard.set(newValue, forKey: armedKey) }
    }

    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("lsc")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func key(lens: String, width: Int, height: Int) -> String {
        let safe = lens.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(safe) + "-\(width)x\(height)"
    }

    private static func url(_ key: String) -> URL { dir.appendingPathComponent(key + ".json") }

    static func stored(_ key: String) -> Map? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return try? JSONDecoder().decode(Map.self, from: data)
    }

    static var count: Int { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.count }

    static func clearAll() {
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
    }

    /// The map for the pipeline: "w,h,g0,g1,..."
    static func wire(_ key: String) -> String? {
        guard let m = stored(key), m.gains.count == m.width * m.height * 4 else { return nil }
        return ([String(m.width), String(m.height)] + m.gains.map { String($0) }).joined(separator: ",")
    }

    struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    /// The map of the series' N frames (up to four averaged): per grid point the mean of each CFA site over a window of the grid's
    /// spacing, black subtracted; gain = the centre's mean / the point's. Refused when the surface is clipped, too dark or not even.
    static func measure(_ burst: BayerBurst, frames: [NchFrame], black: [Float], white: Float) throws -> Map {
        let w = burst.width, h = burst.height
        let normals = frames.filter { $0.role == NchWriter.roleNormal }.prefix(4)
        guard !normals.isEmpty, w >= 256, h >= 256, burst.cfa >= 0, burst.cfa < 4 else {
            throw Failure(text: Lang.t("Нет кадров для калибровки", "No frames to calibrate from"))
        }
        let layouts = ["RGGB", "GRBG", "GBRG", "BGGR"].map(Array.init)
        func channel(_ dy: Int, _ dx: Int) -> Int {
            switch layouts[burst.cfa][dy * 2 + dx] { case "R": return 0; case "B": return 3; default: return dy == 0 ? 1 : 2 }
        }
        let qw = w / 2, qh = h / 2
        // a quarter of the spacing: an edge window, clipped to the frame, sits only an eighth of the spacing inside its point
        let halfX = max(4, qw / (gridW - 1) / 4), halfY = max(4, qh / (gridH - 1) / 4)
        var means = [Double](repeating: 0, count: gridW * gridH * 4)
        for frame in normals {
            frame.raw.withUnsafeBytes { p in
                let v = p.bindMemory(to: UInt16.self)
                guard v.count >= w * h else { return }
                for gy in 0..<gridH {
                    let cy = gy * (qh - 1) / (gridH - 1)
                    let y0 = max(0, cy - halfY), y1 = min(qh - 1, cy + halfY)
                    for gx in 0..<gridW {
                        let cx = gx * (qw - 1) / (gridW - 1)
                        let x0 = max(0, cx - halfX), x1 = min(qw - 1, cx + halfX)
                        var sum = [Double](repeating: 0, count: 4)
                        var n = 0.0
                        // every quad of the window
                        var qy = y0
                        while qy <= y1 {
                            var qx = x0
                            while qx <= x1 {
                                for dy in 0..<2 {
                                    let row = (qy * 2 + dy) * w
                                    for dx in 0..<2 { sum[channel(dy, dx)] += Double(v[row + qx * 2 + dx]) }
                                }
                                n += 1
                                qx += 1
                            }
                            qy += 1
                        }
                        for c in 0..<4 { means[(gy * gridW + gx) * 4 + c] += sum[c] / max(n, 1) / Double(normals.count) }
                    }
                }
            }
        }
        // the edge points' windows are clipped by the frame: their means sit at the window's centre, inside the point - carried out
        // to the point along the line through the next point's mean (rows, then columns)
        func centres(_ n: Int, _ q: Int, _ half: Int) -> (point: [Double], window: [Double]) {
            var point: [Double] = [], window: [Double] = []
            for g in 0..<n {
                let c = g * (q - 1) / (n - 1)
                point.append(Double(c))
                window.append(Double(max(0, c - half) + min(q - 1, c + half)) / 2)
            }
            return (point, window)
        }
        let xs = centres(gridW, qw, halfX), ys = centres(gridH, qh, halfY)
        func carry(_ m: Double, _ next: Double, _ at: Double, _ nextAt: Double, _ target: Double) -> Double {
            guard abs(nextAt - at) > 1e-9 else { return m }
            return m + (m - next) * (target - at) / (at - nextAt)
        }
        for gy in 0..<gridH {
            for (gx, nx) in [(0, 1), (gridW - 1, gridW - 2)] {
                for c in 0..<4 {
                    let i = (gy * gridW + gx) * 4 + c, j = (gy * gridW + nx) * 4 + c
                    means[i] = carry(means[i], means[j], xs.window[gx], xs.window[nx], xs.point[gx])
                }
            }
        }
        for gx in 0..<gridW {
            for (gy, ny) in [(0, 1), (gridH - 1, gridH - 2)] {
                for c in 0..<4 {
                    let i = (gy * gridW + gx) * 4 + c, j = (ny * gridW + gx) * 4 + c
                    means[i] = carry(means[i], means[j], ys.window[gy], ys.window[ny], ys.point[gy])
                }
            }
        }
        // the black of each channel: the DNG's black of the site that channel sits on
        var channelBlack = [Double](repeating: 0, count: 4)
        for dy in 0..<2 { for dx in 0..<2 { channelBlack[channel(dy, dx)] = Double(black.count == 4 ? black[dy * 2 + dx] : black.first ?? 0) } }
        let range = Double(white) - channelBlack.reduce(0, +) / 4
        for i in means.indices { means[i] -= channelBlack[i % 4] }
        let centre = ((gridH / 2) * gridW + gridW / 2) * 4
        for c in 0..<4 {
            let level = means[centre + c] / range
            if level > 0.85 { throw Failure(text: Lang.t("Центр кадра пересвечен: уменьшите яркость или отойдите от источника света",
                                                         "The centre of the frame is clipped: less light or step back from the lamp")) }
            if level < 0.04 { throw Failure(text: Lang.t("Слишком темно для калибровки: нужна ровно освещённая светлая поверхность",
                                                         "Too dark to calibrate: an evenly lit light surface is needed")) }
        }
        var gains = [Float](repeating: 1, count: means.count)
        for i in means.indices {
            let m = means[i]
            if m / range > 0.92 { throw Failure(text: Lang.t("Часть кадра пересвечена", "Part of the frame is clipped")) }
            guard m > 0 else { throw Failure(text: Lang.t("Углы кадра слишком тёмные", "The corners are too dark")) }
            gains[i] = Float(means[centre + i % 4] / m)
            if !(gains[i] > 0.85 && gains[i] < 8) {
                throw Failure(text: Lang.t("Поверхность освещена неравномерно", "The surface is not evenly lit"))
            }
        }
        // an even surface makes a smooth map: a point far from its neighbours' mean is the scene (an edge, a shadow), not the lens
        for gy in 1..<(gridH - 1) {
            for gx in 1..<(gridW - 1) {
                for c in 0..<4 {
                    let at = { (x: Int, y: Int) in gains[(y * gridW + x) * 4 + c] }
                    let around = (at(gx - 1, gy) + at(gx + 1, gy) + at(gx, gy - 1) + at(gx, gy + 1)) / 4
                    if abs(at(gx, gy) - around) / around > 0.06 {
                        throw Failure(text: Lang.t("В кадре есть детали или тени: снимите ровную светлую поверхность без рисунка",
                                                   "The frame has detail or shadows: shoot a plain, evenly lit light surface"))
                    }
                }
            }
        }
        return Map(width: gridW, height: gridH, gains: gains, made: Date())
    }

    static func save(_ map: Map, key: String) throws {
        try JSONEncoder().encode(map).write(to: url(key), options: .atomic)
    }
}
