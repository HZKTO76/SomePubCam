// ScamGL: the subset of EGL 1.5 / OpenGL ES 3.1 that the SCAMERA merge (app/src/main/cpp/scam-*.h) uses, on Metal.
// Compute programs only (the «Качество» route): GLSL is translated at link time (ScamGLCompiler: glslang → SPIR-V →
// SPIRV-Cross MSL) and compiled with fast math off. Every GL command is recorded in order into the context's Metal command
// buffer (compute dispatches, blits for buffer / texture uploads and copies); CPU reads (glMapBufferRange, glReadPixels)
// wait for the work recorded before them, as in GL. Objects are shared by all contexts (names are unique).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <TargetConditionals.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>

#include "ScamGLCompiler.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <memory>
#include <atomic>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

id<MTLDevice> metalDevice() {
    static id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return device;
}

bool verbose() {
    static const bool on = std::getenv("SCAMGL_LOG") != nullptr;
    return on;
}

void note(const std::string& text) {
    if (verbose()) std::fprintf(stderr, "SCAMGL: %s\n", text.c_str());
}

struct Buffer {
    id<MTLBuffer> mtl = nil;
    size_t size = 0;
};

struct Texture {
    id<MTLTexture> mtl = nil;
    GLenum target = 0, internal = 0;
    int width = 0, height = 0, layers = 1, levels = 1;
    GLint minFilter = GL_NEAREST_MIPMAP_LINEAR, magFilter = GL_LINEAR, wrapS = GL_REPEAT, wrapT = GL_REPEAT;
    id<MTLSamplerState> sampler = nil;
};

struct Shader {
    GLenum type = 0;
    std::string source;
};

struct Location {
    int member = -1, element = 0, sampler = -1;
};

struct Linked {
    scamgl::Compiled compiled;               // the compute or the fragment stage (uniforms, resources)
    id<MTLComputePipelineState> pipeline = nil;
    bool render = false;                     // a vertex + fragment program
    id<MTLFunction> vertex = nil, fragment = nil;
    std::unordered_map<std::string, id<MTLRenderPipelineState>> renderPipelines; // by attachment formats + blend
    std::string recipe;                      // a render program's recipe key ("R\n" vs \x01 fs): its pipelines' recipes name it
    std::string log;
    bool ready() const { return render ? (vertex && fragment) : pipeline != nil; }
};

struct Program {
    std::vector<GLuint> shaders;
    bool linked = false;
    std::string log;
    std::shared_ptr<Linked> code;
    std::vector<uint8_t> block;
    std::vector<Location> locations;
    std::unordered_map<std::string, int> byName;
    std::vector<int> samplerUnit; // per Sampled resource, in resource order
};

struct Framebuffer {
    GLuint color[8] = {};
    std::vector<GLenum> drawBuffers{GL_COLOR_ATTACHMENT0}; // glDrawBuffers is framebuffer state (GLES 3.0 4.2.1)
};

struct BufferBinding {
    GLuint buffer = 0;
    GLintptr offset = 0;
    GLsizeiptr size = 0;
};

struct ImageUnit {
    GLuint texture = 0;
    GLint level = 0, layer = 0;
    GLboolean layered = GL_FALSE;
    GLenum format = 0;
};

struct Sync {
    id<MTLCommandBuffer> buffer = nil;
};

struct Context {
    std::string label;                  // scamgl_label: the stage the GPU time of this context's command buffers is booked to
    id<MTLCommandQueue> queue = nil;
    id<MTLCommandBuffer> cb = nil;
    id<MTLComputeCommandEncoder> compute = nil;
    std::vector<id<MTLCommandBuffer>> inFlight;
    GLenum error = GL_NO_ERROR;
    GLuint program = 0;
    std::unordered_map<GLenum, GLuint> bound;
    BufferBinding ssbo[96], ubo[96];
    ImageUnit images[32];
    GLuint tex2D[32] = {}, tex2DArray[32] = {}, tex3D[32] = {};
    GLenum activeUnit = 0;
    GLuint readFb = 0, drawFb = 0;
    GLint unpackRowLength = 0, unpackAlignment = 4, packRowLength = 0, packAlignment = 4;
    GLint viewport[4] = {0, 0, 1, 1}, scissor[4] = {0, 0, 1, 1};
    bool blend = false, scissorTest = false;
    GLenum blendEquation = GL_FUNC_ADD, blendSrc = GL_ONE, blendDst = GL_ZERO;
};

std::recursive_mutex gLock;
std::unordered_map<GLuint, Buffer> gBuffers;
std::unordered_map<GLuint, Texture> gTextures;
std::unordered_map<GLuint, Shader> gShaders;
std::unordered_map<GLuint, Program> gPrograms;
std::unordered_map<GLuint, Framebuffer> gFramebuffers;
std::unordered_map<std::string, std::shared_ptr<Linked>> gLinkCache;
// every program linked in this process, in order ("C\n" + compute source, or linkRender's "R\n" key): the first-run compile's
// recipes (scamgl_save_programs / scamgl_warm_programs)
std::vector<std::string> gRecorded;
GLuint gNextName = 1;
thread_local Context* gCurrent = nullptr;

using Guard = std::lock_guard<std::recursive_mutex>;

Context* ctx() { return gCurrent; }

void fail(GLenum error) {
    if (Context* c = ctx(); c && c->error == GL_NO_ERROR) c->error = error;
}

// ---- command stream ----

id<MTLCommandBuffer> commandBuffer(Context& c) {
    if (!c.cb) c.cb = [c.queue commandBuffer];
    return c.cb;
}

// The last command buffer that used each buffer / texture (any use: read, write, attachment, blit). A CPU read or a synchronised
// map waits for that one only - the commands after it (the next frame's alignment, the merge's later bands) keep running
// (before: every command buffer of the context). Weak: a finished command buffer the context dropped reads nil (nothing to
// wait for). Keyed by the Metal object; a reused address costs at most an extra wait.
std::unordered_map<const void*, __weak id<MTLCommandBuffer>> gLastUse;

inline void used(Context& c, id resource) {
    if (resource) gLastUse[(__bridge const void*)resource] = commandBuffer(c);
}

void endCompute(Context& c) {
    if (c.compute) {
        [c.compute endEncoding];
        c.compute = nil;
    }
}

id<MTLComputeCommandEncoder> computeEncoder(Context& c) {
    if (!c.compute) c.compute = [commandBuffer(c) computeCommandEncoder];
    return c.compute;
}

// The GPU time of the labelled stages (scamgl_label / scamgl_gpu_times): each command buffer's GPUEndTime - GPUStartTime, booked
// to the label it was committed under. Only while a label is set (the shot's processing); no effect on what the GPU runs.
std::mutex gGpuTimesLock;
std::vector<std::pair<std::string, double>> gGpuTimes; // in first-use order
std::atomic<bool> gGpuTiming{false};                    // scamgl_gpu_timing: unlabelled contexts book to "merge / other"

void bookGpuTime(const std::string& label, double ms) {
    std::lock_guard<std::mutex> g(gGpuTimesLock);
    for (auto& e : gGpuTimes) if (e.first == label) { e.second += ms; return; }
    gGpuTimes.emplace_back(label, ms);
}

void submit(Context& c, bool wait) {
    endCompute(c);
    if (c.cb) {
        if (!c.label.empty() || gGpuTiming.load()) {
            const std::string label = c.label.empty() ? std::string("merge / other") : c.label;
            [c.cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
                const double ms = (b.GPUEndTime - b.GPUStartTime) * 1000.0;
                if (ms > 0 && ms < 600000) bookGpuTime(label, ms);
            }];
        }
        [c.cb commit];
        c.inFlight.push_back(c.cb);
        c.cb = nil;
    }
    if (wait) {
        for (id<MTLCommandBuffer> b : c.inFlight) {
            [b waitUntilCompleted];
            if (b.error) {
                std::fprintf(stderr, "SCAMGL: GPU error: %s\n", b.error.localizedDescription.UTF8String);
                if (c.error == GL_NO_ERROR) c.error = GL_OUT_OF_MEMORY;
            }
        }
        c.inFlight.clear();
    } else {
        // Drop the completed ones; the queue keeps the order of the rest.
        std::vector<id<MTLCommandBuffer>> pending;
        for (id<MTLCommandBuffer> b : c.inFlight) {
            if (b.status < MTLCommandBufferStatusCompleted) pending.push_back(b);
            else if (b.error && c.error == GL_NO_ERROR) c.error = GL_OUT_OF_MEMORY;
        }
        c.inFlight.swap(pending);
    }
}

// Waits until the GPU is done with `resource` (gLastUse: its last command buffer completed), gLock released meanwhile: this
// context's open command buffer is committed when it is that one; one of another context not committed yet: this context's
// whole queue as before. Nothing recorded: no wait.
void waitForUse(Context& c, id resource, std::unique_lock<std::recursive_mutex>& lock) {
    // the work recorded so far is handed to the GPU first (as the full wait did): it runs while this waits for `resource`'s
    // command buffer only (left open, the GPU would idle until the next flush: the fast merge's band readbacks)
    submit(c, false);
    auto it = gLastUse.find((__bridge const void*)resource);
    if (it == gLastUse.end()) return;
    id<MTLCommandBuffer> cb = it->second;
    if (!cb) { gLastUse.erase(it); return; }
    if (cb.status < MTLCommandBufferStatusCommitted) { submit(c, true); return; } // another context's, not committed yet
    if (cb.status < MTLCommandBufferStatusCompleted) {
        lock.unlock();
        [cb waitUntilCompleted];
        lock.lock();
    }
    if (cb.error) {
        std::fprintf(stderr, "SCAMGL: GPU error: %s\n", cb.error.localizedDescription.UTF8String);
        if (c.error == GL_NO_ERROR) c.error = GL_OUT_OF_MEMORY;
    }
    // every finished command buffer's error reported here as the full wait reported them (an earlier failed buffer: the
    // readback's caller must see it); the finished ones are dropped
    std::vector<id<MTLCommandBuffer>> pending;
    for (id<MTLCommandBuffer> b : c.inFlight) {
        if (b.status < MTLCommandBufferStatusCompleted) { pending.push_back(b); continue; }
        if (b.error) {
            std::fprintf(stderr, "SCAMGL: GPU error: %s\n", b.error.localizedDescription.UTF8String);
            if (c.error == GL_NO_ERROR) c.error = GL_OUT_OF_MEMORY;
        }
    }
    c.inFlight.swap(pending);
}

constexpr bool kPrivateTextures = true;

// A Metal object no longer used by GL (deleted, or its store replaced): its last-use entry goes too
inline void forgetUse(id resource) {
    if (resource) gLastUse.erase((__bridge const void*)resource);
}

// The staging copies of uploads made while work is in flight (glBufferSubData, glTexSubImage*): kept and refilled once the
// command buffer that read one has completed, instead of a new shared buffer each time (LaGpu uploads 24 MB per frame, 22-45
// times a quality shot). At most kStagingKept buffers / kStagingBytes are kept.
struct Staging {
    id<MTLBuffer> buffer = nil;
    __weak id<MTLCommandBuffer> reader = nil; // nil: free (never read, or the reader is done and gone)
    bool pending = false;                     // the reader was recorded (a weak nil then means it completed)
};
std::vector<Staging> gStaging;
constexpr size_t kStagingKept = 4, kStagingBytes = size_t(128) << 20;

id<MTLBuffer> stagingCopy(Context& c, const void* bytes, size_t length) {
    id<MTLCommandBuffer> reader = commandBuffer(c);
    auto freeNow = [](const Staging& s) {
        id<MTLCommandBuffer> r = s.reader;
        return !s.pending || !r || r.status >= MTLCommandBufferStatusCompleted;
    };
    for (Staging& s : gStaging) {
        if (s.buffer.length >= length && s.buffer.length <= 2 * length + 65536 && freeNow(s)) {
            std::memcpy(s.buffer.contents, bytes, length);
            s.reader = reader;
            s.pending = true;
            return s.buffer;
        }
    }
    id<MTLBuffer> fresh = [metalDevice() newBufferWithBytes:bytes length:NSUInteger(length) options:MTLResourceStorageModeShared];
    if (!fresh) return nil;
    if (length <= kStagingBytes / kStagingKept) {
        size_t total = length;
        for (const Staging& s : gStaging) total += s.buffer.length;
        // room: free kept buffers go first, the oldest first
        for (auto it = gStaging.begin(); it != gStaging.end() && (gStaging.size() >= kStagingKept || total > kStagingBytes);) {
            if (freeNow(*it)) { total -= it->buffer.length; it = gStaging.erase(it); } else ++it;
        }
        if (gStaging.size() < kStagingKept && total <= kStagingBytes) gStaging.push_back(Staging{fresh, reader, true});
    }
    return fresh;
}

void blit(Context& c, void (^body)(id<MTLBlitCommandEncoder>)) {
    endCompute(c);
    id<MTLBlitCommandEncoder> b = [commandBuffer(c) blitCommandEncoder];
    body(b);
    [b endEncoding];
}

