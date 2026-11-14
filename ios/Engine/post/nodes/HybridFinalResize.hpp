// HybridFinalResize.java one to one: the final photo size (P503 «Уменьшить до», below the Sabre grid's size) made on the GPU as the
// last processing step before the rotation, with the downsampler of pref_scam_hybrid_downsampler (hybrid/final_resize: Lanczos-3,
// bicubic, area, bilinear; the separable kernels in two passes through RGBA32F bands of rows). The idle ping-pong texture is freed
// before the allocation.
#pragma once

#include "../Pipeline.hpp"

#include <array>
#include <chrono>
#include <cstdio>
#include <vector>

namespace scam_post {

class HybridFinalResize : public Node {
public:
    HybridFinalResize(Point target, std::string kernelName) : Node("", "FinalResize"), target_(target), kernelName_(std::move(kernelName)) {
        if (kernelName_.empty()) kernelName_ = "lanczos";
    }

    static int kernelIndex(const std::string& name) {
        if (name == "bicubic") return 1;
        if (name == "area") return 2;
        if (name == "bilinear") return 3;
        return 0;
    }

    void Compile() override {}

    /// HybridFinalResize.resized: the linear scene snapshot of Ultra HDR at the final size (LINEAR_IN: the input is linear light)
    static Texture resized(GLProg& prog, const Texture& in, Point target, const std::string& kernelName) {
        if (target.x >= in->mSize.x || target.y >= in->mSize.y || target.x * 4 < in->mSize.x || target.y * 4 < in->mSize.y)
            throw std::runtime_error("resize " + std::to_string(in->mSize.x) + "x" + std::to_string(in->mSize.y) + " -> "
                                     + std::to_string(target.x) + "x" + std::to_string(target.y) + " out of range");
        prog.setDefine("LINEAR_IN", 1);
        prog.useAssetProgram("hybrid/final_resize", false);
        prog.setTexture("InputBuffer", in);
        prog.setVar("kernel", kernelIndex(kernelName));
        prog.setVar("inSize", in->mSize.x, in->mSize.y);
        prog.setVar("outSize", target.x, target.y);
        Texture out = makeTexture(target, in->mFormat, nullptr, GL_LINEAR, GL_CLAMP_TO_EDGE);
        prog.drawBlocks(*out);
        prog.closed = true;
        return out;
    }

    void Run() override {
        PostPipeline& p = *basePipeline;
        GLProg& prog = *glProg;
        const Texture in = previousNode->WorkingTexture;
        if (target_.x >= in->mSize.x || target_.y >= in->mSize.y || target_.x * 4 < in->mSize.x || target_.y * 4 < in->mSize.y)
            throw std::runtime_error("final resize " + std::to_string(in->mSize.x) + "x" + std::to_string(in->mSize.y) + " -> "
                                     + std::to_string(target_.x) + "x" + std::to_string(target_.y)
                                     + " out of range (the output buffer is already at the final size)");
        const auto started = std::chrono::steady_clock::now();
        // the idle ping-pong texture is not needed any more: freed before the allocation
        p.lazyMain2 = nullptr;
        p.lazyMain1 = nullptr;
        Texture* mains[2] = {&p.main1, &p.main2};
        for (Texture* m : mains) {
            if (*m && *m != in) {
                (*m)->close();
                *m = nullptr;
            }
        }
        const int kernel = kernelIndex(kernelName_);
        WorkingTexture = makeTexture(target_, in->mFormat, nullptr, GL_LINEAR, GL_CLAMP_TO_EDGE);
        const bool twoPasses = separableWanted(kernel) && separable(prog, *in, *WorkingTexture, kernel);
        if (!twoPasses) {
            prog.useAssetProgram("hybrid/final_resize", false);
            prog.setTexture("InputBuffer", in);
            prog.setVar("kernel", kernel);
            prog.setVar("inSize", in->mSize.x, in->mSize.y);
            prog.setVar("outSize", target_.x, target_.y);
            prog.drawBlocks(*WorkingTexture);
        }
        // drawn here: the pipeline must not draw the program into the output again
        prog.closed = true;
        p.finalResized = true;
        const long ms = long(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count());
        logI("SCAM_HDR", "hybrid final size " + std::to_string(target_.x) + "x" + std::to_string(target_.y) + " (" + kernelName_ + ", GPU"
             + (twoPasses ? ", two passes" : "") + ") from " + std::to_string(in->mSize.x) + "x" + std::to_string(in->mSize.y)
             + " ms=" + std::to_string(ms));
    }

    /// The output rows of one band of the two-pass route: drawn from an RGBA32F band of this many input rows at most.
    static constexpr int BAND_ROWS = 256;
    /// Input rows the planner adds on each side beyond the shader's reach (its float ceil may land one higher than Java's).
    static constexpr int REACH_MARGIN = 2;

