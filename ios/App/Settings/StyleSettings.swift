import SwiftUI

/// PhotoStyle (settings/PhotoStyle.java, P718): «Стиль снимка» - a tone preset, Насыщенный (Vivid), Обычный (Normal) or Нейтральный
/// (Neutral), in that order on every card row, stored in pref_photo_style; the photo's V2 tone takes it as factors on the user's own
/// tone rows (Engine/post/why/WhyV2Ae.hpp applyStyle), which keep their values. Choosing a preset puts «Why тон» on V2. Black and
/// white and the film colours are no styles any more: their own rows (the black-and-white filter, the film LUT, the film simulation)
/// hold them, untouched by the style; a user who had one keeps it and reads Обычный here, as nothing was stored.
enum PhotoStyle {
    /// WhyV2Ae.STYLE_NORMAL / STYLE_VIVID / STYLE_NEUTRAL
    static let normal = 0, vivid = 1, neutral = 2
    /// The stored preset: "normal" (also unset), "vivid" or "neutral"
    static let key = "pref_photo_style"
    /// «Why тон» (PreferenceKeys.whyToneV2) and its V2 value
    static let toneVersionKey = "pref_scam_hybrid_tone_version", v2 = "v2"
    /// The cards' order (owner, 2026-11-14: «Порядок плиток сделай Насыщенный/Обычный/Нейтральный»)
    static let order = [vivid, normal, neutral]

    /// The stored preset (anything else, or nothing: Normal)
    static func current(_ s: SettingsStore) -> Int { of(s.string(key, "")) }

    /// The preset of a stored value
    static func of(_ value: String?) -> Int {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "vivid": return vivid
        case "neutral": return neutral
        default: return normal
        }
    }

    /// The stored value (and the cards' tag suffix) of a preset
    static func id(_ style: Int) -> String {
        switch style {
        case vivid: return "vivid"
        case neutral: return "neutral"
        default: return "normal"
        }
    }

    /// Stores style and puts «Why тон» on V2 (every preset is a V2 tone); the other settings stay as they are
    static func apply(_ s: SettingsStore, _ style: Int) {
        s.set(key, id(style))
        s.set(toneVersionKey, v2)
    }

    /// The next style in the cards' order (the shade's «Стиль» tile cycles)
    static func next(_ style: Int) -> Int {
        guard let i = order.firstIndex(of: style) else { return normal }
        return order[(i + 1) % order.count]
    }

    static func name(_ style: Int) -> String {
        switch style {
        case vivid: return Lang.t("Насыщенный", "Vivid")
        case neutral: return Lang.t("Нейтральный", "Neutral")
        default: return Lang.t("Обычный", "Normal")
        }
    }

    /// What a preset does, in a line (the settings' long press, the cards' description)
    static func about(_ style: Int) -> String {
        switch style {
        case vivid: return Lang.t("Больше HDR: светлее тени, мягче яркие места, сочнее приглушённые цвета.",
                                  "More HDR: brighter shadows, softer bright areas, richer muted colours.")
        case neutral: return Lang.t("Спокойнее: мягче контраст, меньше подъём теней, сдержаннее цвета.",
                                    "Calmer: gentler contrast, less shadow lift, quieter colours.")
        default: return Lang.t("Тон камеры как есть: ваши настройки тона без изменений.",
                               "The camera's tone as it is: your tone settings unchanged.")
        }
    }
}

