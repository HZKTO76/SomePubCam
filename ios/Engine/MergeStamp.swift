import CoreGraphics
import CoreText
import Foundation

/// MergeStamp (processing/MergeStamp.java): «Отметка ES / L на фото» - two lines in the photo's top right corner, «ES ✓3» / «ES ✗
/// code» for the ultrashort frames and «L ✓3» / «L ✓1/3 code» / «L ✗ code» for the long ones, from the shot's plan (its
/// description), the frames the burst carried and the merge's report; a third «ETTR +1.0» / «ETTR ✗ code» with ETTR on.
enum MergeStamp {
    static let key = "pref_debug_merge_stamp"

    static var on: Bool { PostSettings.bool(key, false) }

    static func lines(plan: String?, esCaptured: Int, esSent: Int, longCaptured: Int, longSent: Int, report: String?, ettr: String?) -> [String] {
        var out = [esLine(plan, esCaptured, esSent, report), longLine(plan, longCaptured, longSent, report)]
        if let ettr { out.append(ettr) }
        return out
    }

    static func esLine(_ plan: String?, _ captured: Int, _ sent: Int, _ report: String?) -> String {
        guard sent >= 0, let report else { return "ES ✗ nomrg" }
        if sent == 0 { return "ES ✗ " + (captured > 0 ? "hal" : notAsked(plan, ultrashort: true)) }
        if report.contains("HYBRID BENTO: applied") { return "ES ✓\(sent)" }
        if let r = report.range(of: "HYBRID FAST MERGE HIGHLIGHT: accumulated validity of ") {
            return "ES ✓\(Int(number(String(report[r.lowerBound...]), "accumulated validity of ", Double(sent)).rounded()))"
        }
        if report.contains("HYBRID FAST MERGE HIGHLIGHT: every short frame rejected") { return "ES ✗ align" }
        if report.contains("-> highlight path off") { return "ES ✗ nclip" }
        if report.contains("HYBRID BENTO: disabled") { return "ES ✗ tune" }
        guard let at = report.range(of: "HYBRID BENTO: not applied (") else { return "ES ✗ align" }
        let why = String(report[at.upperBound...])
        if why.hasPrefix("not enough clipping") { return "ES ✗ nclip" }
        if why.hasPrefix("large inpainting hole") { return "ES ✗ hole" }
        if why.hasPrefix("high clipping ratio") { return "ES ✗ usclip" }
        if why.hasPrefix("ultrashort frame is not the shortest") { return "ES ✗ nshort" }
        if why.hasPrefix("motion: ") { return "ES ✗ mv\(Int(number(why, "motion: ", 0).rounded()))%" }
        return "ES ✗ ?"
    }

    static func longLine(_ plan: String?, _ captured: Int, _ sent: Int, _ report: String?) -> String {
        guard sent >= 0, let report else { return "L ✗ nomrg" }
        if sent == 0 { return "L ✗ " + (captured > 0 ? "hal" : notAsked(plan, ultrashort: false)) }
        guard let stages = report.range(of: "HYBRID STAGES ms:") else { return "L ✗ ?" }
        let dropped = max(0, min(sent, Int(number(String(report[stages.lowerBound...]), "droppedBracketed=", 0).rounded())))
        if dropped == 0 { return "L ✓\(sent)" }
        let why: String
        if report.contains("HYBRID SHASTA: TET ratio") {
            why = "tet"
        } else if report.range(of: "HYBRID SHASTA motion[^\\n]*: dropped\\)", options: .regularExpression) != nil {
            why = "mv"
        } else {
            let re = try? NSRegularExpression(pattern: "HYBRID SHASTA sharpness frame=\\d+[^\\n]*\\(([0-9.]+) % of base\\)")
            let ns = report as NSString
            let matches = re?.matches(in: report, range: NSRange(location: 0, length: ns.length)) ?? []
            let lowest = matches.compactMap { Double(ns.substring(with: $0.range(at: 1))) }.min() ?? .greatestFiniteMagnitude
            why = matches.count < sent ? "align" : "sh\(Int(lowest.rounded()))%"
        }
        return dropped >= sent ? "L ✗ " + why : "L ✓\(sent - dropped)/\(sent) " + why
    }