    /// separableWanted: the two-pass route for Lanczos-3, bicubic and area (bilinear keeps the one pass); scam_dev
    /// resize_separable 0 = the one pass
    static bool separableWanted(int kernel) {
        if (kernel == 3 || PostGlMode::legacy()) return false;
        return Settings::current().scamDevSwitch("resize_separable", true);
    }

    /// reach: the shader's ceil(radius) + 1 along an axis of in -> out pixels, in float as the shader has it
    static int reach(int in, int out, int kernel) {
        const float scale = float(in) / float(out);
        const float radius = kernel == 2 ? 0.5f * scale : (kernel == 1 ? 2.f : 3.f) * scale;
        return int(std::ceil(radius)) + 1;
    }

    /// plan: the output bands of the two-pass route, {first output row, rows, first input row, input rows} - every input row the
    /// output rows' vertical taps reach ((2 y + 1) in - out) / (2 out) +- reachRows, within the frame
    static std::vector<std::array<int, 4>> plan(int inRows, int outRows, int bandRows, int reachRows) {
        const int bands = (outRows + bandRows - 1) / bandRows;
        std::vector<std::array<int, 4>> out(size_t(std::max(0, bands)));
        for (int b = 0; b < bands; b++) {
            const int y0 = b * bandRows, rows = std::min(bandRows, outRows - y0);
            const int64_t den = 2LL * outRows;
            const int first = std::max(0, int(((2LL * y0 + 1) * inRows - outRows) / den) - reachRows);
            const int last = std::min(inRows - 1, int(((2LL * (y0 + rows - 1) + 1) * inRows - outRows) / den) + reachRows);
            out[size_t(b)] = {y0, rows, first, last - first + 1};
        }
        return out;
    }

private:
    /// separable: the two passes into out (hybrid/final_resize PASS 1 into an RGBA32F band of input rows, PASS 2 down it); false
    /// (nothing to keep: the one pass then draws every pixel) when GL refuses them
    bool separable(GLProg& prog, GLTexture& in, GLTexture& out, int kernel) {
        const auto bands = plan(in.mSize.y, target_.y, BAND_ROWS, reach(in.mSize.y, target_.y, kernel) + REACH_MARGIN);
        int bandHeight = 1;
        for (const auto& b : bands) bandHeight = std::max(bandHeight, b[3]);
        Texture band;
        bool done = false;
        try {
            while (glGetError() != GL_NO_ERROR) {} // only the passes below decide
            band = makeTexture({target_.x, bandHeight}, GLFormat(DataType::FLOAT_32, 4), nullptr, GL_NEAREST, GL_CLAMP_TO_EDGE);
            band->BufferLoad();
            if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
                logI("SCAM_HDR", "final resize: RGBA32F band not renderable, one pass");
            } else {
                for (const auto& b : bands) {
                    pass(prog, 1, in, in.mSize, kernel, b[2]);
                    band->BufferLoad();
                    rows(prog, 0, b[3]);
                    pass(prog, 2, *band, in.mSize, kernel, b[2]);
                    out.BufferLoad();
                    rows(prog, b[0], b[1]);
                }
                const GLenum error = glGetError();
                if (error == GL_NO_ERROR) done = true;
                else {
                    char hex[16];
                    std::snprintf(hex, sizeof hex, "%x", unsigned(error));
                    logI("SCAM_HDR", std::string("final resize two passes: GL error 0x") + hex + ", one pass");
                }
            }
        } catch (const std::exception& e) {
            logI("SCAM_HDR", std::string("final resize two passes: ") + e.what() + ", one pass");
            prog.setDefine("PASS", 0); // Java: a failed compile leaves its define pending (the one pass's own)
        }
        if (band) band->close();
        return done;
    }

    void pass(GLProg& prog, int which, GLTexture& source, Point inSize, int kernel, int rowOrigin) {
        prog.setDefine("PASS", which);
        prog.useAssetProgram("hybrid/final_resize", false);
        prog.setTexture("InputBuffer", source);
        prog.setVar("kernel", kernel);
        prog.setVar("inSize", inSize.x, inSize.y);
        prog.setVar("outSize", target_.x, target_.y);
        prog.setVar("rowOrigin", rowOrigin);
    }

    /// rows y0 .. y0 + count - 1 of the bound target, in the bands of GLProg.drawBlocks (no GPU pacing on iOS)
    void rows(GLProg& prog, int y0, int count) {
        for (int y = y0, end = y0 + count; y < end;) {
            const int r = std::min(end - y, GLDrawParams::TileSize());
            glViewport(0, y, target_.x, r);
            prog.draw();
            glFlush();
            y += r;
        }
    }

private:
    Point target_;
    std::string kernelName_;
};

} // namespace scam_post
