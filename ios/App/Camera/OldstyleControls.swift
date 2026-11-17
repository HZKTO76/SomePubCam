import SwiftUI
import UIKit

/// OldstyleStyle (P630c): the mode's style - the palette's «Тон» / «Цвет» and twelve advanced parameters, each -100..100 (0 none)
/// or, for the discrete ones (aura, halo, grain), 0..3 (off, low, medium, high); stored as pref_oldstyle_style_<key>, which the
/// photo's OldstyleStyleNode reads at the press (Engine/post/oldstyle/OldstyleAe.hpp style()) and the viewfinder draws live
/// (viewfinderUniforms -> ViewfinderRenderer.setOldstyle -> Viewfinder.metal oldstyleStyle).
enum OldstyleParam: String, CaseIterable {
    case tone, color, exposure, aura, halo, grain, warmth, hue, highlights, shadows, warmBoost = "warm_boost", coolBoost = "cool_boost",
         sharpness, vignette

    static let advanced: [OldstyleParam] = [.exposure, .aura, .halo, .grain, .warmth, .hue, .highlights, .shadows, .warmBoost, .coolBoost,
                                            .sharpness, .vignette]
    /// OldstyleStyle.uniforms' order: (tone, colour, exposure, warmth), (hue, highlights, shadows, warm boost),
    /// (cool boost, sharpness, vignette, aura), (halo, grain, 0, 0)
    static let uniformOrder: [OldstyleParam] = [.tone, .color, .exposure, .warmth, .hue, .highlights, .shadows, .warmBoost, .coolBoost,
                                                .sharpness, .vignette, .aura, .halo, .grain]
    var discrete: Bool { self == .aura || self == .halo || self == .grain }
    var minValue: Int { discrete ? 0 : -100 }
    var maxValue: Int { discrete ? 3 : 100 }
    var key: String { "pref_oldstyle_style_" + rawValue }

    func clamp(_ v: Int) -> Int { max(minValue, min(maxValue, v)) }

    /// OldstyleStyle.Param.unit: the shader's value, -1..1, a discrete step 0, 1/3, 2/3, 1
    func unit(_ v: Int) -> Float { discrete ? Float(clamp(v)) / 3 : Float(clamp(v)) / 100 }

    /// The stored value in a settings dictionary (SettingsStore's on the main thread, UserDefaults' on the viewfinder's queue)
    func stored(_ prefs: [String: Any]) -> Int {
        let text: String
        if let s = prefs[key] as? String { text = s } else if let n = prefs[key] as? NSNumber { text = n.stringValue } else { text = "0" }
        let d = LutTrayModel.number(text, 0)
        guard d.isFinite else { return 0 }
        return clamp(Int(max(-1000, min(1000, d)).rounded()))
    }

    var value: Int { stored(SettingsStore.shared.values) }

    func set(_ v: Int) { SettingsStore.shared.set(key, String(clamp(v))) }

    var name: String { L("os.p." + rawValue) }
    var help: String { L("os.h." + rawValue) }

    var icon: String {
        switch self {
        case .exposure: return "cv_ev"
        case .aura: return "cv_os_aura"
        case .halo: return "cv_os_halo"
        case .grain: return "cv_os_grain"
        case .warmth: return "cv_thermo"
        case .hue: return "cv_os_hue"
        case .highlights: return "cv_sun"
        case .shadows: return "cv_os_contrast"
        case .warmBoost: return "cv_os_warm"
        case .coolBoost: return "cv_os_cool"
        case .sharpness: return "cv_sharp"
        default: return "cv_os_vignette"
        }
    }

    /// A value's text (OldstyleControls.label): a discrete step's word («Выкл.», «Низк.», «Средн.», «Высок.»), else the signed number
    func text(_ v: Int) -> String {
        if discrete { return L(["os.step0", "os.step1", "os.step2", "os.step3"][max(0, min(3, v))]) }
        return v > 0 ? "+\(v)" : "\(v)"
    }

    static var neutral: Bool { allCases.allSatisfy { $0.value == 0 } }

