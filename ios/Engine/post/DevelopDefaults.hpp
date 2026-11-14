// P696 (owner, 2026-11-14: «В галерее не даёт обрабатывать равы, хотя это Рав из нашей камеры»): the develop record of a DNG that
// has none (a SCAMERA DNG shot before P665 wrote it, or another camera's Bayer DNG with its colour tags) made from the DNG's own
// tags and the camera's settings now, so the gallery developer (DevelopRun.hpp) runs the camera's post pipeline on it as on a shot of
// ours (Android DevelopDefaults.java). A DNG with its record keeps it: this is only the fallback.
//
// What the DNG gives: its grid, the as-shot neutral, camera RGB -> XYZ D50 at that white (DngColor: ForwardMatrix, else the inverse
// ColorMatrix), the scene's colour temperature, the NoiseProfile, ISO, exposure time, f-number, focal length, orientation and - a
// SCAMERA DNG only - the headroom its merged mosaic was written over (P165: BaselineExposure = log2 of it). What it cannot give takes
// the camera's defaults: the merge's numbers of one frame (DevelopRecord::Worker's defaults: no Bento, no frame map, no clip flags or
// highlight mask), no crop, no final size, and the settings and scam_dev lines in force now. The lens shading: the Camera2 map our
// DNG writer put in its OpcodeList2 GainMaps, read back, as the shot's own run takes it (its colour share, ScamRgb); a flat map
// without one. The Facts are the editor's to read from the DNG (Android EditDevelop.facts of DngRaw.Info).
// Java float / double arithmetic kept step by step (built with -ffp-contract=off).
#pragma once