// `region` of level 0 / slice 0 of `t` into `dst` rows of `dstRow` bytes (`bpp` bytes a texel): getBytes of a shared texture; a
// private one blitted into a shared buffer first (the same bytes), this context's queue waited for that blit
void readRegion(Context& c, id<MTLTexture> t, MTLRegion region, int bpp, uint8_t* dst, size_t dstRow, std::unique_lock<std::recursive_mutex>& lock) {
    if (t.storageMode != MTLStorageModePrivate) {
        [t getBytes:dst bytesPerRow:dstRow fromRegion:region mipmapLevel:0];
        return;
    }
    const size_t row = size_t(bpp) * region.size.width, bytes = row * region.size.height;
    id<MTLBuffer> staging = [metalDevice() newBufferWithLength:std::max<size_t>(bytes, 16) options:MTLResourceStorageModeShared];
    if (!staging) { fail(GL_OUT_OF_MEMORY); return; }
    used(c, t);
    blit(c, ^(id<MTLBlitCommandEncoder> e) {
        [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:region.origin sourceSize:region.size toBuffer:staging
           destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:bytes];
    });
    id<MTLCommandBuffer> cb = commandBuffer(c);
    submit(c, false);
    lock.unlock();
    [cb waitUntilCompleted];
    lock.lock();
    if (cb.error) {
        std::fprintf(stderr, "SCAMGL: GPU error: %s\n", cb.error.localizedDescription.UTF8String);
        if (c.error == GL_NO_ERROR) c.error = GL_OUT_OF_MEMORY;
    }
    const uint8_t* src = static_cast<const uint8_t*>(staging.contents);
    for (NSUInteger y = 0; y < region.size.height; ++y) std::memcpy(dst + y * dstRow, src + y * row, row);
}


// ---- formats ----

struct Format {
    MTLPixelFormat pixel;
    int bytes;
};

Format formatOf(GLenum internal) {
    switch (internal) {
    case GL_R8: return {MTLPixelFormatR8Unorm, 1};
    case GL_RG8: return {MTLPixelFormatRG8Unorm, 2};
    case GL_RGBA8: return {MTLPixelFormatRGBA8Unorm, 4};
    case GL_R8UI: return {MTLPixelFormatR8Uint, 1};
    case GL_RGBA8UI: return {MTLPixelFormatRGBA8Uint, 4};
    case GL_R16F: return {MTLPixelFormatR16Float, 2};
    case GL_RG16F: return {MTLPixelFormatRG16Float, 4};
    case GL_RGBA16F: return {MTLPixelFormatRGBA16Float, 8};
    case GL_R32F: return {MTLPixelFormatR32Float, 4};
    case GL_RG32F: return {MTLPixelFormatRG32Float, 8};
    case GL_RGBA32F: return {MTLPixelFormatRGBA32Float, 16};
    case GL_R16UI: return {MTLPixelFormatR16Uint, 2};
    case GL_RG16UI: return {MTLPixelFormatRG16Uint, 4};
    case GL_RGBA16UI: return {MTLPixelFormatRGBA16Uint, 8};
    case GL_R16I: return {MTLPixelFormatR16Sint, 2};
    case GL_R32UI: return {MTLPixelFormatR32Uint, 4};
    case GL_RG32UI: return {MTLPixelFormatRG32Uint, 8};
    case GL_RGBA32UI: return {MTLPixelFormatRGBA32Uint, 16};
    case GL_R32I: return {MTLPixelFormatR32Sint, 4};
    case GL_RG32I: return {MTLPixelFormatRG32Sint, 8};
    case GL_RGBA32I: return {MTLPixelFormatRGBA32Sint, 16};
    case GL_R11F_G11F_B10F: return {MTLPixelFormatRG11B10Float, 4};
    // Metal has no 3-channel formats: RGB is stored as RGBA (uploads and readbacks convert, alpha 1)
    case GL_RGB8: return {MTLPixelFormatRGBA8Unorm, 4};
    case GL_RGB16F: return {MTLPixelFormatRGBA16Float, 8};
    case GL_RGB32F: return {MTLPixelFormatRGBA32Float, 16};
    case GL_RGB16UI: return {MTLPixelFormatRGBA16Uint, 8};
    case GL_RGB32UI: return {MTLPixelFormatRGBA32Uint, 16};
    case GL_RG8UI: return {MTLPixelFormatRG8Uint, 2};
    case GL_R8I: return {MTLPixelFormatR8Sint, 1};
    case GL_RGBA8I: return {MTLPixelFormatRGBA8Sint, 4};
    case GL_RG16I: return {MTLPixelFormatRG16Sint, 4};
    case GL_RGBA16I: return {MTLPixelFormatRGBA16Sint, 8};
    case GL_RGB10_A2: return {MTLPixelFormatRGB10A2Unorm, 4};
    default: return {MTLPixelFormatInvalid, 0};
    }
}

int componentsOf(GLenum format) {
    switch (format) {
    case GL_RED: case GL_RED_INTEGER: return 1;
    case GL_RG: case GL_RG_INTEGER: return 2;
    case GL_RGB: case GL_RGB_INTEGER: return 3;
    case GL_RGBA: case GL_RGBA_INTEGER: return 4;
    default: return 0;
    }
}

int typeBytes(GLenum type) {
    switch (type) {
    case GL_UNSIGNED_BYTE: case GL_BYTE: return 1;
    case GL_UNSIGNED_SHORT: case GL_SHORT: case GL_HALF_FLOAT: return 2;
    case GL_UNSIGNED_INT: case GL_INT: case GL_FLOAT: return 4;
    default: return 0;
    }
}

size_t rowBytes(int width, int bytesPerPixel, GLint rowLength, GLint alignment) {
    size_t row = size_t(rowLength > 0 ? rowLength : width) * size_t(bytesPerPixel);
    const size_t a = size_t(alignment > 0 ? alignment : 1);
    return (row + a - 1) / a * a;
}

// ---- pixel conversions between client data (format / type) and the Metal storage ----

enum class Kind { F16, F32, U8, U16, U32, I8, I16, I32 };

struct Layout {
    int components = 0;
    Kind kind = Kind::U8;
    int size() const {
        const int b = kind == Kind::U8 || kind == Kind::I8 ? 1 : kind == Kind::F16 || kind == Kind::U16 || kind == Kind::I16 ? 2 : 4;
        return components * b;
    }
};

Layout clientLayout(GLenum format, GLenum type) {
    Kind k = Kind::U8;
    switch (type) {
    case GL_FLOAT: k = Kind::F32; break;
    case GL_HALF_FLOAT: k = Kind::F16; break;
    case GL_UNSIGNED_SHORT: k = Kind::U16; break;
    case GL_UNSIGNED_INT: k = Kind::U32; break;
    case GL_BYTE: k = Kind::I8; break;
    case GL_SHORT: k = Kind::I16; break;
    case GL_INT: k = Kind::I32; break;
    default: k = Kind::U8; break;
    }
    return {componentsOf(format), k};
}

Layout storageLayout(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Uint: return {1, Kind::U8};
    case MTLPixelFormatRG8Unorm: case MTLPixelFormatRG8Uint: return {2, Kind::U8};
    case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Uint: return {4, Kind::U8};
    case MTLPixelFormatR8Sint: return {1, Kind::I8};
    case MTLPixelFormatRGBA8Sint: return {4, Kind::I8};
    case MTLPixelFormatR16Float: return {1, Kind::F16};
    case MTLPixelFormatRG16Float: return {2, Kind::F16};
    case MTLPixelFormatRGBA16Float: return {4, Kind::F16};
    case MTLPixelFormatR32Float: return {1, Kind::F32};
    case MTLPixelFormatRG32Float: return {2, Kind::F32};
    case MTLPixelFormatRGBA32Float: return {4, Kind::F32};
    case MTLPixelFormatR16Uint: return {1, Kind::U16};
    case MTLPixelFormatRG16Uint: return {2, Kind::U16};
    case MTLPixelFormatRGBA16Uint: return {4, Kind::U16};
    case MTLPixelFormatR16Sint: return {1, Kind::I16};
    case MTLPixelFormatRG16Sint: return {2, Kind::I16};
    case MTLPixelFormatRGBA16Sint: return {4, Kind::I16};
    case MTLPixelFormatR32Uint: return {1, Kind::U32};
    case MTLPixelFormatRG32Uint: return {2, Kind::U32};
    case MTLPixelFormatRGBA32Uint: return {4, Kind::U32};
    case MTLPixelFormatR32Sint: return {1, Kind::I32};
    case MTLPixelFormatRG32Sint: return {2, Kind::I32};
    case MTLPixelFormatRGBA32Sint: return {4, Kind::I32};
    default: return {0, Kind::U8};
    }
}

inline uint16_t floatToHalf(float f) {
    uint32_t x;
    std::memcpy(&x, &f, 4);
    const uint32_t sign = (x >> 16) & 0x8000u;
    const uint32_t mant = x & 0x007fffffu;
    const int exp = int((x >> 23) & 0xff) - 127 + 15;
    if (((x >> 23) & 0xff) == 0xff) return uint16_t(sign | 0x7c00u | (mant ? 0x200u : 0u));
    if (exp >= 31) return uint16_t(sign | 0x7c00u);
    if (exp <= 0) {
        if (exp < -10) return uint16_t(sign);
        const uint32_t m = mant | 0x00800000u;
        const int shift = 14 - exp;
        uint32_t h = m >> shift;
        const uint32_t rem = m & ((1u << shift) - 1), half = 1u << (shift - 1);
        if (rem > half || (rem == half && (h & 1u))) ++h;
        return uint16_t(sign | h);
    }
    uint32_t h = (uint32_t(exp) << 10) | (mant >> 13);
    const uint32_t rem = mant & 0x1fffu;
    if (rem > 0x1000u || (rem == 0x1000u && (h & 1u))) ++h; // round to nearest even (as the GL / Metal conversions)
    return uint16_t(sign | h);
}

inline float halfToFloat(uint16_t h) {
    const uint32_t sign = uint32_t(h & 0x8000u) << 16;
    uint32_t exp = (h >> 10) & 0x1f, mant = h & 0x3ffu, x;
    if (exp == 0) {
        if (mant == 0) x = sign;
        else {
            exp = 127 - 15 + 1;
            while (!(mant & 0x400u)) { mant <<= 1; --exp; }
            mant &= 0x3ffu;
            x = sign | (exp << 23) | (mant << 13);
        }
    } else if (exp == 31) x = sign | 0x7f800000u | (mant << 13);
    else x = sign | ((exp - 15 + 127) << 23) | (mant << 13);
    float f;
    std::memcpy(&f, &x, 4);
    return f;
}

inline double readComponent(const uint8_t* p, Kind k) {
    switch (k) {
    case Kind::F16: { uint16_t v; std::memcpy(&v, p, 2); return halfToFloat(v); }
    case Kind::F32: { float v; std::memcpy(&v, p, 4); return v; }
    case Kind::U8: return p[0];
    case Kind::I8: return int8_t(p[0]);
    case Kind::U16: { uint16_t v; std::memcpy(&v, p, 2); return v; }
    case Kind::I16: { int16_t v; std::memcpy(&v, p, 2); return v; }
    case Kind::U32: { uint32_t v; std::memcpy(&v, p, 4); return v; }
    case Kind::I32: { int32_t v; std::memcpy(&v, p, 4); return v; }
    }
    return 0;
}

inline void writeComponent(uint8_t* p, Kind k, double v) {
    switch (k) {
    case Kind::F16: { const uint16_t h = floatToHalf(float(v)); std::memcpy(p, &h, 2); break; }
    case Kind::F32: { const float f = float(v); std::memcpy(p, &f, 4); break; }
    case Kind::U8: p[0] = uint8_t(v); break;
    case Kind::I8: p[0] = uint8_t(int8_t(v)); break;
    case Kind::U16: { const uint16_t x = uint16_t(v); std::memcpy(p, &x, 2); break; }
    case Kind::I16: { const int16_t x = int16_t(v); std::memcpy(p, &x, 2); break; }
    case Kind::U32: { const uint32_t x = uint32_t(v); std::memcpy(p, &x, 4); break; }
    case Kind::I32: { const int32_t x = int32_t(v); std::memcpy(p, &x, 4); break; }
    }
}

// A float client value of an 8-bit normalised storage (GL_FLOAT into RGBA8) is in 0..1; bytes of U8 storage are copied.
inline double toStorage(double v, Kind client, Kind storage, bool normalised) {
    if (normalised && (client == Kind::F32 || client == Kind::F16)) return std::round(std::min(1.0, std::max(0.0, v)) * 255.0);
    return v;
}
inline double toClient(double v, Kind storage, Kind client, bool normalised) {
    if (normalised && (client == Kind::F32 || client == Kind::F16)) return v / 255.0;
    return v;
}

/// Rows of `width` pixels from `src` (client layout, `srcRow` bytes a row) into tight storage-layout rows.
std::vector<uint8_t> convertRows(const uint8_t* src, size_t srcRow, int width, int height, Layout from, Layout to, bool normalised) {
    std::vector<uint8_t> out(size_t(to.size()) * size_t(width) * size_t(height));
    const int fb = from.size() / std::max(from.components, 1), tb = to.size() / std::max(to.components, 1);
    for (int y = 0; y < height; ++y) {
        const uint8_t* s = src + size_t(y) * srcRow;
        uint8_t* d = out.data() + size_t(y) * size_t(width) * size_t(to.size());
        for (int x = 0; x < width; ++x) {
            for (int c = 0; c < to.components; ++c) {
                const double v = c < from.components ? toStorage(readComponent(s + c * fb, from.kind), from.kind, to.kind, normalised)
                                                     : (to.kind == Kind::U8 && normalised ? 255.0 : 1.0);
                writeComponent(d + c * tb, to.kind, v);
            }
            s += from.size();
            d += to.size();
        }
    }
    return out;
}