    /// MainRenderer.setOldstyleAdjust(st.neutral() ? null : st.uniforms()) while the mode is on: the 16 floats of uOs0..uOs3, nil
    /// outside «Oldstyle» or with every parameter at 0 (the viewfinder then draws exactly as without the style). The iPhone has no
    /// live ScamMaster tone under the style (Android's OldstyleLive), so the style's exposure stays in (styleAfterTone, toneLive off).
    static func viewfinderUniforms(_ prefs: [String: Any]) -> [Float]? {
        guard (prefs["pref_oldstyle_mode"] as? NSNumber)?.boolValue ?? false else { return nil }
        var u = [Float](repeating: 0, count: 16)
        var any = false
        for (i, p) in uniformOrder.enumerated() {
            let v = p.stored(prefs)
            if v != 0 { any = true }
            u[i] = p.unit(v)
        }
        return any ? u : nil
    }
}

/// OldstyleControls (P630 / P630c / P630g), Android's ui/camera/OldstyleControls 1:1. The «Про» manual row stays open in this mode
/// (and «Про» steps aside); a round 44 pt style button 8 pt above the row's right end (4 pt in) opens the style panel, which takes the
/// row's place (its bottom on the row's bottom; the row is hidden while it is open): the tab's content (150 pt) over a 10 pt gap and
/// the header (back, the segments «Палитра | Расширенные», reset - shown once anything is changed - and the ⋮ menu). «Палитра»: a 2D
/// pad (left a cool grey, right a warm salmon colour = «Цвет»; up lighter, down darker = «Тон»; a dot grid that grows under the
/// finger, a dotted cross at the point at rest) and the HUD line «База: Natural · Тон: 81 · Цвет: -100» 14 pt under the preview's
/// top. «Расширенные»: the chosen parameter's value over a centred tick ruler (a tick of haptics per step, a double tap back to 0)
/// and the row of the twelve parameters' chips. Reset asks first. Every change shows live in the viewfinder (touch()) and the photo
/// takes the style at the press. The layout follows the container it is given (the stage's column), never the device.
@MainActor
@Observable
final class OldstyleModel {
    static let shared = OldstyleModel()
    var open = false
    var tab = 0
    var chosen = OldstyleParam.exposure
    private(set) var revision = 0

    /// OldstyleControls.bind: the views again, and the viewfinder's style (MainRenderer.setOldstyleAdjust)
    func touch() {
        revision += 1
        pushViewfinder()
    }

    /// The style to the live viewfinder now (nil: outside the mode or neutral); the renderer also reads it twice a second
    func pushViewfinder() {
        ViewfinderRenderer.shared.setOldstyle(OldstyleParam.viewfinderUniforms(SettingsStore.shared.values))
    }

    /// resetNow: everything to 0, «Стиль сброшен»
    func reset() {
        for p in OldstyleParam.allCases { p.set(0) }
        touch()
        MessageCenter.shared.info(L("os.reset_done"))
    }
}

/// The controls' sizes and colours (OldstyleControls / UiTokens / ConceptStyle; 1 dp = 1 pt)
private enum OsLook {
    /// UiTokens.shape's stroke: 1 dp
    static let stroke: CGFloat = 1
    /// The unselected chip's fill: 0xD91C1C1E
    static let chipFill = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255).opacity(0xD9 / 255)
    /// ConceptStyle.dark(accent): the accent at 29 %
    static var accentDark: Color {
        let ui = UIColor(CameraStyle.accent)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return CameraStyle.accentDark }
        return Color(red: Double(r) * 0.29, green: Double(g) * 0.29, blue: Double(b) * 0.29)
    }
    /// Motion.ENTER (spring .42 / .7) and EASE_OUT
    static let enter = Animation.spring(response: 0.42, dampingFraction: 0.7)
    static let closePanel = Animation.easeOut(duration: 0.2)
}

/// The round style button (44 pt, a 22 pt glyph; the accent on its glyph and edge once the style is not neutral). A tap opens the
/// panel, a long press says what it is.
struct OldstyleButton: View {
    var shown: Bool
    @State private var pressed = false
    private var model: OldstyleModel { OldstyleModel.shared }

