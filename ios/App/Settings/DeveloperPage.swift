import SwiftUI

/// ScamDevFile (settings/ScamDevFile.java): the developer lines, "key value" per line, in Documents/scam_dev.txt (the Files app:
/// SCAMERA › scam_dev.txt; Android: Download/SCAMERA/scam_dev.txt). The post pipeline reads them as Android's PreferenceKeys
/// reads the file (PostSettings.json's "dev": Settings::scamDevValue / scamDevSwitch / hybridValue), a line written before the Why
/// rename under its new key. The page edits the file itself, so a line works the same whether it was typed into the file (a copy
/// from an Android phone) or set on the page.
enum ScamDevFile {
    static let name = "scam_dev.txt"
    static let shown = "SCAMERA/" + name

    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    static func read() -> String? { try? String(contentsOf: url, encoding: .utf8) }

    static func lines(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    private static func parts(_ line: String) -> [String] {
        line.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// Every key's value from one read of the file (a line before the Why rename under its new key; a new line wins)
    static func snapshot(_ text: String? = read()) -> [String: String] {
        var out: [String: String] = [:]
        for l in lines(text) {
            let p = parts(l)
            guard p.count == 2 else { continue }
            let k = SettingsMigration.why(p[0])
            if out[k] == nil { out[k] = p[1] }
        }
        return out
    }

    /// PreferenceKeys.refreshScamDev: the numbers of the lines (what the pipeline reads)
    static func values(_ text: String? = read()) -> [String: Double] {
        var out: [String: Double] = [:]
        for l in lines(text) {
            let p = parts(l)
            guard p.count == 2, let v = Double(p[1]) else { continue }
            let k = SettingsMigration.why(p[0])
            if k == p[0] || out[k] == nil { out[k] = v }
        }
        return out
    }

    private static var cache: (time: Date, values: [String: Double]) = (.distantPast, [:])

    /// `values()` read again at most every 2 s (PreferenceKeys.refreshScamDev): for the settings' availability, drawn per row
    static func cachedValues() -> [String: Double] {
        if Date().timeIntervalSince(cache.time) > 2 { cache = (Date(), values()) }
        return cache.values
    }

    /// The lines with the key's line replaced (first one), dropped (value nil; every copy) or appended
    static func edit(_ lines: [String], key: String, value: String?) -> [String] {
        var out: [String] = []
        var done = false
        for l in lines {
            let p = parts(l)
            if p.first == key && !l.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                if let value, !done { out.append(key + " " + value) }
                done = true
                continue
            }
            out.append(l)
        }
        if !done, let value { out.append(key + " " + value) }
        return out
    }

    @discardableResult
    static func write(_ lines: [String]) -> Bool {
        var text = lines.joined(separator: "\n")
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            SessionLog.w("Settings", "scam_dev.txt not written: \(error.localizedDescription)")
            return false
        }
    }

    /// Sets (value) or removes (nil) a key's line
    @discardableResult
    static func set(_ key: String, _ value: String?) -> Bool { write(edit(lines(read()), key: key, value: value)) }

    @discardableResult
    static func removeAll(_ keys: [String]) -> Bool {
        var l = lines(read())
        for k in keys { l = edit(l, key: k, value: nil) }
        return write(l)
    }

    /// The full settings reset: the file goes to scam_dev.txt.bak beside it (its lines can be taken back by hand)
    static func setAside() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let bak = url.deletingLastPathComponent().appendingPathComponent(name + ".bak")
        try? fm.removeItem(at: bak)
        try? fm.moveItem(at: url, to: bak)
    }

    /// A number as the file holds it: integers without ".0"
    static func number(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e9 { return String(Int64(v)) }
        return "\(Float(v))"
    }
}

