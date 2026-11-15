#include "ScamGLCompiler.h"

#include <glslang/Public/ResourceLimits.h>
#include <glslang/Public/ShaderLang.h>
#include <glslang/SPIRV/GlslangToSpv.h>
#include <spirv_msl.hpp>
#include <spirv_parser.hpp>

#include <cstdio>
#include <cstring>
#include <map>
#include <cstdlib>
#include <regex>
#include <mutex>
#include <set>

namespace scamgl {

namespace {

constexpr unsigned kDefaultBlockBinding = 99;
constexpr int kBufferSizeIndex = 30;

std::once_flag initOnce;

EShLanguage language(Stage stage) {
    switch (stage) {
    case Stage::Compute: return EShLangCompute;
    case Stage::Vertex: return EShLangVertex;
    case Stage::Fragment: return EShLangFragment;
    }
    return EShLangCompute;
}

spv::ExecutionModel model(Stage stage) {
    switch (stage) {
    case Stage::Compute: return spv::ExecutionModelGLCompute;
    case Stage::Vertex: return spv::ExecutionModelVertex;
    case Stage::Fragment: return spv::ExecutionModelFragment;
    }
    return spv::ExecutionModelGLCompute;
}

bool toSpirv(const std::string& glsl, Stage stage, std::vector<uint32_t>& spirv, std::string& log) {
    std::call_once(initOnce, [] { glslang::InitializeProcess(); });
    const EShLanguage lang = language(stage);
    glslang::TShader shader(lang);
    const char* text = glsl.c_str();
    shader.setStrings(&text, 1);
    shader.setEnvInput(glslang::EShSourceGlsl, lang, glslang::EShClientVulkan, 100);
    shader.setEnvClient(glslang::EShClientVulkan, glslang::EShTargetVulkan_1_1);
    shader.setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_3);
    shader.setEnvInputVulkanRulesRelaxed();
    shader.setGlobalUniformBlockName("gl_DefaultUniformBlock");
    shader.setGlobalUniformSet(0);
    shader.setGlobalUniformBinding(kDefaultBlockBinding);
    shader.setAutoMapBindings(true);
    shader.setAutoMapLocations(true);
    shader.setShiftBinding(glslang::EResSsbo, kShiftSsbo);
    shader.setShiftBinding(glslang::EResImage, kShiftImage);
    shader.setShiftBinding(glslang::EResTexture, kShiftTexture);
    shader.setShiftBinding(glslang::EResSampler, kShiftTexture);
    shader.setShiftBinding(glslang::EResUbo, kShiftUbo);
    const auto messages = static_cast<EShMessages>(EShMsgSpvRules | EShMsgVulkanRules);
    if (!shader.parse(GetDefaultResources(), 310, false, messages)) {
        log = std::string("compile: ") + shader.getInfoLog() + shader.getInfoDebugLog();
        return false;
    }
    glslang::TProgram program;
    program.addShader(&shader);
    if (!program.link(messages) || !program.mapIO()) {
        log = std::string("link: ") + program.getInfoLog() + program.getInfoDebugLog();
        return false;
    }
    glslang::SpvOptions options;
    options.generateDebugInfo = false;
    options.disableOptimizer = true;
    glslang::GlslangToSpv(*program.getIntermediate(lang), spirv, &options);
    return !spirv.empty();
}

int baseTypeOf(const spirv_cross::SPIRType& t) {
    switch (t.basetype) {
    case spirv_cross::SPIRType::Int: return 1;
    case spirv_cross::SPIRType::UInt: return 2;
    case spirv_cross::SPIRType::Boolean: return 3;
    default: return 0;
    }
}

} // namespace

// SCAMGL_FILTER=float: texture() of a uniform sampler2D becomes scam_tex_<name>(): with the bound texture linear, clamped and
// float (ScamGL sets scam_lin_<name>), the four texels by texelFetch and the weights in float (llvmpipe's rule: u x size - 0.5,
// floor / fraction, the edge texels clamped, lerp a + w (b - a)) instead of the GPU's own filter; otherwise texture() as written.
int filterMode() {
    static const int mode = [] {
        const char* e = std::getenv("SCAMGL_FILTER");
        return e && std::string(e) == "float" ? 1 : 0;
    }();
    return mode;
}

