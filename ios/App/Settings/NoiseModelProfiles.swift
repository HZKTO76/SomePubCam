import SwiftUI
import UniformTypeIdentifiers

/// NoiseModelProfile (processing/render/NoiseModelProfile.java): a DNG noise-model calibration of four Bayer planes (R, Gr, Gb, B),
/// S = A x iso + B, O = C x iso^2 + D x digitalGain^2. «Авто» keeps each frame's own profile (the DNG's NoiseProfile); another
/// profile replaces it in the merge (BurstProcessor), the denoise and the DNG (DngShot.noiseModel through "ios_noise_profile").
/// The imported file is kept (Application Support/noise_model_imported.json); Android holds it until the app restarts.
struct NoiseModelProfile {
    static let key = "pref_noise_model_profile_key"
    static let autoID = "auto", importedID = "imported"
    let id: String
    let name: String
    let a: [Double], b: [Double], c: [Double], d: [Double]

    /// One (S, O) pair per plane; `analogueIso` is where the digital gain starts
    func evaluate(iso: Int, analogueIso: Int) -> [(Double, Double)] {
        let digitalGain = Swift.max(Double(iso) / Double(Swift.max(analogueIso, 1)), 1.0)
        return (0..<4).map { p in
            let s = a[p] * Double(iso) + b[p]
            let o = c[p] * Double(iso) * Double(iso) + d[p] * digitalGain * digitalGain
            return (Swift.max(s, 0), Swift.max(o, 0))
        }
    }

    /// The planes' mean (S, O) at an ISO (ScamHybridBurst.noiseFor: the merge's one pair per frame)
    func mean(iso: Int, analogueIso: Int) -> (Float, Float) {
        let m = evaluate(iso: iso, analogueIso: analogueIso)
        return (Float(m.map(\.0).reduce(0, +) / 4), Float(m.map(\.1).reduce(0, +) / 4))
    }

    static let lgv50 = NoiseModelProfile(
        id: "lgv50_imx363_0", name: "IMX363_0 (LG V50)",
        a: [2.691353781189422e-06, 2.6817014313123966e-06, 2.682315890739256e-06, 2.695296790679005e-06],
        b: [5.607265966668617e-06, 1.0263138748900872e-05, 1.0650013817119217e-05, 7.6267061661234736e-06],
        c: [2.9917133034145296e-11, 6.086258466440452e-11, 6.308190715155536e-11, 3.0739030068625654e-11],
        d: [3.275624181535426e-07, 6.624913143068297e-07, 6.662466882279819e-07, 3.1510627507887423e-07])

