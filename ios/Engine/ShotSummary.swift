import Foundation
import QuartzCore
import os

/// SHOT SUMMARY (Android's ScamProcessor line, P646): one line per SHDR shot with the stages the Android tables compare -
///   hold      press -> the burst captured (the brackets included)
///   prep      BurstProcessor up to the merge (levels, the NCH's end, facts, lab files, faces)
///   merge     the GPU merge; «Быстрый»: front / ctx (context + objects) / upload / submit / readback from HYBRID FAST MERGE ms;
///             «Качество»: align / merge from HYBRID STAGES ms
///   gap       the merge's end -> the post pipeline (worker output, context, Parameters, the merged DNG)
///   post      the post pipeline and its tail; nodes: each node's wall ms (the slowest first)
///   save      encode + the library's write; cold: compile ms the shot spent itself; total: press -> saved
enum ShotSummary {
    /// The number after `key=` / `key ` in `text`
    private static func number(_ text: String, _ key: String) -> Int? {
        guard let r = text.range(of: key) else { return nil }
        let rest = text[r.upperBound...]
        guard let m = rest.range(of: "^-?[0-9]+(\\.[0-9]+)?", options: .regularExpression) else { return nil }
        return Double(rest[m]).map { Int($0.rounded()) }
    }

    static func line(log: [String], holdMs: Int, libraryMs: Int, totalMs: Int, meters: String = "") -> String {
        let stages = log.first { $0.contains("SHOT STAGES ms:") } ?? ""
        let swift = log.first { $0.hasPrefix("SHOT SWIFT ms:") } ?? ""
        let fast = log.first { $0.contains("HYBRID FAST MERGE ms:") }
        let quality = log.first { $0.contains("HYBRID STAGES ms:") && !$0.contains("(fast merge)") }
        func v(_ text: String, _ key: String) -> String { number(text, key).map(String.init) ?? "-1" }
        var merge = "merge=" + v(stages, "merge=")
        if let fast {
            let ctx = (number(fast, "context ") ?? 0) + (number(fast, "objects ") ?? 0)
            merge += " (front=\(v(fast, "front ")) ctx=\(ctx) upload=\(v(fast, "uploads ")) submit=\(v(fast, "submit ")) readback=\(v(fast, "readback ")))"
        } else if let quality {
            merge += " (align=\(v(quality, "align=")) merge=\(v(quality, " merge=")))"
        }
        let encode = number(swift, "encode=") ?? 0
        let nodes = stages.range(of: "nodes=").map { String(stages[$0.upperBound...]) } ?? ""
        return "SHOT SUMMARY ms: hold=\(holdMs) prep=\(v(swift, "prep=")) \(merge) gap=\(v(stages, "gap=")) post=\(v(stages, "post="))"
            + " save=\(encode + libraryMs) (encode=\(encode) library=\(libraryMs)) total=\(totalMs) cold=\(v(stages, "cold="))"
            + (meters.isEmpty ? "" : " " + meters) + (nodes.isEmpty ? "" : " | post nodes: " + nodes)
    }
}

/// SHOT SUMMARY's device side: the memory this process may still take (os_proc_available_memory) and the thermal state at the
/// press and when the processing ends, the process's footprint at the end, and the interface's frame rate while the shot was
/// processed (a CADisplayLink: the main thread's hitches; the system preview layer itself is drawn by the render server) with
/// the Metal viewfinder's draws when it draws (a look, the histogram, tracking).
final class ShotMeters: NSObject, @unchecked Sendable {
    let pressAvailableMB = Int(os_proc_available_memory() / 1_048_576)
    let pressThermal = ProcessInfo.processInfo.thermalState
    private var link: CADisplayLink?
    private var ticks = 0, longestGap: CFTimeInterval = 0, last: CFTimeInterval = 0, started: CFTimeInterval = 0
    private var vfStart = 0
    private(set) var processingLine = ""

    static func name(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }

    /// The processing starts (main thread): the frame-rate count
    @MainActor func startProcessing() {
        vfStart = ViewfinderRenderer.shared.drawCount
        started = CACurrentMediaTime()
        last = started
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        ticks += 1
        longestGap = max(longestGap, link.timestamp - last)
        last = link.timestamp
    }

    /// The processing ends (main thread): the fields of SHOT SUMMARY's device part
    @MainActor func endProcessing() {
        guard link != nil else { return } // once (a failed shot ends it from process()'s exit too)
        link?.invalidate()
        link = nil
        let seconds = max(CACurrentMediaTime() - started, 0.001)
        let vf = ViewfinderRenderer.shared.drawCount &- vfStart
        processingLine = String(format: "mem_avail=%d->%d MB footprint_end=%@ thermal=%@->%@ ui_fps=%.0f ui_gap=%.0f ms vf_metal_fps=%.0f",
                                pressAvailableMB, Int(os_proc_available_memory() / 1_048_576), memoryFootprint(),
                                Self.name(pressThermal), Self.name(ProcessInfo.processInfo.thermalState), Double(ticks) / seconds,
                                longestGap * 1000, Double(vf) / seconds)
    }
}