id<MTLSamplerState> samplerOf(Texture& t) {
    if (t.sampler) return t.sampler;
    MTLSamplerDescriptor* d = [MTLSamplerDescriptor new];
    auto filter = [](GLint f) { return f == GL_NEAREST || f == GL_NEAREST_MIPMAP_NEAREST || f == GL_NEAREST_MIPMAP_LINEAR
                                       ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear; };
    auto wrap = [](GLint w) { return w == GL_REPEAT ? MTLSamplerAddressModeRepeat
                                     : w == GL_MIRRORED_REPEAT ? MTLSamplerAddressModeMirrorRepeat : MTLSamplerAddressModeClampToEdge; };
    d.minFilter = filter(t.minFilter);
    d.magFilter = filter(t.magFilter);
    d.mipFilter = t.levels > 1 && (t.minFilter == GL_LINEAR_MIPMAP_LINEAR || t.minFilter == GL_NEAREST_MIPMAP_LINEAR)
        ? MTLSamplerMipFilterLinear : t.levels > 1 && t.minFilter != GL_NEAREST && t.minFilter != GL_LINEAR
        ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterNotMipmapped;
    d.sAddressMode = wrap(t.wrapS);
    d.tAddressMode = wrap(t.wrapT);
    d.rAddressMode = MTLSamplerAddressModeClampToEdge;
    d.normalizedCoordinates = YES;
    t.sampler = [metalDevice() newSamplerStateWithDescriptor:d];
    return t.sampler;
}

id<MTLBuffer> dummyBuffer() {
    static id<MTLBuffer> b = [metalDevice() newBufferWithLength:256 options:MTLResourceStorageModeShared];
    return b;
}

Buffer* bufferBound(Context& c, GLenum target) {
    auto it = c.bound.find(target);
    if (it == c.bound.end() || it->second == 0) return nullptr;
    auto b = gBuffers.find(it->second);
    return b == gBuffers.end() ? nullptr : &b->second;
}

// ---- programs ----

void setupLocations(Program& p) {
    p.locations.clear();
    p.byName.clear();
    const auto& c = p.code->compiled;
    p.block.assign(c.blockSize, 0);
    for (int m = 0; m < int(c.members.size()); ++m) {
        const auto& member = c.members[m];
        const int base = int(p.locations.size());
        for (uint32_t e = 0; e < member.count; ++e) p.locations.push_back({m, int(e), -1});
        p.byName[member.name] = base;
        if (member.arrayStride) {
            for (uint32_t e = 0; e < member.count; ++e) p.byName[member.name + "[" + std::to_string(e) + "]"] = base + int(e);
        }
    }
    p.samplerUnit.clear();
    int s = 0;
    for (const auto& r : c.resources) {
        if (r.type != scamgl::Resource::Sampled) continue;
        p.byName[r.name] = int(p.locations.size());
        p.locations.push_back({-1, 0, s});
        p.samplerUnit.push_back(std::max(0, r.glBinding));
        ++s;
    }
}

// the translations on disk (Caches/scamgl): a launch after the first runs no glslang / SPIRV-Cross for a program it saw before
void ensureTranslationCache() {
#if TARGET_OS_IPHONE
    static std::once_flag once;
    std::call_once(once, [] {
        NSString* caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        if (!caches) return;
        NSString* dir = [caches stringByAppendingPathComponent:@"scamgl"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        scamgl::setCacheDir(dir.fileSystemRepresentation);
    });
#endif
}

// The link cache under gLock; the compile itself (glslang, SPIRV-Cross, the MSL library, the pipeline) without it: a shot's GL
// calls on another thread no longer wait behind the warm-up's programs (two threads linking one source both compile it, the
// first stored wins). The callers must not hold gLock (it is recursive: held, the compile would still run under it).
std::shared_ptr<Linked> cachedLink(const std::string& key) {
    Guard g(gLock);
    auto it = gLinkCache.find(key);
    return it == gLinkCache.end() ? nullptr : it->second;
}
std::shared_ptr<Linked> storeLink(const std::string& key, const std::shared_ptr<Linked>& linked, const std::string& recipe) {
    Guard g(gLock);
    auto placed = gLinkCache.emplace(key, linked);
    if (placed.second) gRecorded.push_back(recipe);
    return placed.first->second;
}

std::shared_ptr<Linked> linkCompute(const std::string& source) {
    ensureTranslationCache();
    if (auto cached = cachedLink(source)) return cached;
    auto linked = std::make_shared<Linked>();
#if TARGET_OS_IPHONE
    linked->compiled = scamgl::compile(source, scamgl::Stage::Compute, true);
#else
    linked->compiled = scamgl::compile(source, scamgl::Stage::Compute, false);
#endif
    if (!linked->compiled.ok) {
        linked->log = linked->compiled.log;
        return linked;
    }
    MTLCompileOptions* options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion2_4;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    options.fastMathEnabled = NO;
#pragma clang diagnostic pop
    NSError* error = nil;
    id<MTLLibrary> library = [metalDevice() newLibraryWithSource:@(linked->compiled.msl.c_str()) options:options error:&error];
    if (!library) {
        linked->log = std::string("MSL: ") + (error ? error.localizedDescription.UTF8String : "unknown");
        if (verbose()) std::fprintf(stderr, "SCAMGL MSL source:\n%s\n", linked->compiled.msl.c_str());
        return linked;
    }
    id<MTLFunction> function = [library newFunctionWithName:@(linked->compiled.entry.c_str())];
    if (!function) {
        linked->log = "MSL: no entry point " + linked->compiled.entry;
        return linked;
    }
    linked->pipeline = [metalDevice() newComputePipelineStateWithFunction:function error:&error];
    if (!linked->pipeline) {
        linked->log = std::string("pipeline: ") + (error ? error.localizedDescription.UTF8String : "unknown");
        return linked;
    }
    const auto& l = linked->compiled.local;
    if (l[0] * l[1] * l[2] > linked->pipeline.maxTotalThreadsPerThreadgroup) {
        linked->log = "workgroup " + std::to_string(l[0] * l[1] * l[2]) + " above the pipeline's "
            + std::to_string(linked->pipeline.maxTotalThreadsPerThreadgroup) + " threads";
        linked->pipeline = nil;
        return linked;
    }
    linked = storeLink(source, linked, "C\n" + source);
    note("linked " + linked->compiled.entry + " local " + std::to_string(l[0]) + "x" + std::to_string(l[1]) + "x" + std::to_string(l[2]));
    return linked;
}

id<MTLFunction> functionOf(const scamgl::Compiled& c, std::string& log) {
    MTLCompileOptions* options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion2_4;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    options.fastMathEnabled = NO;
#pragma clang diagnostic pop
    NSError* error = nil;
    id<MTLLibrary> library = [metalDevice() newLibraryWithSource:@(c.msl.c_str()) options:options error:&error];
    if (!library) {
        log = std::string("MSL: ") + (error ? error.localizedDescription.UTF8String : "unknown");
        if (verbose()) std::fprintf(stderr, "SCAMGL MSL source:\n%s\n", c.msl.c_str());
        return nil;
    }
    id<MTLFunction> f = [library newFunctionWithName:@(c.entry.c_str())];
    if (!f) log = "MSL: no entry point " + c.entry;
    return f;
}

std::shared_ptr<Linked> linkRender(const std::string& vs, const std::string& fs) {
    const std::string key = "R\n" + vs + "\x01" + fs;
    if (auto cached = cachedLink(key)) return cached;
    auto linked = std::make_shared<Linked>();
    linked->render = true;
#if TARGET_OS_IPHONE
    const bool ios = true;
#else
    const bool ios = false;
#endif
    ensureTranslationCache();
    const scamgl::Compiled v = scamgl::compile(vs, scamgl::Stage::Vertex, ios);
    if (!v.ok) { linked->log = "vertex " + v.log; return linked; }
    for (const auto& r : v.resources) {
        if (r.type != scamgl::Resource::DefaultBlock || !v.members.empty()) { linked->log = "vertex shader resources are not supported"; return linked; }
    }
    linked->compiled = scamgl::compile(fs, scamgl::Stage::Fragment, ios);
    if (!linked->compiled.ok) { linked->log = "fragment " + linked->compiled.log; return linked; }
    linked->vertex = functionOf(v, linked->log);
    if (!linked->vertex) return linked;
    linked->fragment = functionOf(linked->compiled, linked->log);
    if (!linked->fragment) return linked;
    linked->recipe = key;
    linked = storeLink(key, linked, key);
    note("linked render program " + linked->compiled.entry);
    return linked;
}

template <typename T>
void writeUniform(GLuint programName, GLint location, int components, GLsizei count, const T* values, int kind) {
    Guard g(gLock);
    if (location < 0) return;
    auto it = gPrograms.find(programName);
    if (it == gPrograms.end() || !it->second.linked) { fail(GL_INVALID_OPERATION); return; }
    Program& p = it->second;
    if (location >= int(p.locations.size())) { fail(GL_INVALID_OPERATION); return; }
    const Location loc = p.locations[size_t(location)];
    if (loc.sampler >= 0) {
        if (kind == 0) { fail(GL_INVALID_OPERATION); return; }
        p.samplerUnit[size_t(loc.sampler)] = int(values[0]);
        return;
    }
    const auto& m = p.code->compiled.members[size_t(loc.member)];
    const uint32_t stride = m.arrayStride ? m.arrayStride : m.size;
    for (GLsizei i = 0; i < count; ++i) {
        const uint32_t element = uint32_t(loc.element + i);
        if (element >= m.count) break;
        uint8_t* dst = p.block.data() + m.offset + element * stride;
        const int n = std::min<int>(components, int(m.vecsize));
        for (int k = 0; k < n; ++k) {
            const T v = values[size_t(i) * size_t(components) + size_t(k)];
            if (m.baseType == 0) { const float f = float(v); std::memcpy(dst + 4 * k, &f, 4); }
            else if (m.baseType == 1) { const int32_t x = int32_t(v); std::memcpy(dst + 4 * k, &x, 4); }
            else if (m.baseType == 2) { const uint32_t x = uint32_t(v); std::memcpy(dst + 4 * k, &x, 4); }
            else { const uint32_t x = v != T(0) ? 1u : 0u; std::memcpy(dst + 4 * k, &x, 4); }
        }
    }
}

id<MTLTexture> imageView(Texture& t, const ImageUnit& unit, bool arrayed) {
    id<MTLTexture> view = t.mtl;
    const Format f = formatOf(unit.format);
    const bool sliceOfArray = t.target == GL_TEXTURE_2D_ARRAY && !arrayed;
    const bool otherFormat = f.pixel != MTLPixelFormatInvalid && f.pixel != t.mtl.pixelFormat;
    if (sliceOfArray || otherFormat || unit.level != 0) {
        const MTLTextureType type = arrayed ? MTLTextureType2DArray : MTLTextureType2D;
        const NSUInteger first = sliceOfArray ? NSUInteger(unit.layer) : 0;
        const NSUInteger slices = sliceOfArray ? 1 : NSUInteger(t.layers);
        view = [t.mtl newTextureViewWithPixelFormat:otherFormat ? f.pixel : t.mtl.pixelFormat textureType:type
                                             levels:NSMakeRange(NSUInteger(unit.level), 1) slices:NSMakeRange(first, slices)];
    }
    return view;
}

void bindResources(Context& c, Program& p, id<MTLComputeCommandEncoder> ce, id<MTLRenderCommandEncoder> re) {
    const auto& cc = p.code->compiled;
    auto setBuffer = [&](id<MTLBuffer> buf, NSUInteger offset, int index) {
        if (ce) [ce setBuffer:buf offset:offset atIndex:NSUInteger(index)]; else [re setFragmentBuffer:buf offset:offset atIndex:NSUInteger(index)];
    };
    auto setBytes = [&](const void* bytes, size_t length, int index) {
        if (ce) [ce setBytes:bytes length:length atIndex:NSUInteger(index)]; else [re setFragmentBytes:bytes length:length atIndex:NSUInteger(index)];
    };
    auto setTexture = [&](id<MTLTexture> t, int index) {
        if (ce) [ce setTexture:t atIndex:NSUInteger(index)]; else [re setFragmentTexture:t atIndex:NSUInteger(index)];
    };
    auto setSampler = [&](id<MTLSamplerState> s, int index) {
        if (ce) [ce setSamplerState:s atIndex:NSUInteger(index)]; else [re setFragmentSamplerState:s atIndex:NSUInteger(index)];
    };
    std::vector<uint32_t> sizes(32, 0);
    int sampled = 0;
    for (const auto& r : cc.resources) {
        switch (r.type) {
        case scamgl::Resource::DefaultBlock:
            if (p.block.empty()) setBuffer(dummyBuffer(), 0, r.mslIndex);
            else if (p.block.size() <= 4096) setBytes(p.block.data(), p.block.size(), r.mslIndex);
            else setBuffer([metalDevice() newBufferWithBytes:p.block.data() length:p.block.size() options:MTLResourceStorageModeShared], 0, r.mslIndex);
            break;
        case scamgl::Resource::UniformBlock:
        case scamgl::Resource::StorageBlock: {
            const int slot = r.glBinding >= 0 && r.glBinding < 96 ? r.glBinding : 0;
            const BufferBinding& b = r.type == scamgl::Resource::UniformBlock ? c.ubo[slot] : c.ssbo[slot];
            auto bit = gBuffers.find(b.buffer);
            if (bit == gBuffers.end() || !bit->second.mtl) {
                setBuffer(dummyBuffer(), 0, r.mslIndex);
            } else {
                setBuffer(bit->second.mtl, NSUInteger(b.offset), r.mslIndex);
                used(c, bit->second.mtl);
                const size_t avail = bit->second.size - size_t(b.offset);
                if (r.mslIndex < 32) sizes[size_t(r.mslIndex)] = uint32_t(b.size > 0 ? std::min<size_t>(size_t(b.size), avail) : avail);
            }
            break;
        }
        case scamgl::Resource::Image: {
            const ImageUnit& unit = c.images[r.glBinding & 31];
            auto t = gTextures.find(unit.texture);
            if (t == gTextures.end() || !t->second.mtl) { note("image unit " + std::to_string(r.glBinding) + " empty"); break; }
            setTexture(imageView(t->second, unit, r.arrayed), r.mslIndex);
            used(c, t->second.mtl);
            break;
        }
        case scamgl::Resource::Sampled: {
            const int unit = p.samplerUnit[size_t(sampled++)] & 31;
            const GLuint name = r.volume ? c.tex3D[unit] : r.arrayed ? c.tex2DArray[unit] : c.tex2D[unit];
            auto t = gTextures.find(name);
            if (t == gTextures.end() || !t->second.mtl) { note("texture unit " + std::to_string(unit) + " empty"); break; }
            setTexture(t->second.mtl, r.mslIndex);
            used(c, t->second.mtl);
            setSampler(samplerOf(t->second), r.mslSampler);
            break;
        }
        }
    }
    if (cc.bufferSizeIndex >= 0) setBytes(sizes.data(), sizes.size() * 4, cc.bufferSizeIndex);
}

void dispatch(Context& c, GLuint gx, GLuint gy, GLuint gz, Buffer* indirect, GLintptr indirectOffset) {
    auto pit = gPrograms.find(c.program);
    if (pit == gPrograms.end() || !pit->second.linked || !pit->second.code || !pit->second.code->pipeline || pit->second.code->render) { fail(GL_INVALID_OPERATION); return; }
    Program& p = pit->second;
    const auto& cc = p.code->compiled;
    id<MTLComputeCommandEncoder> e = computeEncoder(c);
    [e setComputePipelineState:p.code->pipeline];
    bindResources(c, p, e, nil);
    const MTLSize local = MTLSizeMake(cc.local[0], cc.local[1], cc.local[2]);
    if (indirect) {
        used(c, indirect->mtl);
        [e dispatchThreadgroupsWithIndirectBuffer:indirect->mtl indirectBufferOffset:NSUInteger(indirectOffset) threadsPerThreadgroup:local];
    } else {
        if (gx == 0 || gy == 0 || gz == 0) return;
        [e dispatchThreadgroups:MTLSizeMake(gx, gy, gz) threadsPerThreadgroup:local];
    }
}

GLuint newName() { return gNextName++; }

} // namespace