    var body: some View {
        let _ = model.revision
        let neutral = OldstyleParam.neutral
        Image("cv_os_style").renderingMode(.template).resizable().frame(width: 22, height: 22)
            .foregroundStyle(neutral ? CameraStyle.text : CameraStyle.accent)
            .frame(width: 44, height: 44)
            .background(CameraStyle.control, in: Circle())
            .overlay(Circle().strokeBorder(neutral ? CameraStyle.hairline : CameraStyle.accent, lineWidth: OsLook.stroke))
            .contentShape(Circle())
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(pressed ? .easeOut(duration: 0.11) : .spring(response: 0.3, dampingFraction: 0.6), value: pressed)
            .onTapGesture { withAnimation(OsLook.enter) { model.open = true } }
            .onLongPressGesture(minimumDuration: 0.5, perform: { MessageCenter.shared.info(L("os.button_help")) },
                                onPressingChanged: { pressed = $0 })
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .animation(shown ? .easeOut(duration: 0.24) : .easeOut(duration: 0.18), value: shown)
            .accessibilityElement()
            .accessibilityLabel(L("os.button"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { withAnimation(OsLook.enter) { model.open = true } }
    }
}

/// The style panel in the manual row's place: the tab's content over the header. `maxHeight`: the room the stage gives it (the pad
/// keeps Android's 150 pt wherever that fits under the HUD, which is everywhere but a very short window).
struct OldstylePanel: View {
    var shown: Bool
    var maxHeight: CGFloat
    @State private var askReset = false
    @State private var risen = true
    private var model: OldstyleModel { OldstyleModel.shared }

    /// The content's height: 150 pt, less only when the stage is too short for it with the header (50) and the HUD (44) above
    private var contentHeight: CGFloat { min(150, max(96, maxHeight - 50 - 44)) }

    var body: some View {
        let _ = model.revision
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                PalettePad()
                    .frame(height: contentHeight)
                    .opacity(model.tab == 0 ? 1 : 0)
                    .offset(x: model.tab == 0 ? 0 : -24)
                    .allowsHitTesting(model.tab == 0)
                    .accessibilityHidden(model.tab != 0)
                advanced
                    .opacity(model.tab == 1 ? 1 : 0)
                    .offset(x: model.tab == 1 ? 0 : 24)
                    .allowsHitTesting(model.tab == 1)
                    .accessibilityHidden(model.tab != 1)
            }
            .frame(height: contentHeight, alignment: .bottom)
            header.padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(shown ? .easeOut(duration: 0.24) : .easeOut(duration: 0.18), value: shown)
        .alert(L("os.reset_title"), isPresented: $askReset) {
            Button("OK") { model.reset() }
            Button(L("os.cancel"), role: .cancel) {}
        } message: { Text(L("os.reset_message")) }
    }

    // MARK: the header

    private var header: some View {
        let neutral = OldstyleParam.neutral
        return HStack(spacing: 0) {
            round("cv_chev_left", L("os.close")) { withAnimation(OsLook.closePanel) { model.open = false } }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { i in
                    let on = i == model.tab
                    Text(i == 0 ? L("os.palette") : L("os.advanced")).font(.app(13, 600)).lineLimit(1)
                        .foregroundStyle(on ? CameraStyle.accent : CameraStyle.text)
                        .padding(.horizontal, 14).frame(height: 32)
                        .background(on ? CameraStyle.chosen : Color.clear, in: RoundedRectangle(cornerRadius: 16))
                        .contentShape(Rectangle())
                        .onTapGesture { setTab(i) }
                        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(3)
            .background(CameraStyle.control, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(CameraStyle.hairline, lineWidth: OsLook.stroke))
            Spacer(minLength: 0)
            // INVISIBLE, not GONE, while neutral: the segments keep their place
            round("cs_page_reset", L("os.reset_style")) { askReset = true }
                .opacity(neutral ? 0 : 1)
                .allowsHitTesting(!neutral)
                .accessibilityHidden(neutral)
            menu.padding(.leading, 4)
        }
    }

    /// The tab: the content cross-fading (out 160 ms, in 240 ms, 24 pt aside), the chips rising one after another into «Расширенные»
    private func setTab(_ t: Int) {
        guard t != model.tab else { return }
        if t == 1 { risen = false }
        withAnimation(.easeOut(duration: 0.24)) { model.tab = t }
        if t == 1 { DispatchQueue.main.async { risen = true } }
    }

    private func roundLabel(_ icon: String) -> some View {
        Image(icon).renderingMode(.template).resizable().frame(width: 20, height: 20).foregroundStyle(CameraStyle.text)
            .frame(width: 40, height: 40)
            .background(CameraStyle.control, in: Circle())
            .overlay(Circle().strokeBorder(CameraStyle.hairline, lineWidth: OsLook.stroke))
            .contentShape(Circle())
    }

    private func round(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { roundLabel(icon) }
            .buttonStyle(PressScale(scale: 0.94))
            .accessibilityLabel(label)
    }

    /// The ⋮ menu (Android's PopupMenu at the button): reset, the tone's version V1 / V2, help
    private var menu: some View {
        let v2 = SettingsStore.shared.string("pref_scam_hybrid_oldstyle_version", "v1").trimmingCharacters(in: .whitespaces) == "v2"
        return Menu {
            Button(L("os.reset_style")) { askReset = true }
            Button(L("os.tone") + "ScamMaster " + (v2 ? "V2 → V1" : "V1 → V2")) {
                SettingsStore.shared.set("pref_scam_hybrid_oldstyle_version", v2 ? "v1" : "v2")
                model.touch()
                MessageCenter.shared.info("ScamMaster " + (v2 ? "V1" : "V2"))
            }
            Button(L("os.help")) { MessageCenter.shared.info(model.tab == 0 ? L("os.h.tone") : model.chosen.help) }
        } label: {
            roundLabel("cv_os_more")
        }
        .menuOrder(.fixed)
        .accessibilityLabel(L("os.menu"))
    }

    // MARK: «Расширенные»

    private var advanced: some View {
        let p = model.chosen
        let v = p.value
        return VStack(spacing: 0) {
            Text(p.text(v)).font(.app(15, 700)).lineLimit(1)
                .foregroundStyle(v != 0 ? CameraStyle.accent : CameraStyle.text)
                .shadow(color: .black.opacity(0x99 / 255), radius: 3)
                .frame(maxWidth: .infinity)
                .frame(height: 20)
            OldstyleRuler(param: p).frame(height: 38)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(OldstyleParam.advanced.enumerated()), id: \.element) { i, q in
                            OldstyleChip(param: q, chosen: q == p) {
                                guard model.chosen != q else { return }
                                Haptics.tick()
                                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(q, anchor: .center) }
                                model.chosen = q
                                model.touch()
                            }
                            .id(q)
                            .modifier(OsEnter(risen: risen, delay: 0.04 + 0.016 * Double(i)))
                        }
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 12)
                }
            }
            .frame(height: 64)
            .padding(.top, 6)
        }
    }
}