#include "DevelopRecord.hpp"
#include "Parameters.hpp"
#include "Settings.hpp"
#include "color/ShotColour.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <optional>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace scam_post {
namespace DevelopDefaults {

/// the record's "source" of a record made here (a camera's record has none)
inline const char* const SOURCE = "dng_tags";

/// What the DNG says (the editor reads it: DngRaw.Info).
struct Facts {
    /// the DNG's Bayer grid (its decode at full size)
    int width = 0, height = 0;
    /// the as-shot camera neutral (green 1)
    std::vector<float> neutral{1.f, 1.f, 1.f};
    /// camera RGB -> XYZ D50 at neutral (white balance included), row-major; none when the DNG has no matrices
    std::optional<std::vector<float>> cameraToXyzD50;
    /// the as-shot white's correlated colour temperature (K)
    float sceneCct = 6504.f;
    /// the DNG's NoiseProfile: (S, O) per plane (3 planes, or 1 for all) of the DNG's normalised level; none for none
    std::optional<std::vector<double>> noiseProfile;
    int iso = 0;
    /// seconds, f-number, millimetres: 0 when the DNG does not say
    double exposureTime = 0;
    float fNumber = 0, focalMm = 0;
    /// the photo's clockwise rotation (0, 90, 180, 270) from the DNG's orientation
    int rotationDeg = 0;
    /// the DNG's 16-bit white over the RGB's white (a SCAMERA merged DNG's headroom; 1 for any other)
    float headroom = 1.f;
    int whiteLevel = 65535;
    float blackLevel = 0;
    std::string software;
    /// the lens-shading map (Camera2's: shadingW x shadingH points of R, G, G, B gains), none for none
    std::optional<std::vector<float>> shadingMap;
    int shadingW = 0, shadingH = 0;
};

/// whether r was made here (from the DNG's tags) rather than taken by the camera with the shot
inline bool fromTags(const DevelopRecord* r) {
    if (r == nullptr) return false;
    const Json& s = r->meta["source"];
    return s.kind == Json::Kind::String && s.s == SOURCE;
}

namespace detail {

/// Math.max(float, float): a NaN wins
inline float javaMax(float a, float b) { return std::isnan(a) || std::isnan(b) ? NAN : std::max(a, b); }

inline std::vector<float> neutral(const std::vector<float>& n) {
    if (n.size() < 3) return {1.f, 1.f, 1.f};
    std::vector<float> out(3);
    for (size_t c = 0; c < 3; c++) out[c] = n[c] > 1e-4f && std::isfinite(n[c]) ? n[c] : 1.f;
    return out;
}

inline bool usable(const std::optional<std::vector<float>>& mo) {
    if (!mo || mo->size() < 9) return false;
    const std::vector<float>& m = *mo;
    for (int i = 0; i < 9; i++) if (!std::isfinite(m[size_t(i)])) return false;
    const double det = m[0] * (double(m[4]) * m[8] - double(m[5]) * m[7]) - m[1] * (double(m[3]) * m[8] - double(m[5]) * m[6])
                       + m[2] * (double(m[3]) * m[7] - double(m[4]) * m[6]);
    return std::fabs(det) > 1e-9;
}

/// NoiseModeler(null, analog, iso, 0)'s rawModel: «Профиль модели шума» other than «Авто» at the ISO (NoiseModelProfile.evaluate;
/// the app passes its coefficients A, B, C, D, four planes each, as "ios_noise_profile", as DngShot.noiseModel reads them), else
/// the generic phone sensor; the four planes' greens averaged
inline std::vector<std::pair<double, double>> modelOf(const Settings& s, int analog, int iso) {
    std::vector<std::pair<double, double>> in;
    std::vector<double> k;
    std::stringstream text(s.getString("ios_noise_profile", ""));
    for (std::string part; std::getline(text, part, ',');) {
        try { k.push_back(std::stod(part)); } catch (...) { k.clear(); break; }
    }
    if (k.size() == 16) {
        const double digitalGain = std::max(double(iso) / std::max(analog, 1), 1.0);
        for (int p = 0; p < 4; p++) {
            const double S = k[size_t(p)] * iso + k[size_t(4 + p)];
            const double O = k[size_t(8 + p)] * double(iso) * iso + k[size_t(12 + p)] * digitalGain * digitalGain;
            in.push_back({std::max(S, 0.0), std::max(O, 0.0)});
        }
    }
    if (in.empty() || in[0].first == 0.0) {
        // no noise profile: the generic phone sensor - S linear in ISO, O quadratic in ISO plus the digital gain's share
        const double dIso = iso, digitalGain = std::max(dIso / analog, 1.0);
        const double S = 0.0000025720647 * iso + 0.000028855721;
        const double O = (0.000000000039798506 * dIso * dIso) + (0.000000046578279 * digitalGain * digitalGain);
        return {{S, O}, {S, O}, {S, O}};
    }
    return {in[0], {(in[1].first + in[2].first) / 2.0, (in[1].second + in[2].second) / 2.0}, in[3]};
}

} // namespace detail

/// DevelopDefaults.noise: the noise of the RGB the pipeline takes (the DNG's level times the headroom) - the DNG's (S, O) as S H,
/// O H^2 for every frame merged into it (the record's one normal frame: the profile already holds the merge), else the generic phone
/// sensor at the ISO (NoiseModeler's own fallback, or a chosen profile)
inline NoiseModel noise(const Facts& f, int iso, const Settings& s) {
    NoiseModel m;
    m.AnalogueISO = std::max(100, iso);
    m.SensivityISO = iso;
    std::vector<std::pair<double, double>> raw = detail::modelOf(s, m.AnalogueISO, iso);
    const double k = detail::javaMax(1.f, f.headroom);
    if (f.noiseProfile && (f.noiseProfile->size() == 2 || f.noiseProfile->size() >= 6)) {
        const std::vector<double>& np = *f.noiseProfile;
        std::vector<std::pair<double, double>> planes(3);
        bool ok = true;
        for (size_t c = 0; c < 3; c++) {
            const size_t at = np.size() == 2 ? 0 : 2 * c;
            const double S = np[at], O = np[at + 1];
            ok &= S > 0 && std::isfinite(S) && O >= 0 && std::isfinite(O);
            planes[c] = {S * k, O * k * k};
        }
        if (ok) raw = planes;
    }
    m.baseModel = raw;
    m.computeModel = raw;
    return m;
}

/// DevelopDefaults.parameters: the post pipeline's Parameters of f (what the pipeline reads of a shot); s: the settings in force
/// (a chosen noise model profile)
inline Parameters parameters(const Facts& f, const Settings& s = Settings::current()) {
    namespace Conv = ShotColour::Conv;
    Parameters p;
    const int w = std::max(2, f.width), h = std::max(2, f.height);
    p.rawSize = Point{w, h};
    p.sensorPix = Rect{0, 0, w, h};
    p.outputScale = 1.f;
    p.scamHdrRawScale = 1.f;
    p.cameraRotation = ((f.rotationDeg % 360) + 360) % 360;
    // the colour: the white balance, then camera -> ProPhoto (Parameters' DNG chain) and the standard ProPhoto -> sRGB; without
    // matrices the white-balanced camera RGB is taken as sRGB (Parameters' identity fallback)
    const std::vector<float> n = detail::neutral(f.neutral);
    p.whitePoint = n;
    const bool matrices = detail::usable(f.cameraToXyzD50);
    std::vector<float> toProPhoto(9), toSrgb(9);
    if (matrices) {
        ShotColour::F9 cam{};
        for (size_t i = 0; i < 9; i++) cam[i] = (*f.cameraToXyzD50)[i];
        const ShotColour::F9 a = Conv::multiply(Conv::sXYZtoProPhoto, cam), b = Conv::multiply(Conv::sXYZtoSRGB, Conv::sProPhotoToXYZ);
        toProPhoto.assign(a.begin(), a.end());
        toSrgb.assign(b.begin(), b.end());
    } else {
        for (int i = 0; i < 9; i++) toProPhoto[size_t(i)] = i % 4 == 0 ? 1.f / n[size_t(i / 3)] : 0.f;
        toSrgb = {1.f, 0.f, 0.f, 0.f, 1.f, 0.f, 0.f, 0.f, 1.f};
    }
    p.sensorToProPhoto = toProPhoto;
    p.proPhotoToSRGB = toSrgb;
    p.CCT = ColorCorrection{toSrgb};
    p.colourSource = matrices ? "DNG_FM" : "IDENTITY_FALLBACK";
    p.colourSourceWhy = "the DNG's own tags (no develop record)";
    p.sceneCct = f.sceneCct > 1000.f && f.sceneCct < 50000.f ? f.sceneCct : 6504.f;
    p.sceneCctSource = "DNG";
    // the exposure of the shot (EXIF), defaults where the DNG does not say
    p.iso = f.iso > 0 ? f.iso : 100;
    if (f.exposureTime > 0 && std::isfinite(f.exposureTime)) p.exposureTime = f.exposureTime;
    if (f.fNumber > 0 && std::isfinite(f.fNumber)) p.aperture = f.fNumber;
    if (f.focalMm > 0 && std::isfinite(f.focalMm)) p.focalLength = f.focalMm;
    p.whiteLevel = f.whiteLevel > 0 ? f.whiteLevel : 65535;
    p.blackLevel = std::vector<float>(4, detail::javaMax(0.f, f.blackLevel));
    // the DNG's lens-shading map, else a flat one
    if (f.shadingMap && f.shadingW > 0 && f.shadingH > 0 && f.shadingMap->size() >= size_t(4) * f.shadingW * f.shadingH) {
        p.mapSize = Point{f.shadingW, f.shadingH};
        p.gainMap = std::vector<float>(f.shadingMap->begin(), f.shadingMap->begin() + std::ptrdiff_t(4 * f.shadingW * f.shadingH));
    } else {
        p.mapSize = Point{2, 2};
        p.gainMap = std::vector<float>(4 * 2 * 2, 1.f);
    }
    p.noiseModeler = noise(f, p.iso, s);
    p.multiFrameCount = 1;
    return p;
}

/// DevelopDefaults.record: the record of f with the settings and scam_dev lines s (the camera's now: Settings of PostSettings.json)
/// and the app's build
inline DevelopRecord record(const Facts& f, const Settings& s, long long build) {
    DevelopRecord r = DevelopRecord::make(parameters(f, s).toJson(), s, DevelopRecord::Worker(), std::max(1.f, f.headroom), f.width,
                                          f.height, 1.f, false, build);
    // the meta's last keys (JSONObject.put after DevelopCapture.record's)
    r.metaText.pop_back();
    r.metaText += "," + JsonText::quoted("source") + ":" + JsonText::quoted(SOURCE) + "," + JsonText::quoted("software") + ":"
                  + JsonText::quoted(f.software) + "}";
    r.meta = Json::parse(r.metaText);
    return r;
}

} // namespace DevelopDefaults
} // namespace scam_post