// ================================ EGL ================================

extern "C" {

EGLDisplay eglGetDisplay(EGLNativeDisplayType) { return reinterpret_cast<EGLDisplay>(1); }
EGLBoolean eglInitialize(EGLDisplay, EGLint* major, EGLint* minor) {
    if (major) *major = 1;
    if (minor) *minor = 5;
    return metalDevice() ? EGL_TRUE : EGL_FALSE;
}
EGLBoolean eglTerminate(EGLDisplay) { return EGL_TRUE; }
EGLBoolean eglBindAPI(EGLenum) { return EGL_TRUE; }
EGLint eglGetError(void) { return EGL_SUCCESS; }
const char* eglQueryString(EGLDisplay, EGLint name) {
    if (name == EGL_VENDOR) return "SCAMERA";
    if (name == EGL_VERSION) return "1.5 SCAMERA Metal";
    if (name == EGL_CLIENT_APIS) return "OpenGL_ES";
    return "EGL_KHR_surfaceless_context";
}
EGLBoolean eglChooseConfig(EGLDisplay, const EGLint*, EGLConfig* configs, EGLint size, EGLint* count) {
    if (configs && size > 0) configs[0] = reinterpret_cast<EGLConfig>(1);
    if (count) *count = 1;
    return EGL_TRUE;
}
EGLContext eglCreateContext(EGLDisplay, EGLConfig, EGLContext, const EGLint*) {
    if (!metalDevice()) return EGL_NO_CONTEXT;
    auto* c = new Context();
    c->queue = [metalDevice() newCommandQueue];
    return c;
}
EGLBoolean eglDestroyContext(EGLDisplay, EGLContext context) {
    auto* c = static_cast<Context*>(context);
    if (!c) return EGL_FALSE;
    submit(*c, true);
    if (gCurrent == c) gCurrent = nullptr;
    delete c;
    return EGL_TRUE;
}
EGLSurface eglCreatePbufferSurface(EGLDisplay, EGLConfig, const EGLint*) { return reinterpret_cast<EGLSurface>(2); }
EGLBoolean eglDestroySurface(EGLDisplay, EGLSurface) { return EGL_TRUE; }
EGLBoolean eglMakeCurrent(EGLDisplay, EGLSurface, EGLSurface, EGLContext context) {
    if (gCurrent && gCurrent != context) submit(*gCurrent, false);
    gCurrent = static_cast<Context*>(context);
    return EGL_TRUE;
}
EGLBoolean eglQueryContext(EGLDisplay, EGLContext, EGLint, EGLint*) { return EGL_FALSE; }
__eglMustCastToProperFunctionPointerType eglGetProcAddress(const char*) { return nullptr; }

// ================================ GL ================================

GLenum glGetError(void) {
    Context* c = ctx();
    if (!c) return GL_NO_ERROR;
    const GLenum e = c->error;
    c->error = GL_NO_ERROR;
    return e;
}

const GLubyte* glGetString(GLenum name) {
    switch (name) {
    case GL_VENDOR: return reinterpret_cast<const GLubyte*>("SCAMERA");
    case GL_RENDERER: return reinterpret_cast<const GLubyte*>("Apple GPU (SCAMERA Metal)");
    case GL_VERSION: return reinterpret_cast<const GLubyte*>("OpenGL ES 3.1 SCAMERA Metal");
    case GL_SHADING_LANGUAGE_VERSION: return reinterpret_cast<const GLubyte*>("OpenGL ES GLSL ES 3.10");
    case GL_EXTENSIONS: {
        // what the Metal backend serves: float / half-float colour attachments on every Apple GPU, filtered 32-bit float
        // textures where the device filters them (the fast merge reads both)
        static const std::string extensions = std::string("GL_EXT_color_buffer_float GL_EXT_color_buffer_half_float")
            + (metalDevice().supports32BitFloatFiltering ? " GL_OES_texture_float_linear" : "");
        return reinterpret_cast<const GLubyte*>(extensions.c_str());
    }
    default: return nullptr;
    }
}

void glGetIntegerv(GLenum name, GLint* data) {
    Context* c = ctx();
    switch (name) {
    case GL_MAX_SHADER_STORAGE_BLOCK_SIZE: *data = 128 << 20; break;
    case GL_MAX_TEXTURE_SIZE: *data = 16384; break;
    case GL_MAX_ARRAY_TEXTURE_LAYERS: *data = 2048; break;
    case GL_MAX_COMPUTE_IMAGE_UNIFORMS: *data = 8; break;
    case GL_MAX_IMAGE_UNITS: *data = 8; break;
    case GL_MAX_COMPUTE_SHADER_STORAGE_BLOCKS: *data = 16; break;
    case GL_MAX_COMPUTE_TEXTURE_IMAGE_UNITS: *data = 16; break;
    case GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS: *data = 80; break;
    case GL_MAX_VIEWPORT_DIMS: data[0] = data[1] = 16384; break;
    case GL_NUM_PROGRAM_BINARY_FORMATS: *data = 0; break;
    case GL_SHADER_STORAGE_BUFFER_OFFSET_ALIGNMENT: *data = 16; break;
    case GL_ACTIVE_TEXTURE: *data = GLint(GL_TEXTURE0 + (c ? c->activeUnit : 0)); break;
    case GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS: *data = 1024; break;
    case GL_FRAMEBUFFER_BINDING: *data = GLint(c ? c->drawFb : 0); break;
    case GL_TEXTURE_BINDING_2D: *data = GLint(c ? c->tex2D[c->activeUnit] : 0); break;
    case GL_CURRENT_PROGRAM: *data = GLint(c ? c->program : 0); break;
    case GL_VIEWPORT: if (c) for (int i = 0; i < 4; ++i) data[i] = c->viewport[i]; break;
    case GL_MAX_COMPUTE_SHARED_MEMORY_SIZE: *data = 32768; break;
    default: *data = 0; note("glGetIntegerv " + std::to_string(name)); break;
    }
}

void glGetInteger64v(GLenum name, GLint64* data) {
    if (name == GL_MAX_SHADER_STORAGE_BLOCK_SIZE) { *data = GLint64(128) << 20; return; }
    GLint v = 0;
    glGetIntegerv(name, &v);
    *data = v;
}

void glGetIntegeri_v(GLenum name, GLuint index, GLint* data) {
    if (name == GL_MAX_COMPUTE_WORK_GROUP_COUNT) { *data = 65535; return; }
    if (name == GL_MAX_COMPUTE_WORK_GROUP_SIZE) { *data = index == 2 ? 64 : 1024; return; }
    *data = 0;
}

void glFlush(void) { if (Context* c = ctx()) submit(*c, false); }
void glFinish(void) { if (Context* c = ctx()) submit(*c, true); }
void glMemoryBarrier(GLbitfield) {} // serial compute encoder + tracked resources: Metal orders the dispatches
static void enable(GLenum cap, bool on) {
    Context* c = ctx();
    if (!c) return;
    if (cap == GL_BLEND) c->blend = on;
    else if (cap == GL_SCISSOR_TEST) c->scissorTest = on;
}
void glEnable(GLenum cap) { enable(cap, true); }
void glDisable(GLenum cap) { enable(cap, false); }
void glBlendEquation(GLenum mode) { if (Context* c = ctx()) c->blendEquation = mode; }
void glBlendFunc(GLenum src, GLenum dst) { if (Context* c = ctx()) { c->blendSrc = src; c->blendDst = dst; } }
void glViewport(GLint x, GLint y, GLsizei w, GLsizei h) {
    if (Context* c = ctx()) { c->viewport[0] = x; c->viewport[1] = y; c->viewport[2] = w; c->viewport[3] = h; }
}
void glScissor(GLint x, GLint y, GLsizei w, GLsizei h) {
    if (Context* c = ctx()) { c->scissor[0] = x; c->scissor[1] = y; c->scissor[2] = w; c->scissor[3] = h; }
}
void glPixelStorei(GLenum name, GLint value) {
    Context* c = ctx();
    if (!c) return;
    if (name == GL_UNPACK_ROW_LENGTH) c->unpackRowLength = value;
    else if (name == GL_UNPACK_ALIGNMENT) c->unpackAlignment = value;
    else if (name == GL_PACK_ROW_LENGTH) c->packRowLength = value;
    else if (name == GL_PACK_ALIGNMENT) c->packAlignment = value;
}

// ---- buffers ----

void glGenBuffers(GLsizei n, GLuint* names) {
    Guard g(gLock);
    for (GLsizei i = 0; i < n; ++i) { names[i] = newName(); gBuffers[names[i]] = Buffer(); }
}
void glDeleteBuffers(GLsizei n, const GLuint* names) {
    Guard g(gLock);
    for (GLsizei i = 0; i < n; ++i) {
        auto it = gBuffers.find(names[i]);
        if (it != gBuffers.end()) { forgetUse(it->second.mtl); gBuffers.erase(it); }
    }
}
void glBindBuffer(GLenum target, GLuint name) {
    Guard g(gLock);
    Context* c = ctx();
    if (!c) return;
    if (name && !gBuffers.count(name)) gBuffers[name] = Buffer();
    c->bound[target] = name;
}
void glBindBufferBase(GLenum target, GLuint index, GLuint name) {
    Guard g(gLock);
    Context* c = ctx();
    if (!c || index >= 96) { fail(GL_INVALID_VALUE); return; }
    if (name && !gBuffers.count(name)) gBuffers[name] = Buffer();
    BufferBinding b{name, 0, 0};
    if (target == GL_SHADER_STORAGE_BUFFER) c->ssbo[index] = b;
    else if (target == GL_UNIFORM_BUFFER) c->ubo[index] = b;
    c->bound[target] = name;
}
void glBindBufferRange(GLenum target, GLuint index, GLuint name, GLintptr offset, GLsizeiptr size) {
    Guard g(gLock);
    Context* c = ctx();
    if (!c || index >= 96) { fail(GL_INVALID_VALUE); return; }
    BufferBinding b{name, offset, size};
    if (target == GL_SHADER_STORAGE_BUFFER) c->ssbo[index] = b;
    else if (target == GL_UNIFORM_BUFFER) c->ubo[index] = b;
    c->bound[target] = name;
}
void glBufferData(GLenum target, GLsizeiptr size, const void* data, GLenum) {
    Guard g(gLock);
    Context* c = ctx();
    if (!c) return;
    Buffer* b = bufferBound(*c, target);
    if (!b || size < 0) { fail(GL_INVALID_OPERATION); return; }
    // A new store: commands recorded before keep the old one alive.
    const size_t bytes = std::max<size_t>(size_t(size), 16);
    forgetUse(b->mtl); // the old store: commands recorded before keep it alive, no CPU access reaches it any more
    b->mtl = data ? [metalDevice() newBufferWithBytes:data length:bytes options:MTLResourceStorageModeShared]
                  : [metalDevice() newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    if (!b->mtl) { b->size = 0; fail(GL_OUT_OF_MEMORY); return; }
    if (data && size_t(size) < bytes) std::memset(static_cast<uint8_t*>(b->mtl.contents) + size, 0, bytes - size_t(size));
    if (!data) std::memset(b->mtl.contents, 0, bytes);
    b->size = size_t(size);
}
void glBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void* data) {
    Guard g(gLock);
    Context* c = ctx();
    if (!c) return;
    Buffer* b = bufferBound(*c, target);
    if (!b || !b->mtl || offset < 0 || size < 0 || size_t(offset + size) > b->size) { fail(GL_INVALID_VALUE); return; }
    if (size == 0) return;
    if (!c->cb && c->inFlight.empty()) { std::memcpy(static_cast<uint8_t*>(b->mtl.contents) + offset, data, size_t(size)); return; }
    // In order with the recorded commands: a staging copy blitted after them.
    id<MTLBuffer> staging = stagingCopy(*c, data, size_t(size));
    if (!staging) { fail(GL_OUT_OF_MEMORY); return; }
    id<MTLBuffer> dst = b->mtl;
    used(*c, dst);
    blit(*c, ^(id<MTLBlitCommandEncoder> e) {
        [e copyFromBuffer:staging sourceOffset:0 toBuffer:dst destinationOffset:NSUInteger(offset) size:NSUInteger(size)];
    });
}
void glCopyBufferSubData(GLenum readTarget, GLenum writeTarget, GLintptr readOffset, GLintptr writeOffset, GLsizeiptr size) {
    Guard g(gLock);
    Context* c = ctx();
    if (!c) return;
    Buffer* src = bufferBound(*c, readTarget);
    Buffer* dst = bufferBound(*c, writeTarget);
    if (!src || !dst || !src->mtl || !dst->mtl || size_t(readOffset + size) > src->size || size_t(writeOffset + size) > dst->size) {
        fail(GL_INVALID_VALUE);
        return;
    }
    id<MTLBuffer> s = src->mtl, d = dst->mtl;
    used(*c, s);
    used(*c, d);
    blit(*c, ^(id<MTLBlitCommandEncoder> e) {
        [e copyFromBuffer:s sourceOffset:NSUInteger(readOffset) toBuffer:d destinationOffset:NSUInteger(writeOffset) size:NSUInteger(size)];
    });
}
void* glMapBufferRange(GLenum target, GLintptr offset, GLsizeiptr length, GLbitfield access) {
    std::unique_lock<std::recursive_mutex> g(gLock);
    Context* c = ctx();
    if (!c) return nullptr;
    Buffer* b = bufferBound(*c, target);
    if (!b || !b->mtl || offset < 0 || length <= 0 || size_t(offset + length) > b->size) { fail(GL_INVALID_VALUE); return nullptr; }
    // GL_MAP_UNSYNCHRONIZED_BIT on a write-only mapping: the caller orders it itself (the fast merge's upload ring waits on each
    // slot's fence): the shared storage is written at once, the recorded work goes on (no submit and wait - it serialised the
    // frames' uploads with the GPU: ~1 s of a 21-frame burst on the M1)
    const bool unsynchronized = (access & GL_MAP_UNSYNCHRONIZED_BIT) && (access & GL_MAP_WRITE_BIT) && !(access & GL_MAP_READ_BIT);
    id<MTLBuffer> mtl = b->mtl;
    if (!unsynchronized) waitForUse(*c, mtl, g); // (b may move while gLock is released: the Metal buffer is kept)
    return static_cast<uint8_t*>(mtl.contents) + offset;
}
GLboolean glUnmapBuffer(GLenum) { return GL_TRUE; }

// ---- textures ----

void glGenTextures(GLsizei n, GLuint* names) {
    Guard g(gLock);
    for (GLsizei i = 0; i < n; ++i) { names[i] = newName(); gTextures[names[i]] = Texture(); }
}
void glDeleteTextures(GLsizei n, const GLuint* names) {
    Guard g(gLock);
    for (GLsizei i = 0; i < n; ++i) {
        auto it = gTextures.find(names[i]);
        if (it != gTextures.end()) { forgetUse(it->second.mtl); gTextures.erase(it); }
    }
}
void glActiveTexture(GLenum unit) {
    if (Context* c = ctx()) c->activeUnit = (unit - GL_TEXTURE0) & 31;
}
void glBindTexture(GLenum target, GLuint name) {
    Guard g(gLock);
    Context* c = ctx();
    if (!c) return;
    if (name && !gTextures.count(name)) gTextures[name] = Texture();
    if (name) gTextures[name].target = target;
    if (target == GL_TEXTURE_2D) c->tex2D[c->activeUnit] = name;
    else if (target == GL_TEXTURE_2D_ARRAY) c->tex2DArray[c->activeUnit] = name;
    else if (target == GL_TEXTURE_3D) c->tex3D[c->activeUnit] = name;
}
static Texture* boundTexture(Context& c, GLenum target) {
    const GLuint name = target == GL_TEXTURE_2D ? c.tex2D[c.activeUnit] : target == GL_TEXTURE_2D_ARRAY ? c.tex2DArray[c.activeUnit] : c.tex3D[c.activeUnit];
    auto it = gTextures.find(name);
    return it == gTextures.end() ? nullptr : &it->second;
}
void glTexParameteri(GLenum target, GLenum name, GLint value) {
    Guard g(gLock);
    Context* c = ctx();
    Texture* t = c ? boundTexture(*c, target) : nullptr;
    if (!t) return;
    if (name == GL_TEXTURE_MIN_FILTER) t->minFilter = value;
    else if (name == GL_TEXTURE_MAG_FILTER) t->magFilter = value;
    else if (name == GL_TEXTURE_WRAP_S) t->wrapS = value;
    else if (name == GL_TEXTURE_WRAP_T) t->wrapT = value;
    else return;
    t->sampler = nil;
}
static void storage(GLenum target, GLsizei levels, GLenum internal, GLsizei width, GLsizei height, GLsizei depth) {
    Guard g(gLock);
    Context* c = ctx();
    Texture* t = c ? boundTexture(*c, target) : nullptr;
    const Format f = formatOf(internal);
    if (!t || f.pixel == MTLPixelFormatInvalid || width <= 0 || height <= 0) {
        note("glTexStorage: unsupported format " + std::to_string(internal));
        fail(GL_INVALID_ENUM);
        return;
    }
    MTLTextureDescriptor* d = [MTLTextureDescriptor new];
    d.textureType = target == GL_TEXTURE_2D_ARRAY ? MTLTextureType2DArray : target == GL_TEXTURE_3D ? MTLTextureType3D : MTLTextureType2D;
    d.pixelFormat = f.pixel;
    d.width = NSUInteger(width);
    d.height = NSUInteger(height);
    d.depth = target == GL_TEXTURE_3D ? NSUInteger(depth) : 1;
    d.arrayLength = target == GL_TEXTURE_2D_ARRAY ? NSUInteger(depth) : 1;
    d.mipmapLevelCount = NSUInteger(std::max(1, int(levels)));
    // a 3D texture (the film's LUTs) is only sampled
    d.usage = target == GL_TEXTURE_3D ? MTLTextureUsageShaderRead
                                      : MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsagePixelFormatView | MTLTextureUsageRenderTarget;
    // private: the GPU's own memory layout (Apple GPUs compress private textures losslessly: less bandwidth for every pass);
    // the CPU reaches a texture only through glReadPixels, which blits the region to a shared buffer (readRegion), and the
    // uploads, which are blits already
    d.storageMode = kPrivateTextures ? MTLStorageModePrivate : MTLStorageModeShared;
    forgetUse(t->mtl);
    t->mtl = [metalDevice() newTextureWithDescriptor:d];
    if (!t->mtl) { fail(GL_OUT_OF_MEMORY); return; }
    t->target = target;
    t->internal = internal;
    t->width = width;
    t->height = height;
    t->layers = target == GL_TEXTURE_2D ? 1 : depth;
    t->levels = std::max(1, int(levels));
    t->sampler = nil;
    // a new shared texture's pages came zeroed; a private one's memory is whatever it was: cleared to 0 here (every level and
    // slice a render target can reach) so a pass reading texels nothing wrote reads what it read before
    if (t->mtl.storageMode == MTLStorageModePrivate && (t->mtl.usage & MTLTextureUsageRenderTarget)) {
        endCompute(*c);
        used(*c, t->mtl);
        for (NSUInteger level = 0; level < t->mtl.mipmapLevelCount; ++level) {
            for (NSUInteger slice = 0; slice < t->mtl.arrayLength; ++slice) {
                MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture = t->mtl;
                pass.colorAttachments[0].level = level;
                pass.colorAttachments[0].slice = slice;
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                [[commandBuffer(*c) renderCommandEncoderWithDescriptor:pass] endEncoding];
            }
        }
    }
}
void glTexStorage2D(GLenum target, GLsizei levels, GLenum internal, GLsizei width, GLsizei height) {
    storage(target, levels, internal, width, height, 1);
}
void glTexStorage3D(GLenum target, GLsizei levels, GLenum internal, GLsizei width, GLsizei height, GLsizei depth) {
    storage(target, levels, internal, width, height, depth);
}
void glTexImage2D(GLenum target, GLint level, GLint internal, GLsizei width, GLsizei height, GLint, GLenum format, GLenum type,
                  const void* pixels) {
    if (level == 0) storage(target, 1, GLenum(internal), width, height, 1);
    if (pixels) glTexSubImage2D(target, level, 0, 0, width, height, format, type, pixels);
}
void glTexSubImage2D(GLenum target, GLint level, GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type,
                     const void* pixels) {
    Guard g(gLock);
    Context* c = ctx();
    Texture* t = c ? boundTexture(*c, target) : nullptr;
    if (!t || !t->mtl) { fail(GL_INVALID_OPERATION); return; }
    const int bpp = componentsOf(format) * typeBytes(type);
    const uint8_t* src = static_cast<const uint8_t*>(pixels);
    if (Buffer* unpack = bufferBound(*c, GL_PIXEL_UNPACK_BUFFER)) src = static_cast<const uint8_t*>(unpack->mtl.contents) + reinterpret_cast<uintptr_t>(pixels);
    if (!src || width <= 0 || height <= 0) return;
    size_t row = rowBytes(width, bpp, c->unpackRowLength, c->unpackAlignment);
    id<MTLBuffer> staging;
    if (bpp != formatOf(t->internal).bytes) {
        const Layout to = storageLayout(t->mtl.pixelFormat), from = clientLayout(format, type);
        if (!to.components || !from.components) { note("glTexSubImage2D: conversion not supported"); fail(GL_INVALID_OPERATION); return; }
        const bool normalised = t->mtl.pixelFormat == MTLPixelFormatRGBA8Unorm || t->mtl.pixelFormat == MTLPixelFormatR8Unorm
            || t->mtl.pixelFormat == MTLPixelFormatRG8Unorm;
        const std::vector<uint8_t> converted = convertRows(src, row, width, height, from, to, normalised);
        row = size_t(to.size()) * size_t(width);
        staging = [metalDevice() newBufferWithBytes:converted.data() length:converted.size() options:MTLResourceStorageModeShared];
    } else {
        const size_t bytes = row * size_t(height - 1) + size_t(width) * size_t(bpp);
        staging = stagingCopy(*c, src, bytes);
    }
    if (!staging) { fail(GL_OUT_OF_MEMORY); return; }
    id<MTLTexture> dst = t->mtl;
    used(*c, dst);
    blit(*c, ^(id<MTLBlitCommandEncoder> e) {
        [e copyFromBuffer:staging sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:row * size_t(height)
               sourceSize:MTLSizeMake(NSUInteger(width), NSUInteger(height), 1) toTexture:dst destinationSlice:0
         destinationLevel:NSUInteger(level) destinationOrigin:MTLOriginMake(NSUInteger(x), NSUInteger(y), 0)];
    });
}
// The film's 3D LUTs (FilmLut.upload: glTexImage3D of RGB float rows, red fastest, one slice per blue step): stored as RGBA16Float
// (Metal has no 3-channel formats), every slice converted as glTexSubImage2D converts its rows.
void glTexImage3D(GLenum target, GLint level, GLint internal, GLsizei width, GLsizei height, GLsizei depth, GLint, GLenum format, GLenum type,
                  const void* pixels) {
    if (level == 0) storage(target, 1, GLenum(internal), width, height, depth);
    if (pixels) glTexSubImage3D(target, level, 0, 0, 0, width, height, depth, format, type, pixels);
}
void glTexSubImage3D(GLenum target, GLint level, GLint x, GLint y, GLint z, GLsizei width, GLsizei height, GLsizei depth, GLenum format,
                     GLenum type, const void* pixels) {
    Guard g(gLock);
    Context* c = ctx();
    Texture* t = c ? boundTexture(*c, target) : nullptr;
    if (!t || !t->mtl) { fail(GL_INVALID_OPERATION); return; }
    const int bpp = componentsOf(format) * typeBytes(type);
    const uint8_t* src = static_cast<const uint8_t*>(pixels);
    if (Buffer* unpack = bufferBound(*c, GL_PIXEL_UNPACK_BUFFER)) src = static_cast<const uint8_t*>(unpack->mtl.contents) + reinterpret_cast<uintptr_t>(pixels);
    if (!src || width <= 0 || height <= 0 || depth <= 0) return;
    size_t row = rowBytes(width, bpp, c->unpackRowLength, c->unpackAlignment);
    id<MTLBuffer> staging;
    if (bpp != formatOf(t->internal).bytes) {
        const Layout to = storageLayout(t->mtl.pixelFormat), from = clientLayout(format, type);
        if (!to.components || !from.components) { note("glTexSubImage3D: conversion not supported"); fail(GL_INVALID_OPERATION); return; }
        const std::vector<uint8_t> converted = convertRows(src, row, width, height * depth, from, to, false);
        row = size_t(to.size()) * size_t(width);
        staging = [metalDevice() newBufferWithBytes:converted.data() length:converted.size() options:MTLResourceStorageModeShared];
    } else {
        const size_t bytes = row * size_t(height) * size_t(depth);
        staging = [metalDevice() newBufferWithBytes:src length:bytes options:MTLResourceStorageModeShared];
    }
    id<MTLTexture> dst = t->mtl;
    used(*c, dst);
    const size_t image = row * size_t(height);
    blit(*c, ^(id<MTLBlitCommandEncoder> e) {
        [e copyFromBuffer:staging sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:image
               sourceSize:MTLSizeMake(NSUInteger(width), NSUInteger(height), NSUInteger(depth)) toTexture:dst destinationSlice:0
         destinationLevel:NSUInteger(level) destinationOrigin:MTLOriginMake(NSUInteger(x), NSUInteger(y), NSUInteger(z))];
    });
}
// The photo editor's mipmapped picture (EditRenderer: main / look, sampled with GL_LINEAR_MIPMAP_LINEAR by finish): the levels
// below 0 from level 0, recorded in order with the draws (a blit encoder's box filter).
void glGenerateMipmap(GLenum target) {
    Guard g(gLock);
    Context* c = ctx();
    Texture* t = c ? boundTexture(*c, target) : nullptr;
    if (!t || !t->mtl) { fail(GL_INVALID_OPERATION); return; }
    if (t->levels <= 1) return;
    id<MTLTexture> tex = t->mtl;
    used(*c, tex);
    blit(*c, ^(id<MTLBlitCommandEncoder> e) {
        [e generateMipmapsForTexture:tex];
    });
}
void glBindImageTexture(GLuint unit, GLuint texture, GLint level, GLboolean layered, GLint layer, GLenum, GLenum format) {
    Context* c = ctx();
    if (!c || unit >= 32) { fail(GL_INVALID_VALUE); return; }
    c->images[unit] = ImageUnit{texture, level, layer, layered, format};
}

// ---- framebuffers (readback) ----

void glGenFramebuffers(GLsizei n, GLuint* names) {
    Guard g(gLock);
    for (GLsizei i = 0; i < n; ++i) { names[i] = newName(); gFramebuffers[names[i]] = Framebuffer(); }
}
void glDeleteFramebuffers(GLsizei n, const GLuint* names) {
    Guard g(gLock);
    for (GLsizei i = 0; i < n; ++i) gFramebuffers.erase(names[i]);
}
void glBindFramebuffer(GLenum target, GLuint name) {
    Context* c = ctx();
    if (!c) return;
    if (target == GL_READ_FRAMEBUFFER || target == GL_FRAMEBUFFER) c->readFb = name;
    if (target == GL_DRAW_FRAMEBUFFER || target == GL_FRAMEBUFFER) c->drawFb = name;
}
void glFramebufferTexture2D(GLenum target, GLenum attachment, GLenum, GLuint texture, GLint) {
    Guard g(gLock);
    Context* c = ctx();
    if (!c) return;
    const GLuint fb = target == GL_READ_FRAMEBUFFER ? c->readFb : c->drawFb;
    const GLuint i = attachment - GL_COLOR_ATTACHMENT0;
    if (i < 8) gFramebuffers[fb].color[i] = texture;
}
GLenum glCheckFramebufferStatus(GLenum) { return GL_FRAMEBUFFER_COMPLETE; }
void glReadBuffer(GLenum) {}
void glDrawBuffers(GLsizei n, const GLenum* bufs) {
    Guard g(gLock);
    if (Context* c = ctx()) gFramebuffers[c->drawFb].drawBuffers.assign(bufs, bufs + std::max<GLsizei>(n, 0));
}
void glInvalidateFramebuffer(GLenum, GLsizei, const GLenum*) {}
void glReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void* pixels) {
    std::unique_lock<std::recursive_mutex> g(gLock);
    Context* c = ctx();
    if (!c) return;
    auto fb = gFramebuffers.find(c->readFb);
    auto found = fb == gFramebuffers.end() ? gTextures.end() : gTextures.find(fb->second.color[0]);
    if (found == gTextures.end() || !found->second.mtl) { fail(GL_INVALID_OPERATION); return; }
    const int bpp = componentsOf(format) * typeBytes(type);
    // the texture's last writer (and the pack buffer's last user) only; the texture kept by value: the maps may change while
    // gLock is released for the wait
    const Texture tex = found->second;
    Buffer* packBuffer = bufferBound(*c, GL_PIXEL_PACK_BUFFER);
    id<MTLBuffer> pack = packBuffer ? packBuffer->mtl : nil;
    waitForUse(*c, tex.mtl, g);
    if (pack) waitForUse(*c, pack, g);
    uint8_t* dst = static_cast<uint8_t*>(pixels);
    if (pack) dst = static_cast<uint8_t*>(pack.contents) + reinterpret_cast<uintptr_t>(pixels);
    const size_t row = rowBytes(width, bpp, c->packRowLength, c->packAlignment);
    const MTLRegion region = MTLRegionMake2D(NSUInteger(x), NSUInteger(y), NSUInteger(width), NSUInteger(height));
    if (bpp == formatOf(tex.internal).bytes) {
        readRegion(*c, tex.mtl, region, bpp, dst, row, g);
        return;
    }
    // GL_FLOAT of a half-float target, RGB of an RGBA store, ...: read the storage, convert the rows
    const Layout from = storageLayout(tex.mtl.pixelFormat), to = clientLayout(format, type);
    if (!from.components || !to.components) { note("glReadPixels: conversion not supported"); fail(GL_INVALID_OPERATION); return; }
    std::vector<uint8_t> raw(size_t(from.size()) * size_t(width) * size_t(height));
    readRegion(*c, tex.mtl, region, formatOf(tex.internal).bytes, raw.data(), size_t(from.size()) * size_t(width), g);
    const bool normalised = tex.mtl.pixelFormat == MTLPixelFormatRGBA8Unorm || tex.mtl.pixelFormat == MTLPixelFormatR8Unorm
        || tex.mtl.pixelFormat == MTLPixelFormatRG8Unorm;
    const int fromBytes = from.size() / from.components, toBytes = to.size() / to.components;
    for (int yy = 0; yy < height; ++yy) {
        const uint8_t* sp = raw.data() + size_t(yy) * size_t(width) * size_t(from.size());
        uint8_t* dp = dst + size_t(yy) * row;
        for (int xx = 0; xx < width; ++xx) {
            for (int k = 0; k < to.components; ++k) {
                // GL: a component the storage lacks reads 0, alpha 1
                const double v = k < from.components ? toClient(readComponent(sp + k * fromBytes, from.kind), from.kind, to.kind, normalised) : k == 3 ? (normalised && to.kind == Kind::U8 ? 255.0 : 1.0) : 0.0;
                writeComponent(dp + k * toBytes, to.kind, v);
            }
            sp += from.size();
            dp += to.size();
        }
    }
}
// an integer attachment takes the clear colour's doubles as its integer values (Metal)
static void clearColour(GLenum buffer, GLint drawBuffer, const double* value);
void glClearBufferfv(GLenum buffer, GLint drawBuffer, const GLfloat* value) {
    const double v[4] = {value[0], value[1], value[2], value[3]};
    clearColour(buffer, drawBuffer, v);
}
void glClearBufferuiv(GLenum buffer, GLint drawBuffer, const GLuint* value) {
    const double v[4] = {double(value[0]), double(value[1]), double(value[2]), double(value[3])};
    clearColour(buffer, drawBuffer, v);
}
void glClearBufferiv(GLenum buffer, GLint drawBuffer, const GLint* value) {
    const double v[4] = {double(value[0]), double(value[1]), double(value[2]), double(value[3])};
    clearColour(buffer, drawBuffer, v);
}
static void clearColour(GLenum buffer, GLint drawBuffer, const double* value) {
    Guard g(gLock);
    Context* c = ctx();
    if (!c || buffer != GL_COLOR || drawBuffer < 0 || drawBuffer >= 8) return;
    auto fb = gFramebuffers.find(c->drawFb);
    auto t = fb == gFramebuffers.end() ? gTextures.end() : gTextures.find(fb->second.color[drawBuffer]);
    if (t == gTextures.end() || !t->second.mtl) { fail(GL_INVALID_OPERATION); return; }
    endCompute(*c);
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = t->second.mtl;
    used(*c, t->second.mtl);
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(value[0], value[1], value[2], value[3]);
    [[commandBuffer(*c) renderCommandEncoderWithDescriptor:pass] endEncoding];
}
static MTLBlendFactor blendFactor(GLenum f) {
    switch (f) {
    case GL_ZERO: return MTLBlendFactorZero;
    case GL_SRC_ALPHA: return MTLBlendFactorSourceAlpha;
    case GL_ONE_MINUS_SRC_ALPHA: return MTLBlendFactorOneMinusSourceAlpha;
    case GL_DST_ALPHA: return MTLBlendFactorDestinationAlpha;
    case GL_SRC_COLOR: return MTLBlendFactorSourceColor;
    case GL_DST_COLOR: return MTLBlendFactorDestinationColor;
    default: return MTLBlendFactorOne;
    }
}
static MTLBlendOperation blendOperation(GLenum e) {
    switch (e) {
    case GL_MIN: return MTLBlendOperationMin;
    case GL_MAX: return MTLBlendOperationMax;
    case GL_FUNC_SUBTRACT: return MTLBlendOperationSubtract;
    case GL_FUNC_REVERSE_SUBTRACT: return MTLBlendOperationReverseSubtract;
    default: return MTLBlendOperationAdd;
    }
}
// A draw of the current render program into the draw framebuffer's attachments (GL window rows = texture rows: the vertex
// stage is flipped by SPIRV-Cross, so gl_FragCoord, the viewport and the scissor keep their GL meaning).
// A render program's pipeline state for its attachments' formats and the blend (glDrawArrays' key: the formats, "b" eq, src, dst
// with blending). Its recipe ("P\n" program recipe \x02 key) lets the warm-up build it before the first draw needs it.
id<MTLRenderPipelineState> makeRenderPipeline(const Linked& l, const std::vector<MTLPixelFormat>& formats, bool blend, GLenum eq, GLenum src,
                                              GLenum dst, std::string& error) {
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = l.vertex;
    d.fragmentFunction = l.fragment;
    for (size_t i = 0; i < formats.size(); ++i) {
        if (formats[i] == MTLPixelFormatInvalid) continue;
        d.colorAttachments[i].pixelFormat = formats[i];
        if (blend) {
            d.colorAttachments[i].blendingEnabled = YES;
            d.colorAttachments[i].rgbBlendOperation = d.colorAttachments[i].alphaBlendOperation = blendOperation(eq);
            d.colorAttachments[i].sourceRGBBlendFactor = d.colorAttachments[i].sourceAlphaBlendFactor = blendFactor(src);
            d.colorAttachments[i].destinationRGBBlendFactor = d.colorAttachments[i].destinationAlphaBlendFactor = blendFactor(dst);
        }
    }
    NSError* e = nil;
    id<MTLRenderPipelineState> state = [metalDevice() newRenderPipelineStateWithDescriptor:d error:&e];
    if (!state) error = e ? e.localizedDescription.UTF8String : "unknown";
    return state;
}

