// SceneLumaCache.java one to one: P671's scene luma cache of the photo's combine (why/combine.glsl EDGE_LUMA_CACHE) - the
// full-size merge's scene luminance (why/scene_y: the same sceneLinear and LUMA dot the combine's sceneY took per tap) drawn once
// into an R32F texture of the input's size, which the edge hold and the trench read instead of converting up to 9 + 4 pixels a
// pixel: the same floats (speed only). ActivityManager.MemoryInfo.availMem's place: availableMemory below (os_proc_available_memory
// on the iPhone, /proc/meminfo's MemAvailable on the Linux host, as scam-hybrid.h hybridMemAvailable; unknown: no cache).
#pragma once

#include "../why/WhyToneCore.hpp"

#include <cstdint>
#include <cstdio>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif
#endif

namespace scam_post {
namespace SceneLumaCache {

/// the memory this process may still take, bytes (0: unknown) - scam-hybrid.h hybridMemAvailable
inline uint64_t availableMemory() {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    return uint64_t(os_proc_available_memory());
#else
    std::ifstream f("/proc/meminfo");
    std::string key, rest;
    uint64_t kb = 0;
    while (f >> key >> kb) {
        std::getline(f, rest);
        if (key == "MemAvailable:") return kb * 1024;
    }
    return 0;
#endif
}

inline bool fits(int width, int height, int64_t available) {
    if (width <= 0 || height <= 0) return false;
    const int64_t pixels = int64_t(width) * height;
    return pixels <= (int64_t(256) << 20) / 4 && available >= pixels * 8 + (int64_t(256) << 20);
}

/// the R32F scene luma of `input` (nullptr when it does not fit the memory or cannot be drawn: the original colour evaluation);
/// the framebuffers and the viewport bound before are bound again
inline Texture prepare(GLProg& prog, PostPipeline& pipeline, GLTexture& input, const GLTexture& gainMap, float inScale) {
    Texture cache;
    GLint read = 0, draw = 0, viewport[4] = {0, 0, 0, 0};
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw);
    glGetIntegerv(GL_VIEWPORT, viewport);
    Texture out;
    try {
        if (fits(input.mSize.x, input.mSize.y, int64_t(availableMemory()))) {
            cache = makeTexture(input.mSize, GLFormat(DataType::FLOAT_32, 1), nullptr, GL_NEAREST, GL_CLAMP_TO_EDGE);
            cache->BufferLoad();
            if (cache->mTextureID == 0 || cache->mBuffer == 0 || glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
                throw std::runtime_error("R32F scene luma is not renderable");
            prog.useAssetProgram("why/scene_y", false);
            prog.setTexture("InputBuffer", input);
            WhyTone::setColour(prog, pipeline, gainMap, inScale);   // pipeline.why.inScale
            prog.drawBlocks(cache);
            const GLenum error = glGetError();
            if (error != GL_NO_ERROR) {
                char hex[16];
                std::snprintf(hex, sizeof hex, "%x", error);
                throw std::runtime_error(std::string("scene luma GL error 0x") + hex);
            }
            out = cache;
            cache = nullptr;
        }
    } catch (const std::exception& e) {
        logI("SCAM_PIPELINE", std::string("scene luma cache failed: ") + e.what() + "; original colour evaluation");
        out = nullptr;
    }
    if (cache) cache->close();
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, GLuint(draw));
    glBindFramebuffer(GL_READ_FRAMEBUFFER, GLuint(read));
    glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
    prog.closed = true;
    return out;
}

/// GLProg binds its samplers on even units: unit 1 stays free
inline void bind(GLProg& prog, GLTexture& cache) {
    prog.setVar("WhySceneY", 1);
    cache.bind(GL_TEXTURE0 + 1);
}

} // namespace SceneLumaCache
} // namespace scam_post