    private static var importedURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("noise_model_imported.json")
    }

    static var imported: NoiseModelProfile? {
        guard let data = try? Data(contentsOf: importedURL),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let a = o["a"] as? [Double], let b = o["b"] as? [Double], let c = o["c"] as? [Double], let d = o["d"] as? [Double],
              [a, b, c, d].allSatisfy({ $0.count == 4 }) else { return nil }
        return NoiseModelProfile(id: importedID, name: o["name"] as? String ?? Lang.t("Импортированный", "Imported"), a: a, b: b, c: c, d: d)
    }

    static func setImported(_ p: NoiseModelProfile) throws {
        let data = try JSONSerialization.data(withJSONObject: ["name": p.name, "a": p.a, "b": p.b, "c": p.c, "d": p.d])
        try data.write(to: importedURL, options: .atomic)
    }

    static func byId(_ id: String?) -> NoiseModelProfile? {
        switch id {
        case nil, autoID: return nil
        case importedID: return imported
        case lgv50.id: return lgv50
        default: return nil
        }
    }

    static func active(_ values: [String: Any]? = nil) -> NoiseModelProfile? {
        let prefs = values ?? UserDefaults.standard.dictionary(forKey: PostSettings.prefsKey) ?? [:]
        return byId(prefs[key] as? String ?? autoID)
    }

    /// The coefficients for the C++ side (DngShot.noiseModel): A, B, C, D, four each
    var wire: String { (a + b + c + d).map { String($0) }.joined(separator: ",") }

    /// The calibration file's four arrays, read as data (nothing compiled); nil unless all four are there with four numbers
    static func parse(_ source: String, id: String, name: String) -> NoiseModelProfile? {
        guard let re = try? NSRegularExpression(pattern: "noise_model_([ABCD])\\s*\\[\\s*\\]\\s*=\\s*\\{([^}]*)\\}") else { return nil }
        var found: [Int: [Double]] = [:]
        let ns = source as NSString
        for m in re.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let slot = "ABCD".distance(from: "ABCD".startIndex, to: "ABCD".firstIndex(of: Character(ns.substring(with: m.range(at: 1))))!)
            let parts = ns.substring(with: m.range(at: 2)).split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var values: [Double] = []
            for part in parts {
                guard let v = Double(part.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
                values.append(v)
            }
            found[slot] = values
        }
        guard let a = found[0], let b = found[1], let c = found[2], let d = found[3] else { return nil }
        return NoiseModelProfile(id: id, name: name, a: a, b: b, c: c, d: d)
    }

    /// The profile in the calibration-file format it was imported from
    var calibrationSource: String {
        func array(_ name: String, _ v: [Double]) -> String { "    static double \(name)[] = { " + v.map { String($0) }.joined(separator: ",") + " };\n" }
        return "/* SCAMERA noise model export: \(name) */\n\n"
            + "double compute_noise_model_entry_S(int plane, int sens) {\n" + array("noise_model_A", a) + array("noise_model_B", b)
            + "    double s = noise_model_A[plane] * sens + noise_model_B[plane];\n    return s < 0.0 ? 0.0 : s;\n}\n\n"
            + "double compute_noise_model_entry_O(int plane, int sens) {\n" + array("noise_model_C", c) + array("noise_model_D", d)
            + "    double digital_gain = (sens / 800.0) < 1.0 ? 1.0 : (sens / 800.0);\n"
            + "    double o = noise_model_C[plane] * sens * sens + noise_model_D[plane] * digital_gain * digital_gain;\n"
            + "    return o < 0.0 ? 0.0 : o;\n}\n"
    }
}

/// «Импорт модели шума»: a calibration file (.c) becomes the imported profile and the chosen one
struct NoiseModelImportRow<Label: View>: View {
    let label: Label
    @State private var picking = false
    @State private var message: String?

    var body: some View {
        Button { picking = true } label: { label }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.cSource, .plainText, .text, .data]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url), let source = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                    message = Lang.t("Не удалось открыть файл", "Couldn't open the file")
                    return
                }
                guard let profile = NoiseModelProfile.parse(source, id: NoiseModelProfile.importedID, name: Lang.t("Импортированный", "Imported")) else {
                    message = Lang.t("Файл не содержит noise_model_A/B/C/D", "The file has no noise_model_A/B/C/D")
                    return
                }
                do {
                    try NoiseModelProfile.setImported(profile)
                    SettingsStore.shared.set(NoiseModelProfile.key, NoiseModelProfile.importedID)
                    message = Lang.t("Модель шума импортирована", "Noise model imported")
                } catch {
                    message = Lang.t("Ошибка импорта: ", "Import error: ") + error.localizedDescription
                }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            }
    }
}

/// «Экспорт модели шума»: the active profile as a calibration file, through the share sheet (Android: Download/SCAMERA)
struct NoiseModelExportRow<Label: View>: View {
    let label: Label
    @State private var sharing: [URL]?
    @State private var message: String?

    var body: some View {
        Button {
            guard let profile = NoiseModelProfile.active(SettingsStore.shared.values) else {
                message = Lang.t("Активен автоматический профиль, экспортировать нечего", "The automatic profile is active, nothing to export")
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("SCAMERA-noise-\(profile.id).c")
            do {
                try profile.calibrationSource.data(using: .utf8)?.write(to: url, options: .atomic)
                sharing = [url]
            } catch {
                message = Lang.t("Не удалось записать файл", "Couldn't write the file")
            }
        } label: { label }
            .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) { ActivityView(items: sharing ?? []) }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            }
    }
}
