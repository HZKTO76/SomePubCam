#import "ScamShot.h"
#import "ScamDevelopCodec.h"

#include "post/DevelopRun.hpp"
#include "post/DngPreview.hpp"
#include "post/Json.hpp"
#include "post/ShotRun.hpp"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

#include <EGL/egl.h>
#include <cmath>
#include <cstdio>
#include <mutex>
#include <set>

@interface SCAMPhoto ()
@property (nonatomic, readwrite) NSData *rgba;
@property (nonatomic, readwrite) NSInteger width;
@property (nonatomic, readwrite) NSInteger height;
@property (nonatomic, readwrite) double mergeMilliseconds;
@property (nonatomic, readwrite) double postMilliseconds;
@property (nonatomic, readwrite) NSArray<NSString *> *log;
@property (nonatomic, readwrite, nullable) NSData *gainMap;
@property (nonatomic, readwrite) NSInteger gainMapWidth;
@property (nonatomic, readwrite) NSInteger gainMapHeight;
@property (nonatomic, readwrite) float gainMapMin;
@property (nonatomic, readwrite) float gainMapMax;
@property (nonatomic, readwrite) float hdrCapacityMax;
@property (nonatomic, readwrite, nullable) NSData *developRecord;
@property (nonatomic, readwrite, nullable) NSData *mergedDng;
@property (nonatomic, readwrite) NSInteger dngRotation;
@property (nonatomic, readwrite) BOOL mirrored;
@end

/// An NSData that owns `bytes` (moved in, freed with the data): the photo's RGBA and the merged DNG reach Swift without a copy
static NSData* ownedData(std::vector<uint8_t>&& bytes) {
    if (bytes.empty()) return [NSData data];
    auto* owned = new std::vector<uint8_t>(std::move(bytes));
    return [[NSData alloc] initWithBytesNoCopy:owned->data() length:owned->size() deallocator:^(void*, NSUInteger) { delete owned; }];
}

@implementation SCAMPhoto
@end

// the post pipeline's GL context on this thread (the merge makes and drops its own)
static void makePostContext() {
    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    eglInitialize(display, nullptr, nullptr);
    eglBindAPI(EGL_OPENGL_ES_API);
    const EGLint configAttrs[] = {EGL_RENDERABLE_TYPE, 0x40, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE};
    EGLConfig config;
    EGLint n = 0;
    eglChooseConfig(display, configAttrs, &config, 1, &n);
    const EGLint ctxAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, ctxAttrs);
    const EGLint size[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    EGLSurface surface = eglCreatePbufferSurface(display, config, size);
    if (!eglMakeCurrent(display, surface, surface, context)) throw std::runtime_error("no GL context for the post pipeline");
}