/// Motion.enter: from 14 pt lower, at .92 and faded in, on the enter spring, one after another
private struct OsEnter: ViewModifier {
    let risen: Bool
    let delay: Double
    func body(content: Content) -> some View {
        content.opacity(risen ? 1 : 0).offset(y: risen ? 0 : 14).scaleEffect(risen ? 1 : 0.92)
            .animation(risen ? OsLook.enter.delay(delay) : nil, value: risen)
    }
}

/// A 64 pt chip: the parameter's glyph (22 pt) over its name (10 pt medium, 8.5 pt for a name over 10 letters), 12 pt corners; the
/// chosen one the accent's dark tone with an accent edge and accent ink, the others #1C1C1E at 85 % with the hairline; an accent dot
/// at the top right of a changed one that is not chosen. A tap chooses it (a tick, the glyph's pop, the row scrolled to centre it), a
/// long press says what it does.
private struct OldstyleChip: View {
    let param: OldstyleParam
    let chosen: Bool
    let onTap: () -> Void
    @State private var pops = 0
    @State private var pressed = false

    var body: some View {
        let v = param.value
        let ink = chosen ? CameraStyle.accent : CameraStyle.text
        let name = param.name
        VStack(spacing: 4) {
            Image(param.icon).renderingMode(.template).resizable().frame(width: 22, height: 22)
                .foregroundStyle(ink)
                .keyframeAnimator(initialValue: PopValue(), trigger: pops) { content, value in
                    content.scaleEffect(value.scale)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        LinearKeyframe(0.82, duration: 0.11)
                        LinearKeyframe(1.12, duration: 0.16)
                        LinearKeyframe(1.0, duration: 0.15)
                    }
                }
            Text(name).font(.app(name.count > 10 ? 8.5 : 10, 500)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(ink)
        }
        .frame(width: 64, height: 64)
        .background(chosen ? OsLook.accentDark : OsLook.chipFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(chosen ? CameraStyle.accent : CameraStyle.hairline, lineWidth: OsLook.stroke))
        .overlay(alignment: .topTrailing) {
            if v != 0 && !chosen {
                Circle().fill(CameraStyle.accent).frame(width: 5, height: 5).padding(.top, 5.5).padding(.trailing, 5.5)
            }
        }
        .contentShape(Rectangle())
        .scaleEffect(pressed ? 0.94 : 1)
        .animation(pressed ? .easeOut(duration: 0.11) : .spring(response: 0.3, dampingFraction: 0.6), value: pressed)
        .onTapGesture {
            guard !chosen else { return }
            pops += 1
            onTap()
        }
        .onLongPressGesture(minimumDuration: 0.5, perform: { MessageCenter.shared.info(param.help) }, onPressingChanged: { pressed = $0 })
        .accessibilityElement()
        .accessibilityLabel(name + " " + param.text(v))
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if !chosen { onTap() } }
    }
}

