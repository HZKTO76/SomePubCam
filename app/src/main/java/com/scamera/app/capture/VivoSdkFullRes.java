package com.scamera.app.capture;

import android.util.Size;

import androidx.annotation.Nullable;

import com.scamera.app.app.ScameraApp;
import com.scamera.app.capture.spoof.CameraPackageSpoof;
import com.scamera.app.settings.PreferenceKeys;

public final class VivoSdkFullRes {
    private VivoSdkFullRes() { }

    public static final class Profile {
        public final Size size;
        public final int sensorMode;
        public final int nativeBlock;
        /**
         * P208 (X100 / X300 Ultra 200 MP, the stock camera's session of 2026-10-17): the viewfinder is the camera's own RAW stream in
         * its normal mode (no forceSensorMode), the full-size RAW stream only takes the stills, the HAL switches the sensor for them.
         */
        public final boolean stillOnly;
        /**
         * P609 (owner, 2026-11-10: «Оба пути»): the session runs this 200 MP Tetra row (16320x12288, block 4) but the shot is its
         * 50 MP: every still is binned 2x2 inside each 4x4 Tetra colour cell when it is copied (processing/TetraBin) into an
         * 8160x6144 Quad (block 2), the sensor's own Quad at 50 MP; the OnePlus 16 main when its 50 MP rows all failed.
         */
        public final boolean tetraBin;

        private Profile(int width, int height, int sensorMode) {
            this(width, height, sensorMode, 0);
        }

        Profile(int width, int height, int sensorMode, int nativeBlock) {
            this(width, height, sensorMode, nativeBlock, false);
        }

        Profile(int width, int height, int sensorMode, int nativeBlock, boolean stillOnly) {
            this(width, height, sensorMode, nativeBlock, stillOnly, false);
        }

        /** P609: {@code tetraBin} only on a 4x4 row ({@code nativeBlock} 4). */
        Profile(int width, int height, int sensorMode, int nativeBlock, boolean stillOnly, boolean tetraBin) {
            size = new Size(width, height);
            this.sensorMode = sensorMode;
            this.nativeBlock = nativeBlock;
            this.stillOnly = stillOnly && nativeBlock > 0;
            this.tetraBin = tetraBin && nativeBlock == 4;
        }

        /** P609: the colour block the shot merges with (the binned Tetra row's Quad 2, else the row's own block). */
        public int mergeBlock() {
            return tetraBin ? 2 : nativeBlock;
        }

        /** P609: the size of the shot's frames (the binned Tetra row's half sides, whole 8x8 periods; else the row's size). */
        public Size shotSize() {
            if (!tetraBin) return size;
            final int[] out = com.scamera.app.processing.TetraBin.outSize(size.getWidth(), size.getHeight());
            return new Size(out[0], out[1]);
        }

        /**
         * The native route (RAW-only session, forceSensorMode / the OPPO mode, the own RAW viewfinder): a Quad / Tetra mosaic
         * (nativeBlock 2 / 4) or P194's hardware-remosaicked plain Bayer (nativeBlock 1); 0 is the X200 Ultra's SDK route.
         */
        public boolean nativeRoute() {
            return nativeBlock > 0;
        }

        /** P194: the native route's plain Bayer row of the X100 / X300 Ultra's hardware remosaic. */
        public boolean nativeBayer() {
            return nativeBlock == 1;
        }
    }

    public static Profile profile(String cameraId) {
        return profile(cameraId, PixelPro10.tele200());
    }

    /** P181: the camera's profile at the given size of a camera with two (200 MP and 50 MP); others have one size. */
    public static Profile profile(String cameraId, boolean tele200) {
        // P192: the sensor's own mosaic; P586: the size asked on a camera with two (the OnePlus 16 main: 50 MP row 9, 200 MP row 24)
        if (OppoNativeFullRes.device()) return OppoNativeFullRes.profile(cameraId, tele200);
        final boolean nativeBuild = nativeRaw();
        return choose(cameraId, nativeBuild, nativeBuild && hardwareRemosaicOn(), tele200);
    }