/// LookThumbs.preset (P718): a «Стиль» preset's thumbnail - the settings' drawn sunset sample (LutSamples «Закат»: a bright sky and
/// sun over dark ridges and trees) through a cheap CPU sketch of WhyV2Ae.applyStyle, not the photo's tone: the fusion's shadow lift
/// and highlight compression as an exposure over the local base (the log luma box-blurred over a tenth of the side), liftEV /
/// compressEV EV per unit of the preset's factor, the macro contrast on the cube root of the luminance round 0.40 (the default
/// 1.1's excess by the preset's factor), the vibrance on the chroma (muted / saturated colours, the sky and light-tone terms).
/// Every term `emphasis` x its change from Normal, so the difference reads on a 53 pt card.
enum StyleThumbs {
    /// The picture's size in pixels (LookThumbs.SIZE)
    static let size = 112
    /// LookThumbs.PRESET_SAMPLE: «Закат»
    static let sample = 1
    /// how much more than the photo's change a card shows (the photo's own +-0.24 EV and +-8-15 % chroma vanish at 53 pt)
    static let emphasis: Float = 2
    /// EV per unit of the shadow / highlight factor (1.8 x 0.45 and 2.5 x 0.3)
    static let liftEV: Float = 0.81, compressEV: Float = 0.75
    private static let luma: [Float] = [0.2126, 0.7152, 0.0722]

    /// WhyV2Ae.Style: shadow, highlight, macro, boost, vibrance, vibSaturated, vibTerms (WhyV2Ae.STYLES, index PhotoStyle's)
    struct Factors { let shadow, highlight, macro, boost, vibrance, vibSaturated, vibTerms: Float }
    static func factors(_ style: Int) -> Factors {
        switch style {
        case PhotoStyle.vivid: return Factors(shadow: 1.7, highlight: 1.6, macro: 1.5, boost: 1, vibrance: 0.30, vibSaturated: 0, vibTerms: 1)
        case PhotoStyle.neutral: return Factors(shadow: 0.85, highlight: 1, macro: 0.3, boost: 1 / 3, vibrance: -0.12, vibSaturated: -0.12, vibTerms: 0.55)
        default: return Factors(shadow: 1, highlight: 1, macro: 1, boost: 1, vibrance: 0, vibSaturated: 0, vibTerms: 1)
        }
    }

    /// The card's picture of a preset (drawn off the main thread, kept in SampleCache)
    static func picture(_ style: Int) -> SamplePixels { pixels(LutSamples.draw(sample, size, size), style: style) }

