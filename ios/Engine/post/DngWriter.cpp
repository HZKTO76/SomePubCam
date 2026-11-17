// The iPhone's DNG writer: Android's library dngCreator (app/src/main/cpp/dngCreator.cpp, class scamdng::DngFile) without its JNI
// part, over the same tiny_dng_writer (app/src/main/cpp/deps) - the same setters, order and layout, so the same inputs give the
// same file. The class body is dngCreator.cpp's as is; its log lines go to dngLog(). The Linear DNG (dngCreator.cpp's linear
// DngFile, layoutLinear, nLinearHeadroom / nLinearStrip / nLinearCompress) with DngCreator.writeLinearBuffer's strip loop
// (processing/DngCreator.java) is buildLinear: the file in memory instead of a seekable file, the same bytes.
#include "DngWriter.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <future>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>
#define TINY_DNG_WRITER_IMPLEMENTATION
#include "deps/tiny_dng_writer.h"

namespace scam_post {
namespace dng {

namespace {
void logf(const char *level, const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    dngLog()(std::string("ScamDng ") + level + ": " + buf);
}
}  // namespace

#define DNG_INFO(...) logf("D", __VA_ARGS__)
#define DNG_FAIL(...) logf("E", __VA_ARGS__)

namespace tdw = tinydngwriter;

/** The 3x3 matrices a file may carry, in the order their tags are written. */
enum Matrix { kColour1, kColour2, kForward1, kForward2, kCalibration1, kCalibration2, kMatrixCount };

/** Colour (0 R, 1 G, 2 B) of the 2x2 sites (y * 2 + x) for Camera2's CFA arrangement 0 RGGB, 1 GRBG, 2 GBRG, 3 BGGR. */
constexpr unsigned char kSiteColour[4][4] = {{0, 1, 1, 2}, {1, 0, 2, 1}, {1, 2, 0, 1}, {2, 1, 1, 0}};
/**
 * The 2x2 site of each lens-shading channel (Camera2 order R, G on the even row, G on the odd row, B) per arrangement:
 * the GainMap of channel k is anchored on that site.
 */
constexpr unsigned char kShadingSite[4][4] = {{0, 1, 2, 3}, {1, 0, 3, 2}, {2, 0, 3, 1}, {3, 1, 2, 0}};

/** A matrix worth writing (P280): every entry finite and not all of them zero (zero = never set by the camera). */
bool writable(const std::array<double, 9> &m) {
    double magnitude = 0;
    for (double v : m) {
        if (!std::isfinite(v)) return false;
        magnitude += std::fabs(v);
    }
    return magnitude > 1e-9;
}

struct DngFile::Impl {
    explicit Impl(bool linear) : image_(new tdw::DNGImage()), linear_(linear) {
        image_->SetSubfileType(false, false, false);
        image_->SetBigEndian(false);
        image_->SetSamplesPerPixel(linear ? 3 : 1);
        image_->SetPhotometric(linear ? tdw::PHOTOMETRIC_LINEARRAW : tdw::PHOTOMETRIC_CFA);
        image_->SetPlanarConfig(tdw::PLANARCONFIG_CONTIG);
        image_->SetDNGVersion(1, 3, 0, 0);
        if (linear) {
            const unsigned char backward[] = {1, 3, 0, 0};
            setTag(0, tdw::TIFFTAG_DNG_BACKWARD_VERSION, tdw::TIFF_BYTE, 4, backward);
        }
        // P618: ExifVersion 2.31 (the version with OffsetTime*) in the Exif IFD, where it belongs
        image_->SetTag(1, tdw::EXIFTAG_EXIFVERSION, tdw::TIFF_UNDEFINED, 4, "0231");
    }

    // --- what goes straight to the image, in the caller's order ---
    void setUniqueCameraModel(const std::string &s) { image_->SetUniqueCameraModel(s); }
    void setDescription(const std::string &s) { image_->SetImageDescription(s); }
    void setSoftware(const std::string &s) { image_->SetSoftware(s); }
    void setMake(const std::string &s) { image_->SetMake(s); }
    void setModel(const std::string &s) { image_->SetModel(s); }
    void setDateTime(const std::string &s) { image_->SetDateTime(s); }
    void setIso(unsigned short v) { image_->SetIso(v); }
    void setExposureTime(double seconds) { image_->SetExposureTime(seconds); }
    void setAperture(double fNumber) { image_->SetAperture(fNumber); }
    void setFocalLength(double mm) { image_->SetFocalLength(mm); }
    void setNoiseProfile(const double *pairs, int count) { image_->SetNoiseProfile(static_cast<unsigned int>(count / 2), pairs); }