static std::string emulateFilter(const std::string& glsl) {
    static const std::regex decl("((?:layout\\s*\\([^)]*\\)\\s*)?uniform\\s+(?:(?:highp|mediump|lowp)\\s+)?sampler2D\\s+(\\w+)\\s*;)");
    std::string out;
    std::vector<std::string> names;
    auto begin = std::sregex_iterator(glsl.begin(), glsl.end(), decl);
    size_t last = 0;
    for (auto it = begin; it != std::sregex_iterator(); ++it) {
        const std::smatch& m = *it;
        const std::string name = m[2].str();
        out.append(glsl, last, size_t(m.position(0)) - last);
        out += m[1].str();
        out += "\nuniform int scam_lin_" + name + ";\n"
               "highp vec4 scam_tex_" + name + "(highp vec2 scam_uv) {\n"
               "    if (scam_lin_" + name + " == 0) return texture(" + name + ", scam_uv);\n"
               "    highp ivec2 sz = textureSize(" + name + ", 0);\n"
               "    highp vec2 p = scam_uv * vec2(sz) - 0.5;\n"
               "    highp vec2 f = floor(p);\n"
               "    highp vec2 w = p - f;\n"
               "    highp ivec2 i = ivec2(f);\n"
               "    highp ivec2 a = clamp(i, ivec2(0), sz - 1), b = clamp(i + 1, ivec2(0), sz - 1);\n"
               "    highp vec4 t00 = texelFetch(" + name + ", a, 0), t10 = texelFetch(" + name + ", ivec2(b.x, a.y), 0);\n"
               "    highp vec4 t01 = texelFetch(" + name + ", ivec2(a.x, b.y), 0), t11 = texelFetch(" + name + ", b, 0);\n"
               "    highp vec4 r0 = t00 + (t10 - t00) * w.x, r1 = t01 + (t11 - t01) * w.x;\n"
               "    return r0 + (r1 - r0) * w.y;\n"
               "}\n"
               "highp vec4 scam_tex_" + name + "(highp vec2 scam_uv, highp float scam_bias) { return scam_tex_" + name + "(scam_uv); }\n";
        last = size_t(m.position(0) + m.length(0));
        names.push_back(name);
    }
    out.append(glsl, last, std::string::npos);
    if (names.empty()) return glsl;
    // the calls after the declarations (the helpers' own texture() calls stay: they are written with the name and "scam_uv)")
    for (const std::string& name : names) {
        const std::regex call("\\btexture\\s*\\(\\s*" + name + "\\s*,(?!\\s*scam_uv\\))");
        out = std::regex_replace(out, call, "scam_tex_" + name + "(");
    }
    return out;
}

