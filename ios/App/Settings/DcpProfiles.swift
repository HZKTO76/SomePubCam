import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

/// DcpProfiles (processing/color/DcpProfiles.java): private, content-addressed imports (Application Support/dcp/<sha256>.dcp)
/// with the import's name; the selected file in pref_dcp_profile_key. The pipeline reads it through PostSettings ("ios_dcp_path")
/// and ShotColour's DCP route.
enum DcpProfiles {
    static let key = "pref_dcp_profile_key"
    private static let namesKey = "dcp_import_names"
    // stored with the import's name (Android's format: Russian parts), shown in the UI language by label()
    private static let defaultName = "Профиль DCP", matricesOnly = " · только матрицы"

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("dcp")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func label(_ stored: String) -> String {
        let only = stored.hasSuffix(matricesOnly)
        var name = only ? String(stored.dropLast(matricesOnly.count)) : stored
        if name == defaultName { name = Lang.t("Профиль DCP", "DCP profile") }
        return only ? name + Lang.t(" · только матрицы", " · matrices only") : name
    }

    /// The camera matrix first (""), then the imports by their file names
    static func list() -> [(id: String, label: String)] {
        var result = [(id: "", label: Lang.t("Камерная матрица", "Camera matrix"))]
        let names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files.sorted() where f.range(of: "^[0-9a-f]{64}\\.dcp$", options: .regularExpression) != nil {
            result.append((id: f, label: label(names[f] ?? f)))
        }
        return result
    }

    static func path(_ id: String) -> URL? {
        guard id.range(of: "^[0-9a-f]{64}\\.dcp$", options: .regularExpression) != nil else { return nil }
        let url = dir.appendingPathComponent(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func label(of id: String) -> String { list().first { $0.id == id }?.label ?? Lang.t("Камерная матрица", "Camera matrix") }

    /// Validates (DcpProfile.parse), stores under its SHA-256 and returns the id
    static func importFile(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 16 * 1024 * 1024 { throw NSError(domain: "DCP", code: 1, userInfo: [NSLocalizedDescriptionKey: Lang.t("DCP больше 16 МБ", "DCP larger than 16 MB")]) }
        let data = try Data(contentsOf: url)
        // the bridge's (NSNumber *)…error: comes in as a throwing call
        let looks: NSNumber
        do { looks = try SCAMDcp.checkProfile(data) } catch {
            throw NSError(domain: "DCP", code: 2, userInfo: [NSLocalizedDescriptionKey: Lang.t("Неверный DCP: ", "Invalid DCP: ")
                                                              + error.localizedDescription])
        }
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".dcp"
        let target = dir.appendingPathComponent(id)
        if !FileManager.default.fileExists(atPath: target.path) { try data.write(to: target, options: .atomic) }
        var names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        names[id] = url.lastPathComponent + (looks.boolValue ? matricesOnly : "")
        UserDefaults.standard.set(names, forKey: namesKey)
        return id
    }
}

/// DcpSettingsFragment: the profiles with the chosen one ticked, the import.
struct DcpPage: View {
    private var store: SettingsStore { SettingsStore.shared }
    @State private var importing = false
    @State private var picking = false
    @State private var failure: String?
    @State private var refresh = 0

    var body: some View {
        let selected = store.string(DcpProfiles.key, "")
        List {
            Section {
                ForEach(DcpProfiles.list(), id: \.id) { item in
                    Button { store.set(DcpProfiles.key, item.id) } label: {
                        HStack {
                            Text(item.label).foregroundStyle(.primary)
                            Spacer()
                            if item.id == selected { Image(systemName: "checkmark").foregroundStyle(AccentPalette.settingsColor) }
                        }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Lang.t("Выбирайте профиль для этого сенсора. Используются ColorMatrix, ForwardMatrix и источники освещения. Таблицы оттенков и тональные кривые DCP не применяются.",
                                "Pick a profile for this sensor. ColorMatrix, ForwardMatrix and the illuminants are used. DCP hue tables and tone curves are not applied."))
                    Text(Lang.t("Выбор сохраняется в профиле модуля и доступен для копирования между модулями.",
                                "The choice is saved in the module profile and can be copied between modules."))
                }
            }
            Section {
                Button(importing ? Lang.t("Импорт…", "Importing…") : Lang.t("Импортировать DCP", "Import DCP")) { picking = true }
                    .disabled(importing)
            }
        }
        .id(refresh)
        .navigationTitle(Lang.t("Цветовой профиль", "Colour profile"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data, .item]) { result in
            guard case .success(let url) = result else { return }
            importing = true
            Task.detached {
                let outcome: Result<String, Error> = Result { try DcpProfiles.importFile(url) }
                await MainActor.run {
                    importing = false
                    switch outcome {
                    case .success(let id): store.set(DcpProfiles.key, id); refresh += 1
                    case .failure(let e): failure = e.localizedDescription
                    }
                }
            }
        }
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}