    /** P618: one more tag of IFD 0 (ifd 0) or the Exif IFD (ifd 1), values in host order; false (logged) when refused. */
    bool setTag(int ifd, unsigned short tag, unsigned short type, unsigned int count, const void *values) {
        if (image_->SetTag(ifd, tag, type, count, values)) return true;
        DNG_FAIL("tag %u of IFD %d (type %u x %u) refused: %s", tag, ifd, type, count, image_->Error().c_str());
        return false;
    }

    // --- what the layout uses when the file is built ---
    void setOrientation(int v) { orientation_ = v; }
    void setWhiteLevel(double v) { white_ = v; }
    void setBlackLevel(const unsigned short *v) { std::copy(v, v + 4, black_.begin()); }
    void setCompression(bool lossless) { lossless_ = lossless; }
    void setBaselineExposure(double ev) { baselineEv_ = ev; }
    void setCalibrationIlluminant1(unsigned short v) { illuminant_[0] = v; }
    void setCalibrationIlluminant2(unsigned short v) { illuminant_[1] = v; }
    void setColorMatrix1(const double *m) { keep(kColour1, m); }
    void setColorMatrix2(const double *m) { keep(kColour2, m); }
    void setForwardMatrix1(const double *m) { keep(kForward1, m); }
    void setForwardMatrix2(const double *m) { keep(kForward2, m); }
    void setCameraCalibration1(const double *m) { keep(kCalibration1, m); }
    void setCameraCalibration2(const double *m) { keep(kCalibration2, m); }
    void setAsShotNeutral(const double *rgb) {
        std::copy(rgb, rgb + 3, neutral_.begin());
        neutralSet_ = true;
    }

    /** Camera2's CFA arrangement; an unknown value is written as RGGB but places no GainMap. */
    void setCFAPattern(int arrangement) {
        arrangement_ = arrangement;
        const int row = arrangement >= 0 && arrangement < 4 ? arrangement : 0;
        std::copy(kSiteColour[row], kSiteColour[row] + 4, siteColour_.begin());
    }

    /** P318: colour block of the stored mosaic (2 Quad, 4 Tetra, else Bayer); before setGainMap, which places its maps by it. */
    void setMosaicBlock(int block) {
        block_ = block == 2 || block == 4 ? block : 1;
        if (gainMapPlaced_ && block_ > 1) DNG_FAIL("block %d after the GainMap: the maps stay on the Bayer grid", block_);
    }
    int mosaicBlock() const { return block_; }

    /** P618: DefaultCropOrigin / Size in the stored image's pixels; a non-positive size (or a negative origin) clears it. */
    void setDefaultCrop(int x, int y, int w, int h) {
        if (x >= 0 && y >= 0 && w > 0 && h > 0) crop_ = {unsigned(x), unsigned(y), unsigned(w), unsigned(h)};
        else crop_ = {0, 0, 0, 0};
    }

    /**
     * The lens-shading map, Camera2 layout (w x h points, 4 interleaved channels), over the stored area (xmin, ymin) ..
     * (xmax, ymax): one GainMap per channel on its 2x2 site, or per channel and site of a b x b colour block (pitch 2b).
     */
    void setGainMap(const float *interleaved, int xmin, int ymin, int xmax, int ymax, int w, int h) {
        const size_t points = static_cast<size_t>(w) * static_cast<size_t>(h);
        const bool known = arrangement_ >= 0 && arrangement_ < 4;
        std::vector<float> plane(points);
        std::vector<tdw::GainMap> maps;
        if (linear_) {
            // Linear DNG: one map a colour plane (R, the mean of the two greens, B) over every pixel
            for (unsigned channel = 0; channel < 3; ++channel) {
                for (size_t p = 0; p < points; ++p)
                    plane[p] = channel == 1 ? (interleaved[4 * p + 1] + interleaved[4 * p + 2]) * .5f
                                            : interleaved[4 * p + (channel == 0 ? 0 : 3)];
                tdw::GainMap map(plane.data(), w, h, xmin, ymin, xmax, ymax, 1);
                map.plane = channel;
                maps.push_back(std::move(map));
            }
            image_->SetGainMap(maps);
            gainMapPlaced_ = true;
            return;
        }
        for (int channel = 0; channel < 4; ++channel) {
            for (size_t p = 0; p < points; ++p) plane[p] = interleaved[4 * p + channel];
            tdw::GainMap map(plane.data(), w, h, xmin, ymin, xmax, ymax);
            if (known) {
                const unsigned site = kShadingSite[arrangement_][channel];
                map.top = site >> 1;
                map.left = site & 1;
            }
            // P205: Bottom / Right are exclusive bounds of the area
            map.bottom = static_cast<unsigned>(ymax - ymin);
            map.right = static_cast<unsigned>(xmax - xmin);
            for (int sy = 0; sy < block_; ++sy)
                for (int sx = 0; sx < block_; ++sx) {
                    tdw::GainMap onSite = map;
                    if (block_ > 1) {
                        onSite.top = map.top * block_ + sy;
                        onSite.left = map.left * block_ + sx;
                        onSite.row_pitch = onSite.col_pitch = 2 * block_;
                    }
                    maps.push_back(onSite);
                }
        }
        image_->SetGainMap(maps);
        gainMapPlaced_ = true;
    }