    /**
     * The FULLRES profile of a camera: the default package's SDK route (the sensor's hardware remosaic, plain Bayer); the
     * native build's own mosaic (Quad / Tetra, the own remosaic), or P182 (owner, 2026-10-17: «дай возможность для fullres
     * включать аппаратный ремозаик») with «Аппаратный ремозаик» on its 50 MP shots by the SDK route's hardware-remosaic modes -
     * there is no hardware-remosaic 200 MP mode, a 200 MP shot keeps the own remosaic.
     */
    static Profile choose(String cameraId, boolean nativeBuild, boolean hardwareRemosaic, boolean tele200) {
        return choose(VivoNativeFullRes.phone(), cameraId, nativeBuild, hardwareRemosaic, tele200);
    }

    /**
     * {@link #choose} on a given phone (null: not one of the native tables, as the X200 Ultra). P194 (owner, 2026-10-17: the
     * hardware remosaic on the X100 / X300 Ultra too): they have no verified SDK mode, so their 50 MP hardware remosaic is the
     * native route with the row their HAL gives remosaicked (VivoNativeFullRes.hardwareProfile, plain Bayer); a camera without
     * such a row keeps its own mosaic whatever the switch.
     */
    static Profile choose(@Nullable VivoNativeFullRes.Phone phone, String cameraId, boolean nativeBuild, boolean hardwareRemosaic,
                          boolean tele200) {
        if (!nativeBuild) return sdkProfile(cameraId);
        if (phone == VivoNativeFullRes.Phone.X100_ULTRA || phone == VivoNativeFullRes.Phone.X300_ULTRA) {
            final boolean large = tele200 && VivoNativeFullRes.twoSizes(phone, cameraId, true);
            final Profile hardware = hardwareRemosaic && !large ? VivoNativeFullRes.hardwareProfile(phone, cameraId, true) : null;
            return hardware != null ? hardware : VivoNativeFullRes.profile(phone, cameraId, tele200);
        }
        final boolean large = tele200 && VivoNativeFullRes.twoSizes(cameraId);
        final Profile hardware = sdkProfile(cameraId);
        if (hardwareRemosaic && !large && hardware != null) return hardware;
        return VivoNativeFullRes.profile(cameraId, tele200);
    }

    /** The X200 Ultra's hardware-remosaic FULLRES modes (P109m / P109p, the SDK route): DNGHWREMOSAIC Bayer at 50 MP. */
    static Profile sdkProfile(String cameraId) {
        if ("3".equals(cameraId)) return new Profile(8192, 6144, 13);
        if ("4".equals(cameraId)) return new Profile(8192, 6144, 11);
        if ("5".equals(cameraId)) return new Profile(8160, 6144, 18);
        return null;
    }

    /** P182: the setting «Аппаратный ремозаик» (FULLRES 50 MP by the sensor's hardware remosaic). */
    public static final String PREF_HW_REMOSAIC = "pref_fullres_hw_remosaic";

    /**
     * P182: the switch acts here: the native build on the X200 Ultra, whose hardware-remosaic modes are known; P194 the X100 /
     * X300 Ultra's native build too (the main camera's 50 MP, VivoNativeFullRes.hardwareRow). Never the OPPO Find X7 Ultra.
     */
    public static boolean hardwareRemosaicOffered() {
        return !OppoNativeFullRes.device() && nativeRaw();
    }

    static boolean hardwareRemosaicOn() {
        return !OppoNativeFullRes.device() && VivoNativeFullRes.phone() != null && PreferenceKeys.isFullResHwRemosaic();
    }