void glDrawArrays(GLenum mode, GLint first, GLsizei count) {
    Guard g(gLock);
    Context* c = ctx();
    if (!c || count <= 0) return;
    auto pit = gPrograms.find(c->program);
    if (pit == gPrograms.end() || !pit->second.linked || !pit->second.code || !pit->second.code->render) { fail(GL_INVALID_OPERATION); return; }
    Program& p = pit->second;
    auto fb = gFramebuffers.find(c->drawFb);
    if (fb == gFramebuffers.end()) { fail(GL_INVALID_FRAMEBUFFER_OPERATION); return; }
    std::vector<id<MTLTexture>> targets;
    for (GLenum b : fb->second.drawBuffers) {
        const GLuint i = b - GL_COLOR_ATTACHMENT0;
        auto t = b == GL_NONE || i >= 8 ? gTextures.end() : gTextures.find(fb->second.color[i]);
        targets.push_back(t == gTextures.end() ? nil : t->second.mtl);
    }
    if (targets.empty() || !targets[0]) { fail(GL_INVALID_FRAMEBUFFER_OPERATION); return; }
    std::string key;
    for (id<MTLTexture> t : targets) key += std::to_string(t ? t.pixelFormat : 0) + ",";
    if (c->blend) key += "b" + std::to_string(c->blendEquation) + "," + std::to_string(c->blendSrc) + "," + std::to_string(c->blendDst);
    id<MTLRenderPipelineState> state = p.code->renderPipelines[key];
    if (!state) {
        std::vector<MTLPixelFormat> formats;
        for (id<MTLTexture> t : targets) formats.push_back(t ? t.pixelFormat : MTLPixelFormatInvalid);
        std::string error;
        state = makeRenderPipeline(*p.code, formats, c->blend, c->blendEquation, c->blendSrc, c->blendDst, error);
        if (!state) {
            std::fprintf(stderr, "SCAMGL: render pipeline failed: %s\n", error.c_str());
            fail(GL_INVALID_OPERATION);
            return;
        }
        p.code->renderPipelines[key] = state;
        if (!p.code->recipe.empty()) gRecorded.push_back("P\n" + p.code->recipe + "\x02" + key);
    }
    endCompute(*c);
    // a draw over every texel of its target (the viewport and any scissor cover it, no blending; no shader discards, and the MSL
    // fragment always returns its output) overwrites it whole: their old texels are not loaded into tile memory first
    const NSInteger fw = NSInteger(targets[0].width), fh = NSInteger(targets[0].height);
    bool covers = !c->blend && c->viewport[0] <= 0 && c->viewport[1] <= 0 && c->viewport[0] + c->viewport[2] >= fw
                  && c->viewport[1] + c->viewport[3] >= fh
                  && (!c->scissorTest || (c->scissor[0] <= 0 && c->scissor[1] <= 0 && c->scissor[0] + c->scissor[2] >= fw
                                          && c->scissor[1] + c->scissor[3] >= fh));
    // one target only: with several the fragment may not declare an output for each (an attachment it leaves must keep its texels)
    covers = covers && targets.size() == 1;
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    for (size_t i = 0; i < targets.size(); ++i) {
        if (!targets[i]) continue;
        pass.colorAttachments[i].texture = targets[i];
        used(*c, targets[i]);
        pass.colorAttachments[i].loadAction = covers ? MTLLoadActionDontCare : MTLLoadActionLoad;
        pass.colorAttachments[i].storeAction = MTLStoreActionStore;
    }
    id<MTLRenderCommandEncoder> e = [commandBuffer(*c) renderCommandEncoderWithDescriptor:pass];
    [e setRenderPipelineState:state];
    MTLViewport viewport = {double(c->viewport[0]), double(c->viewport[1]), double(c->viewport[2]), double(c->viewport[3]), 0.0, 1.0};
    [e setViewport:viewport];
    const NSInteger tw = NSInteger(targets[0].width), th = NSInteger(targets[0].height);
    NSInteger x0 = 0, y0 = 0, x1 = tw, y1 = th;
    if (c->scissorTest) {
        x0 = std::max<NSInteger>(0, c->scissor[0]); y0 = std::max<NSInteger>(0, c->scissor[1]);
        x1 = std::min<NSInteger>(tw, c->scissor[0] + c->scissor[2]); y1 = std::min<NSInteger>(th, c->scissor[1] + c->scissor[3]);
    }
    if (x1 <= x0 || y1 <= y0) { [e endEncoding]; return; }
    MTLScissorRect rect = {NSUInteger(x0), NSUInteger(y0), NSUInteger(x1 - x0), NSUInteger(y1 - y0)};
    [e setScissorRect:rect];
    bindResources(*c, p, nil, e);
    const MTLPrimitiveType type = mode == GL_TRIANGLE_STRIP ? MTLPrimitiveTypeTriangleStrip : MTLPrimitiveTypeTriangle;
    [e drawPrimitives:type vertexStart:NSUInteger(first) vertexCount:NSUInteger(count)];
    [e endEncoding];
}