    /** The whole file for a w x h 16-bit mosaic (malloc'ed; the caller frees it), nullptr on failure. */
    void *createDng(void *mosaic, int w, int h, size_t &size) {
        tdw::DNGWriter writer(false);
        const unsigned short bitsPerSample = 16;
        const unsigned int width = static_cast<unsigned>(w), height = static_cast<unsigned>(h);
        image_->SetBitsPerSample(1, &bitsPerSample);
        image_->SetOrientation(static_cast<unsigned short>(orientation_));
        image_->SetImageWidth(width);
        image_->SetImageLength(height);
        image_->SetRowsPerStrip(height);
        const unsigned int active[4] = {0, 0, height, width};
        image_->SetActiveArea(active);
        image_->SetResolutionUnit(tdw::RESUNIT_INCH);
        image_->SetXResolution(72.f);
        image_->SetYResolution(72.f);

        // P318: the 2x2 order repeated over the colour blocks (2x2 Bayer, 4x4 Quad, 8x8 Tetra)
        const int period = 2 * block_;
        unsigned char cfa[64];
        for (int y = 0; y < period; ++y)
            for (int x = 0; x < period; ++x) cfa[y * period + x] = siteColour_[siteOf(x, y, block_)];
        image_->SetCFARepeatPatternDim(static_cast<unsigned short>(period), static_cast<unsigned short>(period));
        image_->SetCFAPattern(static_cast<unsigned int>(period * period), cfa);
        writeBlack(period);
        image_->SetWhiteLevelRational(1, &white_);

        writeColour();

        if (crop_[2] > 0 && crop_[3] > 0) {
            if (crop_[0] + crop_[2] <= width && crop_[1] + crop_[3] <= height) {
                setTag(0, tdw::TIFFTAG_DEFAULT_CROP_ORIGIN, tdw::TIFF_LONG, 2, &crop_[0]);
                setTag(0, tdw::TIFFTAG_DEFAULT_CROP_SIZE, tdw::TIFF_LONG, 2, &crop_[2]);
            } else {
                DNG_FAIL("default crop %u,%u %ux%u outside %ux%u: not written", crop_[0], crop_[1], crop_[2], crop_[3], width, height);
            }
        }
        if (!image_->WriteExifIFD()) DNG_FAIL("Exif IFD not written: %s", image_->Error().c_str());

        if (!(lossless_ && writeLosslessJpeg(mosaic, w, h))) {
            image_->SetCompression(tdw::COMPRESSION_NONE);
            image_->SetImageData(static_cast<const unsigned char *>(mosaic), static_cast<size_t>(width) * height * 2);
        }
        writer.AddImage(image_.get());
        std::string error;
        size_t stripOffset = 0;
        void *file = writer.WriteToMemory(&size, &error, &stripOffset);
        if (!error.empty()) DNG_FAIL("layout failed: %s", error.c_str());
        return file;
    }

