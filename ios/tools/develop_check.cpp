// P665 host check of the gallery developer's C++ (Engine/post/DevelopRecord.hpp, DevelopRun.hpp, DevelopDefaults.hpp,
// Editor/EditDevelop.hpp) on the cases of the Android tests (DevelopRecordTest, DevelopRunTest, DevelopDefaultsTest, EditDevelopTest): the record through a file and back (zlib as the
// platform's deflate), the Parameters field for field, a reduced grid and a Sabre 2x shot's final size, the settings with the
// changes, the maps' resampling, the crops, the demosaics and the halves; P696 / P706: a DNG without the record (DngRaw's tags, opcode
// lists and shading map, EditDevelop's refusal and facts, the developer's GainMaps). No GL: the pipeline's run itself is the post checks'.
//   g++ -std=c++17 -O1 -ffp-contract=off -Iios/ScamGL/include -Iapp/src/main/cpp -Iapp/src/main/cpp/third_party/tone_port/include
//       ios/tools/develop_check.cpp -lz -pthread -o develop_check && ./develop_check
#include "../Engine/post/DevelopDefaults.hpp"
#include "../Engine/post/DevelopRun.hpp"
#include "../Engine/post/DngWriter.hpp"
#include "../Editor/EditDevelop.hpp"

#include <zlib.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <iostream>

using namespace scam_post;

static int failures = 0;
#define CHECK(c) do { if (!(c)) { std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)
#define NEAR(a, b, e) CHECK(std::fabs(double(a) - double(b)) <= (e))

static DevelopRecord::Codec zlibCodec() {
    DevelopRecord::Codec c;
    c.deflateRaw = [](const uint8_t* p, size_t n) {
        z_stream z{};
        deflateInit2(&z, 1, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY);
        std::vector<uint8_t> out(deflateBound(&z, uLong(n)) + 16);
        z.next_in = const_cast<Bytef*>(p);
        z.avail_in = uInt(n);
        z.next_out = out.data();
        z.avail_out = uInt(out.size());
        deflate(&z, Z_FINISH);
        out.resize(z.total_out);
        deflateEnd(&z);
        return out;
    };
    c.inflateRaw = [](const uint8_t* p, size_t n, uint8_t* out, size_t outLen) {
        z_stream z{};
        inflateInit2(&z, -15);
        z.next_in = const_cast<Bytef*>(p);
        z.avail_in = uInt(n);
        z.next_out = out;
        z.avail_out = uInt(outLen);
        const int rc = inflate(&z, Z_FINISH);
        const bool ok = (rc == Z_STREAM_END || rc == Z_OK || rc == Z_BUF_ERROR) && z.total_out == outLen;
        inflateEnd(&z);
        return ok;
    };
    return c;
}

static Parameters shot() {
    Parameters p;
    p.rawSize = Point{4096, 3072};
    p.sensorPix = Rect{0, 0, 4096, 3072};
    p.hybridFinalSize = Point{2048, 1536};
    p.whitePoint = std::vector<float>{.5f, 1.f, .7f};
    p.sensorToProPhoto = std::vector<float>{1, 2, 3, 4, 5, 6, 7, 8, 9};
    p.CCT = ColorCorrection{{9, 8, 7, 6, 5, 4, 3, 2, 1}};
    p.gainMap = std::vector<float>{1, 1.5f, 1.5f, 2, 1, 1, 1, 1};
    p.mapSize = Point{2, 1};
    p.iso = 640;
    p.cameraRotation = 90;
    p.filmFrameScale = .8f;
    p.portraitFaces = std::vector<float>{.1f, .2f, .3f, .4f};
    p.sceneDuv = NAN;
    NoiseModel n;
    n.baseModel = {{1e-4, 1e-6}, {2e-4, 2e-6}, {3e-4, 3e-6}};
    n.computeModel = {{1e-5, 1e-7}, {2e-5, 2e-7}, {3e-5, 3e-7}};
    n.AnalogueISO = 100;
    n.SensivityISO = 640;
    p.noiseModeler = n;
    p.tonemapCurves = {std::vector<float>{0, 0, 1, 1}, std::nullopt, std::vector<float>{0, .1f}};
    return p;
}

static Settings prefs() {
    Settings s;
    s.prefs["pref_scam_hybrid_why_sharp_gain"] = Pref::string("1.25");
    s.prefs["pref_scam_hybrid_tone_version"] = Pref::string("v2");
    s.prefs["pref_scam_hybrid_denoise"] = Pref::boolean(true);
    s.prefs["pref_film_sim_stock"] = Pref::string("kodak_portra_400");
    s.prefs["pref_scam_hybrid_diagnostics"] = Pref::boolean(true);
    s.prefs["pref_keep_raw_burst"] = Pref::boolean(true);
    s.prefs["pref_some_int"] = Pref::integer(3);
    s.prefs["pref_some_float"] = Pref::real(0.1f);
    Pref set;
    set.type = Pref::Type::Set;
    set.set = {"a", "b \"q\""};
    s.prefs["pref_some_set"] = set;
    s.dev["hybrid_sun_bloom_no_short"] = 0.f;
    return s;
}

static DevelopRecord::Worker worker() {
    DevelopRecord::Worker w;
    w.bentoApplied = true;
    w.bentoFactor = 6.5f;
    w.bentoUsClipped = .02f;
    w.effectiveMedian = 11.f;
    w.noiseFactor = .8f;
    w.normals = 12;
    w.report = "HYBRID FAST MERGE HIGHLIGHT: accumulated validity 0.9\nHYBRID NOISE CHECK: x -> model x0.75";
    return w;
}