private struct PopValue {
    var scale: CGFloat = 1
}

/// The «Палитра» pad (OldstyleControls.PalettePad): a rounded (22 pt), see-through gradient - left a cool grey #8A939B, the middle
/// #B3A8A6, right a warm salmon #F2907F, each at 0xE0 - under a shade (white 25 % at the top, clear, black 40 % at the bottom), with
/// a dot grid (11 pt, 1.1 pt dots at 42 %); under the finger the dots within 48 pt grow (up to 2.8x) and brighten, at rest a dotted
/// cross (1.2 pt, 2 / 3 dashes, white 80 %) and a ring (6 pt, 1.6 pt) with a 2.2 pt dot mark the point, a 7 pt disc while dragged.
/// x = «Цвет», y = «Тон» (up +), -100..100, the marker 14 pt in from the edges; a tick of haptics every 10, a double tap (two lifts
/// within 300 ms) back to the centre.
struct PalettePad: View {
    /// The point while dragged (0..1, y down) and the finger (pt)
    @State private var drag: CGPoint?
    @State private var finger: CGPoint?
    @State private var glow: CGFloat = 0
    @State private var lastTickC = Int.min
    @State private var lastTickT = Int.min
    @State private var lastUp = Date.distantPast
    private var model: OldstyleModel { OldstyleModel.shared }
    private static let inset: CGFloat = 14