    /// LookThumbs.presetPixels on RGBA8 pixels (Normal: the sample itself)
    static func pixels(_ src: SamplePixels, style: Int) -> SamplePixels {
        if style == PhotoStyle.normal { return src }
        let s = factors(style)
        let w = src.width, h = src.height, n = w * h
        let bytes = [UInt8](src.rgba)
        guard bytes.count >= n * 4 else { return src }
        var lin = [Float](repeating: 0, count: n * 3), lg = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var y: Float = 0
            for k in 0..<3 {
                let v = toLinear(Float(bytes[i * 4 + k]) / 255)
                lin[i * 3 + k] = v
                y += luma[k] * v
            }
            lg[i] = Float(log(Double(Swift.max(y, Float(1e-4)))) / log(2.0))
        }
        let base = box(box(lg, w, h, Swift.max(1, w / 10), true), w, h, Swift.max(1, h / 10), false)
        let e = emphasis
        let contrast: Float = 1 + e * ((1 + 0.1 * s.macro) / 1.1 - 1)
        var out = [UInt8](repeating: 255, count: n * 4)
        var d: [Float] = [0, 0, 0]
        for i in 0..<n {
            let b = base[i]
            let dark = ramp(-1.0, -4.0, b), bright = ramp(-1.5, 0, b)
            let ev: Float = e * (liftEV * (s.shadow - 1) * dark - compressEV * (s.highlight - 1) * bright)
            var gain = Float(pow(2.0, Double(ev)))
            var yl: Float = 0
            for k in 0..<3 { yl += luma[k] * lin[i * 3 + k] * gain }
            if yl > 1e-6 {
                let l = Float(cbrt(Double(yl))), lc = Swift.max(Float(0.0001), 0.4 + (l - 0.4) * contrast)
                gain *= (lc / l) * (lc / l) * (lc / l)
            }
            var y: Float = 0
            for k in 0..<3 {
                d[k] = toDisplay(lin[i * 3 + k] * gain)
                y += luma[k] * d[k]
            }
            // the chroma: muted -> saturated colours by its size, the sky (blue) and light-tone terms by their masks
            let chroma = Swift.max(Swift.max(d[0], d[1]), d[2]) - Swift.min(Swift.min(d[0], d[1]), d[2])
            let satT = ramp(0.08, 0.35, chroma)
            let sky: Float = d[2] > d[0] ? Swift.min(1, (d[2] - d[0]) / Swift.max(chroma, 1e-4)) : 0
            let light = ramp(0.6, 0.8, y) * (1 - ramp(0.88, 0.98, y))
            let boost = s.vibrance + (s.vibSaturated - s.vibrance) * satT + (s.vibTerms - 1) * 0.25 * (sky + light)
            let sat = Swift.max(Float(0), 1 + e * boost)
            for k in 0..<3 {
                let v = Swift.max(Float(0), Swift.min(Float(1), y + (d[k] - y) * sat))
                out[i * 4 + k] = UInt8((v * 255 + 0.5).rounded(.down))
            }
        }
        return SamplePixels(rgba: Data(out), width: w, height: h)
    }

    private static func ramp(_ from: Float, _ to: Float, _ v: Float) -> Float {
        let t = Swift.max(0, Swift.min(1, (v - from) / (to - from)))
        return t * t * (3 - 2 * t)
    }

    private static func toLinear(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : Float(pow(Double((v + 0.055) / 1.055), Double(Float(2.4))))
    }

    private static func toDisplay(_ x: Float) -> Float {
        let v = Swift.max(0, Swift.min(1, x))
        return v <= 0.0031308 ? v * 12.92 : 1.055 * Float(pow(Double(v), Double(Float(1) / Float(2.4)))) - 0.055
    }

    /// A box mean along x (horizontal) or y with radius r, the edges clamped
    private static func box(_ a: [Float], _ w: Int, _ h: Int, _ r: Int, _ horizontal: Bool) -> [Float] {
        var out = [Float](repeating: 0, count: a.count)
        let len = horizontal ? w : h, lines = horizontal ? h : w
        func at(_ line: Int, _ i: Int) -> Int { horizontal ? line * w + i : i * w + line }
        for line in 0..<lines {
            var sum: Double = 0
            for j in -r...r { sum += Double(a[at(line, Swift.max(0, Swift.min(len - 1, j)))]) }
            for i in 0..<len {
                out[at(line, i)] = Float(sum / Double(2 * r + 1))
                sum += Double(a[at(line, Swift.min(len - 1, i + r + 1))]) - Double(a[at(line, Swift.max(0, i - r))])
            }
        }
        return out
    }
}

/// PhotoStylePreference + StyleCards (P718): the tone presets as the wizard shows them - a row of three cards, Насыщенный / Обычный /
/// Нейтральный (PhotoStyle.order), each with the preset's thumbnail (StyleThumbs: the sunset sample through the preset, as the LUT
/// tray's cards), its name and the wizard card's fill, ring and tick - and a line on what the chosen one does; a tap stores the
/// preset and puts «Why тон» on V2 (PhotoStyle.apply). Black and white and film have their own rows below.
struct PhotoStylePicker: View {
    private var store: SettingsStore { SettingsStore.shared }

    var body: some View {
        let chosen = PhotoStyle.current(store)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach(PhotoStyle.order, id: \.self) { style in
                    StyleCard(style: style, on: style == chosen) {
                        guard style != chosen else { return }
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { PhotoStyle.apply(store, style) }
                    }
                }
            }
            Text(PhotoStyle.about(chosen))
                .font(.app(13)).foregroundStyle(.secondary)
                .padding(.horizontal, 4).padding(.top, 10)
                .accessibilityIdentifier("style_about")
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("photo_style")
    }
}

/// StyleCards' card (SettingsWizard.Card with a picture): the preset's thumbnail, its name on one line (shrinking to fit), the tick;
/// chosen: the accent ring, an accent-tinted fill and the tick shown
private struct StyleCard: View {
    let style: Int
    let on: Bool
    let pick: () -> Void
    private static let thumb: CGFloat = 53, thumbCorner: CGFloat = 14, corner: CGFloat = 18