/// the record as the camera appends it to a DNG and the editor reads it back from the file's end
static DevelopRecord throughTheFile(const DevelopRecord& r) {
    const DevelopRecord::Codec c = zlibCodec();
    std::vector<uint8_t> file = {'I', 'I', 42, 0, 8, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
    const std::vector<uint8_t> tail = r.appendix(c);
    file.insert(file.end(), tail.begin(), tail.end());
    const std::optional<DevelopRecord> back = DevelopRecord::read(file.data(), file.size(), c);
    CHECK(back.has_value());
    // a flipped byte in a section fails the CRC
    std::vector<uint8_t> bad = file;
    bad[18 + 30] ^= 0x40;
    CHECK(!DevelopRecord::read(bad.data(), bad.size(), c).has_value());
    return back ? *back : DevelopRecord();
}

static DevelopRecord record(const Parameters& p, float headroom, float zoom, bool isz) {
    Settings s = prefs();
    return throughTheFile(DevelopRecord::make(p.toJson(), s, worker(), headroom, 4096, 3072, zoom, isz, 665));
}

/// P696 / P706: a little-endian DNG in memory - IFD 0 the 16-bit Bayer raw itself (8 x 6, its tags), an Exif IFD - as the editor's
/// reader takes another camera's or our own DNG (DngRawTest's fixtures)
struct TestDng {
    struct Entry { uint16_t tag, type; uint32_t count; std::vector<uint8_t> data; };
    std::vector<Entry> ifd0, exif;
    static constexpr int W = 8, H = 6;

    static void le(std::vector<uint8_t>& b, uint64_t v, int n) { for (int i = 0; i < n; i++) b.push_back(uint8_t(v >> (8 * i))); }
    static void put(std::vector<Entry>& to, uint16_t tag, uint16_t type, uint32_t count, std::vector<uint8_t> data) {
        to.push_back({tag, type, count, std::move(data)});
    }
    static std::vector<uint8_t> shorts(std::initializer_list<int> v) { std::vector<uint8_t> b; for (int x : v) le(b, uint16_t(x), 2); return b; }
    static std::vector<uint8_t> longs(std::initializer_list<long long> v) { std::vector<uint8_t> b; for (long long x : v) le(b, uint32_t(x), 4); return b; }
    static std::vector<uint8_t> rationals(std::initializer_list<std::pair<long long, long long>> v) {
        std::vector<uint8_t> b;
        for (const auto& [n, d] : v) { le(b, uint32_t(n), 4); le(b, uint32_t(d), 4); }
        return b;
    }
    static std::vector<uint8_t> doubles(const std::vector<double>& v) {
        std::vector<uint8_t> b;
        for (double x : v) { uint64_t u; std::memcpy(&u, &x, 8); le(b, u, 8); }
        return b;
    }
    static std::vector<uint8_t> text(const std::string& s) { std::vector<uint8_t> b(s.begin(), s.end()); b.push_back(0); return b; }
    /// big-endian GainMap opcodes (id 9), each {top, left, pitch, pointsV, pointsH, gains...} over the whole raw
    static std::vector<uint8_t> opcodes(const std::vector<std::array<int, 5>>& maps, const std::vector<std::vector<float>>& gains) {
        std::vector<uint8_t> b;
        auto be = [&b](uint64_t v, int n) { for (int i = n - 1; i >= 0; i--) b.push_back(uint8_t(v >> (8 * i))); };
        auto bed = [&be](double x) { uint64_t u; std::memcpy(&u, &x, 8); be(u, 8); };
        be(maps.size(), 4);
        for (size_t m = 0; m < maps.size(); m++) {
            const auto [top, left, pitch, pv, ph] = maps[m];
            be(9, 4); be(0x01030000, 4); be(0, 4); be(76 + 4 * gains[m].size(), 4);
            for (int v : {top, left, H, W, 0, 1, pitch, pitch, pv, ph}) be(uint32_t(v), 4);
            bed(1.0 / std::max(1, pv - 1)); bed(1.0 / std::max(1, ph - 1)); bed(0); bed(0);
            be(1, 4);
            for (float g : gains[m]) { uint32_t u; std::memcpy(&u, &g, 4); be(u, 4); }
        }
        return b;
    }

    /// the raw (every site value) and the base tags: RGGB, black 64, white 1023, orientation, Software, the exposure in the Exif IFD
    TestDng(int value, int orientation, const std::string& software) {
        put(ifd0, 0xFE, 4, 1, longs({0}));
        put(ifd0, 0x100, 4, 1, longs({W}));
        put(ifd0, 0x101, 4, 1, longs({H}));
        put(ifd0, 0x102, 3, 1, shorts({16}));
        put(ifd0, 0x103, 3, 1, shorts({1}));
        put(ifd0, 0x106, 3, 1, shorts({32803}));
        put(ifd0, 0x112, 3, 1, shorts({orientation}));
        put(ifd0, 0x115, 3, 1, shorts({1}));
        put(ifd0, 0x116, 4, 1, longs({H}));
        put(ifd0, 0x117, 4, 1, longs({W * H * 2}));
        if (!software.empty()) put(ifd0, 0x131, 2, uint32_t(software.size() + 1), text(software));
        put(ifd0, 0x828D, 3, 2, shorts({2, 2}));
        put(ifd0, 0x828E, 1, 4, {0, 1, 1, 2});
        put(ifd0, 0xC612, 1, 4, {1, 4, 0, 0});
        put(ifd0, 0xC61A, 3, 1, shorts({64}));
        put(ifd0, 0xC61D, 3, 1, shorts({1023}));
        put(ifd0, 0xC761, 12, 6, doubles({2e-4, 4e-7, 3e-4, 5e-7, 4e-4, 6e-7}));
        put(exif, 0x8827, 3, 1, shorts({50}));
        put(exif, 0x829A, 5, 1, rationals({{1, 254}}));
        put(exif, 0x829D, 5, 1, rationals({{227, 100}}));
        put(exif, 0x920A, 5, 1, rationals({{2248, 100}}));
        raw.assign(size_t(W) * H, uint16_t(value));
    }
    std::vector<uint16_t> raw;

    void colour() {
        std::vector<uint8_t> cm;
        for (std::pair<long long, long long> v : {std::pair<long long, long long>{9, 10}, {-3, 10}, {-1, 10}, {-4, 10}, {13, 10}, {1, 10}, {-5, 100}, {2, 10}, {6, 10}}) {
            le(cm, uint32_t(int32_t(v.first)), 4);
            le(cm, uint32_t(v.second), 4);
        }
        put(ifd0, 0xC621, 10, 9, cm);
        put(ifd0, 0xC65A, 3, 1, shorts({21}));
        put(ifd0, 0xC628, 5, 3, rationals({{1, 2}, {1, 1}, {7, 10}}));
    }

    std::vector<uint8_t> build() const {
        std::vector<uint8_t> out = {'I', 'I', 42, 0, 0, 0, 0, 0};
        const uint32_t strip = uint32_t(out.size());
        for (uint16_t v : raw) le(out, v, 2);
        auto write = [&out](std::vector<Entry> entries) {
            std::sort(entries.begin(), entries.end(), [](const Entry& a, const Entry& b) { return a.tag < b.tag; });
            std::vector<uint32_t> at(entries.size());
            for (size_t i = 0; i < entries.size(); i++) {
                if (entries[i].data.size() <= 4) continue;
                if (out.size() & 1) out.push_back(0);
                at[i] = uint32_t(out.size());
                out.insert(out.end(), entries[i].data.begin(), entries[i].data.end());
            }
            if (out.size() & 1) out.push_back(0);
            const uint32_t ifd = uint32_t(out.size());
            le(out, entries.size(), 2);
            for (size_t i = 0; i < entries.size(); i++) {
                le(out, entries[i].tag, 2);
                le(out, entries[i].type, 2);
                le(out, entries[i].count, 4);
                if (entries[i].data.size() <= 4) {
                    std::vector<uint8_t> field = entries[i].data;
                    field.resize(4, 0);
                    out.insert(out.end(), field.begin(), field.end());
                } else {
                    le(out, at[i], 4);
                }
            }
            le(out, 0, 4);
            return ifd;
        };
        const uint32_t exifAt = write(exif);
        std::vector<Entry> top = ifd0;
        top.push_back({0x111, 4, 1, longs({strip})});
        top.push_back({0x8769, 4, 1, longs({exifAt})});
        const uint32_t ifd0At = write(top);
        for (int i = 0; i < 4; i++) out[size_t(4 + i)] = uint8_t(ifd0At >> (8 * i));
        return out;
    }
};

/// DngCreator's lens shading: one map a 2x2 site (pitch 2), 3 x 2 points, a constant gain a site (R 2, G 1.5 / 1.25, B 3)
static std::vector<uint8_t> camera2Maps() {
    std::vector<std::vector<float>> g;
    for (float v : {2.f, 1.5f, 1.25f, 3.f}) g.push_back(std::vector<float>(6, v));
    return TestDng::opcodes({{0, 0, 2, 2, 3}, {0, 1, 2, 2, 3}, {1, 0, 2, 2, 3}, {1, 1, 2, 2, 3}}, g);
}

/// one GainMap of gain over every site (pitch 1, 2 x 2 points): no Camera2 map
static std::vector<uint8_t> flatMap(float gain) { return TestDng::opcodes({{0, 0, 1, 2, 2}}, {std::vector<float>(4, gain)}); }

int main() {
    // the record: the shot's Parameters field for field, its settings, dev lines, the merge's numbers, headroom
    {
        const Parameters p = shot();
        DevelopRecord r = record(p, 4.f, 1.f, false);
        CHECK(Develop::parameters(r, 4096, 3072).toJson() == p.toJson());
        NEAR(r.headroom(), 4.f, 0);
        CHECK(r.worker().toJson() == worker().toJson());
        CHECK(r.meta["build"].integer() == 665);
        Settings v = Develop::settings(r, {});
        CHECK(!v.getBoolean("pref_scam_hybrid_diagnostics", true));
        CHECK(!v.getBoolean("pref_keep_raw_burst", true));
        CHECK(!v.getBoolean("pref_scam_lab_keep", true));
        CHECK(!v.getBoolean("pref_debug_merge_stamp", true));
        CHECK(v.getString("pref_scam_hybrid_why_sharp_gain", "") == "1.25");
        CHECK(v.getBoolean("pref_scam_hybrid_denoise", false));
        CHECK(v.get("pref_some_int") && v.get("pref_some_int")->type == Pref::Type::Int && v.getInteger("pref_some_int", 0) == 3);
        CHECK(v.get("pref_some_float") && v.get("pref_some_float")->type == Pref::Type::Float && v.getFloat("pref_some_float", 0) == 0.1f);
        CHECK(v.get("pref_some_set") && v.get("pref_some_set")->set.size() == 2 && v.get("pref_some_set")->set[1] == "b \"q\"");
        CHECK(v.scamDevValue("hybrid_sun_bloom_no_short") && *v.scamDevValue("hybrid_sun_bloom_no_short") == 0.f);
        const Develop::Changes changes = Develop::changesFromJson("{\"pref_scam_hybrid_why_sharp_gain\":\"0.5\",\"pref_film_sim_stock\":null,"
                                                                  "\"pref_scam_hybrid_denoise\":false}");
        Settings c = Develop::settings(r, changes);
        CHECK(c.getString("pref_scam_hybrid_why_sharp_gain", "") == "0.5");
        CHECK(!c.contains("pref_film_sim_stock"));
        CHECK(!c.getBoolean("pref_scam_hybrid_denoise", true));
    }
    // a reduced grid scales only its size
    {
        DevelopRecord r = record(shot(), 1.f, 1.f, false);
        Parameters q = Develop::parameters(r, 1024, 768);
        CHECK(q.rawSize && *q.rawSize == (Point{1024, 768}));
        CHECK(q.sensorPix && q.sensorPix->right == 1024 && q.sensorPix->bottom == 768);
        CHECK(q.hybridFinalSize && *q.hybridFinalSize == (Point{512, 384}));
        NEAR(q.outputScale, .25f, 1e-6);
        Parameters a = shot();
        q.rawSize = a.rawSize;
        q.sensorPix = a.sensorPix;
        q.hybridFinalSize = a.hybridFinalSize;
        q.outputScale = a.outputScale;
        CHECK(q.toJson() == a.toJson());
    }
    // a Sabre 2x shot's final size is against the DNG's grid
    {
        Parameters p = shot();
        p.rawSize = Point{8192, 6144};
        p.sensorPix = Rect{0, 0, 8192, 6144};
        p.hybridFinalSize = Point{4096, 3072};
        p.outputScale = 2.f;
        const Parameters q = Develop::parameters(record(p, 1.f, 1.f, false), 4096, 3072);
        CHECK(!q.hybridFinalSize);
        NEAR(q.outputScale, 1.f, 1e-6);
    }
    // the maps: the shot's at its size; on a reduced grid the flags OR-ed, the frame map averaged
    {
        std::vector<uint8_t> flags(16);
        flags[0] = 1;
        flags[5] = 4;
        flags[15] = 2;
        CHECK(Develop::map(flags, 4, 4, 4, 4, true) == flags);
        CHECK(Develop::resampled(flags, 4, 4, 2, 2, true) == (std::vector<uint8_t>{5, 0, 0, 2}));
        const std::vector<uint8_t> frames = {10, 20, 30, 40, 10, 20, 30, 40, 50, 50, 0, 0, 50, 50, 0, 0};
        CHECK(Develop::resampled(frames, 4, 4, 2, 2, false) == (std::vector<uint8_t>{15, 35, 50, 0}));
        CHECK(!Develop::map({}, 4, 4, 4, 4, true));
        // the maps and the highlight mask through the file
        DevelopRecord r = DevelopRecord::make(shot().toJson(), prefs(), worker(), 1.f, 4, 4, 1.f, false, 1);
        r.clipFlags = flags;
        r.clipW = r.clipH = 4;
        r.frames = frames;
        r.framesW = r.framesH = 4;
        r.hlMask = {0x00, 0x3C, 0x00, 0x40, 0x00, 0x00, 0xFF, 0x7B};
        r.hlW = r.hlH = 2;
        const DevelopRecord b = throughTheFile(r);
        CHECK(b.clipFlags == flags && b.frames == frames && b.hlMask == r.hlMask && b.hlW == 2);
        const std::optional<MergeInfo::HlMask> m = Develop::hlMask(b, 4096, 4096);
        CHECK(m && m->halves == (std::vector<uint16_t>{0x3C00, 0x4000, 0x0000, 0x7BFF}));
        const std::optional<MergeInfo::HlMask> half = Develop::hlMask(b, 2048, 4096);
        CHECK(half && half->width == 1 && half->height == 1);
    }
    // the crops after the pipeline
    {
        DevelopRecord r = record(shot(), 1.f, 2.f, true);
        NEAR(DevelopRecord::numberOf(r.meta["crop"]["zoom"], 0), 2.0, 0);
        CHECK(DevelopRecord::boolOf(r.meta["crop"]["isz4x3"], false));
        CHECK(DevelopRecord::numberOf(record(shot(), 1.f, NAN, false).meta["crop"]["zoom"], 0) == 1.f);
        PostOutput photo;
        photo.width = 400;
        photo.height = 300;
        photo.rgba.assign(size_t(400) * 300 * 4, 7);
        Develop::crops(r, photo);
        CHECK(photo.width == 200 && photo.height == 150 && photo.rgba.size() == size_t(200) * 150 * 4);
    }
    // not a record: no footer, a later version
    {
        const DevelopRecord::Codec c = zlibCodec();
        const std::vector<uint8_t> plain(64, 1);
        CHECK(!DevelopRecord::read(plain.data(), plain.size(), c));
        DevelopRecord r = DevelopRecord::make("{}", prefs(), worker(), 1.f, 4, 4, 1.f, false, 1);
        r.metaText = "{\"v\":2}";
        const std::vector<uint8_t> t = r.appendix(c);
        CHECK(!DevelopRecord::read(t.data(), t.size(), c));
    }
    // P696: the record of a DNG without one, made from its tags (DevelopDefaultsTest)
    {
        auto facts = [] {
            DevelopDefaults::Facts f;
            f.width = 4080;
            f.height = 3072;
            f.neutral = {.484375f, 1.f, .6416016f};
            f.cameraToXyzD50 = std::vector<float>{1.01f, .254f, .344f, .253f, .837f, .063f, .035f, -.499f, 2.04f};
            f.sceneCct = 5825.f;
            f.noiseProfile = std::vector<double>{2e-4, 4e-7, 3e-4, 5e-7, 4e-4, 6e-7};
            f.iso = 50;
            f.exposureTime = 1 / 254.0;
            f.fNumber = 2.27f;
            f.focalMm = 22.48f;
            f.rotationDeg = 90;
            f.headroom = 2.f;
            f.whiteLevel = 65535;
            f.blackLevel = 4100.f;
            f.software = "SCAMERA 0.98 (31254) 5b8d8d04";
            f.shadingW = 3;
            f.shadingH = 2;
            std::vector<float> map(4 * 6);
            for (size_t i = 0; i < map.size(); i++) map[i] = 1.f + float(i) * .01f;
            f.shadingMap = map;
            return f;
        };
        const Settings none;
        // the Parameters are the DNG's tags
        {
            const DevelopDefaults::Facts f = facts();
            const Parameters p = DevelopDefaults::parameters(f, none);
            CHECK(p.rawSize && *p.rawSize == (Point{4080, 3072}));
            CHECK(p.sensorPix && p.sensorPix->left == 0 && p.sensorPix->top == 0 && p.sensorPix->right == 4080 && p.sensorPix->bottom == 3072);
            CHECK(p.whitePoint && *p.whitePoint == f.neutral);
            namespace Conv = ShotColour::Conv;
            ShotColour::F9 cam{};
            for (size_t i = 0; i < 9; i++) cam[i] = (*f.cameraToXyzD50)[i];
            const ShotColour::F9 want = Conv::multiply(Conv::sXYZtoProPhoto, cam), srgb = Conv::multiply(Conv::sXYZtoSRGB, Conv::sProPhotoToXYZ);
            for (size_t i = 0; i < 9; i++) {
                NEAR((*p.sensorToProPhoto)[i], want[i], 1e-6);
                NEAR((*p.proPhotoToSRGB)[i], srgb[i], 1e-6);
                NEAR(p.CCT->matrix[i], srgb[i], 1e-6);
            }
            CHECK(p.colourSource == "DNG_FM");
            CHECK(p.sceneCct == 5825.f && p.iso == 50 && p.aperture == 2.27f && p.focalLength == 22.48f && p.cameraRotation == 90);
            NEAR(p.exposureTime, 1 / 254.0, 1e-12);
            CHECK(p.outputScale == 1.f && !p.hybridFinalSize && p.multiFrameCount == 1);
            CHECK(p.blackLevel && *p.blackLevel == std::vector<float>(4, 4100.f) && p.whiteLevel == 65535);
            // the noise of the RGB the pipeline takes: the DNG's level times the headroom (S x 2, O x 4), one frame
            for (size_t c = 0; c < 3; c++) {
                NEAR(p.noiseModeler->baseModel[c].first, (*f.noiseProfile)[2 * c] * 2, 1e-12);
                NEAR(p.noiseModeler->baseModel[c].second, (*f.noiseProfile)[2 * c + 1] * 4, 1e-15);
                CHECK(p.noiseModeler->computeModel[c] == p.noiseModeler->baseModel[c]);
            }
            // the DNG's lens-shading map
            CHECK(p.mapSize && *p.mapSize == (Point{3, 2}) && p.gainMap && *p.gainMap == *f.shadingMap);
        }
        // without matrices, noise or shading the defaults stand
        {
            DevelopDefaults::Facts f;
            f.width = 64;
            f.height = 48;
            f.neutral = {.5f, 1.f, .8f};
            f.rotationDeg = 270;
            const Parameters p = DevelopDefaults::parameters(f, none);
            const std::vector<float> wb = {2.f, 0, 0, 0, 1.f, 0, 0, 0, 1.25f};
            for (size_t i = 0; i < 9; i++) NEAR((*p.sensorToProPhoto)[i], wb[i], 1e-6);
            CHECK(*p.proPhotoToSRGB == (std::vector<float>{1, 0, 0, 0, 1, 0, 0, 0, 1}));
            CHECK(p.colourSource == "IDENTITY_FALLBACK");
            CHECK(p.iso == 100);
            for (size_t c = 0; c < 3; c++) {
                CHECK(p.noiseModeler->baseModel[c].first > 0 && std::isfinite(p.noiseModeler->baseModel[c].first));
                CHECK(p.noiseModeler->computeModel[c].second > 0);
            }
            CHECK(p.gainMap && p.gainMap->size() == size_t(4 * p.mapSize->x * p.mapSize->y));
            for (float v : *p.gainMap) CHECK(v == 1.f);
            CHECK(p.cameraRotation == 270);
        }
        // the record reads back as the develop's and says where it came from
        {
            const DevelopDefaults::Facts f = facts();
            Settings s;
            s.prefs["pref_scam_hybrid_why_sharp_gain"] = Pref::string("1.6");
            s.prefs["pref_scam_hybrid_denoise"] = Pref::boolean(false);
            s.dev["hybrid_sun_bloom_no_short"] = 0.f;
            const DevelopRecord r = throughTheFile(DevelopDefaults::record(f, s, 696));
            CHECK(DevelopDefaults::fromTags(&r));
            CHECK(r.meta["software"].text() == f.software);
            NEAR(r.headroom(), 2.f, 0);
            // the develop's Parameters at the DNG's grid are the ones made from the tags, field for field
            CHECK(Develop::parameters(r, 4080, 3072).toJson() == DevelopDefaults::parameters(f, s).toJson());
            const Settings v = Develop::settings(r, {});
            CHECK(v.getString("pref_scam_hybrid_why_sharp_gain", "") == "1.6");
            CHECK(!v.getBoolean("pref_scam_hybrid_denoise", true));
            CHECK(!v.getBoolean("pref_scam_hybrid_diagnostics", true));
            CHECK(v.scamDevValue("hybrid_sun_bloom_no_short") && *v.scamDevValue("hybrid_sun_bloom_no_short") == 0.f);
            // one frame's merge numbers, no maps, no crop
            const DevelopRecord::Worker w = r.worker();
            CHECK(!w.bentoApplied && w.normals == 1 && w.noiseFactor == 1.f && std::isnan(w.effectiveMedian));
            CHECK(r.clipFlags.empty() && r.frames.empty() && r.hlMask.empty());
            CHECK(DevelopRecord::numberOf(r.meta["crop"]["zoom"], 0) == 1.f && !DevelopRecord::boolOf(r.meta["crop"]["isz4x3"], true));
        }
        // a camera's record is not from tags
        {
            const DevelopRecord r = record(shot(), 4.f, 1.f, false);
            CHECK(!DevelopDefaults::fromTags(&r));
            CHECK(!DevelopDefaults::fromTags(nullptr));
        }
    }
    // the developer's demosaics (EditDevelopTest)
    {
        using namespace scam_edit;
        CHECK(develop::colour(DngRaw::RGGB, 0, 0) == 0 && develop::colour(DngRaw::RGGB, 1, 1) == 2);
        CHECK(develop::colour(DngRaw::GRBG, 1, 0) == 0 && develop::colour(DngRaw::GRBG, 0, 1) == 2);
        CHECK(develop::colour(DngRaw::GBRG, 1, 0) == 2 && develop::colour(DngRaw::GBRG, 0, 1) == 0);
        CHECK(develop::colour(DngRaw::BGGR, 0, 0) == 2 && develop::colour(DngRaw::BGGR, 1, 1) == 0 && develop::colour(DngRaw::BGGR, 1, 0) == 1);
        auto mosaic = [](int w, int h, int phase, const std::function<std::array<float, 3>(int, int)>& rgb) {
            std::vector<float> m(size_t(w) * h);
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++) m[size_t(y) * w + x] = rgb(x, y)[size_t(develop::colour(phase, x, y))];
            return m;
        };
        for (int phase = 0; phase < 4; phase++) {
            const std::vector<float> m = mosaic(8, 6, phase, [](int x, int) { return std::array<float, 3>{.2f, .3f + (x & 1) * .02f, .1f}; });
            const std::vector<float> rgb = develop::superpixel(m, 8, 6, phase, 4.f);
            CHECK(rgb.size() == 36);
            for (size_t i = 0; i < rgb.size(); i += 3) {
                NEAR(rgb[i], .8f, 1e-6);
                NEAR(rgb[i + 1], (.3f + .32f) / 2 * 4.f, 1e-6);
                NEAR(rgb[i + 2], .4f, 1e-6);
            }
            const int w = 24, h = 18;
            auto field = [](int x, int y) {
                return std::array<float, 3>{.1f + .01f * x + .005f * y, .2f + .004f * x + .007f * y, .3f - .003f * x + .002f * y};
            };
            const std::vector<uint8_t> out = develop::mhc(mosaic(w, h, phase, field), w, h, phase, 2.f, false);
            const float* f = reinterpret_cast<const float*>(out.data());
            for (int y = 2; y < h - 2; y++)
                for (int x = 2; x < w - 2; x++)
                    for (int c = 0; c < 3; c++) NEAR(f[(size_t(y) * w + x) * 3 + c], field(x, y)[size_t(c)] * 2.f, 1e-5);
            const std::vector<uint8_t> flat = develop::mhc(mosaic(w, h, phase, [](int, int) { return std::array<float, 3>{.25f, .5f, .125f}; }),
                                                           w, h, phase, 1.f, false);
            const float* g = reinterpret_cast<const float*>(flat.data());
            for (int i = 0; i < w * h; i++) {
                NEAR(g[3 * i], .25f, 1e-6);
                NEAR(g[3 * i + 1], .5f, 1e-6);
                NEAR(g[3 * i + 2], .125f, 1e-6);
            }
        }
        CHECK(develop::toHalf(1.f) == 0x3C00 && develop::toHalf(0.f) == 0 && develop::toHalf(1.f / 3.f) == 0x3555);
        CHECK(develop::toHalf(65504.f) == 0x7BFF && develop::toHalf(1e6f) == 0x7C00 && develop::toHalf(5.96e-8f) == 0x0001);
        CHECK(develop::toHalf(10.f) == 0x4900);
        const std::vector<uint8_t> half = develop::mhc(mosaic(8, 8, DngRaw::RGGB, [](int, int) { return std::array<float, 3>{.25f, .5f, 3.f}; }),
                                                       8, 8, DngRaw::RGGB, 2.f, true);
        const uint16_t* hv = reinterpret_cast<const uint16_t*>(half.data());
        CHECK(hv[0] == develop::toHalf(.5f) && hv[1] == develop::toHalf(1.f) && hv[2] == develop::toHalf(6.f));
        CHECK(develop::binFor(4096, 3072) == 1 && develop::binFor(8160, 6144) == 2 && develop::binFor(16320, 12288) == 4
              && develop::binFor(1000, 800) == 1);
    }
    // P165: the merged DNG's arithmetic (DngMetadataTest, ShotExifTest)
    {
        using namespace dng;
        const std::string F = "HYBRID MERGE FACTORS: 1:0.32 2:0.30 3:0.33 4:0.33 5:0.29 6:0.54 7:0.51 8:0.54 9:0.58 10:0.57 11:0.00 12:0.32  average=0.386570";
        NEAR(DngMetadata::mergeFrames("HYBRID OUTPUT: Sabre 2x grid 8192x6144\n" + F + "\nHYBRID EFFECTIVE MAP: median frames=4.2\n"), 1 + 12 * 0.386570, 1e-9);
        NEAR(DngMetadata::mergeFrames("HYBRID MERGE FACTORS: 1:0.32 2:0.30 7:0.50"), 1 + 0.32 + 0.30 + 0.5, 1e-9);
        NEAR(DngMetadata::mergeFrames("HYBRID MERGE FACTORS: 1:1.70 2:-0.20"), 2, 1e-9);
        NEAR(DngMetadata::mergeFrames("HYBRID MERGE FACTORS:\nSCAM CAPTURE OK\n"), 1, 0);
        CHECK(std::isnan(DngMetadata::mergeFrames("")));
        CHECK(std::isnan(DngMetadata::mergeFrames("HYBRID EFFECTIVE MAP: median frames=71.629272 code scale=0.893489\n")));
        const std::string previous = "SCAMERA: neural inference job\nPREVIOUS ATTEMPT:\n" + F + "\nWORKER EXIT: signal 9\nRETRY:\n";
        CHECK(std::isnan(DngMetadata::mergeFrames(previous + "HYBRID DNG: merged Bayer 8192x6144\n")));
        NEAR(DngMetadata::mergeFrames(previous + "HYBRID MERGE FACTORS: 1:0.50  average=0.500000\n"), 1.5, 1e-9);
        NEAR(DngMetadata::mergeFrames(F + "\nHYBRID DNG: merged Bayer 4096x3072\nHYBRID MERGE FACTORS: 1:0.20 2:0.30  average=0.250000\n"), 1.5, 1e-9);
        const std::string split = "HYBRID MOSAIC: binned alignment 210 ms; merging 8 sub-frames on their 2x grid -> 8192x6144\n"
                                  "HYBRID OUTPUT: Sabre 2x grid 8192x6144 (kernel in sensor px)\n"
                                  "HYBRID MERGE FACTORS: 1:0.90 2:0.90 3:0.90 4:0.50 5:0.50 6:0.50 7:0.50  average=0.671429\n";
        NEAR(DngMetadata::mergeFrames(split), (1 + 7 * 0.671429) / 4, 1e-9);
        NEAR(DngMetadata::mergeFrames(split + "HYBRID MERGE FACTORS: 1:0.40  average=0.400000\n"), 1.4, 1e-9);
        const auto np = DngMetadata::noiseProfile({2e-4, 4e-7, 1.5e-4, 3e-7, 2.5e-4, 5e-7}, 0.8, 4, 5, 1);
        NEAR(np[2], 0.8 * 1.5e-4 / 20, 1e-18);
        NEAR(np[3], 0.8 * 3e-7 / 80, 1e-20);
        CHECK(ShotExif::iso16(102400) == 65535);
        auto e = ShotExif::exposureRational(1 / 852.0);
        CHECK(e && (*e)[0] == 1 && (*e)[1] == 852);
        e = ShotExif::exposureRational(0.3);
        CHECK(e && (*e)[0] == 300000 && (*e)[1] == 1000000);
        e = ShotExif::exposureRational(30);
        CHECK(e && (*e)[0] == 30 && (*e)[1] == 1);
        CHECK(!ShotExif::exposureRational(0) && !ShotExif::exposureRational(NAN));
        auto r = ShotExif::rational(ShotExif::apex(1.69), 1000);
        CHECK(r && (*r)[0] == 1514);
        CHECK(ShotExif::focal35(6.81, 9.6, 7.2, 1) == 25 && ShotExif::focal35(6.81, 9.6, 7.2, 2) == 49 && ShotExif::focal35(6.81, 9.6, 7.2, 0) == 0);
        CHECK(ShotExif::lensModel("vivo X200 Ultra", "back", 9.12, 1.69) == "vivo X200 Ultra back camera 9.12mm f/1.69");
        CHECK(ShotExif::lensModel("vivo X200 Ultra", "front", 4.5, 2.0) == "vivo X200 Ultra front camera 4.5mm f/2");
        CHECK(ShotExif::lensModel("vivo X200 Ultra", "", NAN, NAN) == "vivo X200 Ultra camera");
        CHECK(ShotExif::uniqueCameraModel("vivo", "V2454A", 3) == "vivo V2454A camera 3");
    }
    // P696 / P706: a DNG without the record, read by the editor (DngRaw: the opcode lists by the specification, Software, NoiseProfile,
    // the Exif exposure, the Camera2 shading map; EditDevelop: refusal, facts) and the developer's decode of its GainMaps
    {
        using scam_edit::DngRaw;
        namespace dev = scam_edit::develop;
        const float plain = 300.f / 959.f;
        auto at = [](const DngRaw::Image& img, int x, int y) { return img.linear[size_t(y) * img.width + x]; };
        // ours (Software SCAMERA, with spaces round it), OpcodeList2 = the Camera2 map, BaselineExposure 1 (headroom 2), rotated 90
        TestDng t(364, 6, "  SCAMERA 9.9 (99) abc ");
        t.put(t.ifd0, 0xC62A, 10, 1, TestDng::rationals({{1, 1}}));
        const std::vector<uint8_t> ops = camera2Maps();
        t.put(t.ifd0, 0xC741, 7, uint32_t(ops.size()), ops);
        const std::vector<uint8_t> file = t.build();
        const DngRaw::Info info = DngRaw::probe(file.data(), file.size());
        CHECK(info.software == "SCAMERA 9.9 (99) abc" && dev::ours(info));
        CHECK(info.noiseProfile && info.noiseProfile->size() == 6 && (*info.noiseProfile)[3] == 5e-7);
        CHECK(info.iso == 50 && info.fNumber == 2.27 && info.focalLength == 22.48);
        NEAR(info.exposureTime, 1 / 254.0, 1e-15);
        CHECK(!info.asShotGiven && info.whiteLevel == 1023 && info.blackLevel == 64 && info.gainMap);
        CHECK(info.shadingMap && info.shadingW == 3 && info.shadingH == 2 && info.shadingMap->size() == 24);
        if (info.shadingMap)
            for (int i = 0; i < 6; i++)
                CHECK((*info.shadingMap)[size_t(4 * i)] == 2.f && (*info.shadingMap)[size_t(4 * i + 1)] == 1.5f
                      && (*info.shadingMap)[size_t(4 * i + 2)] == 1.25f && (*info.shadingMap)[size_t(4 * i + 3)] == 3.f);
        // the editor's decode applies OpcodeList2 (read as OpcodeList1 before P706: never applied); the developer leaves it to the
        // pipeline, with a record and from the tags alike (the map is the record's)
        const DngRaw::Image edit = DngRaw::decodeLinear(file.data(), file.size(), 1);
        NEAR(at(edit, 0, 0), plain * 2, 1e-6);
        NEAR(at(edit, 1, 0), plain * 1.5, 1e-6);
        NEAR(at(edit, 0, 1), plain * 1.25, 1e-6);
        NEAR(at(edit, 1, 1), plain * 3, 1e-6);
        for (bool fromRecord : {true, false}) {
            const DngRaw::Image d = DngRaw::decodeForDevelop(file.data(), file.size(), 1, fromRecord);
            CHECK(!d.info.gainMap);
            for (float v : d.linear) NEAR(v, plain, 1e-6);
        }
        CHECK(!dev::refusal(info));
        const DevelopDefaults::Facts f = dev::facts(info);
        CHECK(f.width == 8 && f.height == 6 && f.rotationDeg == 90 && f.headroom == 2.f && f.iso == 50 && f.whiteLevel == 1023 && f.blackLevel == 64.f);
        CHECK(f.fNumber == 2.27f && f.focalMm == 22.48f && f.software == info.software && !f.cameraToXyzD50);
        CHECK(f.neutral == (std::vector<float>{1.f, 1.f, 1.f}) && f.noiseProfile == info.noiseProfile);
        CHECK(f.shadingMap == info.shadingMap && f.shadingW == 3 && f.shadingH == 2);
        // its record: from the tags, the DNG's map as the shot's lens shading
        Settings now;
        now.prefs["pref_scam_hybrid_why_sharp_gain"] = Pref::string("1.4");
        const DevelopRecord r = throughTheFile(DevelopDefaults::record(f, now, 696));
        CHECK(DevelopDefaults::fromTags(&r) && r.meta["software"].text() == "SCAMERA 9.9 (99) abc");
        NEAR(r.headroom(), 2.f, 0);
        const Parameters rp = Develop::parameters(r, 8, 6);
        CHECK(rp.toJson() == DevelopDefaults::parameters(f, now).toJson());
        CHECK(rp.mapSize && *rp.mapSize == (Point{3, 2}) && rp.gainMap && *rp.gainMap == *info.shadingMap && rp.cameraRotation == 90);
        CHECK(Develop::settings(r, {}).getString("pref_scam_hybrid_why_sharp_gain", "") == "1.4");
    }
    {
        using scam_edit::DngRaw;
        namespace dev = scam_edit::develop;
        const float plain = 300.f / 959.f;
        // another app's DNG: developed only with its colour matrix and as-shot white; its BaselineExposure is no headroom
        TestDng t(364, 1, "Other Camera 1.0");
        t.put(t.ifd0, 0xC62A, 10, 1, TestDng::rationals({{1, 1}}));
        std::vector<uint8_t> file = t.build();
        DngRaw::Info info = DngRaw::probe(file.data(), file.size());
        CHECK(!dev::ours(info) && dev::refusal(info) && dev::refusal(info)->find("colour matrix") != std::string::npos);
        t.colour();
        file = t.build();
        info = DngRaw::probe(file.data(), file.size());
        CHECK(info.asShotGiven && info.colour.hasMatrices() && !dev::refusal(info));
        const DevelopDefaults::Facts f = dev::facts(info);
        CHECK(f.headroom == 1.f && f.rotationDeg == 0 && f.cameraToXyzD50 && f.cameraToXyzD50->size() == 9 && !f.shadingMap);
        NEAR(f.neutral[0], .5f, 1e-7);
        NEAR(f.neutral[2], .7f, 1e-7);
        CHECK(f.sceneCct > 1000.f && f.sceneCct < 50000.f);
        CHECK(DevelopDefaults::parameters(f, Settings()).colourSource == "DNG_FM");
        // a mirrored orientation, a missing Software: refused / not ours
        TestDng m(364, 2, "SCAMERA 1");
        info = DngRaw::probe(m.build().data(), m.build().size());
        CHECK(dev::refusal(info) && dev::refusal(info)->find("mirrored") != std::string::npos);
        TestDng none(364, 8, "");
        info = DngRaw::probe(none.build().data(), none.build().size());
        CHECK(info.software.empty() && !dev::ours(info) && dev::refusal(info) && dev::rotation(8) == 270);
        // OpcodeList2 maps that are no Camera2 map: applied by the developer from the tags (the pipeline has none), not with a record
        TestDng one(364, 1, "SCAMERA 1");
        const std::vector<uint8_t> flat = flatMap(2.f);
        one.put(one.ifd0, 0xC741, 7, uint32_t(flat.size()), flat);
        file = one.build();
        info = DngRaw::probe(file.data(), file.size());
        CHECK(info.gainMap && !info.shadingMap);
        const DngRaw::Image tags = DngRaw::decodeForDevelop(file.data(), file.size(), 1, false);
        CHECK(tags.info.gainMap);
        for (float v : tags.linear) NEAR(v, plain * 2, 1e-6);
        const DngRaw::Image rec = DngRaw::decodeForDevelop(file.data(), file.size(), 1, true);
        CHECK(!rec.info.gainMap);
        for (float v : rec.linear) NEAR(v, plain, 1e-6);
        // OpcodeList1 (0xC740, read as OpcodeList2 before P706): applied by every decode (the record path: unless the shot's
        // Parameters carry the map, as before); with it the OpcodeList2 maps are no Camera2 map
        TestDng l1(364, 1, "SCAMERA 1");
        const std::vector<uint8_t> c2 = camera2Maps();
        l1.put(l1.ifd0, 0xC740, 7, uint32_t(flat.size()), flat);
        l1.put(l1.ifd0, 0xC741, 7, uint32_t(c2.size()), c2);
        file = l1.build();
        info = DngRaw::probe(file.data(), file.size());
        CHECK(info.gainMap && !info.shadingMap);
        const DngRaw::Image both = DngRaw::decode(file.data(), file.size(), 1);
        NEAR(float(both.data[0]) / DngRaw::FIXED_ONE, plain * 2 * 2, 2e-4);
        const DngRaw::Image recordL1 = DngRaw::decodeForDevelop(file.data(), file.size(), 1, true);
        for (float v : recordL1.linear) NEAR(v, plain * 2, 1e-6);
        const DngRaw::Image recordNone = DngRaw::decodeForDevelop(file.data(), file.size(), 1, true, false);
        CHECK(!recordNone.info.gainMap);
        for (float v : recordNone.linear) NEAR(v, plain, 1e-6);
        const DngRaw::Image tagsBoth = DngRaw::decodeForDevelop(file.data(), file.size(), 1, false);
        NEAR(tagsBoth.linear[0], plain * 2 * 2, 1e-6);
        NEAR(tagsBoth.linear[1], plain * 2 * 1.5, 1e-6);
    }
    std::printf(failures ? "develop_check: %d failure(s)\n" : "develop_check: all passed\n", failures);
    return failures ? 1 : 0;
}