    /**
     * The native FULLRES build (its own package; the default package takes the SDK profiles): the X200 Ultra, P180 the X100 /
     * X300 Ultra unless their switch turns them off (VivoNativeFullRes).
     */
    static boolean nativeRaw() {
        android.content.Context context = ScameraApp.getAppContext();
        return context != null && VivoNativeFullRes.device() && VivoPd2454NativeRaw.nativePackage(context.getPackageName());
    }

    /** The phone's native profile of a camera (P180: VivoNativeFullRes' table; the X200 Ultra's anywhere else). */
    static Profile nativeProfile(String cameraId) {
        return VivoNativeFullRes.profile(cameraId, PixelPro10.tele200());
    }

    /** P179: the telephoto's two native sizes - 200 MP (mode 0, Tetra 16320x12288) and 50 MP (mode 1, Quad 8160x6144). */
    static final Profile TELE_200 = new Profile(16320, 12288, 0, 4), TELE_50 = new Profile(8160, 6144, 1, 2);

    /**
     * P179: the camera offers both sizes (the X200 Ultra's telephoto, native build): a FULLRES button for each; P180 the X100
     * Ultra's telephoto, the X300 Ultra's main camera and telephoto too.
     */
    public static boolean teleSizes(String cameraId) {
        if (OppoNativeFullRes.device()) return OppoNativeFullRes.twoSizes(cameraId); // P586: the OnePlus 16 main's 50 / 200 MP
        return nativeRaw() && VivoNativeFullRes.twoSizes(cameraId);
    }

    static int frameCount(int requested, long frameBytes, long availableBytes) {
        if (frameBytes <= 0) throw new IllegalArgumentException("Invalid FULLRES frame size");
        int count = Math.max(1, Math.min(65, requested)); // P578: «Кадры FULLRES 50» up to 65
        // Retained RAWs must leave room for the camera, frame copies and subsequent processing.
        return availableBytes >= 0 ? (int) Math.min(count, availableBytes / 2 / frameBytes) : count;
    }

    /**
     * P190: frames of an explicit FULLRES series (pref_scam_hybrid_fullres50_frames / fullres200_frames) the merge can hold beside
     * {@code availableBytes}: the worker's fixed part ({@code huge}: 20 B, else 40 B per output pixel, scam-hybrid.h), the copied-out
     * reference RAW, then per frame its RAW, its binned copy (2 B / block^2 per pixel) and the GPU strip windows (3.8 KB per
     * column). A 200 MP merge runs with the camera closed: the HAL's four RAW buffers count as free. 0 when nothing fits.
     */
    static int seriesFit(long pixels, int width, long frameBytes, int block, int grid, boolean huge, long availableBytes) {
        return seriesFit(pixels, width, frameBytes, block, grid, huge, availableBytes, huge ? 4L * frameBytes : 0);
    }

    /**
     * {@link #seriesFit} with the HAL's buffers that go back for the merge given ({@code halFreeBytes}; P609: a 50 MP shot binned
     * from the 200 MP row merges with the camera closed as a 200 MP shot: its four 16320x12288 buffers, 4 x 401 MB, count as free).
     */
    static int seriesFit(long pixels, int width, long frameBytes, int block, int grid, boolean huge, long availableBytes, long halFreeBytes) {
        final double reserve = (huge ? 20.0 : 40.0) * pixels * grid * grid + frameBytes;
        final double perFrame = frameBytes + 2.0 * pixels / ((double) block * block) + 3800.0 * width;
        return fitSeries(availableBytes, halFreeBytes, reserve, perFrame);
    }

    /**
     * P190: frames of a FULLRES series: {@link #frameCount}'s RAW guard, at least the legacy count (200 MP: 4, as before P190; 50 MP:
     * 2, the merge's minimum), beyond it as many as {@link #seriesFit} gives. Up to 4 frames at 200 MP exactly the P179 count.
     */
    static int seriesCount(int requested, long pixels, int width, long frameBytes, int block, int grid, boolean huge, long availableBytes) {
        return seriesCount(requested, pixels, width, frameBytes, block, grid, huge, availableBytes, huge ? 4L * frameBytes : 0);
    }