// ---- shaders and programs ----

GLuint glCreateShader(GLenum type) {
    Guard g(gLock);
    const GLuint name = newName();
    gShaders[name] = Shader{type, {}};
    return name;
}
void glDeleteShader(GLuint name) {
    Guard g(gLock);
    gShaders.erase(name);
}
void glShaderSource(GLuint name, GLsizei count, const GLchar* const* strings, const GLint* lengths) {
    Guard g(gLock);
    auto it = gShaders.find(name);
    if (it == gShaders.end()) { fail(GL_INVALID_VALUE); return; }
    std::string s;
    for (GLsizei i = 0; i < count; ++i) s.append(strings[i], lengths && lengths[i] >= 0 ? size_t(lengths[i]) : std::strlen(strings[i]));
    it->second.source = s;
}
void glCompileShader(GLuint) {} // translated at link time
void glGetShaderiv(GLuint, GLenum name, GLint* value) {
    *value = name == GL_COMPILE_STATUS ? GL_TRUE : 0;
}
void glGetShaderInfoLog(GLuint, GLsizei size, GLsizei* length, GLchar* log) {
    if (length) *length = 0;
    if (log && size > 0) log[0] = 0;
}
GLuint glCreateProgram(void) {
    Guard g(gLock);
    const GLuint name = newName();
    gPrograms[name] = Program();
    return name;
}
void glDeleteProgram(GLuint name) {
    Guard g(gLock);
    gPrograms.erase(name);
}
void glAttachShader(GLuint program, GLuint shader) {
    Guard g(gLock);
    gPrograms[program].shaders.push_back(shader);
}
void glProgramParameteri(GLuint, GLenum, GLint) {}
void glLinkProgram(GLuint name) {
    std::string compute, vertex, fragment;
    {
        Guard g(gLock);
        auto it = gPrograms.find(name);
        if (it == gPrograms.end()) { fail(GL_INVALID_VALUE); return; }
        Program& p = it->second;
        p.linked = false;
        p.log.clear();
        for (GLuint s : p.shaders) {
            auto sh = gShaders.find(s);
            if (sh == gShaders.end()) continue;
            if (sh->second.type == GL_COMPUTE_SHADER) compute = sh->second.source;
            else if (sh->second.type == GL_VERTEX_SHADER) vertex = sh->second.source;
            else if (sh->second.type == GL_FRAGMENT_SHADER) fragment = sh->second.source;
        }
    }
    // the compile outside gLock (linkCompute / linkRender take it for the cache only)
    std::shared_ptr<Linked> code;
    if (!compute.empty()) code = linkCompute(compute);
    else if (!vertex.empty() && !fragment.empty()) code = linkRender(vertex, fragment);
    Guard g(gLock);
    auto it = gPrograms.find(name);
    if (it == gPrograms.end()) { fail(GL_INVALID_VALUE); return; }
    Program& p = it->second;
    if (!code) { p.log = "ScamGL: a compute or a vertex + fragment program"; return; }
    p.code = code;
    if (!p.code->ready()) {
        p.log = p.code->log;
        std::fprintf(stderr, "SCAMGL: link failed: %s\n", p.log.c_str());
        return;
    }
    setupLocations(p);
    p.linked = true;
}
void glGetProgramiv(GLuint name, GLenum pname, GLint* value) {
    Guard g(gLock);
    auto it = gPrograms.find(name);
    if (it == gPrograms.end()) { *value = 0; return; }
    if (pname == GL_LINK_STATUS) *value = it->second.linked ? GL_TRUE : GL_FALSE;
    else if (pname == GL_INFO_LOG_LENGTH) *value = GLint(it->second.log.size() + 1);
    else if (pname == GL_PROGRAM_BINARY_LENGTH) *value = 0;
    else if (pname == GL_ACTIVE_UNIFORMS && it->second.code) {
        *value = GLint(it->second.code->compiled.members.size() + it->second.samplerUnit.size());
    } else if (pname == GL_ACTIVE_UNIFORM_MAX_LENGTH && it->second.code) {
        size_t n = 0;
        for (const auto& m : it->second.code->compiled.members) n = std::max(n, m.name.size() + 4);
        for (const auto& r : it->second.code->compiled.resources) n = std::max(n, r.name.size() + 1);
        *value = GLint(n);
    }
    else if (pname == GL_COMPUTE_WORK_GROUP_SIZE && it->second.code) {
        for (int i = 0; i < 3; ++i) value[i] = GLint(it->second.code->compiled.local[i]);
    } else *value = 0;
}
void glGetProgramInfoLog(GLuint name, GLsizei size, GLsizei* length, GLchar* log) {
    Guard g(gLock);
    auto it = gPrograms.find(name);
    const std::string text = it == gPrograms.end() ? std::string() : it->second.log;
    const size_t n = size > 0 ? std::min(text.size(), size_t(size - 1)) : 0;
    if (log && size > 0) { std::memcpy(log, text.data(), n); log[n] = 0; }
    if (length) *length = GLsizei(n);
}
void glGetProgramBinary(GLuint, GLsizei, GLsizei* length, GLenum*, void*) {
    if (length) *length = 0;
    fail(GL_INVALID_OPERATION);
}
void glProgramBinary(GLuint name, GLenum, const void*, GLsizei) {
    Guard g(gLock);
    gPrograms[name].linked = false;
    fail(GL_INVALID_ENUM);
}
void glUseProgram(GLuint name) {
    if (Context* c = ctx()) c->program = name;
}
GLint glGetUniformLocation(GLuint program, const GLchar* name) {
    Guard g(gLock);
    auto it = gPrograms.find(program);
    if (it == gPrograms.end() || !it->second.linked) return -1;
    auto loc = it->second.byName.find(name);
    return loc == it->second.byName.end() ? -1 : loc->second;
}

