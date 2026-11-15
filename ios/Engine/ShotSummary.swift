import Foundation

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

    static func line(log: [String], holdMs: Int, libraryMs: Int, totalMs: Int) -> String {
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
            + (nodes.isEmpty ? "" : " | post nodes: " + nodes)
    }
}
