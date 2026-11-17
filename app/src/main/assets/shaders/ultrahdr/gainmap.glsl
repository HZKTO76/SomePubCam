precision highp float; precision highp sampler2D;
// The Ultra HDR gain map (the last stage of the scene-anchored pass): per uDown x uDown block, log2 of the anchored scene
// luminance over the base's, both with the hdrgm offset added (the decoder applies (SDR + OffsetSDR) 2^gain - OffsetHDR),
// faded out in deep blacks (no shadow noise boosted on HDR displays), over [0, uScale] in 8 bits (R = G = B, A = 1).
// InputBuffer: the stored SDR base (display-encoded RGBA8). LBuffer: the scene-luma plane (ultrahdr/sceneluma.glsl, linear,
// pixel-aligned) - the only place the highlight headroom the local tone map compressed away is left.
// uAnchor: linear median of the base / linear median of the scene plane: the midtones gain nothing, brighter scene content
// more, anything below stays at identity (clamp).
uniform sampler2D InputBuffer;
uniform float uAnchor, uScale, uEps;
uniform sampler2D LBuffer;
uniform int uDown;
// P370 (B3): 1 = the base is Display P3 (PhotoOutput): its luminance takes the P3 weights; 0 / unset: sRGB (Rec.709)
uniform int uP3;
// P728 (owner, 2026-11-17: «чтобы при включении Ultra HDR динамический диапазон действительно улучшался, а не просто становилось
// светлее как в большинстве стоков»): the boost only where the SDR tone curve compressed the light - from uKnee.x to uKnee.y of the
// SDR's linear luminance it fades in (smoothstep), below it the HDR rendition is the SDR picture itself. With the anchor taken at
// the knee (SceneGainMap: the scene's ratio there is 1), a mid-grey wall, faces and every diffuse surface keep their SDR level on
// an HDR display, the highlights get the scene's own headroom over them (clouds, the sky, lights and their texture): a wider
// range, not a brighter picture. uKnee.x <= 0: off (the boost from the median anchor everywhere, as before).
uniform vec2 uKnee;
// P728: 1 = measure pass - the block's log2(scene / SDR) where its SDR luminance is at the knee (uKnee.x / 1.25 .. x 1.25), as
// (v + 4) / 8 in [1 / 255, 1]; 0 elsewhere (SceneGainMap's median of it moves the anchor to the knee)
uniform int uMeasure;
out vec4 Output;

#define SHADOW_FADE 0.02
const vec3 W709 = vec3(0.2126, 0.7152, 0.0722);
const vec3 WP3 = vec3(0.2290, 0.6917, 0.0793);

float decode(float v) {
    v = clamp(v, 0.0, 1.0);
    if (v <= 0.04045) return v / 12.92;
    return pow((v + 0.055) / 1.055, 2.4);
}

void main() {
    ivec2 corner = ivec2(gl_FragCoord.xy) * uDown;
    float base = 0.0;
    float scene = 0.0;
    int n = 0;
    for (int y = 0; y < uDown; y++) {
        for (int x = 0; x < uDown; x++) {
            ivec2 p = corner + ivec2(x, y);
            vec3 sdr = texelFetch(InputBuffer, p, 0).rgb;
            vec3 linear = vec3(decode(sdr.r), decode(sdr.g), decode(sdr.b));
            float sdrY = uP3 == 1 ? dot(linear, WP3) : dot(linear, W709);
            float sceneY = dot(max(texelFetch(LBuffer, p, 0).rgb, vec3(0.0)), W709) * uAnchor;
            base += sdrY + uEps;
            scene += sceneY + uEps;
            n++;
        }
    }
    float sdrL = base / float(n);
    float sceneL = scene / float(n);
    float boost = log2(sceneL / sdrL);
    if (uMeasure == 1) {
        float y = sdrL - uEps;
        float v = y >= uKnee.x / 1.25 && y <= uKnee.x * 1.25 ? clamp((boost + 4.0) / 8.0, 1.0 / 255.0, 1.0) : 0.0;
        Output = vec4(v, v, v, 1.0);
        return;
    }
    boost *= smoothstep(0.0, SHADOW_FADE, sdrL - uEps);
    if (uKnee.x > 0.0) boost *= smoothstep(uKnee.x, max(uKnee.y, uKnee.x + 0.001), sdrL - uEps);
    int code = int(clamp(boost / uScale, 0.0, 1.0) * 255.0 + 0.5);
    float level = float(code) / 255.0;
    Output = vec4(level, level, level, 1.0);
}