// «Сохранять этапы обработки» (ScamDiagnostics.gpu / convertAndWrite): one post node's output as an 8-bit PNG of its samples -
// every step-th texel of every step-th row, at most 1024 px a side (ScamDiagnostics' sampling), channels 0..2 (one channel as
// grey), linear stages with gamma 1/2.2 (the tone's and later stages as they are), clipped to 0..1 - and its line in stages.txt.
// Read through a temporary read framebuffer (the pipeline's bindings stay as they were); a texture of another kind than
// half / float / 8-bit normalised gets its line only. Anything that fails costs the stage's file, never the shot.
static void writeStage(const std::string& dir, int index, const std::string& name, const scam_post::Texture& t, bool linear,
                       const std::function<void(const std::string&)>& log) {
    using scam_post::DataType;
    char prefix[16];
    std::snprintf(prefix, sizeof prefix, "%02d-", index);
    const std::string stage = prefix + name;
    std::string line;
    auto finish = [&] {
        std::FILE *f = std::fopen((dir + "/stages.txt").c_str(), "a");
        if (f) { std::fputs((line + "\n").c_str(), f); std::fclose(f); }
    };
    if (!t || !t->mTextureID || t->mSize.x <= 0 || t->mSize.y <= 0) { line = stage + ": no texture"; finish(); return; }
    const DataType type = t->mFormat.mFormat;
    const bool isFloat = type == DataType::FLOAT_16 || type == DataType::FLOAT_32;
    const bool isUnorm = type == DataType::SIMPLE_8;
    const int channels = std::max(1, std::min(4, t->mFormat.mChannels));
    const int W = t->mSize.x, H = t->mSize.y;
    if (!isFloat && !isUnorm) {
        line = stage + ": " + std::to_string(W) + "x" + std::to_string(H) + " integer texture, not written";
        finish();
        return;
    }
    // the errors the pipeline left (ScamDiagnostics.gpuStage: logged, then the read-back)
    for (int i = 0; i < 32; i++) {
        const GLenum e = glGetError();
        if (e == GL_NO_ERROR) break;
        char b[64];
        std::snprintf(b, sizeof b, "diagnostics: GL error 0x%x before %s", e, name.c_str());
        log(b);
    }
    const int step = std::max(1, (std::max(W, H) + 1023) / 1024), w = W / step, h = H / step;
    if (w <= 0 || h <= 0) { line = stage + ": too small"; finish(); return; }
    std::vector<float> samples(size_t(w) * size_t(h) * 3, 0.f);
    GLint oldRead = 0;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &oldRead);
    GLuint fb = 0;
    glGenFramebuffers(1, &fb);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fb);
    glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t->mTextureID, 0);
    bool ok = glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    if (ok) {
        std::vector<float> rowF(isFloat ? size_t(W) * 4 : 0);
        std::vector<uint8_t> rowB(isUnorm ? size_t(W) * 4 : 0);
        for (int y = 0; y < h && ok; y++) {
            if (isFloat) glReadPixels(0, y * step, W, 1, GL_RGBA, GL_FLOAT, rowF.data());
            else glReadPixels(0, y * step, W, 1, GL_RGBA, GL_UNSIGNED_BYTE, rowB.data());
            if (glGetError() != GL_NO_ERROR) { ok = false; break; }
            for (int x = 0; x < w; x++)
                for (int c = 0; c < 3; c++) {
                    const int src = channels == 1 ? 0 : std::min(c, channels - 1);
                    const size_t at = size_t(x) * size_t(step) * 4 + size_t(src);
                    samples[(size_t(y) * size_t(w) + size_t(x)) * 3 + size_t(c)] = isFloat ? rowF[at] : rowB[at] / 255.f;
                }
        }
    }
    glBindFramebuffer(GL_READ_FRAMEBUFFER, GLuint(oldRead));
    glDeleteFramebuffers(1, &fb);
    while (glGetError() != GL_NO_ERROR) {}
    if (!ok) { line = stage + ": " + std::to_string(W) + "x" + std::to_string(H) + " not readable"; finish(); return; }
    std::vector<uint8_t> rgbx(size_t(w) * size_t(h) * 4, 255);
    float lo = INFINITY, hi = -INFINITY;
    long long nonfinite = 0;
    for (size_t i = 0; i < size_t(w) * size_t(h); i++)
        for (int c = 0; c < 3; c++) {
            float v = samples[i * 3 + size_t(c)];
            if (!std::isfinite(v)) { nonfinite++; v = 0.f; } else { lo = std::min(lo, v); hi = std::max(hi, v); }
            float d = std::max(0.f, std::min(1.f, v));
            if (linear) d = std::pow(d, 1.f / 2.2f);
            rgbx[i * 4 + size_t(c)] = uint8_t(std::lround(d * 255.f));
        }
    char facts[160];
    std::snprintf(facts, sizeof facts, ": %dx%d of %dx%d %s x%d%s min=%g max=%g nonfinite=%lld", w, h, W, H,
                  isFloat ? (type == DataType::FLOAT_16 ? "half" : "float") : "unorm8", channels, linear ? " linear" : "", lo, hi, nonfinite);
    line = stage + facts;
    @autoreleasepool {
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CFDataRef pixels = CFDataCreate(nullptr, rgbx.data(), CFIndex(rgbx.size()));
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixels);
        CGImageRef image = CGImageCreate(size_t(w), size_t(h), 8, 32, size_t(w) * 4, space,
                                         (CGBitmapInfo)((uint32_t)kCGBitmapByteOrderDefault | (uint32_t)kCGImageAlphaNoneSkipLast), provider,
                                         nullptr, false, kCGRenderingIntentDefault);
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:(dir + "/" + stage + ".png").c_str()]];
        CGImageDestinationRef dst = url ? CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, nullptr) : nullptr;
        bool written = false;
        if (dst && image) {
            CGImageDestinationAddImage(dst, image, nullptr);
            written = CGImageDestinationFinalize(dst);
        }
        if (dst) CFRelease(dst);
        if (image) CGImageRelease(image);
        CGDataProviderRelease(provider);
        CFRelease(pixels);
        CGColorSpaceRelease(space);
        if (!written) line += " (PNG not written)";
    }
    finish();
}

