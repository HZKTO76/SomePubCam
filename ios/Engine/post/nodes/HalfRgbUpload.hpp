// HalfRgbUpload.java (P145, the Android default: scam_dev half_rgb_gpu): the worker's half-float RGB (6 B a pixel) into ScamRgb's
// RGBA16F input texture (alpha 1.0) by the compute pass scamhdr/halfrgba over bands of rows in a storage buffer, instead of the
// CPU repack into a full-size RGBA buffer and its upload. The pass widens every half exactly (unpackHalf2x16) and stores the same
// half; whether this driver keeps every one of the 65536 patterns (denormals, NaNs as NaNs) is checked once per process (probe),
// otherwise - and on a GL error - the caller repacks on the CPU (uploadHalfRgbaBands: the same halves). The texture's texels are
// the CPU repack's either way.
#pragma once

#include "../Pipeline.hpp"

#include <chrono>
#include <cstring>

namespace scam_post {

namespace HalfRgbUpload {

/// band of rows per storage-buffer upload (about 16 MB of halves, as Java's BAND_BYTES)
constexpr int BAND_BYTES = 16 << 20;

/// 1 = the pass keeps every half on this driver, -1 = it does not, 0 = not checked yet (HalfRgbUpload.state)
inline int& state() { static int s = 0; return s; }

/// HalfRgbUpload.run: the bands of `rgb` (w * h * 3 halves) through scamhdr/halfrgba into `tex`; false on a GL error
inline bool run(GLProg& prog, GLTexture& tex, int w, int h, const uint8_t* rgb) {
    while (glGetError() != GL_NO_ERROR) {}
    const size_t rowBytes = size_t(w) * 6;
    const int band = std::max(1, std::min(h, int(size_t(BAND_BYTES) / rowBytes)));
    GLuint buffers[2] = {0, 0};
    glGenBuffers(2, buffers);
    bool ok = false;
    try {
        prog.setLayout(16, 16, 1);
        prog.useAssetProgram("scamhdr/halfrgba", true);
        glBindImageTexture(0, tex.mTextureID, 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA16F);
        for (int y0 = 0, k = 0; y0 < h; y0 += band, k++) {
            const int rows = std::min(band, h - y0);
            const size_t bytes = size_t(rows) * rowBytes;
            // a store of its own per band (two names in turn): the pass on the previous band keeps its store, no wait for it
            // (whole words: the band's bytes as they are; else a zeroed word-padded store and the bytes into it)
            glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[k & 1]);
            if (bytes % 4 == 0) {
                glBufferData(GL_SHADER_STORAGE_BUFFER, GLsizeiptr(bytes), rgb + size_t(y0) * rowBytes, GL_STREAM_DRAW);
            } else {
                glBufferData(GL_SHADER_STORAGE_BUFFER, GLsizeiptr((bytes + 3) & ~size_t(3)), nullptr, GL_STREAM_DRAW);
                glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, GLsizeiptr(bytes), rgb + size_t(y0) * rowBytes);
            }
            glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, buffers[k & 1]);
            prog.setVar("bandU", w, y0);
            prog.setVar("rowsU", rows);
            glDispatchCompute(GLuint((w + 15) / 16), GLuint((rows + 15) / 16), 1);
        }
        glMemoryBarrier(GL_TEXTURE_FETCH_BARRIER_BIT | GL_SHADER_IMAGE_ACCESS_BARRIER_BIT | GL_FRAMEBUFFER_BARRIER_BIT
                        | GL_PIXEL_BUFFER_BARRIER_BIT);
        glBindImageTexture(0, 0, 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA16F);
        prog.closed = true;
        ok = glGetError() == GL_NO_ERROR;
        if (!ok) logI("SCAM_PIPELINE", "half RGB GPU upload: GL error, CPU repack");
    } catch (const std::exception& e) {
        logI("SCAM_PIPELINE", std::string("half RGB GPU upload failed: ") + e.what() + ", CPU repack");
        ok = false;
    }
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, 0);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
    glDeleteBuffers(2, buffers);
    return ok;
}