static Compiled compileUncached(const std::string& source, Stage stage, bool iosPlatform) {
    Compiled out;
    // GLSL ES words that Vulkan GLSL reserves or refuses: a parameter named `sampler` (a type there), #version 100 / 300 es
    std::string glsl = std::regex_replace(source, std::regex("\\bsampler\\b"), "scam_sampler");
    glsl = std::regex_replace(glsl, std::regex("#version[ \\t]+(100|300[ \\t]+es)"), "#version 310 es");
    if (filterMode() == 1) glsl = emulateFilter(glsl);
    std::vector<uint32_t> spirv;
    if (!toSpirv(glsl, stage, spirv, out.log)) return out;
    try {
        // GLSL names that are Metal library names (a function `level` is ambiguous with metal::level): user functions get a
        // prefix, the few names that clash as variables a suffix.
        spirv_cross::Parser parser(std::move(spirv));
        parser.parse();
        spirv_cross::ParsedIR& ir = parser.get_parsed_ir();
        static const std::set<std::string> clashing = {"level", "bias", "gradient2d", "gradient3d", "gradientcube", "min_lod_clamp",
                                                       "access", "coord", "address", "filter", "mip_filter", "compare_func"};
        ir.for_each_typed_id<spirv_cross::SPIRFunction>([&](uint32_t id, spirv_cross::SPIRFunction&) {
            const std::string name = ir.get_name(id);
            if (!name.empty() && name != "main") ir.set_name(id, "scam_" + name);
        });
        ir.for_each_typed_id<spirv_cross::SPIRVariable>([&](uint32_t id, spirv_cross::SPIRVariable&) {
            const std::string name = ir.get_name(id);
            if (clashing.count(name)) ir.set_name(id, name + "_");
        });
        spirv_cross::CompilerMSL msl(std::move(ir));
        spirv_cross::CompilerMSL::Options options;
        options.platform = iosPlatform ? spirv_cross::CompilerMSL::Options::iOS : spirv_cross::CompilerMSL::Options::macOS;
        options.set_msl_version(2, 4);
        options.buffer_size_buffer_index = kBufferSizeIndex;
        options.enable_decoration_binding = false;
        // GL writes a float / vec2 / vec3 output into any colour target; Metal needs the target's components: pad to four
        options.pad_fragment_output_components = true;
        msl.set_msl_options(options);
        if (stage == Stage::Vertex) {
            // GL window rows = texture rows: y flipped into Metal's top-left space, z from [-w, w] to [0, w]
            auto common = msl.get_common_options();
            common.vertex.flip_vert_y = true;
            common.vertex.fixup_clipspace = true;
            msl.set_common_options(common);
        }
        const spv::ExecutionModel exec = model(stage);
        const auto resources = msl.get_shader_resources();
        int nextBuffer = 0, nextTexture = 0, nextSampler = 0;
        std::map<uint32_t, int> bufferOfBinding; // SPIR-V binding → [[buffer]] (aliased blocks share it)
        auto bindBuffer = [&](uint32_t binding) {
            auto it = bufferOfBinding.find(binding);
            if (it != bufferOfBinding.end()) return it->second;
            const int index = nextBuffer++;
            if (index == kBufferSizeIndex) throw std::runtime_error("too many buffers");
            bufferOfBinding[binding] = index;
            spirv_cross::MSLResourceBinding b;
            b.stage = exec;
            b.desc_set = 0;
            b.binding = binding;
            b.msl_buffer = uint32_t(index);
            msl.add_msl_resource_binding(b);
            return index;
        };
        for (const auto& r : resources.uniform_buffers) {
            const uint32_t binding = msl.get_decoration(r.id, spv::DecorationBinding);
            Resource res;
            res.name = msl.get_name(r.base_type_id);
            // The global block's binding is shifted with the UBOs; its name identifies it.
            const bool isDefault = res.name == "gl_DefaultUniformBlock" || binding == kDefaultBlockBinding + unsigned(kShiftUbo);
            res.type = isDefault ? Resource::DefaultBlock : Resource::UniformBlock;
            res.glBinding = isDefault ? -1 : int(binding) - kShiftUbo;
            res.mslIndex = bindBuffer(binding);
            out.resources.push_back(res);
            if (isDefault) {
                const auto& type = msl.get_type(r.base_type_id);
                out.blockSize = uint32_t(msl.get_declared_struct_size(type));
                for (uint32_t i = 0; i < type.member_types.size(); ++i) {
                    const auto& mt = msl.get_type(type.member_types[i]);
                    Member m;
                    m.name = msl.get_member_name(r.base_type_id, i);
                    m.offset = msl.type_struct_member_offset(type, i);
                    m.size = uint32_t(msl.get_declared_struct_member_size(type, i));
                    m.vecsize = mt.vecsize;
                    m.columns = mt.columns;
                    m.baseType = baseTypeOf(mt);
                    if (!mt.array.empty()) {
                        m.count = mt.array[0];
                        m.arrayStride = msl.type_struct_member_array_stride(type, i);
                    }
                    if (mt.columns > 1) m.matrixStride = msl.type_struct_member_matrix_stride(type, i);
                    out.members.push_back(m);
                }
            }
        }
        for (const auto& r : resources.storage_buffers) {
            const uint32_t binding = msl.get_decoration(r.id, spv::DecorationBinding);
            Resource res;
            res.type = Resource::StorageBlock;
            res.name = msl.get_name(r.base_type_id);
            res.glBinding = int(binding) - kShiftSsbo;
            res.mslIndex = bindBuffer(binding);
            out.resources.push_back(res);
        }
        for (const auto& r : resources.storage_images) {
            const uint32_t binding = msl.get_decoration(r.id, spv::DecorationBinding);
            Resource res;
            res.type = Resource::Image;
            res.name = msl.get_name(r.id);
            res.glBinding = int(binding) - kShiftImage;
            res.mslIndex = nextTexture++;
            res.arrayed = msl.get_type(r.type_id).image.arrayed;
            spirv_cross::MSLResourceBinding b;
            b.stage = exec;
            b.desc_set = 0;
            b.binding = binding;
            b.msl_texture = uint32_t(res.mslIndex);
            msl.add_msl_resource_binding(b);
            out.resources.push_back(res);
        }
        for (const auto& r : resources.sampled_images) {
            const uint32_t binding = msl.get_decoration(r.id, spv::DecorationBinding);
            Resource res;
            res.type = Resource::Sampled;
            res.name = msl.get_name(r.id);
            res.glBinding = int(binding) - kShiftTexture;
            res.mslIndex = nextTexture++;
            res.mslSampler = nextSampler++;
            res.arrayed = msl.get_type(r.type_id).image.arrayed;
            res.volume = msl.get_type(r.type_id).image.dim == spv::Dim3D;
            spirv_cross::MSLResourceBinding b;
            b.stage = exec;
            b.desc_set = 0;
            b.binding = binding;
            b.msl_texture = uint32_t(res.mslIndex);
            b.msl_sampler = uint32_t(res.mslSampler);
            msl.add_msl_resource_binding(b);
            out.resources.push_back(res);
        }
        out.msl = msl.compile();
        out.entry = msl.get_cleansed_entry_point_name("main", exec);
        if (stage == Stage::Compute) {
            for (int i = 0; i < 3; ++i) out.local[i] = std::max(1u, msl.get_execution_mode_argument(spv::ExecutionModeLocalSize, uint32_t(i)));
        }
        if (msl.needs_buffer_size_buffer()) out.bufferSizeIndex = kBufferSizeIndex;
        out.ok = true;
    } catch (const std::exception& error) {
        out.log = std::string("SPIRV-Cross: ") + error.what();
    }
    return out;
}