/// The hook of a diagnostic shot: the nodes numbered in order, display-referred from the first tone node on
static std::function<void(const std::string&, const scam_post::Texture&)> stageDumper(const std::string& dir,
                                                                                    const std::function<void(const std::string&)>& log) {
    struct State { int index = 0; bool display = false; };
    auto state = std::make_shared<State>();
    return [dir, log, state](const std::string& name, const scam_post::Texture& t) {
        // ScamDiagnostics.gpuStage: WhyCombine and Sharpening are not linear; the iPhone's tone nodes and what follows them neither
        static const std::set<std::string> tone = {"WhyCombine", "WhyV2Tone", "OldstyleTone", "Sharpening", "WhyLumaSharpen"};
        if (tone.count(name)) state->display = true;
        state->index++;
        try {
            writeStage(dir, state->index, name, t, !state->display, log);
        } catch (const std::exception &e) {
            log(std::string("diagnostics: stage ") + name + " not written: " + e.what());
        }
    };
}

@implementation SCAMShot

+ (SCAMPhoto *)processBurstAtPath:(NSString *)burst dng:(NSData *)dng settings:(NSString *)settings
                            faces:(NSArray<NSNumber *> *)faces facesDetected:(BOOL)facesDetected front:(BOOL)front
                         dngFacts:(NSDictionary<NSString *, id> *)dngFacts rawOnly:(BOOL)rawOnly
                          shaders:(NSString *)shaders error:(NSError **)error {
    // the merge's process-wide hooks and the pipeline's statics: one shot (or one gallery develop) at a time
    std::lock_guard<std::timed_mutex> guard(scam_post::processLock());
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSString *job = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:job withIntermediateDirectories:YES attributes:nil error:nil];
    auto log = [lines](const std::string& line) {
        NSString *s = [NSString stringWithUTF8String:line.c_str()] ?: @"";
        @synchronized (lines) { [lines addObject:s]; }
    };
    SCAMPhoto *photo = nil;
    try {
        scam_post::Settings prefs = scam_post::Settings::fromJson(scam_post::Json::parse(settings.UTF8String));
        scam_post::Settings::Scope scope(prefs);
        scam_post::postLog() = log;
        // «Сохранять этапы обработки»: the folder Swift made for this shot (ShotDiagnostics; the Android key stays off in Settings)
        struct StageDumpReset { ~StageDumpReset() { scam_post::shotStageDump() = nullptr; } } stageDumpReset;
        const std::string diagnosticsDir = prefs.getString("ios_diagnostics_dir", "");
        if (!diagnosticsDir.empty()) scam_post::shotStageDump() = stageDumper(diagnosticsDir, log);
        const uint8_t *bytes = static_cast<const uint8_t *>(dng.bytes);
        const std::vector<uint8_t> dngBytes(bytes, bytes + dng.length);
        scam_post::ShotFaces shotFaces;
        shotFaces.detected = facesDetected;
        shotFaces.front = front;
        for (NSNumber *v in faces) shotFaces.boxes.push_back(v.floatValue);
        const long long build = [[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] longLongValue];
        std::optional<scam_post::DngRequest> dngRequest;
        if (dngFacts) {
            auto text = [dngFacts](NSString *key) {
                id v = dngFacts[key];
                return std::string([v isKindOfClass:[NSString class]] ? [(NSString *)v UTF8String] ?: "" : "");
            };
            auto number = [dngFacts](NSString *key, double fallback) {
                id v = dngFacts[key];
                return [v isKindOfClass:[NSNumber class]] ? [(NSNumber *)v doubleValue] : fallback;
            };
            scam_post::DngRequest r;
            r.facts.make = text(@"make");
            r.facts.model = text(@"model");
            r.facts.device = text(@"device");
            r.facts.buildModel = text(@"buildModel");
            r.facts.software = text(@"software");
            r.facts.dateTime = text(@"dateTime");
            r.facts.subSec = text(@"subSec");
            r.facts.offset = text(@"offset");
            r.facts.facing = text(@"facing");
            r.facts.fNumber = number(@"fNumber", NAN);
            r.facts.focalLength = number(@"focalLength", NAN);
            r.facts.focal35 = int(number(@"focal35", 0));
            r.facts.lossless = number(@"lossless", 0) != 0;
            r.frames = int(number(@"frames", 0));
            r.cameraID = text(@"cameraID");
            r.filmRecipe = text(@"filmRecipe");
            r.physicalId = int(number(@"physicalId", -1));
            r.rawOnly = rawOnly;
            dngRequest = r;
        }
        scam_post::ShotOutput out = scam_post::runShot(burst.UTF8String, dngBytes, job.UTF8String, shaders.UTF8String, log, makePostContext,
                                                             16384, shotFaces, true, {}, build, dngRequest ? &*dngRequest : nullptr);
        photo = [SCAMPhoto new];
        photo.rgba = ownedData(std::move(out.photo.rgba)); // the pipeline's buffer handed over (48 MB: no copy)
        photo.width = out.photo.width;
        photo.height = out.photo.height;
        photo.mergeMilliseconds = out.mergeMs;
        photo.postMilliseconds = out.postMs;
        if (out.gainMap) {
            const std::vector<uint8_t> luma = out.gainMap->luma();
            photo.gainMap = [NSData dataWithBytes:luma.data() length:luma.size()];
            photo.gainMapWidth = out.gainMap->width;
            photo.gainMapHeight = out.gainMap->height;
            photo.gainMapMin = out.gainMap->gainMapMin;
            photo.gainMapMax = out.gainMap->gainMapMax;
            photo.hdrCapacityMax = out.gainMap->hdrCapacityMax;
        }
        photo.dngRotation = out.params.cameraRotation;
        photo.mirrored = out.params.mirror;
        if (!out.dng.empty()) photo.mergedDng = ownedData(std::move(out.dng));
        if (out.develop) {
            try {
                const std::vector<uint8_t> tail = out.develop->appendix(scamDevelopCodec());
                photo.developRecord = [NSData dataWithBytes:tail.data() length:tail.size()];
            } catch (const std::exception &e) {
                log(std::string("develop record not written: ") + e.what());
            }
        }
        photo.log = lines;
    } catch (const std::exception &e) {
        if (error) *error = [NSError errorWithDomain:@"SCAMShot" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:e.what()] ?: @"processing failed",
                                                       @"log": [lines copy]}];
    }
    scam_post::postLog() = [](const std::string& s) { std::fprintf(stderr, "%s\n", s.c_str()); };
    [[NSFileManager defaultManager] removeItemAtPath:job error:nil];
    return photo;
}