static GLenum glTypeOf(const scamgl::Member& m) {
    if (m.columns == 4 && m.vecsize == 4) return GL_FLOAT_MAT4;
    if (m.columns == 3 && m.vecsize == 3) return GL_FLOAT_MAT3;
    static const GLenum floats[] = {GL_FLOAT, GL_FLOAT_VEC2, GL_FLOAT_VEC3, GL_FLOAT_VEC4};
    static const GLenum ints[] = {GL_INT, GL_INT_VEC2, GL_INT_VEC3, GL_INT_VEC4};
    static const GLenum uints[] = {GL_UNSIGNED_INT, GL_UNSIGNED_INT_VEC2, GL_UNSIGNED_INT_VEC3, GL_UNSIGNED_INT_VEC4};
    static const GLenum bools[] = {GL_BOOL, GL_BOOL_VEC2, GL_BOOL_VEC3, GL_BOOL_VEC4};
    const int i = int(std::min<uint32_t>(std::max<uint32_t>(m.vecsize, 1), 4)) - 1;
    return m.baseType == 1 ? ints[i] : m.baseType == 2 ? uints[i] : m.baseType == 3 ? bools[i] : floats[i];
}
void glGetActiveUniform(GLuint program, GLuint index, GLsizei bufSize, GLsizei* length, GLint* size, GLenum* type, GLchar* name) {
    Guard g(gLock);
    auto it = gPrograms.find(program);
    if (it == gPrograms.end() || !it->second.code) { fail(GL_INVALID_VALUE); return; }
    const auto& c = it->second.code->compiled;
    std::string n;
    if (index < c.members.size()) {
        const auto& m = c.members[index];
        n = m.arrayStride ? m.name + "[0]" : m.name;
        if (size) *size = GLint(m.count);
        if (type) *type = glTypeOf(m);
    } else {
        size_t k = index - c.members.size();
        const scamgl::Resource* found = nullptr;
        for (const auto& r : c.resources) if (r.type == scamgl::Resource::Sampled && k-- == 0) { found = &r; break; }
        if (!found) { fail(GL_INVALID_VALUE); return; }
        n = found->name;
        if (size) *size = 1;
        if (type) *type = found->volume ? GL_SAMPLER_3D : found->arrayed ? GL_SAMPLER_2D_ARRAY : GL_SAMPLER_2D;
    }
    const size_t len = bufSize > 0 ? std::min(n.size(), size_t(bufSize - 1)) : 0;
    if (name && bufSize > 0) { std::memcpy(name, n.data(), len); name[len] = 0; }
    if (length) *length = GLsizei(len);
}
extern "C++" {
template <typename T>
static void readUniform(GLuint program, GLint location, T* out) {
    Guard g(gLock);
    auto it = gPrograms.find(program);
    if (location < 0 || it == gPrograms.end() || !it->second.linked || location >= GLint(it->second.locations.size())) {
        fail(GL_INVALID_OPERATION);
        return;
    }
    const Program& p = it->second;
    const Location loc = p.locations[size_t(location)];
    if (loc.sampler >= 0) { out[0] = T(p.samplerUnit[size_t(loc.sampler)]); return; }
    const auto& m = p.code->compiled.members[size_t(loc.member)];
    const uint8_t* src = p.block.data() + m.offset + uint32_t(loc.element) * (m.arrayStride ? m.arrayStride : m.size);
    const uint32_t n = m.vecsize * std::max<uint32_t>(m.columns, 1);
    for (uint32_t k = 0; k < n; ++k) {
        if (m.baseType == 0) { float f; std::memcpy(&f, src + 4 * k, 4); out[k] = T(f); }
        else if (m.baseType == 1) { int32_t x; std::memcpy(&x, src + 4 * k, 4); out[k] = T(x); }
        else { uint32_t x; std::memcpy(&x, src + 4 * k, 4); out[k] = T(x); }
    }
}
} // extern "C++"
void glGetUniformfv(GLuint program, GLint location, GLfloat* params) { readUniform(program, location, params); }
void glGetUniformiv(GLuint program, GLint location, GLint* params) { readUniform(program, location, params); }

static GLuint currentProgram() { Context* c = ctx(); return c ? c->program : 0; }