// ---- the translation cache ----

namespace {
std::mutex gCacheLock;
std::string gCacheDir;

uint64_t fnv(const std::string& text, uint64_t h = 1469598103934665603ULL) {
    for (unsigned char c : text) { h ^= c; h *= 1099511628211ULL; }
    return h;
}

struct Writer {
    std::string out;
    void u32(uint32_t v) { out.append(reinterpret_cast<const char*>(&v), 4); }
    void i32(int v) { u32(uint32_t(v)); }
    void str(const std::string& s) { u32(uint32_t(s.size())); out += s; }
};
struct Reader {
    const std::string& in;
    size_t at = 0;
    bool bad = false;
    uint32_t u32() {
        if (at + 4 > in.size()) { bad = true; return 0; }
        uint32_t v;
        std::memcpy(&v, in.data() + at, 4);
        at += 4;
        return v;
    }
    int i32() { return int(u32()); }
    std::string str() {
        const uint32_t n = u32();
        if (bad || at + n > in.size()) { bad = true; return ""; }
        std::string s = in.substr(at, n);
        at += n;
        return s;
    }
};

std::string serialize(const Compiled& c) {
    Writer w;
    w.str("SCAMGLC2");
    w.str(c.log); w.str(c.msl); w.str(c.entry);
    for (uint32_t v : c.local) w.u32(v);
    w.u32(uint32_t(c.resources.size()));
    for (const Resource& r : c.resources) {
        w.i32(int(r.type)); w.i32(r.glBinding); w.i32(r.mslIndex); w.i32(r.mslSampler); w.i32(r.arrayed); w.i32(r.volume); w.str(r.name);
    }
    w.u32(uint32_t(c.members.size()));
    for (const Member& m : c.members) {
        w.str(m.name);
        for (uint32_t v : {m.offset, m.size, m.arrayStride, m.count, m.vecsize, m.columns, m.matrixStride}) w.u32(v);
        w.i32(m.baseType);
    }
    w.u32(c.blockSize);
    w.i32(c.bufferSizeIndex);
    return w.out;
}

bool deserialize(const std::string& data, Compiled& c) {
    Reader r{data};
    if (r.str() != "SCAMGLC2") return false;
    c.log = r.str(); c.msl = r.str(); c.entry = r.str();
    for (uint32_t& v : c.local) v = r.u32();
    const uint32_t nr = r.u32();
    if (r.bad || nr > 4096) return false;
    for (uint32_t i = 0; i < nr; i++) {
        Resource res;
        res.type = Resource::Type(r.i32()); res.glBinding = r.i32(); res.mslIndex = r.i32(); res.mslSampler = r.i32();
        res.arrayed = r.i32() != 0; res.volume = r.i32() != 0; res.name = r.str();
        c.resources.push_back(res);
    }
    const uint32_t nm = r.u32();
    if (r.bad || nm > 65536) return false;
    for (uint32_t i = 0; i < nm; i++) {
        Member m;
        m.name = r.str();
        m.offset = r.u32(); m.size = r.u32(); m.arrayStride = r.u32(); m.count = r.u32(); m.vecsize = r.u32(); m.columns = r.u32();
        m.matrixStride = r.u32(); m.baseType = r.i32();
        c.members.push_back(m);
    }
    c.blockSize = r.u32();
    c.bufferSizeIndex = r.i32();
    c.ok = !r.bad && !c.msl.empty();
    return c.ok;
}
} // namespace