    var body: some View {
        let _ = model.revision
        let colour = OldstyleParam.color.value, tone = OldstyleParam.tone.value
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let rest = CGPoint(x: CGFloat(colour + 100) / 200, y: CGFloat(100 - tone) / 200)
            PadCanvas(glow: glow, point: drag ?? rest, finger: finger, inset: Self.inset)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { d in
                        if finger == nil { withAnimation(.easeOut(duration: 0.16)) { glow = 1 } }
                        move(d.location, w: w, h: h)
                    }
                    .onEnded { _ in
                        let now = Date()
                        if now.timeIntervalSince(lastUp) < 0.3 {
                            OldstyleParam.color.set(0)
                            OldstyleParam.tone.set(0)
                            model.touch()
                        }
                        lastUp = now
                        drag = nil
                        finger = nil
                        withAnimation(.easeOut(duration: 0.26)) { glow = 0 }
                    })
        }
        .accessibilityElement()
        .accessibilityLabel(L("os.pad"))
        .accessibilityValue(L("os.p.tone") + " \(tone), " + L("os.p.color") + " \(colour)")
    }

    private func move(_ location: CGPoint, w: CGFloat, h: CGFloat) {
        let x = min(max(location.x, 0), w), y = min(max(location.y, 0), h)
        finger = CGPoint(x: x, y: y)
        let iw = max(1, w - 2 * Self.inset), ih = max(1, h - 2 * Self.inset)
        let u = min(max((x - Self.inset) / iw, 0), 1), v = min(max((y - Self.inset) / ih, 0), 1)
        drag = CGPoint(x: u, y: v)
        // Math.round: half up
        let c = Int(floor(u * 200 - 100 + 0.5)), t = Int(floor(100 - v * 200 + 0.5))
        if c / 10 != lastTickC || t / 10 != lastTickT {
            if lastTickC != Int.min { Haptics.tick() }
            lastTickC = c / 10
            lastTickT = t / 10
        }
        OldstyleParam.color.set(c)
        OldstyleParam.tone.set(t)
        model.touch()
    }
}

/// The pad's drawing; `glow` animates (160 ms in, 260 ms out)
private struct PadCanvas: View, Animatable {
    var glow: CGFloat
    let point: CGPoint
    let finger: CGPoint?
    let inset: CGFloat