void glUniform1i(GLint l, GLint a) { writeUniform(currentProgram(), l, 1, 1, &a, 1); }
void glUniform2i(GLint l, GLint a, GLint b) { const GLint v[] = {a, b}; writeUniform(currentProgram(), l, 2, 1, v, 1); }
void glUniform4i(GLint l, GLint a, GLint b, GLint c, GLint d) { const GLint v[] = {a, b, c, d}; writeUniform(currentProgram(), l, 4, 1, v, 1); }
void glUniform1f(GLint l, GLfloat a) { writeUniform(currentProgram(), l, 1, 1, &a, 0); }
void glUniform2f(GLint l, GLfloat a, GLfloat b) { const GLfloat v[] = {a, b}; writeUniform(currentProgram(), l, 2, 1, v, 0); }
void glUniform3f(GLint l, GLfloat a, GLfloat b, GLfloat c) { const GLfloat v[] = {a, b, c}; writeUniform(currentProgram(), l, 3, 1, v, 0); }
void glUniform4f(GLint l, GLfloat a, GLfloat b, GLfloat c, GLfloat d) { const GLfloat v[] = {a, b, c, d}; writeUniform(currentProgram(), l, 4, 1, v, 0); }
void glUniform1fv(GLint l, GLsizei n, const GLfloat* v) { writeUniform(currentProgram(), l, 1, n, v, 0); }
void glUniform4fv(GLint l, GLsizei n, const GLfloat* v) { writeUniform(currentProgram(), l, 4, n, v, 0); }
void glUniform2fv(GLint l, GLsizei n, const GLfloat* v) { writeUniform(currentProgram(), l, 2, n, v, 0); }
void glUniform3fv(GLint l, GLsizei n, const GLfloat* v) { writeUniform(currentProgram(), l, 3, n, v, 0); }
void glUniform3iv(GLint l, GLsizei n, const GLint* v) { writeUniform(currentProgram(), l, 3, n, v, 1); }
void glUniform4iv(GLint l, GLsizei n, const GLint* v) { writeUniform(currentProgram(), l, 4, n, v, 1); }
void glUniform1iv(GLint l, GLsizei n, const GLint* v) { writeUniform(currentProgram(), l, 1, n, v, 1); }
void glUniform2iv(GLint l, GLsizei n, const GLint* v) { writeUniform(currentProgram(), l, 2, n, v, 1); }
void glUniform1uiv(GLint l, GLsizei n, const GLuint* v) { writeUniform(currentProgram(), l, 1, n, v, 2); }
void glProgramUniform1i(GLuint p, GLint l, GLint a) { writeUniform(p, l, 1, 1, &a, 1); }
void glProgramUniform2i(GLuint p, GLint l, GLint a, GLint b) { const GLint v[] = {a, b}; writeUniform(p, l, 2, 1, v, 1); }
void glProgramUniform1f(GLuint p, GLint l, GLfloat a) { writeUniform(p, l, 1, 1, &a, 0); }
void glProgramUniform2f(GLuint p, GLint l, GLfloat a, GLfloat b) { const GLfloat v[] = {a, b}; writeUniform(p, l, 2, 1, v, 0); }
void glProgramUniform3f(GLuint p, GLint l, GLfloat a, GLfloat b, GLfloat c) { const GLfloat v[] = {a, b, c}; writeUniform(p, l, 3, 1, v, 0); }
void glProgramUniform4f(GLuint p, GLint l, GLfloat a, GLfloat b, GLfloat c, GLfloat d) {
    const GLfloat v[] = {a, b, c, d};
    writeUniform(p, l, 4, 1, v, 0);
}
static void writeMatrix(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value, int n) {
    Guard g(gLock);
    auto it = gPrograms.find(program);
    if (location < 0 || it == gPrograms.end() || !it->second.linked || location >= GLint(it->second.locations.size())) return;
    Program& p = it->second;
    const Location loc = p.locations[size_t(location)];
    if (loc.member < 0) return;
    const auto& m = p.code->compiled.members[size_t(loc.member)];
    const uint32_t colStride = m.matrixStride ? m.matrixStride : 16;
    const uint32_t stride = m.arrayStride ? m.arrayStride : m.size;
    for (GLsizei i = 0; i < count && uint32_t(loc.element + i) < m.count; ++i) {
        uint8_t* dst = p.block.data() + m.offset + uint32_t(loc.element + i) * stride;
        for (int col = 0; col < n; ++col)
            for (int row = 0; row < n; ++row) {
                const float v = transpose ? value[i * n * n + row * n + col] : value[i * n * n + col * n + row];
                std::memcpy(dst + col * colStride + row * 4, &v, 4);
            }
    }
}
void glProgramUniformMatrix4fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
    writeMatrix(program, location, count, transpose, value, 4);
}
void glUniformMatrix4fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
    writeMatrix(currentProgram(), location, count, transpose, value, 4);
}
void glUniformMatrix3fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
    writeMatrix(currentProgram(), location, count, transpose, value, 3);
}
void glUniform3i(GLint l, GLint a, GLint b, GLint c) { const GLint v[] = {a, b, c}; writeUniform(currentProgram(), l, 3, 1, v, 1); }
void glUniform2ui(GLint l, GLuint a, GLuint b) { const GLuint v[] = {a, b}; writeUniform(currentProgram(), l, 2, 1, v, 2); }
void glUniform1ui(GLint l, GLuint a) { writeUniform(currentProgram(), l, 1, 1, &a, 2); }
// glProgramUniform*: the named program's uniforms (FastMergeGpu::resetForMerge zeroes every uniform of its programs)
void glProgramUniform1fv(GLuint p, GLint l, GLsizei n, const GLfloat* v) { writeUniform(p, l, 1, n, v, 0); }
void glProgramUniform2fv(GLuint p, GLint l, GLsizei n, const GLfloat* v) { writeUniform(p, l, 2, n, v, 0); }
void glProgramUniform3fv(GLuint p, GLint l, GLsizei n, const GLfloat* v) { writeUniform(p, l, 3, n, v, 0); }
void glProgramUniform4fv(GLuint p, GLint l, GLsizei n, const GLfloat* v) { writeUniform(p, l, 4, n, v, 0); }
void glProgramUniform1iv(GLuint p, GLint l, GLsizei n, const GLint* v) { writeUniform(p, l, 1, n, v, 1); }
void glProgramUniform2iv(GLuint p, GLint l, GLsizei n, const GLint* v) { writeUniform(p, l, 2, n, v, 1); }
void glProgramUniform3iv(GLuint p, GLint l, GLsizei n, const GLint* v) { writeUniform(p, l, 3, n, v, 1); }
void glProgramUniform4iv(GLuint p, GLint l, GLsizei n, const GLint* v) { writeUniform(p, l, 4, n, v, 1); }
void glProgramUniform1uiv(GLuint p, GLint l, GLsizei n, const GLuint* v) { writeUniform(p, l, 1, n, v, 2); }
void glProgramUniform2uiv(GLuint p, GLint l, GLsizei n, const GLuint* v) { writeUniform(p, l, 2, n, v, 2); }
void glProgramUniform3uiv(GLuint p, GLint l, GLsizei n, const GLuint* v) { writeUniform(p, l, 3, n, v, 2); }
void glProgramUniform4uiv(GLuint p, GLint l, GLsizei n, const GLuint* v) { writeUniform(p, l, 4, n, v, 2); }
void glProgramUniformMatrix2fv(GLuint p, GLint l, GLsizei n, GLboolean transpose, const GLfloat* v) { writeMatrix(p, l, n, transpose, v, 2); }
void glProgramUniformMatrix3fv(GLuint p, GLint l, GLsizei n, GLboolean transpose, const GLfloat* v) { writeMatrix(p, l, n, transpose, v, 3); }

// ---- dispatch, sync, queries ----

void glDispatchCompute(GLuint x, GLuint y, GLuint z) {
    Guard g(gLock);
    if (Context* c = ctx()) dispatch(*c, x, y, z, nullptr, 0);
}
void glDispatchComputeIndirect(GLintptr offset) {
    Guard g(gLock);
    Context* c = ctx();
    if (!c) return;
    Buffer* b = bufferBound(*c, GL_DISPATCH_INDIRECT_BUFFER);
    if (!b || !b->mtl) { fail(GL_INVALID_OPERATION); return; }
    dispatch(*c, 0, 0, 0, b, offset);
}
GLsync glFenceSync(GLenum, GLbitfield) {
    Context* c = ctx();
    if (!c) return nullptr;
    id<MTLCommandBuffer> last = c->cb;
    submit(*c, false);
    if (!last && !c->inFlight.empty()) last = c->inFlight.back();
    auto* s = new Sync();
    s->buffer = last;
    return reinterpret_cast<GLsync>(s);
}
GLenum glClientWaitSync(GLsync sync, GLbitfield, GLuint64 timeout) {
    auto* s = reinterpret_cast<Sync*>(sync);
    if (!s || !s->buffer || s->buffer.status >= MTLCommandBufferStatusCompleted) return GL_ALREADY_SIGNALED;
    if (timeout == 0) return GL_TIMEOUT_EXPIRED;
    [s->buffer waitUntilCompleted];
    return GL_CONDITION_SATISFIED;
}
void glDeleteSync(GLsync sync) { delete reinterpret_cast<Sync*>(sync); }
void glGenQueries(GLsizei n, GLuint* names) {
    Guard g(gLock);
    for (GLsizei i = 0; i < n; ++i) names[i] = newName();
}
void glDeleteQueries(GLsizei, const GLuint*) {}

// FirstRunCompile (P470 on the iPhone): the programs this process linked are kept as recipes (length-prefixed sources, the
// ones of earlier recipes first) so a later first-run compile builds them all before the first shot needs one; Metal keeps the
// compiled functions in its own cache across launches.
// The stage this thread's context books its GPU time to (empty / null: none); the work recorded so far goes under the old one
void scamgl_label(const char* name) {
    Guard g(gLock);
    Context* c = ctx();
    if (!c) return;
    const std::string next = name ? name : "";
    if (next == c->label) return;
    if (!c->label.empty()) submit(*c, false);
    c->label = next;
}

// The shot's GPU timing on (1) / off (0): while on, the command buffers of contexts without a label are booked too
void scamgl_gpu_timing(int on) { gGpuTiming = on != 0; }

// "label ms, label ms, ..." of the stages booked since the last call (completed command buffers only), then cleared
int scamgl_gpu_times(char* out, int size) {
    std::string text;
    {
        std::lock_guard<std::mutex> g(gGpuTimesLock);
        char line[160];
        for (const auto& e : gGpuTimes) {
            std::snprintf(line, sizeof line, "%s%s %.0f", text.empty() ? "" : ", ", e.first.c_str(), e.second);
            text += line;
        }
        gGpuTimes.clear();
    }
    if (out && size > 0) {
        const size_t n = std::min(text.size(), size_t(size - 1));
        std::memcpy(out, text.data(), n);
        out[n] = 0;
    }
    return int(text.size());
}

size_t scamgl_program_count(void) {
    Guard g(gLock);
    return gRecorded.size();
}

int scamgl_save_programs(const char* path) {
    std::vector<std::string> keys;
    {
        Guard g(gLock);
        keys = gRecorded;
    }
    std::vector<std::string> all;
    if (FILE* in = std::fopen(path, "rb")) {
        uint32_t n = 0;
        while (std::fread(&n, 4, 1, in) == 1 && n < (64u << 20)) {
            std::string k(n, '\0');
            if (n && std::fread(&k[0], 1, n, in) != n) break;
            all.push_back(k);
        }
        std::fclose(in);
    }
    for (const auto& k : keys) if (std::find(all.begin(), all.end(), k) == all.end()) all.push_back(k);
    if (all.size() > 800) all.erase(all.begin(), all.begin() + (all.size() - 800)); // programs and their pipeline states
    const std::string tmp = std::string(path) + ".tmp";
    FILE* out = std::fopen(tmp.c_str(), "wb");
    if (!out) return -1;
    for (const auto& k : all) {
        const uint32_t n = uint32_t(k.size());
        std::fwrite(&n, 4, 1, out);
        std::fwrite(k.data(), 1, n, out);
    }
    std::fclose(out);
    std::rename(tmp.c_str(), path);
    return int(all.size());
}

int scamgl_warm_programs(const char* path, void (*progress)(int done, int total, void* context), void* context) {
    std::vector<std::string> keys;
    if (FILE* in = std::fopen(path, "rb")) {
        uint32_t n = 0;
        while (std::fread(&n, 4, 1, in) == 1 && n < (64u << 20)) {
            std::string k(n, '\0');
            if (n && std::fread(&k[0], 1, n, in) != n) break;
            keys.push_back(k);
        }
        std::fclose(in);
    }
    int built = 0;
    for (size_t i = 0; i < keys.size(); ++i) {
        if (progress) progress(int(i), int(keys.size()), context);
        const std::string& k = keys[i];
        std::shared_ptr<Linked> l; // (the link takes gLock for its cache only)
        if (k.rfind("C\n", 0) == 0) {
            l = linkCompute(k.substr(2));
        } else if (k.rfind("R\n", 0) == 0) {
            const size_t cut = k.find('\x01', 2);
            if (cut != std::string::npos) l = linkRender(k.substr(2, cut - 2), k.substr(cut + 1));
        } else if (k.rfind("P\n", 0) == 0) {
            // a render program's pipeline state (glDrawArrays' key), built outside gLock, kept unless a draw made it meanwhile
            const size_t at = k.find('\x02', 2);
            const std::string program = at == std::string::npos ? std::string() : k.substr(2, at - 2), key = at == std::string::npos ? std::string() : k.substr(at + 1);
            const size_t cut = program.find('\x01', 2);
            if (program.rfind("R\n", 0) == 0 && cut != std::string::npos) l = linkRender(program.substr(2, cut - 2), program.substr(cut + 1));
            if (l && l->ready()) {
                std::vector<MTLPixelFormat> formats;
                bool blend = false;
                unsigned eq = 0, src = 0, dst = 0;
                size_t pos = 0;
                while (pos < key.size() && key[pos] != 'b') {
                    const size_t comma = key.find(',', pos);
                    if (comma == std::string::npos) break;
                    formats.push_back(MTLPixelFormat(std::strtoul(key.c_str() + pos, nullptr, 10)));
                    pos = comma + 1;
                }
                if (pos < key.size() && key[pos] == 'b') blend = std::sscanf(key.c_str() + pos + 1, "%u,%u,%u", &eq, &src, &dst) == 3;
                bool have = false;
                {
                    Guard g(gLock);
                    have = l->renderPipelines.count(key) != 0;
                }
                std::string error;
                id<MTLRenderPipelineState> state = have || formats.empty() ? nil : makeRenderPipeline(*l, formats, blend, eq, src, dst, error);
                if (state) {
                    Guard g(gLock);
                    if (!l->renderPipelines.count(key)) {
                        l->renderPipelines[key] = state;
                        gRecorded.push_back(k);
                    }
                }
                if (!have && !state) l = nullptr;
            }
        }
        if (l && l->ready()) ++built;
    }
    if (progress) progress(int(keys.size()), int(keys.size()), context);
    return built;
}

} // extern "C"