    /** P609: {@link #seriesCount} with the HAL's buffers freed for the merge given ({@link #seriesFit}'s {@code halFreeBytes}). */
    static int seriesCount(int requested, long pixels, int width, long frameBytes, int block, int grid, boolean huge, long availableBytes,
                           long halFreeBytes) {
        return seriesCount(requested, pixels, width, frameBytes, block, grid, huge, availableBytes, halFreeBytes, false);
    }

    /**
     * P721: {@link #seriesCount} for the merge route of the shot: {@code fast} («Быстрый») sizes the series by
     * {@link #fastSeriesFit} - the fast route merges in row bands that fit its share of MemAvailable and reads every frame in place
     * (P685), so it needs no fixed 40 B per output pixel beside the frames ({@link #seriesFit} is the SCAM merge's, «Качество»).
     */
    static int seriesCount(int requested, long pixels, int width, long frameBytes, int block, int grid, boolean huge, long availableBytes,
                           long halFreeBytes, boolean fast) {
        return seriesCount(requested, pixels, width, frameBytes, block, grid, pixels * grid * grid,
                huge, availableBytes, halFreeBytes, fast);
    }

    static int seriesCount(int requested, long pixels, int width, long frameBytes, int block, int grid,
                           long outputPixels, boolean huge, long availableBytes, long halFreeBytes, boolean fast) {
        final int guard = frameCount(requested, frameBytes, availableBytes);
        final int legacy = Math.min(huge ? 4 : 2, guard);
        final int fit = fast ? fastSeriesFit(outputPixels, frameBytes, availableBytes, halFreeBytes)
                : block == 2 || block == 4
                        ? mosaicSeriesFit(pixels, width, frameBytes, block, grid, huge, availableBytes, halFreeBytes)
                        : seriesFit(pixels, width, frameBytes, block, grid, huge, availableBytes, halFreeBytes);
        return Math.min(guard, Math.max(legacy, fit));
    }

    // The Quality mosaic merge maps the shot arena, makes a binned copy of each selected frame and uses GPU strips.
    // Its worker reserves 20 B per pixel inside 80% of the remaining memory (hybridMosaicNativeBudget).
    private static int mosaicSeriesFit(long pixels, int width, long frameBytes, int block, int grid, boolean huge,
                                       long availableBytes, long halFreeBytes) {
        // Keep the 200 MP strip-merge reserve. Below it, allow for the native mosaic worker's memory share.
        final double reserve = (huge ? 20.0 : 20.0 / 0.8) * pixels * grid * grid + frameBytes;
        final double perFrame = frameBytes + 2.0 * pixels / (block * block) + 3800.0 * width;
        return fitSeries(availableBytes, halFreeBytes, reserve, perFrame);
    }

    private static int fitSeries(long availableBytes, long halFreeBytes, double reserve, double perFrame) {
        if (availableBytes < 0) return 65;
        final double free = availableBytes + Math.max(0, halFreeBytes) - reserve;
        return (int) Math.max(0, Math.min(65, Math.floor(free / perFrame)));
    }

    /**
     * P721 (X300 Ultra log 2026-11-15, 8160x6128 Quad: «7 N asked, 4 by the memory», «1 of 4 ring frames + 0 N after the shutter
     * (asked 7, budget 4 frames)» at 2228 - 2739 MB available; the worker then merged those 1 - 4 frames in 4 - 5 row bands of
     * ~1044 - 1430 MB + ~405 - 691 MB of outputs within 60 % of MemAvailable): the frames the fast route holds - every frame's RAW
     * (its memfd, read in place by every band) above {@link #FAST_MERGE_BYTES_PER_PX} per output pixel for the smallest row band and
     * the frame's outputs. A frame the bands still cannot hold is left out by the worker itself (short frames first, P685 / P699).
     */
    static int fastSeriesFit(long outputPixels, long frameBytes, long availableBytes, long halFreeBytes) {
        return fitSeries(availableBytes, halFreeBytes, FAST_MERGE_BYTES_PER_PX * outputPixels, frameBytes);
    }