    /**
     * dngCreator.cpp layoutLinear: every tag of a w x h Linear DNG stored in strips of `rows` rows (uncompressed) or, compressed,
     * in tiles of the image's width and `rows` rows (LJ92 of 3 components); the strip / tile tables are zeros, the caller fills them
     * once the samples are placed. head: the TIFF header, the metadata, IFD 0 and no next IFD (a preview may be appended).
     */
    bool layoutLinear(int w, int h, int rows, bool compressed, std::string &head) {
        if (!linear_ || w <= 0 || w > 65520 || h <= 0 || rows <= 0 || (!compressed && rows > h)) return false;
        prepareLinearTags(w, h, compressed ? 0 : rows);
        image_->SetCompression(compressed ? tdw::COMPRESSION_NEW_JPEG : tdw::COMPRESSION_NONE);

        // A row of tiles spans the image. Several readers only handle multiple LJ92 sections as tiles.
        constexpr unsigned short tileWidth = 322, tileLength = 323, tileOffsets = 324, tileByteCounts = 325;
        if (compressed) {
            const unsigned int tileColumns = w, tileRows = rows;
            if ((w & 15) != 0 || (rows & 15) != 0 || !setTag(0, tileWidth, tdw::TIFF_LONG, 1, &tileColumns) ||
                !setTag(0, tileLength, tdw::TIFF_LONG, 1, &tileRows)) return false;
        }
        const std::vector<unsigned int> zeros((h - 1) / rows + 1);
        const auto count = static_cast<unsigned int>(zeros.size());
        if (!setTag(0, compressed ? tileOffsets : tdw::TIFFTAG_STRIP_OFFSET, tdw::TIFF_LONG, count, zeros.data()) ||
            !setTag(0, compressed ? tileByteCounts : tdw::TIFFTAG_STRIP_BYTE_COUNTS, tdw::TIFF_LONG, count, zeros.data())) return false;
        std::string metadata = image_->DataPrefix();
        if (metadata.size() & 1u) metadata.push_back(char(0));
        const uint32_t ifdOffset = 8u + static_cast<uint32_t>(metadata.size());
        std::ostringstream ifd;
        if (!image_->WriteIFDToStream(0, 0, &ifd, false)) return false;
        head.assign("II*\0", 4);
        for (int byte = 0; byte < 4; ++byte) head.push_back(char(ifdOffset >> (8 * byte)));
        head += metadata;
        head += ifd.str();
        head.append(4, char(0)); // No next IFD; a preview may be appended by the app.
        return true;
    }

    /** dngCreator.cpp prepareTags for the Linear DNG: three 16-bit samples, black 0, white 65535 a plane; rows 0: no RowsPerStrip. */
    void prepareLinearTags(int w, int h, int rows) {
        const unsigned short bitsPerSample[] = {16, 16, 16};
        const unsigned int width = static_cast<unsigned>(w), height = static_cast<unsigned>(h);
        image_->SetBitsPerSample(3, bitsPerSample);
        image_->SetOrientation(static_cast<unsigned short>(orientation_));
        image_->SetImageWidth(width);
        image_->SetImageLength(height);
        if (rows > 0) image_->SetRowsPerStrip(static_cast<unsigned int>(rows));
        const unsigned int active[4] = {0, 0, height, width};
        image_->SetActiveArea(active);
        image_->SetResolutionUnit(tdw::RESUNIT_INCH);
        image_->SetXResolution(72.f);
        image_->SetYResolution(72.f);

        const unsigned short black[] = {0, 0, 0};
        const double white[] = {65535., 65535., 65535.};
        image_->SetBlackLevelRepeatDim(1, 1);
        image_->SetBlackLevel(3, black);
        image_->SetWhiteLevelRational(3, white);

        writeColour();

        if (crop_[2] > 0 && crop_[3] > 0) {
            if (crop_[0] + crop_[2] <= width && crop_[1] + crop_[3] <= height) {
                setTag(0, tdw::TIFFTAG_DEFAULT_CROP_ORIGIN, tdw::TIFF_LONG, 2, &crop_[0]);
                setTag(0, tdw::TIFFTAG_DEFAULT_CROP_SIZE, tdw::TIFF_LONG, 2, &crop_[2]);
            } else {
                DNG_FAIL("default crop %u,%u %ux%u outside %ux%u: not written", crop_[0], crop_[1], crop_[2], crop_[3], width, height);
            }
        }
        if (!image_->WriteExifIFD()) DNG_FAIL("Exif IFD not written: %s", image_->Error().c_str());
    }

    /** The 2x2 site (y * 2 + x) whose colour the pixel (x, y) of a block-b mosaic has. */
    static int siteOf(int x, int y, int b) { return ((y / b) & 1) * 2 + ((x / b) & 1); }

    void keep(Matrix which, const double *m) {
        std::copy(m, m + 9, matrix_[which].begin());
        matrixSet_[which] = true;
    }

    bool usable(Matrix which) const { return matrixSet_[which] && writable(matrix_[which]); }