    var body: some View {
        let accent = AccentPalette.settingsColor
        let preset = style
        Button(action: pick) {
            VStack(spacing: 0) {
                Group {
                    if let img = SampleCache.shared.get("preset|\(preset)", { StyleThumbs.picture(preset) })?.image {
                        Image(decorative: img, scale: 1).resizable().scaledToFill()
                    } else {
                        Color(white: 0.2)
                    }
                }
                .frame(width: Self.thumb, height: Self.thumb)
                .clipShape(RoundedRectangle(cornerRadius: Self.thumbCorner))
                .overlay(RoundedRectangle(cornerRadius: Self.thumbCorner).strokeBorder(Color.white.opacity(0.12)))
                .padding(.bottom, 8)
                Text(PhotoStyle.name(style))
                    .font(.app(15, 600)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(10.0 / 15.0)
                    .frame(maxWidth: .infinity)
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(accent)
                    .frame(width: 20, height: 20)
                    .opacity(on ? 1 : 0)
                    .scaleEffect(on ? 1 : 0.6)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 8).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(on ? accent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: Self.corner))
            .background(Color(white: 0.23), in: RoundedRectangle(cornerRadius: Self.corner))
            .overlay(RoundedRectangle(cornerRadius: Self.corner).strokeBorder(accent.opacity(on ? 1 : 0), lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: Self.corner))
        }
        .buttonStyle(StyleCardPress())
        .accessibilityLabel(PhotoStyle.name(style) + ". " + PhotoStyle.about(style))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("style_option_" + PhotoStyle.id(style))
    }
}

/// Motion.press(view, .97f): the card a little smaller while held
private struct StyleCardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// LutLook (processing/color/LutLook.java): reference colours and greys through the LUT at its strength, «before» against «after».
/// The LUT is sampled through SCAMFilm.lookThumbnail (the engine's FinishedLook table at full strength, 8-bit in and out); the
/// strength mixes as the photo does.
struct LutLook {
    static let chart: [[Int]] = [[115, 82, 68], [194, 150, 130], [98, 122, 157], [87, 108, 67], [133, 128, 177],
                                 [103, 189, 170], [214, 126, 44], [80, 91, 166], [193, 90, 99], [94, 60, 108], [157, 188, 64], [224, 163, 46],
                                 [56, 61, 150], [70, 148, 73], [175, 54, 60], [231, 199, 31], [187, 86, 149], [8, 133, 161], [243, 243, 242],
                                 [200, 200, 200], [160, 160, 160], [122, 122, 121], [85, 85, 85], [52, 52, 52]]
    static let keyColours: [[Int]] = [[194, 150, 130], [98, 122, 157], [87, 108, 67], [175, 54, 60], [45, 45, 48], [225, 222, 215]]
    static let curveSteps = 40

    private let table: [Int: [Float]]
    let strength: Float

    private static func code(_ v: Float) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
    private static func pack(_ r: Int, _ g: Int, _ b: Int) -> Int { r << 16 | g << 8 | b }

    /// Every colour the analysis, the curve and the swatches read
    private static func inputs() -> [[Int]] {
        var out: [[Int]] = []
        for v: Float in [0, 0.1, 0.2, 0.3, 0.7, 0.8, 0.9, 1] { out.append([code(v), code(v), code(v)]) }
        for k in 0...curveSteps { let c = code(Float(k) / Float(curveSteps)); out.append([c, c, c]) }
        out += chart + keyColours
        return out
    }

