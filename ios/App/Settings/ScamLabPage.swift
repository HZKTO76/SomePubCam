import SwiftUI

/// SCAM Lab on the iPhone (Android: ScamLabFragment, the merge worker on kept bursts): the last SHDR series (Documents/Bursts) merged
/// again on the device with the settings as they are now - change a setting, run, compare in the gallery. The photo goes to the
/// library as a shot does.
struct ScamLabPage: View {
    static let screen = "scam_lab_screen"
    @State private var running = false
    @State private var status: String?
    @State private var lines: [String] = []

    private var info: String {
        let lab = (try? Data(contentsOf: BurstProcessor.lastBurstURL.appendingPathExtension("lab")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard let lab, FileManager.default.fileExists(atPath: BurstProcessor.lastBurstURL.path) else {
            return Lang.t("Сохранённой серии нет: снимите кадр SHDR.", "No kept series: take an SHDR shot.")
        }
        let time = (lab["time"] as? Double).map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "?"
        return Lang.t("Последняя серия: \(lab["frames"] ?? "?") кадров \(lab["width"] ?? "?")×\(lab["height"] ?? "?"), \(time)",
                      "Last series: \(lab["frames"] ?? "?") frames \(lab["width"] ?? "?")×\(lab["height"] ?? "?"), \(time)")
    }

    var body: some View {
        List {
            Section {
                Text(info).font(.app(14))
                Button {
                    run()
                } label: {
                    HStack {
                        Text(running ? Lang.t("Склейка…", "Merging…") : Lang.t("Склеить заново с текущими настройками", "Merge again with the current settings"))
                        if running { Spacer(); ProgressView() }
                    }
                }
                .disabled(running)
                if let status { Text(status).font(.app(13)).foregroundStyle(.secondary) }
            } footer: {
                Text(Lang.t("Лаборатория склеивает последнюю серию SHDR заново на телефоне: измените настройки склейки или обработки, запустите и сравните снимки в галерее. Хранится одна последняя серия.",
                            "The lab merges the last SHDR series again on the phone: change a merge or processing setting, run it and compare the photos in the gallery. One last series is kept."))
            }
            if !lines.isEmpty {
                Section(Lang.t("Журнал", "Log")) {
                    ForEach(Array(lines.suffix(40).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(Lang.t("Лаборатория", "Lab"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run() {
        running = true
        status = nil
        Task.detached(priority: .userInitiated) {
            let outcome: Result<BurstProcessor.Result, Error> = Result { try BurstProcessor.relab() }
            var text: String
            var log: [String] = []
            switch outcome {
            case .success(let r):
                log = r.log
                r.log.forEach { SessionLog.i("Lab", $0) }
                do {
                    try await MediaLibrary().save(CapturedPhoto(processed: r.heic, processedUTI: r.uti, rawFile: nil, report: []))
                    text = Lang.t("Готово: снимок сохранён в галерею", "Done: the photo is in the gallery")
                } catch {
                    text = error.localizedDescription
                }
            case .failure(let e):
                text = e.localizedDescription
                SessionLog.e("Lab", text)
            }
            let shown = log
            await MainActor.run {
                running = false
                status = text
                lines = shown
            }
        }
    }
}