    /** BlackLevel by 2x2 site: one 2x2 cell when the four agree, else the whole colour-block period. */
    void writeBlack(int period) {
        const bool flat = black_[1] == black_[0] && black_[2] == black_[0] && black_[3] == black_[0];
        const int dim = flat ? 2 : period, b = dim / 2;
        std::vector<unsigned short> levels(static_cast<size_t>(dim) * dim);
        for (int y = 0; y < dim; ++y)
            for (int x = 0; x < dim; ++x) levels[static_cast<size_t>(y) * dim + x] = black_[siteOf(x, y, b)];
        image_->SetBlackLevelRepeatDim(static_cast<unsigned short>(dim), static_cast<unsigned short>(dim));
        image_->SetBlackLevel(static_cast<unsigned int>(levels.size()), levels.data());
    }

    /**
     * P280 (owner, 2026-10-19: «Наши равы не открываются в лайтруме»): only colour data a raw converter accepts. The second
     * profile only with a usable first one and a different second illuminant; forward and calibration matrices only with
     * their colour matrix; AsShotNeutral only with three positive channels.
     */
    void writeColour() {
        const bool first = usable(kColour1);
        const bool second = first && usable(kColour2) && illuminant_[1] != 0 && illuminant_[1] != illuminant_[0];
        if (first) image_->SetColorMatrix1(3, matrix_[kColour1].data());
        if (second) image_->SetColorMatrix2(3, matrix_[kColour2].data());
        if (first && usable(kForward1)) image_->SetForwardMatrix1(3, matrix_[kForward1].data());
        if (second && usable(kForward2)) image_->SetForwardMatrix2(3, matrix_[kForward2].data());
        if (first && usable(kCalibration1)) image_->SetCameraCalibration1(3, matrix_[kCalibration1].data());
        if (second && usable(kCalibration2)) image_->SetCameraCalibration2(3, matrix_[kCalibration2].data());
        if (neutralSet_ && neutral_[0] > 0 && neutral_[1] > 0 && neutral_[2] > 0) image_->SetAsShotNeutral(3, neutral_.data());
        if (baselineEv_ != 0.0) {
            if (linear_) {
                // Use an SRATIONAL with both values fitting in int32, including very small positive EV.
                const int ev[] = {static_cast<int>(std::lround(baselineEv_ * 1000000)), 1000000};
                setTag(0, tdw::TIFFTAG_BASELINE_EXPOSURE, tdw::TIFF_SRATIONAL, 1, ev);
            } else {
                image_->SetBaselineExposure(baselineEv_);
            }
        }
        if (first) image_->SetCalibrationIlluminant1(illuminant_[0]);
        if (second) image_->SetCalibrationIlluminant2(illuminant_[1]);
    }

    /**
     * P24: DNG compression 7 - the mosaic's row pairs as one 2W x H/2 component (LibRaw decodes it bit-exact). Encoded
     * before the tag is set, so a failure leaves the caller to store the samples uncompressed.
     */
    bool writeLosslessJpeg(void *mosaic, int w, int h) {
        if (w % 2 != 0 || h % 2 != 0) return false;
        uint8_t *encoded = nullptr;
        int encodedSize = 0;
        const int rc = tdw::detail::lj92_encode(static_cast<uint16_t *>(mosaic), w * 2, h / 2, 16, w * 2 * (h / 2), 0,
                                                nullptr, 0, &encoded, &encodedSize);
        bool stored = false;
        if (rc == tdw::detail::LJ92_ERROR_NONE && encoded != nullptr && encodedSize > 0) {
            image_->SetCompression(tdw::COMPRESSION_NEW_JPEG);
            stored = image_->SetImageData(encoded, static_cast<size_t>(encodedSize));
            DNG_INFO("LJ92 %d x %d: %d bytes", w, h, encodedSize);
        } else {
            DNG_FAIL("LJ92 failed (%d): stored uncompressed", rc);
        }
        free(encoded);
        return stored;
    }