/// HalfRgbUpload.probe: all 65536 halves (the RGB of 128 x 171 pixels) through the pass, read back (as halves, or as floats where
/// the half read is refused); the first pattern lost, -1 for none, 0x10000 on a GL error. A NaN only has to stay a NaN; alpha 1.0.
inline int probe(GLProg& prog) {
    const int w = 128, h = (65536 + 3 * w - 1) / (3 * w);
    std::vector<uint16_t> halves(size_t(w) * size_t(h) * 3, 0);
    for (int i = 0; i < 65536; i++) halves[size_t(i)] = uint16_t(i);
    GLTexture tex({w, h}, GLFormat(DataType::FLOAT_16, 4), nullptr, GL_NEAREST, GL_CLAMP_TO_EDGE);
    if (!run(prog, tex, w, h, reinterpret_cast<const uint8_t*>(halves.data()))) return 0x10000;
    GLint oldRead = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &oldRead);
    GLuint fb = 0;
    glGenFramebuffers(1, &fb);
    glBindFramebuffer(GL_FRAMEBUFFER, fb);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex.mTextureID, 0);
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    while (glGetError() != GL_NO_ERROR) {}
    std::vector<uint16_t> backHalf(size_t(w) * size_t(h) * 4);
    std::vector<float> backFloat;
    glReadPixels(0, 0, w, h, GL_RGBA, GL_HALF_FLOAT, backHalf.data());
    const bool asHalves = glGetError() == GL_NO_ERROR;
    if (!asHalves) {
        backFloat.resize(size_t(w) * size_t(h) * 4);
        glReadPixels(0, 0, w, h, GL_RGBA, GL_FLOAT, backFloat.data());
    }
    const bool readOk = glGetError() == GL_NO_ERROR;
    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(oldRead));
    glDeleteFramebuffers(1, &fb);
    tex.close();
    if (!readOk) return 0x10000;
    // firstLost: as halves the pattern itself, as floats its exact widening; a NaN only has to stay a NaN
    auto widen = [](uint16_t v) {
        const uint32_t sign = uint32_t(v & 0x8000u) << 16;
        uint32_t e = (v >> 10) & 0x1fu, m = v & 0x3ffu, x;
        if (e == 0) {
            if (m == 0) x = sign;
            else { e = 127 - 15 + 1; while (!(m & 0x400u)) { m <<= 1; --e; } m &= 0x3ffu; x = sign | (e << 23) | (m << 13); }
        } else if (e == 31) x = sign | 0x7f800000u | (m << 13);
        else x = sign | ((e - 15 + 127) << 23) | (m << 13);
        float f;
        std::memcpy(&f, &x, 4);
        return f;
    };
    for (int px = 0; px < w * h; px++)
        for (int c = 0; c < 4; c++) {
            const int pattern = c < 3 ? px * 3 + c : -1;
            const uint16_t want = c == 3 ? uint16_t(0x3C00) : pattern < 65536 ? uint16_t(pattern) : uint16_t(0);
            const size_t at = size_t(px) * 4 + size_t(c);
            const float wantF = widen(want);
            const float got = asHalves ? widen(backHalf[at]) : backFloat[at];
            bool same;
            if (std::isnan(wantF)) same = std::isnan(got);
            else if (asHalves) same = backHalf[at] == want;
            else { uint32_t a, b; std::memcpy(&a, &got, 4); std::memcpy(&b, &wantF, 4); same = a == b; }
            if (!same) return want;
        }
    return -1;
}

/// HalfRgbUpload.exact: whether the pass keeps every half on this driver (checked once per process, logged)
inline bool exact(GLProg& prog) {
    if (state() != 0) return state() > 0;
    const auto started = std::chrono::steady_clock::now();
    int mismatch;
    std::string failure;
    try {
        mismatch = probe(prog);
    } catch (const std::exception& e) {
        mismatch = 0x10000;
        failure = e.what();
    }
    state() = mismatch < 0 ? 1 : -1;
    char hex[16];
    std::snprintf(hex, sizeof hex, "%x", mismatch);
    logI("SCAM_PIPELINE", std::string("half RGB GPU upload check: ")
         + (mismatch < 0 ? "exact for all 65536 halves" : !failure.empty() ? "failed (" + failure + "), CPU repack kept"
            : mismatch > 0xffff ? "GL error, CPU repack kept" : "half 0x" + std::string(hex) + " differs, CPU repack kept")
         + " ms=" + std::to_string(long(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count())));
    return mismatch < 0;
}

/// HalfRgbUpload.upload: the input texture (alpha 1.0) or null when this driver does not keep the halves or a GL call failed
inline Texture upload(GLProg& prog, Point size, const uint8_t* rgb) {
    if (!exact(prog)) return nullptr;
    Texture tex = makeTexture(size, GLFormat(DataType::FLOAT_16, 4), nullptr, GL_NEAREST, GL_CLAMP_TO_EDGE);
    if (!run(prog, *tex, size.x, size.y, rgb)) {
        tex->close();
        return nullptr;
    }
    return tex;
}

/// ScamRgb.uploadHalfRgba: the CPU repack (alpha 1.0 = 0x3C00) in row bands of ~16 MB, each band uploaded as RGBA16F halves - the
/// texels of one full-size repack and upload, without the full-size RGBA buffer
inline Texture uploadHalfRgbaBands(Point size, const uint8_t* rgb) {
    const int w = size.x, h = size.y;
    const int band = std::max(1, std::min(h, (16 << 20) / (8 * w)));
    std::vector<uint16_t> stage(size_t(band) * size_t(w) * 4);
    Texture tex = makeTexture(size, GLFormat(DataType::FLOAT_16, 4), nullptr, GL_NEAREST, GL_CLAMP_TO_EDGE);
    GLint previous = 0;
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &previous);
    glBindTexture(GL_TEXTURE_2D, tex->mTextureID);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    for (int y0 = 0; y0 < h; y0 += band) {
        const int rows = std::min(band, h - y0);
        const size_t px = size_t(rows) * size_t(w);
        const uint16_t* src = reinterpret_cast<const uint16_t*>(rgb) + size_t(y0) * size_t(w) * 3;
        uint16_t* out = stage.data();
        for (size_t i = 0; i < px; i++) {
            out[i * 4] = src[i * 3]; out[i * 4 + 1] = src[i * 3 + 1]; out[i * 4 + 2] = src[i * 3 + 2]; out[i * 4 + 3] = 0x3C00;
        }
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, y0, w, rows, GL_RGBA, GL_HALF_FLOAT, stage.data());
    }
    glBindTexture(GL_TEXTURE_2D, GLuint(previous));
    return tex;
}

} // namespace HalfRgbUpload

} // namespace scam_post