void setCacheDir(const std::string& dir) {
    std::lock_guard<std::mutex> g(gCacheLock);
    gCacheDir = dir;
}

Compiled compile(const std::string& source, Stage stage, bool iosPlatform) {
    std::string dir;
    {
        std::lock_guard<std::mutex> g(gCacheLock);
        dir = gCacheDir;
    }
    if (dir.empty()) return compileUncached(source, stage, iosPlatform);
    // this build's translator: a new app version translates again
    static const std::string build = std::string(__DATE__) + " " + __TIME__ + " filter " + std::to_string(filterMode());
    char name[64];
    std::snprintf(name, sizeof name, "/%016llx-%d%d.scamglc",
                  static_cast<unsigned long long>(fnv(source, fnv(build))), int(stage), iosPlatform ? 1 : 0);
    const std::string path = dir + name;
    if (FILE* f = std::fopen(path.c_str(), "rb")) {
        std::string data;
        char buf[65536];
        for (size_t n; (n = std::fread(buf, 1, sizeof buf, f)) > 0;) data.append(buf, n);
        std::fclose(f);
        Compiled cached;
        if (deserialize(data, cached)) return cached;
    }
    Compiled out = compileUncached(source, stage, iosPlatform);
    if (out.ok) {
        const std::string tmp = path + ".tmp";
        if (FILE* f = std::fopen(tmp.c_str(), "wb")) {
            const std::string data = serialize(out);
            const bool written = std::fwrite(data.data(), 1, data.size(), f) == data.size();
            std::fclose(f);
            if (written) std::rename(tmp.c_str(), path.c_str()); else std::remove(tmp.c_str());
        }
    }
    return out;
}

} // namespace scamgl