/// The «Для разработчика» page (DeveloperPreferences): one row per scam_dev.txt line of DevKeys, grouped. Rows are not stored as
/// preferences: a switch writes "key 1" / "key 0", a number "key value" (empty: the line goes and the code's default applies)
/// straight into scam_dev.txt; under its name a row shows its state («задано: 1», «по умолчанию: 0»), its meaning is its long press.
/// The iPhone's pipeline reads the merge and processing lines; the lines only Android's camera, worker or GPU route reads are not
/// shown here (`shownOnIPhone`), and the file keeps them for a config carried between the phones.
struct DeveloperPage: View {
    static let screen = "developer_settings_screen"
    static func rowID(_ key: String) -> String { "dev_" + key }

    /// DevKeys groups (their English names) only Android's capture reads: the camera session, its viewfinder, the vendor modes
    private static let androidGroups: Set<String> = [
        "Capture and session", "Viewfinder", "Xiaomi 17 Ultra (tele)", "Xiaomi 15 Ultra (DCG)", "vivo", "Pixel 10 Pro / Pro XL",
    ]
    /// The lines of those groups the iPhone does read (HybridPlan: ETTR; WhyToneCore: the YUV AE's daylight rule)
    private static let readOnIPhone: Set<String> = ["ettr", "yuv_ae_day"]
    /// Lines of the other groups that only the Android worker, its process, its GL / JPEG / GPU route or its diagnostics read
    private static let androidOnly: Set<String> = [
        // the merge worker and its process
        "motion_base_sharp", "prewarm_give_up", "worker_watchdog", "ok_read", "worker_prespawn", "worker_keep_ready", "worker_nice",
        "zero_copy_read", "ahb_transport", "worker_gpu_normal_priority", "isp_preview_off_always",
        // the Android processing's speed switches (the same output)
        "half_rgb_gpu", "scamrgb_tail", "sharpen_stripes", "post_priority", "gpu_low_priority", "post_gpu_pace", "post_band_ms",
        "hybrid_why_edge_luma_cache", "ms_oklab_cache", "why_gather_taps", "post_shared_context", "gainmap_run_context", "jpeg_threads",
        "rgba_upload", "hybrid_isp_ccm", "jpeg_aq", "jpeg_fast_tables", "gl_warm_up", "gl_warm_up_merge", "gl_warm_up_recipes",
        "gl_warm_up_shared", "black_scan_bulk", "pedestal_memory", "post_pbo_readback", "post_pbo_ring", "post_half_mapped",
        "jpeg_stream", "jpeg_stream_marks", "jpeg_stream_tiles", "jpeg_stream_combine", "post_noise_quantile_gpu", "thermal_async",
        "release_async", "dng_async", "raw_crop_in_place", "prep_warm", "exif_beside_encode",
        // diagnostics
        "film_reference_dump", "post_sync", "post_gpu_timer", "diag_sync", "diag_gpu_async", "stab_trace", "stab_trace_ois",
    ]

    /// Whether the page shows the line on the iPhone (the search and the page's reset go by the same rule)
    static func shownOnIPhone(_ k: SettingsCatalog.DevKey) -> Bool {
        if readOnIPhone.contains(k.k) { return true }
        if androidGroups.contains(k.g.en) || androidOnly.contains(k.k) || k.k.hasPrefix("post_ab") { return false }
        return true
    }

    /// The lines the page shows
    static var shownKeys: [SettingsCatalog.DevKey] { SettingsCatalog.shared.devKeys.filter(shownOnIPhone) }

    let node: SettingsNode
    @Environment(\.settingsHighlight) private var highlight
    @State private var values: [String: String] = [:]
    @State private var asking = false
    @State private var editing: SettingsCatalog.DevKey?
    @State private var help: SettingsCatalog.DevKey?
    @State private var typed = ""

    private struct DevGroup: Identifiable { let id: String; var keys: [SettingsCatalog.DevKey] }

    private var groups: [DevGroup] {
        var out: [DevGroup] = []
        for k in Self.shownKeys {
            if let i = out.firstIndex(where: { $0.id == k.group }) { out[i].keys.append(k) } else { out.append(DevGroup(id: k.group, keys: [k])) }
        }
        return out
    }