    static func notAsked(_ plan: String?, ultrashort: Bool) -> String {
        guard let plan else { return "?" }
        if plan.contains("ring frames only") { return "ring" }
        if ultrashort {
            if plan.contains(" bento off") { return "off" }
            if plan.contains(" us skipped (sensor floor)") { return "floor" }
            if plan.contains(" no clipping (") { return String(format: "nc %.2f%%", 100 * number(plan, " no clipping (", 0)) }
            return plan.contains("EXTRA_SHORT") ? "lost" : "?"
        }
        if plan.contains(" shasta off") { return "off" }
        if plan.contains(" brackets skipped (ratio ") { return String(format: "r%.1f", number(plan, " brackets skipped (ratio ", 0)) }
        return plan.contains("LONG") ? "lost" : "?"
    }

    /// The number right after `key` in `text`, `fallback` without one
    static func number(_ text: String, _ key: String, _ fallback: Double) -> Double {
        guard let at = text.range(of: key) else { return fallback }
        let rest = text[at.upperBound...]
        guard let m = rest.range(of: "^-?[0-9]+(\\.[0-9]+)?", options: .regularExpression) else { return fallback }
        return Double(rest[m]) ?? fallback
    }

    /// The ETTR line of the burst's report (BayerBurst.ettrExposure: "ETTR: tail …, boost w EV wanted, e EV: …"); nil: ETTR off
    static func ettrLine(_ report: [String]) -> String? {
        guard EttrMeter.enabled else { return nil }
        guard let line = report.first(where: { $0.hasPrefix("ETTR:") }) else { return "ETTR ✗ man" }
        if line.contains("refused") { return "ETTR ✗ ?" }
        let wanted = number(line, "boost ", 0), ev = number(line, "EV wanted, ", 0)
        if ev >= EttrMeter.minStep { return String(format: "ETTR +%.1f", ev) }
        if wanted <= 0 { return number(line, "tail ", 0) >= 0.995 ? "ETTR ✗ clip" : "ETTR ✗ hi" }
        return "ETTR ✗ room"
    }

    /// The lines drawn into the top right corner of an RGBA8 photo: white monospace on a dark plate, ~3.5 % of the short side high
    static func draw(_ rgba: inout Data, width: Int, height: Int, lines: [String]) {
        guard !lines.isEmpty, width > 0, height > 0, rgba.count >= width * height * 4 else { return }
        let size = max(16, CGFloat(min(width, height)) * 0.035)
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)]
        let ctLines = lines.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes)) }
        let widths = ctLines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        let pad = size * 0.45, step = size * 1.25, margin = size * 0.6
        let w = (widths.max() ?? 0)
        let plateH = 2 * pad + step * CGFloat(lines.count) - (step - size)
        rgba.withUnsafeMutableBytes { p in
            guard let base = p.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // CoreGraphics' origin is the bottom left: the top right corner's plate in its coordinates
            let plate = CGRect(x: CGFloat(width) - margin - w - 2 * pad, y: CGFloat(height) - margin - plateH, width: w + 2 * pad, height: plateH)
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0xA0 / 255))
            ctx.addPath(CGPath(roundedRect: plate, cornerWidth: pad, cornerHeight: pad, transform: nil))
            ctx.fillPath()
            for (i, line) in ctLines.enumerated() {
                let baselineFromTop = pad + size * 0.82 + CGFloat(i) * step
                ctx.textPosition = CGPoint(x: plate.maxX - pad - widths[i], y: plate.maxY - baselineFromTop)
                CTLineDraw(line, ctx)
            }
        }
    }
}