    init?(lut: String, strength: Float) {
        let colours = Self.inputs()
        var rgba = [UInt8](repeating: 255, count: colours.count * 4)
        for (i, c) in colours.enumerated() {
            rgba[i * 4] = UInt8(c[0]); rgba[i * 4 + 1] = UInt8(c[1]); rgba[i * 4 + 2] = UInt8(c[2])
        }
        guard let out = SCAMFilm.lookThumbnail(Data(rgba), width: colours.count, height: 1, lut: lut, film: ""),
              out.count >= rgba.count else { return nil }
        let bytes = [UInt8](out)
        var table: [Int: [Float]] = [:]
        for (i, c) in colours.enumerated() {
            table[Self.pack(c[0], c[1], c[2])] = [Float(bytes[i * 4]) / 255, Float(bytes[i * 4 + 1]) / 255, Float(bytes[i * 4 + 2]) / 255]
        }
        self.table = table
        self.strength = max(0, min(1, strength))
    }

    /// One display colour through the LUT at the strength (the input on the 8-bit grid it was sampled at)
    func apply(_ r: Float, _ g: Float, _ b: Float) -> [Float] {
        let ri = Self.code(r), gi = Self.code(g), bi = Self.code(b)
        let rq = Float(ri) / 255, gq = Float(gi) / 255, bq = Float(bi) / 255
        let o = table[Self.pack(ri, gi, bi)] ?? [rq, gq, bq]
        func mix(_ a: Float, _ b: Float) -> Float { max(0, min(1, a + (max(0, min(1, b)) - a) * strength)) }
        return [mix(rq, o[0]), mix(gq, o[1]), mix(bq, o[2])]
    }

    static func luma(_ c: [Float]) -> Float { 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2] }
    private func grey(_ v: Float) -> Float { Self.luma(apply(v, v, v)) }
    private static func spread(_ c: [Float]) -> Float { c.max()! - c.min()! }

    /// The analysis (the concept's thresholds): (aspect, verdict) in the concept's order
    func analyse() -> [(String, String)] {
        var t: [(String, String)] = []
        let all = (grey(0.9) - grey(0.1)) / 0.8, mid = (grey(0.7) - grey(0.3)) / 0.4
        if mid > 1.05 && all <= 1.05 { t.append(("contrast", "midtones")) } else {
            t.append(("contrast", all > 1.05 ? "stronger" : all < 0.97 ? "softer" : "same"))
        }
        if Self.luma(apply(0, 0, 0)) > 0.015 { t.append(("black", "lifted")) }
        if Self.luma(apply(1, 1, 1)) < 0.985 { t.append(("white", "muted")) }
        var before: Float = 0, after: Float = 0
        for c in Self.chart.prefix(18) {
            let r = Float(c[0]) / 255, g = Float(c[1]) / 255, b = Float(c[2]) / 255
            before += Self.spread([r, g, b])
            after += Self.spread(apply(r, g, b))
        }
        let ratio = after / before
        t.append(("colours", ratio < 0.08 ? "mono" : ratio > 1.04 ? "richer" : ratio < 0.95 ? "calmer" : "kept"))
        if ratio >= 0.08 {
            if let sh = Self.tone(apply(0.2, 0.2, 0.2)) { t.append(("shadows", sh)) }
            if let hi = Self.tone(apply(0.8, 0.8, 0.8)) { t.append(("highlights", hi)) }
            let skin: [Float] = [194 / 255, 150 / 255, 130 / 255]
            if Self.spread(apply(skin[0], skin[1], skin[2])) > Self.spread(skin) * 1.04 { t.append(("skin", "richer")) }
            let gr = apply(87 / 255, 108 / 255, 67 / 255)
            let dr = gr[0] - 87 / 255, db = gr[2] - 67 / 255
            if db > 0.015 || dr > 0.02 { t.append(("greens", dr > db ? "olive" : "teal")) }
        }
        return t
    }

    private static func tone(_ c: [Float]) -> String? {
        let w = c[0] - c[2]
        return w > 0.012 ? "warmer" : w < -0.012 ? "cooler" : nil
    }

    static func aspectName(_ a: String) -> String {
        switch a {
        case "contrast": return Lang.t("Контраст", "Contrast")
        case "black": return Lang.t("Чёрный", "Black")
        case "white": return Lang.t("Белый", "White")
        case "colours": return Lang.t("Цвета", "Colours")
        case "shadows": return Lang.t("Тени", "Shadows")
        case "highlights": return Lang.t("Света", "Highlights")
        case "skin": return Lang.t("Кожа", "Skin")
        default: return Lang.t("Зелень", "Greens")
        }
    }

    static func verdictName(_ v: String) -> String {
        switch v {
        case "midtones": return Lang.t("ярче в середине, мягче по краям", "punchier middle, softer ends")
        case "stronger": return Lang.t("сильнее", "stronger")
        case "softer": return Lang.t("мягче", "softer")
        case "same": return Lang.t("почти как был", "about the same")
        case "lifted": return Lang.t("приподнят", "lifted")
        case "muted": return Lang.t("приглушён", "muted")
        case "mono": return Lang.t("чёрно-белые", "black and white")
        case "richer": return Lang.t("насыщеннее", "richer")
        case "calmer": return Lang.t("спокойнее", "calmer")
        case "kept": return Lang.t("как были", "as they were")
        case "warmer": return Lang.t("теплее", "warmer")
        case "cooler": return Lang.t("холоднее", "cooler")
        case "olive": return Lang.t("к оливковой", "towards olive")
        default: return Lang.t("к бирюзовой", "towards teal")
        }
    }

    /// FilmLooks.description, or «Свой LUT из файла …»
    static func description(_ value: String) -> String {
        switch value {
        case "scam:warm400": return Lang.t("Портретный негатив: тёплые чёрные, кремовые света, оливковая зелень, мягкие края тонов",
                                           "Portrait negative: warm blacks, creamy highlights, olive greens, soft tonal ends")
        case "scam:cool160": return Lang.t("Мелкозернистый негатив: низкий контраст, пастель, бирюзовые тени, розоватые белые",
                                           "Fine-grain negative: low contrast, pastels, teal shadows, pinkish whites")
        case "scam:slide100": return Lang.t("Обращаемая плёнка: глубокий чёрный, сильный контраст, плотное синее небо, сочные цвета",
                                            "Slide film: deep black, strong contrast, dense blue sky, rich colours")
        case "scam:cine500": return Lang.t("Кинокопия: контрастная середина, бирюзовые тени, тёплые света, мягкие белые",
                                           "Print film: contrasty middle, teal shadows, warm highlights, soft whites")
        case "scam:mono400": return Lang.t("Панхроматическая ч/б плёнка: плотная S-кривая, мягкий подъём теней",
                                           "Panchromatic black-and-white film: a firm S-curve, a soft shadow lift")
        default: return Lang.t("Свой LUT из файла «" + value + "»", "Own LUT from «" + value + "»")
        }
    }
}