    private func state(_ k: SettingsCatalog.DevKey) -> String {
        if let cur = values[k.k] { return L("dev.state.set") + " " + cur }
        if let d = k.d { return L("dev.state.default") + " " + d }
        return L("dev.state.app")
    }

    private func refresh() { values = ScamDevFile.snapshot() }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    Button(L("dev.reset")) { asking = true }
                } footer: {
                    Text(String(format: L("dev.note"), ScamDevFile.shown))
                }
                ForEach(groups) { group in
                    Section(group.id) {
                        ForEach(group.keys) { k in row(k).id(Self.rowID(k.k)) }
                    }
                }
            }
            .onAppear {
                refresh()
                guard let highlight else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation { proxy.scrollTo(highlight, anchor: .center) } }
            }
            .tabletReadableList()
        }
        .navigationTitle(SettingsCatalog.shared.text(node.title) ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .alert(L("dev.reset_title"), isPresented: $asking) {
            Button(L("set.layout.reset"), role: .destructive) {
                // the page's own lines: the Android-only ones it does not show stay in the file
                let shown = Self.shownKeys
                let set = shown.filter { values[$0.k] != nil }.count
                ScamDevFile.removeAll(shown.map(\.k))
                refresh()
                SettingsTips.show(PageReset.message(set))
            }
            Button(L("settings.cancel"), role: .cancel) {}
        } message: {
            Text(L("dev.reset_message"))
        }
        .alert(editing?.k ?? "", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField(L("dev.empty_default"), text: $typed).keyboardType(.numbersAndPunctuation)
            Button(L("set.precise.done")) {
                guard let k = editing else { return }
                let text = typed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                if text.isEmpty {
                    ScamDevFile.set(k.k, nil)
                } else if let v = Double(text), v.isFinite {
                    ScamDevFile.set(k.k, ScamDevFile.number(v))
                }
                refresh()
            }
            Button(L("settings.cancel"), role: .cancel) {}
        } message: {
            if let k = editing { Text(k.text + "\n" + L("dev.empty_default") + (k.d.map { " (\($0))" } ?? "")) }
        }
        .sheet(item: $help) { k in
            SettingHelpSheet(title: k.k, text: k.text, facts: [SettingHelp.Fact(label: L("set.help.now"), value: state(k), now: true)], reset: nil)
        }
        .overlay(alignment: .bottom) { SettingsTips.Toast() }
    }

    @ViewBuilder private func row(_ k: SettingsCatalog.DevKey) -> some View {
        let title = Text(k.k).font(.callout.monospaced())
            .foregroundStyle(Self.rowID(k.k) == highlight ? AnyShapeStyle(AccentPalette.settingsColor) : AnyShapeStyle(HierarchicalShapeStyle.primary))
        Group {
            if k.n {
                Button {
                    typed = values[k.k] ?? ""
                    editing = k
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        Text(state(k)).font(.app(12)).foregroundStyle(.secondary)
                    }
                }
            } else {
                Toggle(isOn: Binding(get: {
                    if let cur = values[k.k] { return (Double(cur) ?? 0) != 0 }
                    return k.d.map { $0 != "0" } ?? false
                }, set: { on in
                    ScamDevFile.set(k.k, on ? "1" : "0")
                    refresh()
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        Text(state(k)).font(.app(12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .contextMenu {
            Button { help = k } label: { Label(L("set.help.open"), systemImage: "text.alignleft") }
            if values[k.k] != nil {
                Button {
                    ScamDevFile.set(k.k, nil)
                    refresh()
                } label: { Label(L("dev.remove_line"), systemImage: "arrow.counterclockwise") }
            }
        } preview: {
            HelpCard(title: k.k, text: k.text, facts: [SettingHelp.Fact(label: L("set.help.now"), value: state(k), now: true)], lineLimit: 14)
                .frame(width: 340)
        }
    }
}

extension SettingsCatalog.DevKey: Identifiable {
    var id: String { k }
}