    std::unique_ptr<tdw::DNGImage> image_;
    int orientation_ = 0;
    double white_ = 1023.0;
    std::array<unsigned short, 4> black_{};
    bool lossless_ = false;
    bool linear_ = false;
    double baselineEv_ = 0.0;
    unsigned short illuminant_[2] = {0, 0};
    std::array<std::array<double, 9>, kMatrixCount> matrix_{};
    bool matrixSet_[kMatrixCount] = {};
    std::array<double, 3> neutral_{};
    bool neutralSet_ = false;
    int arrangement_ = 0;
    std::array<unsigned char, 4> siteColour_ = {1, 0, 2, 1};
    int block_ = 1;
    bool gainMapPlaced_ = false;
    std::array<unsigned int, 4> crop_{};
};

namespace {

/** dngCreator.cpp linearHalf: an IEEE half as a float (Inf / NaN: NaN, which the callers drop as not finite). */
inline float linearHalf(uint16_t bits) {
    const int exponent = (bits >> 10) & 31, mantissa = bits & 1023;
    const float value = exponent == 31 ? NAN : exponent == 0 ? std::ldexp(float(mantissa), -24)
                                                              : std::ldexp(float(mantissa + 1024), exponent - 25);
    return bits & 0x8000 ? -value : value;
}

inline float linearSample(uint16_t value) { return linearHalf(value); }
inline float linearSample(float value) { return value; }

template <typename Sample> float linearHeadroomOf(const Sample *rgb, size_t count) {
    float peak = 1.f;
    for (size_t i = 0; i < count; ++i) {
        const float value = linearSample(rgb[i]);
        if (std::isfinite(value)) peak = std::max(peak, value);
    }
    return peak;
}

template <typename Sample> void packLinearStrip(const Sample *rgb, uint16_t *dst, size_t count, float headroom) {
    const float scale = 65535.f / headroom;
    for (size_t i = 0; i < count; ++i) {
        const float value = linearSample(rgb[i]);
        dst[i] = std::isfinite(value) ? uint16_t(std::min(65535.f, std::max(0.f, value * scale)) + .5f) : 0;
    }
}

/** nLinearStrip: rows [firstRow, firstRow + rows) of the RGB over the headroom into strip, the last row repeated to storedRows. */
bool linearStrip(const uint8_t *rgb, bool half, int width, int firstRow, int rows, float headroom, uint16_t *strip, int storedRows) {
    if (!rgb || !strip || width <= 0 || firstRow < 0 || rows <= 0 || storedRows < rows || !std::isfinite(headroom) || headroom < 1.f)
        return false;
    const size_t rowSamples = 3u * size_t(width);
    const size_t from = rowSamples * size_t(firstRow);
    if (half) packLinearStrip(reinterpret_cast<const uint16_t *>(rgb) + from, strip, size_t(rows) * rowSamples, headroom);
    else packLinearStrip(reinterpret_cast<const float *>(rgb) + from, strip, size_t(rows) * rowSamples, headroom);
    const uint16_t *last = strip + size_t(rows - 1) * rowSamples;
    for (int y = rows; y < storedRows; ++y) std::copy_n(last, rowSamples, strip + size_t(y) * rowSamples);
    return true;
}

/** nLinearCompress: the strip's rows as one LJ92 frame of 3 components, empty on failure. */
std::vector<uint8_t> linearCompress(uint16_t *strip, int width, int rows) {
    if (!strip || width <= 0 || width > 65535 || rows <= 0 || rows > 65535) return {};
    const long long count = 3LL * width * rows;
    if (count > INT32_MAX) return {};
    uint8_t *bytes = nullptr;
    int size = 0;
    const auto rc = tdw::detail::lj92_encode(strip, width, rows, 16, int(count), 0, nullptr, 0, &bytes, &size, 3);
    const std::unique_ptr<uint8_t, decltype(&free)> owned(bytes, &free);
    if (rc != tdw::detail::LJ92_ERROR_NONE || !bytes || size <= 0) return {};
    return std::vector<uint8_t>(bytes, bytes + size);
}

uint32_t le32(const std::string &b, size_t at) {
    return uint32_t(uint8_t(b[at])) | uint32_t(uint8_t(b[at + 1])) << 8 | uint32_t(uint8_t(b[at + 2])) << 16 | uint32_t(uint8_t(b[at + 3])) << 24;
}

/** DngCreator.stripTable: where the head's LONG table of `tag` with `strips` entries is (0: not found). */
size_t stripTable(const std::string &head, unsigned tag, int strips) {
    if (head.size() < 8) return 0;
    const size_t ifd = le32(head, 4);
    if (ifd + 2 > head.size()) return 0;
    const unsigned entries = unsigned(uint8_t(head[ifd])) | unsigned(uint8_t(head[ifd + 1])) << 8;
    for (unsigned i = 0; i < entries; i++) {
        const size_t entry = ifd + 2 + size_t(i) * 12;
        if (entry + 12 > head.size()) return 0;
        const unsigned t = unsigned(uint8_t(head[entry])) | unsigned(uint8_t(head[entry + 1])) << 8;
        const unsigned type = unsigned(uint8_t(head[entry + 2])) | unsigned(uint8_t(head[entry + 3])) << 8;
        if (t == tag && type == 4 && le32(head, entry + 4) == uint32_t(strips)) {
            const size_t table = strips == 1 ? entry + 8 : le32(head, entry + 8);
            if (table >= 8 && table + 4ull * size_t(strips) <= head.size()) return table;
        }
    }
    return 0;
}

void put32(std::vector<uint8_t> &file, size_t at, uint32_t v) {
    for (int k = 0; k < 4; k++) file[at + size_t(k)] = uint8_t(v >> (8 * k));
}

/** DngCreator.STREAM_PIECE: the bound of one strip's bytes */
constexpr int kStreamPiece = 1 << 20;

}  // namespace

DngFile::DngFile(bool linear) : impl_(new Impl(linear)) {}
DngFile::~DngFile() = default;
void DngFile::setUniqueCameraModel(const std::string &s) { impl_->setUniqueCameraModel(s); }
void DngFile::setDescription(const std::string &s) { impl_->setDescription(s); }
void DngFile::setSoftware(const std::string &s) { impl_->setSoftware(s); }
void DngFile::setMake(const std::string &s) { impl_->setMake(s); }
void DngFile::setModel(const std::string &s) { impl_->setModel(s); }
void DngFile::setDateTime(const std::string &s) { impl_->setDateTime(s); }
void DngFile::setNoiseProfile(const double *pairs, int count) { impl_->setNoiseProfile(pairs, count); }
bool DngFile::setTag(int ifd, unsigned short tag, unsigned short type, unsigned int count, const void *values) {
    return impl_->setTag(ifd, tag, type, count, values);
}
void DngFile::setOrientation(int v) { impl_->setOrientation(v); }
void DngFile::setWhiteLevel(double v) { impl_->setWhiteLevel(v); }
void DngFile::setBlackLevel(const unsigned short *v) { impl_->setBlackLevel(v); }
void DngFile::setCompression(bool lossless) { impl_->setCompression(lossless); }
void DngFile::setBaselineExposure(double ev) { impl_->setBaselineExposure(ev); }
void DngFile::setCalibrationIlluminant1(unsigned short v) { impl_->setCalibrationIlluminant1(v); }
void DngFile::setCalibrationIlluminant2(unsigned short v) { impl_->setCalibrationIlluminant2(v); }
void DngFile::setColorMatrix1(const double *m) { impl_->setColorMatrix1(m); }
void DngFile::setColorMatrix2(const double *m) { impl_->setColorMatrix2(m); }
void DngFile::setForwardMatrix1(const double *m) { impl_->setForwardMatrix1(m); }
void DngFile::setForwardMatrix2(const double *m) { impl_->setForwardMatrix2(m); }
void DngFile::setCameraCalibration1(const double *m) { impl_->setCameraCalibration1(m); }
void DngFile::setCameraCalibration2(const double *m) { impl_->setCameraCalibration2(m); }
void DngFile::setAsShotNeutral(const double *rgb) { impl_->setAsShotNeutral(rgb); }
void DngFile::setCFAPattern(int arrangement) { impl_->setCFAPattern(arrangement); }
void DngFile::setMosaicBlock(int block) { impl_->setMosaicBlock(block); }
void DngFile::setDefaultCrop(int x, int y, int w, int h) { impl_->setDefaultCrop(x, y, w, h); }
void DngFile::setGainMap(const float *interleaved, int xmin, int ymin, int xmax, int ymax, int w, int h) {
    impl_->setGainMap(interleaved, xmin, ymin, xmax, ymax, w, h);
}

float DngFile::linearHeadroom(const uint8_t *rgb, size_t bytes, bool half) {
    if (!rgb || bytes == 0) return 1.f;
    if (half) return linearHeadroomOf(reinterpret_cast<const uint16_t *>(rgb), bytes / 2);
    return linearHeadroomOf(reinterpret_cast<const float *>(rgb), bytes / 4);
}

std::vector<uint8_t> DngFile::buildLinear(const uint8_t *rgb, size_t bytes, bool half, int width, int height, float headroom, bool lossless,
                                          bool parallel) {
    const auto started = std::chrono::steady_clock::now();
    const long long rowBytesLong = 6LL * width;
    if (width <= 0 || width > 65520 || height <= 0 || (long long)bytes / height != rowBytesLong * (half ? 1 : 2)
        || (long long)bytes % height != 0) {
        DNG_FAIL("Linear DNG: wrong RGB dimensions (%zu B for %dx%d)", bytes, width, height);
        return {};
    }
    // TIFF tiles must be multiples of 16. Store narrow or unaligned rows as uncompressed strips.
    const bool compress = lossless && (width & 15) == 0;
    const int rowBytes = int(rowBytesLong);
    const int rows = compress ? std::max(16, std::min((height + 15) & ~15, (kStreamPiece / rowBytes) & ~15))
                              : std::min(height, std::max(1, kStreamPiece / rowBytes));
    const int strips = (height - 1) / rows + 1;
    std::string head;
    if (!impl_->layoutLinear(width, height, rows, compress, head)) {
        DNG_FAIL("Linear DNG: metadata could not be written");
        return {};
    }
    const size_t offsets = stripTable(head, compress ? 324 : 273, strips), counts = stripTable(head, compress ? 325 : 279, strips);
    if (!offsets || !counts) {
        DNG_FAIL("Linear DNG: missing TIFF strip table");
        return {};
    }
    const size_t stripSamples = size_t(rows) * size_t(width) * 3;
    // DngCreator.writeLinearBuffer's second worker (scam_dev dng_linear_parallel, off by default): the next tile compressed beside
    // this one; the file is the same, strip for strip
    const bool twoWorkers = parallel && compress && strips > 1 && stripSamples * 2 <= size_t(kStreamPiece)
                            && (long long)width * height <= 16000000LL && std::thread::hardware_concurrency() >= 4;
    std::vector<uint8_t> file;
    file.reserve(head.size() + (compress ? size_t(rowBytesLong) * size_t(height) * 2 / 3 : size_t(rowBytesLong) * size_t(height)));
    file.insert(file.end(), head.begin(), head.end());
    std::vector<uint16_t> strip(stripSamples), next(twoWorkers ? stripSamples : 0);
    auto compressed = [&](std::vector<uint16_t> &into, int y, int h) {
        if (!linearStrip(rgb, half, width, y, h, headroom, into.data(), rows)) return std::vector<uint8_t>();
        return linearCompress(into.data(), width, rows);
    };
    std::future<std::vector<uint8_t>> pending;
    bool pendingSet = false;
    for (int y = 0, index = 0; y < height; index++) {
        const int h = std::min(rows, height - y);
        const size_t start = file.size();
        if (compress) {
            std::vector<uint8_t> coded;
            if (pendingSet) {
                coded = pending.get();
                pendingSet = false;
            } else {
                const int nextY = y + h;
                if (twoWorkers && nextY < height) {
                    pending = std::async(std::launch::async, [&, nextY] { return compressed(next, nextY, std::min(rows, height - nextY)); });
                    pendingSet = true;
                }
                coded = compressed(strip, y, h);
            }
            if (coded.empty()) {
                if (pendingSet) pending.wait();
                DNG_FAIL("Linear DNG: lossless JPEG failed");
                return {};
            }
            file.insert(file.end(), coded.begin(), coded.end());
        } else {
            if (!linearStrip(rgb, half, width, y, h, headroom, strip.data(), h)) {
                DNG_FAIL("Linear DNG: invalid RGB strip");
                return {};
            }
            const uint8_t *b = reinterpret_cast<const uint8_t *>(strip.data());
            file.insert(file.end(), b, b + size_t(h) * size_t(rowBytes));
        }
        const size_t end = file.size();
        if (end > 0xffffffffull) {
            if (pendingSet) pending.wait();
            DNG_FAIL("Linear DNG exceeds classic TIFF offsets");
            return {};
        }
        put32(file, offsets + 4 * size_t(index), uint32_t(start));
        put32(file, counts + 4 * size_t(index), uint32_t(end - start));
        y += h;
    }
    const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    char line[200];
    std::snprintf(line, sizeof line, "PERF Linear DNG written: %zu KB, %dx%d%s, %d worker(s), %d ms", file.size() >> 10, width, height,
                  compress ? ", lossless JPEG" : ", uncompressed", twoWorkers ? 2 : 1, int(ms));
    dngLog()(line);
    return file;
}

std::vector<uint8_t> DngFile::build(uint16_t *mosaic, int w, int h) {
    size_t size = 0;
    void *bytes = impl_->createDng(mosaic, w, h, size);
    if (bytes == nullptr) return {};
    std::vector<uint8_t> out(static_cast<uint8_t *>(bytes), static_cast<uint8_t *>(bytes) + size);
    free(bytes);
    return out;
}

}  // namespace dng
}  // namespace scam_post