+ (NSData *)dng:(NSData *)dng withPreview:(NSData *)rgba width:(NSInteger)width height:(NSInteger)height
         rotation:(NSInteger)rotation software:(NSString *)software {
    if ((NSInteger)rgba.length < width * height * 4 || width <= 0 || height <= 0) return nil;
    int tw = 0, th = 0;
    std::vector<uint8_t> small = scam_post::DngPreview::scaled(static_cast<const uint8_t *>(rgba.bytes), int(width), int(height),
                                                               scam_post::DngPreview::DNG_LONG_SIDE, tw, th);
    small = scam_post::DngPreview::dngSource(small, tw, th, int(rotation));
    // PhotoThumbnail.jpeg: a baseline JPEG at quality 90 (ImageIO's encoder in place of Bitmap.compress)
    NSMutableData *jpeg = [NSMutableData data];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CFDataRef pixels = CFDataCreate(nullptr, small.data(), CFIndex(small.size()));
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixels);
    CGImageRef image = CGImageCreate(size_t(tw), size_t(th), 8, 32, size_t(tw) * 4, space,
                                     (CGBitmapInfo)((uint32_t)kCGBitmapByteOrderDefault | (uint32_t)kCGImageAlphaNoneSkipLast), provider,
                                     nullptr, false, kCGRenderingIntentDefault);
    CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, nullptr);
    bool encoded = false;
    if (dst && image) {
        NSDictionary *props = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.9};
        CGImageDestinationAddImage(dst, image, (__bridge CFDictionaryRef)props);
        encoded = CGImageDestinationFinalize(dst);
    }
    if (dst) CFRelease(dst);
    if (image) CGImageRelease(image);
    CGDataProviderRelease(provider);
    CFRelease(pixels);
    CGColorSpaceRelease(space);
    if (!encoded || jpeg.length == 0) return nil;
    const uint8_t *d = static_cast<const uint8_t *>(dng.bytes);
    std::vector<uint8_t> file(d, d + dng.length);
    const uint8_t *j = static_cast<const uint8_t *>(jpeg.bytes);
    const std::vector<uint8_t> jpegBytes(j, j + jpeg.length);
    if (!scam_post::DngPreview::append(file, jpegBytes, tw, th, scam_post::DngPreview::COLOUR_SRGB, software.UTF8String ?: "")) return nil;
    return [NSData dataWithBytes:file.data() length:file.size()];
}

@end