/// LutChangesPreference: «Что меняется» of the LUT page - what the LUT imitates («Слегка.» under 50 %), the analysis chips, the
/// tone curve («тени / середина / света») and its reading, the six key colours before → after and «Как это определяется». With
/// no LUT or at 0 %: one line.
struct LutChangesView: View {
    private var store: SettingsStore { SettingsStore.shared }
    @State private var look: LutLook?
    @State private var failed = false
    @State private var howOpen = false

    private var value: String { store.string("pref_film_lut", "") }
    private var strength: Float {
        Float(max(0, min(100, PrefValue.number(store.values["pref_film_lut_strength"], 100)))) / 100
    }

    var body: some View {
        let value = value, k = strength
        VStack(alignment: .leading, spacing: 10) {
            Text(Lang.t("Что меняется", "What changes")).font(.app(13, 600)).foregroundStyle(Color.accentColor)
            if value.isEmpty {
                line(Lang.t("Плёночный образ выключен: снимок как есть.", "The film look is off: the photo stays as it is."))
            } else if k <= 0 {
                line(Lang.t("Сила 0 %: снимок не меняется.", "Strength 0 %: the photo does not change."))
            } else if failed {
                line(Lang.t("Файл не читается: выберите другой LUT.", "The file cannot be read: choose another LUT."))
            } else if let look {
                details(look, value: value)
            } else {
                ProgressView()
            }
        }
        .padding(.vertical, 6)
        .task(id: value + "|" + String(k)) {
            look = nil
            failed = false
            guard !value.isEmpty, k > 0 else { return }
            let made = await Task.detached(priority: .userInitiated) { LutLook(lut: value, strength: k) }.value
            if Task.isCancelled { return }
            look = made
            failed = made == nil
        }
    }

