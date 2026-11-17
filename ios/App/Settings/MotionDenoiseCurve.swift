import SwiftUI
import UIKit

/// MotionDenoiseCurvePreference (ui/settings/custompreferences/MotionDenoiseCurvePreference.java): the preview of «Шумоподавление
/// движения»'s SNR curve that the seven sliders on the same page edit - it stores nothing (the sliders store
/// pref_scam_hybrid_fast_motion_denoise_<snr>, 0..100, PreferenceKeys.fastMotionDenoisePercent reads them). The SNR points sit at
/// their normalised log2 positions (as the merge interpolates them), the strength 0..100 % upwards.
enum MotionDenoiseCurve {
    /// PreferenceKeys.FAST_MOTION_DENOISE_SNR / _DEFAULT
    static let snr = [2, 3, 4, 8, 16, 32, 64]
    static let defaults: [Double] = [65, 65, 65, 45, 22, 8, 0]
    static let prefix = "pref_scam_hybrid_fast_motion_denoise_"

    /// PreferenceKeys.fastMotionDenoisePercent: the stored value clamped to 0..100, the default when unset or not a number
    static func percent(_ values: any SettingsValues, _ point: Int) -> Double {
        let fallback = defaults[point]
        let v = SliderGrid.number(values.string(prefix + String(snr[point]), ""), fallback: fallback)
        return v.isFinite ? Swift.max(0, Swift.min(100, v)) : fallback
    }

    /// Math.log(snr / first) / Math.log(last / first)
    static func position(_ point: Int) -> Double {
        let first = Double(snr[0])
        return log(Double(snr[point]) / first) / log(Double(snr[snr.count - 1]) / first)
    }
}

struct MotionDenoiseCurveView: View {
    let store: any SettingsValues
    let enabled: Bool

    var body: some View {
        // read here, so the graph follows the sliders (SettingsStore is observed)
        let strengths = (0..<MotionDenoiseCurve.snr.count).map { MotionDenoiseCurve.percent(store, $0) * 0.01 }
        Canvas { ctx, size in draw(ctx, size: size, strengths: strengths) }
            .frame(height: 144)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemGroupedBackground)))
            .opacity(enabled ? 1 : 0.45)
            .accessibilityHidden(true)
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, strengths: [Double]) {
        let accent = Color.accentColor
        let hairline = Color.secondary.opacity(0.35)
        func label(_ s: String) -> GraphicsContext.ResolvedText { ctx.resolve(Text(s).font(.app(11)).foregroundStyle(.secondary)) }
        let full = label("100%"), none = label("0%")
        let left = 16 + full.measure(in: size).width
        let right = size.width - 18
        let top: CGFloat = 16
        let bottom = size.height - 38
        guard left < right && top < bottom else { return }
        ctx.draw(full, at: CGPoint(x: left - 6, y: top), anchor: .trailing)
        ctx.draw(none, at: CGPoint(x: left - 6, y: bottom), anchor: .trailing)
        var grid = Path()
        for i in 0...4 {
            let y = top + (bottom - top) * CGFloat(i) / 4
            grid.move(to: CGPoint(x: left, y: y))
            grid.addLine(to: CGPoint(x: right, y: y))
        }
        let width = right - left
        let gap: CGFloat = 3
        var rowEnd = -CGFloat.infinity, lowerRowEnd = -CGFloat.infinity
        var curve = Path()
        var dots: [CGPoint] = []
        for i in 0..<strengths.count {
            let x = left + CGFloat(MotionDenoiseCurve.position(i)) * width
            let y = bottom - (bottom - top) * CGFloat(strengths[i])
            grid.move(to: CGPoint(x: x, y: top))
            grid.addLine(to: CGPoint(x: x, y: bottom))
            // the SNR under its line; one that would touch the previous label goes to a second row
            let text = label(String(MotionDenoiseCurve.snr[i]))
            let half = text.measure(in: size).width / 2
            if x - half >= rowEnd + gap {
                ctx.draw(text, at: CGPoint(x: x, y: bottom + 12), anchor: .center)
                rowEnd = x + half
            } else if x - half >= lowerRowEnd + gap {
                ctx.draw(text, at: CGPoint(x: x, y: bottom + 26), anchor: .center)
                lowerRowEnd = x + half
            }
            if i == 0 { curve.move(to: CGPoint(x: x, y: y)) } else { curve.addLine(to: CGPoint(x: x, y: y)) }
            dots.append(CGPoint(x: x, y: y))
        }
        ctx.stroke(grid, with: .color(hairline), lineWidth: 1)
        ctx.stroke(curve, with: .color(accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        for c in dots {
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(accent))
        }
    }
}