    var animatableData: CGFloat {
        get { glow }
        set { glow = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let a = 0xE0 / 255.0
            context.fill(Path(rect), with: .linearGradient(Gradient(colors: [Color(red: 0x8A / 255, green: 0x93 / 255, blue: 0x9B / 255).opacity(a),
                                                                          Color(red: 0xB3 / 255, green: 0xA8 / 255, blue: 0xA6 / 255).opacity(a),
                                                                          Color(red: 0xF2 / 255, green: 0x90 / 255, blue: 0x7F / 255).opacity(a)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
            context.fill(Path(rect), with: .linearGradient(Gradient(colors: [Color.white.opacity(0x40 / 255.0), Color.black.opacity(0),
                                                                          Color.black.opacity(0x66 / 255.0)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let step: CGFloat = 11, r0: CGFloat = 1.1, reach: CGFloat = 48
            let fx = finger?.x ?? -1e6, fy = finger?.y ?? -1e6
            var y = step / 2
            while y < size.height {
                var x = step / 2
                while x < size.width {
                    let dist = hypot(x - fx, y - fy)
                    let k = dist < reach ? (1 - dist / reach) * glow : 0
                    let r = r0 * (1 + 1.8 * k * k)
                    context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                                 with: .color(Color.white.opacity(Double(0.42 + 0.58 * k))))
                    x += step
                }
                y += step
            }
            let px = inset + point.x * (size.width - 2 * inset), py = inset + point.y * (size.height - 2 * inset)
            if finger == nil {
                var cross = Path()
                cross.move(to: CGPoint(x: 0, y: py)); cross.addLine(to: CGPoint(x: size.width, y: py))
                cross.move(to: CGPoint(x: px, y: 0)); cross.addLine(to: CGPoint(x: px, y: size.height))
                context.stroke(cross, with: .color(Color.white.opacity(0xCC / 255.0)), style: StrokeStyle(lineWidth: 1.2, dash: [2, 3]))
                context.stroke(Path(ellipseIn: CGRect(x: px - 6, y: py - 6, width: 12, height: 12)), with: .color(.white), lineWidth: 1.6)
                context.fill(Path(ellipseIn: CGRect(x: px - 2.2, y: py - 2.2, width: 4.4, height: 4.4)), with: .color(.white))
            } else {
                context.fill(Path(ellipseIn: CGRect(x: px - 7, y: py - 7, width: 14, height: 14)), with: .color(.white))
            }
        }
    }
}

/// The centred tick ruler (OldstyleControls.Ruler): the chosen value under the fixed accent mark (3 pt, 12..88 % of the height);
/// -100..100 a tick per unit 7 pt apart with a long one every 10 (52 % of the height, the others 32 % at 65 %), or the four steps
/// off / low / medium / high 44 pt apart; the edges fade over 22 % of the width. A drag moves the scale under the mark (a tick of
/// haptics per step), the release settles it on the value in 180 ms, a double tap goes back to 0.
struct OldstyleRuler: View {
    let param: OldstyleParam
    @State private var position: CGFloat = 0
    @State private var dragFrom: CGFloat?
    @State private var lastUp = Date.distantPast
    private var model: OldstyleModel { OldstyleModel.shared }
    private var step: CGFloat { param.discrete ? 44 : 7 }

    var body: some View {
        let _ = model.revision
        let v = param.value
        RulerScale(position: position, minValue: param.minValue, maxValue: param.maxValue, discrete: param.discrete,
                   accent: CameraStyle.accent)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in
                    if dragFrom == nil { dragFrom = position }
                    let p = max(CGFloat(param.minValue), min(CGFloat(param.maxValue), (dragFrom ?? position) - d.translation.width / step))
                    position = p
                    let next = Int(floor(p + 0.5))
                    if next != param.value {
                        Haptics.tick()
                        param.set(next)
                        model.touch()
                    }
                }
                .onEnded { d in
                    let now = Date()
                    if abs(d.translation.width) < step / 2 && now.timeIntervalSince(lastUp) < 0.3 {
                        param.set(0)
                        model.touch()
                    }
                    lastUp = now
                    dragFrom = nil
                    withAnimation(.easeOut(duration: 0.18)) { position = CGFloat(param.value) }
                })
            .onAppear { position = CGFloat(v) }
            // configure(chosen, value, false): another parameter, or a value set elsewhere (reset), jumps there
            .onChange(of: param) { position = CGFloat(param.value) }
            .onChange(of: model.revision) {
                if dragFrom == nil && abs(position - CGFloat(param.value)) > 0.5 { position = CGFloat(param.value) }
            }
            .accessibilityElement()
            .accessibilityLabel(param.name)
            .accessibilityValue(param.text(v))
            .accessibilityAdjustableAction { dir in
                switch dir {
                case .increment: param.set(v + 1)
                case .decrement: param.set(v - 1)
                @unknown default: break
                }
                model.touch()
                position = CGFloat(param.value)
            }
    }
}

/// The ruler's drawing; `position` animates (the settle)
private struct RulerScale: View, Animatable {
    var position: CGFloat
    let minValue: Int
    let maxValue: Int
    let discrete: Bool
    let accent: Color

    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height, mid = w / 2, s: CGFloat = discrete ? 44 : 7
            for i in minValue...maxValue {
                let x = mid + (CGFloat(i) - position) * s
                if x < -s || x > w + s { continue }
                let edge = min(1, min(x, w - x) / max(1, w * 0.22))
                let major = discrete || i % 10 == 0
                let alpha = max(0, edge) * (major ? 1 : 0.65)
                if alpha <= 0 { continue }
                let len = (major ? 0.52 : 0.32) * h
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: (h - len) / 2))
                tick.addLine(to: CGPoint(x: x, y: (h + len) / 2))
                context.stroke(tick, with: .color(CameraStyle.text.opacity(Double(alpha))), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            var mark = Path()
            mark.move(to: CGPoint(x: mid, y: h * 0.12))
            mark.addLine(to: CGPoint(x: mid, y: h * 0.88))
            context.stroke(mark, with: .color(accent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }
}

/// The palette's HUD line 14 pt under the preview's top while the panel is open on «Палитра» (and the shade down): «База: Natural  ·
/// Тон: 81  ·  Цвет: -100», 12 pt semibold, the text colour with a 3 pt shadow, no background (Android's oldstyle_hud)
struct OldstyleHud: View {
    var body: some View {
        let _ = OldstyleModel.shared.revision
        Text(L("os.base") + ": Natural  ·  " + L("os.p.tone") + ": \(OldstyleParam.tone.value)  ·  " + L("os.p.color") + ": \(OldstyleParam.color.value)")
            .font(.app(12, 600)).foregroundStyle(CameraStyle.text)
            .lineLimit(1)
            .shadow(color: .black.opacity(0xAA / 255), radius: 3)
            .allowsHitTesting(false)
    }
}