    private func line(_ text: String) -> some View { Text(text).font(.app(13)).foregroundStyle(.secondary) }

    @ViewBuilder private func details(_ look: LutLook, value: String) -> some View {
        Text((look.strength < 0.5 ? Lang.t("Слегка. ", "Slightly. ") : "") + LutLook.description(value)).font(.app(13))
        let tags = look.analyse()
        FlowChips(items: tags.map { LutLook.aspectName($0.0) + ": " + LutLook.verdictName($0.1) })
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 2) {
                LutCurveShape(look: look).frame(width: 120, height: 90)
                HStack {
                    Text(Lang.t("тени", "shadows")); Spacer(); Text(Lang.t("середина", "middle")); Spacer(); Text(Lang.t("света", "lights"))
                }
                .font(.app(10)).foregroundStyle(.secondary).frame(width: 120)
            }
            Text(Lang.t("Линия выше пунктира — эта часть снимка станет светлее, ниже — темнее. Цветные линии показывают сдвиг оттенка.",
                        "Above the dashed line that part of the photo gets lighter, below it darker. The coloured lines show the tint shift."))
                .font(.app(12)).foregroundStyle(.secondary)
        }
        Text(Lang.t("Ключевые цвета: слева — до, справа — после", "Key colours: before on the left, after on the right"))
            .font(.app(12)).foregroundStyle(.secondary)
        let names = [Lang.t("Кожа", "Skin"), Lang.t("Небо", "Sky"), Lang.t("Зелень", "Greens"), Lang.t("Красный", "Red"),
                     Lang.t("Тени", "Shadows"), Lang.t("Света", "Lights")]
        HStack(spacing: 6) {
            ForEach(0..<LutLook.keyColours.count, id: \.self) { i in
                let k0 = LutLook.keyColours[i]
                let a = look.apply(Float(k0[0]) / 255, Float(k0[1]) / 255, Float(k0[2]) / 255)
                VStack(spacing: 4) {
                    HStack(spacing: 0) {
                        Color(red: Double(k0[0]) / 255, green: Double(k0[1]) / 255, blue: Double(k0[2]) / 255)
                        Color(red: Double(a[0]), green: Double(a[1]), blue: Double(a[2]))
                    }
                    .frame(height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(names[i]).font(.app(10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        DisclosureGroup(Lang.t("Как это определяется", "How it is worked out"), isExpanded: $howOpen) {
            Text(Lang.t(
                "Через LUT прогоняются эталонные цвета и серые тона, и сравнивается «до» и «после». Так же и для ваших файлов — описание из файла не нужно.\n"
                    + "• Контраст — разница яркости между тёмно-серым (10 %) и светло-серым (90 %): больше на 5 % — «сильнее», меньше на 3 % — «мягче». Если середина (30–70 %) растёт, а края нет — «ярче в середине, мягче по краям».\n"
                    + "• Чёрный / Белый — во что превращается чистый чёрный и чистый белый: чёрный светлее 1,5 % — «приподнят», белый темнее 98,5 % — «приглушён».\n"
                    + "• Цвета — насыщенность 18 цветов шкалы: больше на 4 % — «насыщеннее», меньше на 5 % — «спокойнее», почти ноль — «чёрно-белые».\n"
                    + "• Тени / Света — оттенок тёмно-серого (20 %) и светло-серого (80 %): красного больше синего — «теплее», наоборот — «холоднее».\n"
                    + "• Кожа — светлый тон кожи со шкалы стал насыщеннее. Зелень — цвет листвы ушёл к жёлтому (оливковая) или к синему (бирюзовая).",
                "Reference colours and greys go through the LUT and «before» is compared with «after» - the same for your own files, no description in the file is needed.\n"
                    + "• Contrast - the brightness spread of dark grey (10 %) and light grey (90 %): 5 % more is «stronger», 3 % less «softer». A middle (30-70 %) that grows while the ends do not: «punchier middle, softer ends».\n"
                    + "• Black / White - what pure black and pure white become: black above 1.5 % is «lifted», white below 98.5 % «muted».\n"
                    + "• Colours - the saturation of the chart's 18 colours: 4 % more is «richer», 5 % less «calmer», about none «black and white».\n"
                    + "• Shadows / Highlights - the tint of dark grey (20 %) and light grey (80 %): more red than blue is «warmer», the other way «cooler».\n"
                    + "• Skin - the chart's light skin got richer. Greens - foliage moved to yellow (olive) or to blue (teal)."))
                .font(.app(12)).foregroundStyle(.secondary)
        }
        .font(.app(13, 600))
    }
}

/// LutCurveView: greys 0..1 through the LUT at its strength - the dashed diagonal «no change», the red / green / blue lines the
/// channels, the white line the luminance with the area between it and the diagonal in the accent.
struct LutCurveShape: View {
    let look: LutLook
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10), with: .color(Color(red: 0.067, green: 0.082, blue: 0.094)))
            var grid = Path()
            for k in 1..<4 {
                grid.move(to: CGPoint(x: w * CGFloat(k) / 4, y: 0)); grid.addLine(to: CGPoint(x: w * CGFloat(k) / 4, y: h))
                grid.move(to: CGPoint(x: 0, y: h * CGFloat(k) / 4)); grid.addLine(to: CGPoint(x: w, y: h * CGFloat(k) / 4))
            }
            ctx.stroke(grid, with: .color(.white.opacity(0.13)), lineWidth: 1)
            var diag = Path()
            diag.move(to: CGPoint(x: 0, y: h)); diag.addLine(to: CGPoint(x: w, y: 0))
            ctx.stroke(diag, with: .color(.white.opacity(0.33)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            let n = LutLook.curveSteps
            let out = (0...n).map { k -> [Float] in let v = Float(k) / Float(n); return look.apply(v, v, v) }
            let colours: [Color] = [Color(red: 1, green: 0.42, blue: 0.42), Color(red: 0.42, green: 0.86, blue: 0.55), Color(red: 0.42, green: 0.66, blue: 1)]
            for ch in 0..<3 {
                var p = Path()
                for k in 0...n {
                    let pt = CGPoint(x: CGFloat(k) / CGFloat(n) * w, y: h - CGFloat(out[k][ch]) * h)
                    if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                ctx.stroke(p, with: .color(colours[ch].opacity(0.67)), lineWidth: 1.2)
            }
            var area = Path(), line = Path()
            area.move(to: CGPoint(x: 0, y: h))
            for k in 0...n {
                let pt = CGPoint(x: CGFloat(k) / CGFloat(n) * w, y: h - CGFloat(LutLook.luma(out[k])) * h)
                area.addLine(to: pt)
                if k == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
            }
            for k in stride(from: n, through: 0, by: -1) { area.addLine(to: CGPoint(x: CGFloat(k) / CGFloat(n) * w, y: h - CGFloat(k) / CGFloat(n) * h)) }
            area.closeSubpath()
            ctx.fill(area, with: .color(Color.accentColor.opacity(0.22)))
            ctx.stroke(line, with: .color(.white), lineWidth: 2)
        }
        .accessibilityLabel(Lang.t("Тоновая кривая", "Tone curve"))
    }
}

/// Chips left to right, wrapped onto new lines (LutChangesPreference.FlowLayout)
struct FlowChips: View {
    let items: [String]
    var body: some View {
        ChipFlow(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item).font(.app(12)).padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color(red: 0.137, green: 0.165, blue: 0.18), in: Capsule())
            }
        }
    }
}

struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, s.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > bounds.width { x = 0; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}