    /** P721: the fast route's smallest row band plus the frame's outputs per output pixel (~1.45 GB at 50 MP in the log above). */
    static final double FAST_MERGE_BYTES_PER_PX = 22.0;

    public static boolean available(String cameraId) {
        // P593: the size asked must have a row itself (an OPPO-family camera with two sizes: a dead «50 Мп» is no 200 MP session)
        return offered(cameraId) && profile(cameraId) != null && !SensorModeSwitches.sensorPreset(
                com.scamera.app.settings.ModuleRegistry.active()) && !Dcg14Mode.on();
    }

    public static boolean offered(String cameraId) {
        // P192: the OPPO Find X7 Ultra's native modes, its telephotos listed through the Oplus package (OppoNativeFullRes); P214j:
        // OnePlus and realme by what their cameras list (OppoNativeFullRes.candidates)
        // P593: offered while any of its sizes has a row (the sheet keeps «200 Мп» beside a dimmed «50 Мп»); the session itself
        // needs the asked size's row (available)
        if (OppoNativeFullRes.device()) return profile(cameraId) != null || OppoNativeFullRes.anyLive(cameraId);
        // P180: the X100 / X300 Ultra only by the native route (the CTS package; their switch not off)
        return (VivoQcomModes.device() || nativeRaw()) && profile(cameraId) != null
                && "off".equals(CameraPackageSpoof.signature(ScameraApp.getAppContext()))
                && PreferenceKeys.scamDevSwitch("vivo_sdk_fullres", true);
    }

    /**
     * P214h (speed-ux C2; P210: «all own rows fail, the size goes off, the button hides»): the camera would offer FULLRES - the
     * conditions of {@link #offered} but its profile - yet every row it tried failed (VivoNativeFullRes / OppoNativeFullRes
     * trials). Its button stays, dimmed; a tap says why (FullResTrials.status) and offers «Попробовать снова».
     */
    public static boolean exhausted(String cameraId) {
        if (cameraId == null || offered(cameraId)) return false;
        if (OppoNativeFullRes.device()) return OppoNativeFullRes.exhausted(cameraId);
        return nativeRaw() && VivoNativeFullRes.hasTable(VivoNativeFullRes.phone(), cameraId)
                && "off".equals(CameraPackageSpoof.signature(ScameraApp.getAppContext()))
                && PreferenceKeys.scamDevSwitch("vivo_sdk_fullres", true);
    }

    /**
     * P593: a «50 Мп» of this camera whose rows all failed stays off - it does not turn into 200 MP by itself (the OPPO family;
     * the vivo phones' sizes give way to each other, P186).
     */
    public static boolean fiftyStaysFifty(String cameraId) {
        return OppoNativeFullRes.device() && OppoNativeFullRes.twoSizes(cameraId);
    }

    /** P214h: that size ({@code large}: 200 MP) of a camera with two buttons has no row left (dimmed). */
    public static boolean sizeExhausted(String cameraId, boolean large) {
        if (OppoNativeFullRes.device()) return OppoNativeFullRes.sizeExhausted(cameraId, large); // P586
        return nativeRaw() && !OppoNativeFullRes.device()
                && VivoNativeFullRes.sizeExhausted(VivoNativeFullRes.phone(), cameraId, large, hardwareRemosaicOn());
    }

    /**
     * P192: the running FULLRES is the OPPO route's (no SDK lease, the own AE and white balance); P214j: on any phone of its family
     * (OPPO, OnePlus, realme - OppoNativeFullRes.family).
     */
    static boolean oppo() {
        return OppoNativeFullRes.device();
    }
}
