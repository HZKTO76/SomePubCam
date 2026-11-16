package com.scamera.app.processing.opengl.postpipeline;

/** Runtime libraries shared with the APK packaging script. */
final class ScamRuntimeAssets {
    private ScamRuntimeAssets() {}
    /**
     * The SHDR merge job's runtime: the PD2454 CRE motion. P129: SCAM HDR's forward and tone networks (nice-main-forward,
     * nice-tone-*) are gone with SCAM HDR (still verified in the private bundle, tools/ci_neural_assets.py BUNDLE_ONLY).
     */
    static final String[][] SCAM_FILES = {
        // PD2454 CRE motion (same pinned file as /vendor) plus its runtime for non-scam
        // devices; the three vivo libraries it links are scam-cre-compat.cpp stubs.
        {"libvivo_nice_cre.so","41b277753f7fedbe4dda1e1c4b76d2086d6e79768904d8a4922b48a0e023e76e"},
        {"libc++_shared.so","f9992c4ba6b7c5a716e3a202fceb1ce029d6a2b0605838ac6b3219f489dd7970"},
        {"libvivolog.so","1dd79c9a92d3856fcf5e5f93ee532c98559ae82f6adff8f0810e20a04e3db704"},
        {"libvivo_platform_common.so","173945c6ebda5ff6cfea6e5b56c90818fd85cc531438d8304a4fb478e5c537b1"},
        {"libvivo.mempool.so","51e3029a6f32ca537033bb9f5ea4bdcbb3ba573626dd8ae830d2a0354ebe3d4c"}
    };
    /**
     * The QNN runtime the SHDR merge job links next to the CRE motion (shipped as native libraries). P175: the neural
     * remosaic's networks (the HexQuad and Quad 2x2 contexts, the tele576 set with its own QNN build) are gone (still verified
     * in the private bundle, tools/ci_neural_assets.py BUNDLE_ONLY).
     */
    static final String[][] HEX_FILES = {
        {"libQnnSystem.so","4250e5366a7f7b3c692a184649929e4d763a979c47691bfec49e8511af993842"},
        {"libQnnHtp.so","3c71c06536c7f42966aff0ed12cb40fe0ada57132ef2b4b4fa1e72d3aaa0be1d"},
        {"libQnnHtpV79Stub.so","2dfaabe735cdd3f6a23e9089d9b93c04cee2818e8168fdad7a864535ff620656"},
        {"libQnnHtpV79Skel.so","eaf6f153c814f1f4d544ae17b37ee25835f678ed4b81d43e30a25e65396c5a8d"}
    };
}
