package com.scamera.app.processing.opengl;

import com.scamera.app.util.Log;

import java.util.ArrayDeque;
import java.util.Locale;

/**
 * P616 (owner, 2026-11-11: «Ты не исправил тормоза видоискателя во время обработки»; vivo X200 Ultra, Adreno 830, build 31254:
 * one viewfinder draw of 240 - 339 ms in every post pipeline, each inside ScamHdrDenoise, the draw blocked in the RAW frame's
 * texture upload - VF_RAW «upload 10.2/296.0» against 4 - 5 ms otherwise). The post pipeline's thread queued its passes as fast as
 * the driver took them: 48 resolve blocks of ~10 ms GPU each, the node's own CPU time (360 - 490 ms) the GPU's, i.e. the thread
 * was held inside the driver (glFlush / glFinish / a synchronous read-back) for the whole node. The viewfinder's context in the
 * same process waited behind that queue (its high priority did not help: the post and the viewfinder share the process's driver).
 * <p>
 * This paces the post's submissions: after each block (a glFlush the passes already make) a fence goes in; while more than
 * {@link #inFlight} fences are pending the thread waits for the oldest by polling it (glClientWaitSync with a zero timeout and a
 * short sleep in between - no call that blocks inside the driver), so the GPU holds at most that many blocks of the post at any
 * time and the viewfinder's work is never more than that behind. A glFinish of the post (GLProg.computeManual) becomes the same
 * polled wait for a fence. The GPU runs the same commands in the same order: the output is bit for bit the same; the GPU keeps
 * one block queued while the thread waits for the one before, so it does not idle between blocks.
 * <p>
 * Active only on the post pipeline's thread between {@link #begin} and {@link #end} (GLBasePipeline.runNodes); by default on
 * Adreno only (the Mali logs of 31253 kept 27 - 31 fps with gaps of 62 - 102 ms through the post). scam_dev post_gpu_pace: 0 off,
 * N > 0 at most N blocks in flight on any GPU, absent: {@link #DEFAULT_IN_FLIGHT} on Adreno, off elsewhere.
 * <p>
 * P668 (owner, 2026-11-13: «видоискатель тормозит, оптимизируй под старые устройства»; Xiaomi 12X, Adreno 650, build 31266: «slow
 * draw 311 / 337 / 317 / 227 ms in node WhyCombine», the pace's longest wait 119 - 142 ms). Two blocks in flight bound the
 * viewfinder's wait by two blocks' GPU time, and a 256-row band of the tone's combine is ~80 - 140 ms on that GPU (~10 ms on the
 * Adreno 830 it was sized on). The pacer now measures each block it had to wait for (from the moment the block before it was
 * seen done, or its own submission if later: never more than its real GPU time) and remembers the GPU time per pixel of each
 * program; {@link GLProg#drawBlocks(int, int)} then draws that program's bands {@link #bandRows tall enough for} about
 * {@link #DEFAULT_BAND_MS} ms (multiples of 16 rows, at least 16, never above the 256 of before), from its next band and in every
 * later shot. A band is a viewport of the same full-screen draw: every pixel runs the same fragment shader on the same textures
 * and uniforms (gl_FragCoord is window-absolute; tools/check_post_bands.py), so the photo is bit for bit the same. Fast GPUs keep
 * their 256-row bands (measured, no device names); scam_dev post_band_ms (0: off). The final output's tiles are paced as well.
 */
public final class GpuPace {
    private static final String TAG = "SCAM_PIPELINE";
    /** Blocks of the post the GPU may hold: the one running and the next (no idle GPU between blocks). */
    public static final int DEFAULT_IN_FLIGHT = 2;
    /** A pending fence is polled this often (the sleep between two zero-timeout polls). */
    static final long POLL_NS = 250_000L;
    /** A fence not signalled after this long is given up (the GPU goes on; the thread no longer waits for it). */
    static final long GIVE_UP_NS = 3_000_000_000L;
    /** P668: the GPU time a band of a paced pass is sized to (scam_dev post_band_ms). */
    public static final float DEFAULT_BAND_MS = 10f;
    /** P668: band heights are multiples of this (2 x 2 pixel quads never straddle two bands' starts), and at least this. */
    static final int BAND_STEP = 16;
    private static final int LEGACY_ADRENO_MIN_BAND_ROWS = 128;
    /**
     * P724 (owner, 2026-11-17: «Оптимизируй нашу постобработку»; LG V50, Adreno 640, build 2ede4e2b: post 14.6 s of which the GPU
     * timer queries counted 2.6 s, 1079 bands, 337 waits of 13.5 s): a band is sized by the program's GPU time as the timer queries
     * measured it (GLGpuTimer, {@link #learnGpuTime}), up to this many rows. The wait of a band (P668) also holds the cost of the
     * submission itself - the same tens of ms for 16 rows as for 256 on that GPU - so it narrowed the bands and multiplied the
     * submissions. Bands are a viewport of the same draw: the photo is bit for bit the same (tools/check_post_bands.py). Every
     * submission also costs the CPU in the driver (vivo X200 Ultra, Adreno 830: post 1.0 s for 0.24 s of GPU and 0.23 s of waits,
     * ~600 bands): a fast GPU's 10 ms are most of a 50 MP frame's height.
     */
    public static final int WIDE_BAND_ROWS = 4096;
    /**
     * P724: a band sized by the GPU timer keeps its wall time (the wait for it, less the smallest wait of any band - the part every
     * submission costs whatever its size) under this many times the band time aimed at: the viewfinder never waits behind much more
     * than before should the timer miss part of the work.
     */
    static final int WALL_CEILING_BANDS = 4;
    /** P724: a program's GPU time is learnt from at least this many pixels and this much time. */
    static final long LEARN_MIN_PIXELS = 1L << 20, LEARN_MIN_NS = 200_000L;
    private static final java.util.regex.Pattern ADRENO_MODEL = java.util.regex.Pattern.compile("(?i)Adreno\\s*(?:\\(TM\\)\\s*)?(\\d{3})\\b");

    /** The GL side, a fake on the host. */
    public interface Gpu {
        /** A fence after the commands so far (and their flush); 0 when the driver gives none. */
        long fence();
        /** Whether the fence is signalled (a poll that does not wait); true for a fence the driver lost (nothing to wait for). */
        boolean signalled(long fence);
        void delete(long fence);
        /** The driver's own finish (the fall-back when no fence is made). */
        void finish();
        /** Sleeps between two polls. */
        void pause(long ns);
        long nanoTime();
    }

    /** P668: a submitted block - its fence, the program it drew (null: not a band of one) and its pixels, when it went. */
    private static final class Block {
        final long fence;
        final String pass;
        final long pixels;
        final long submittedNs;

        Block(long fence, String pass, long pixels, long submittedNs) {
            this.fence = fence;
            this.pass = pass;
            this.pixels = pixels;
            this.submittedNs = submittedNs;
        }
    }

    /** P668: GPU ns per pixel of each program's bands, as measured (process-wide: the next shot starts with them). */
    private static final java.util.concurrent.ConcurrentHashMap<String, Float> NS_PER_PIXEL = new java.util.concurrent.ConcurrentHashMap<>();
    /** P724: GPU ns per pixel of each program by the timer queries (or the first-run calibration); preferred to NS_PER_PIXEL. */
    private static final java.util.concurrent.ConcurrentHashMap<String, Float> GPU_NS_PER_PIXEL = new java.util.concurrent.ConcurrentHashMap<>();
    /** P724: the last waited band of each program: {wall ns, pixels}. */
    private static final java.util.concurrent.ConcurrentHashMap<String, long[]> LAST_WALL = new java.util.concurrent.ConcurrentHashMap<>();
    /** P724: the smallest wall time of any waited band (ns; Long.MAX_VALUE before any). */
    private static volatile long minWallNs = Long.MAX_VALUE;
    /** P724: the pixels each GPU timer span (GLGpuTimer's "node/program") drew in bands of the last run on this thread. */
    private static final ThreadLocal<java.util.Map<String, Drawn>> LAST_RUN = new ThreadLocal<>();
    /** P724: scam_dev post_scissor (default on): a band's draw is scissored to it (GLProg.band). */
    private static volatile boolean scissor = true;

    /** P724: what one timer span drew in bands: its program, pixels; null program when two programs shared the span. */
    static final class Drawn {
        String pass;
        long pixels;
        boolean mixed;
    }
    /** P668: the band sizing logged once per process (the first pass it narrowed). */
    private static final java.util.concurrent.atomic.AtomicBoolean BANDS_LOGGED = new java.util.concurrent.atomic.AtomicBoolean();
    private static volatile String renderer = "";

    /** One pacer (one thread's post run). */
    public static final class Pacer {
        final Gpu gpu;
        final int inFlight;
        /** P668: the GPU time a band is sized to (ns); 0: bands as the caller asks. */
        final long bandNs;
        private final int minBandRows;
        private final ArrayDeque<Block> pending = new ArrayDeque<>();
        long fences, waits, waitedNs, maxWaitNs, givenUp, finishes, finishNs;
        /** P668: when the last block was seen done (its fence signalled), 0 before any. */
        private long lastDoneNs;
        long measured;
        /** P668: the passes whose bands were narrowed this run: {smallest rows, bands, widest rows asked}. */
        private final java.util.LinkedHashMap<String, int[]> narrowed = new java.util.LinkedHashMap<>();
        /** P724: the bands by timer span (see {@link #LAST_RUN}). */
        final java.util.HashMap<String, Drawn> drawn = new java.util.HashMap<>();
        /** P724: bands sized by the GPU timer's time per pixel. */
        long gpuSized;
        /**
         * P685: true while the viewfinder is paused (VfDrawMeter.hidden: the gallery, the settings, the app left): nothing waits behind
         * the post then - its blocks go unpaced (no fence, no wait) and its bands at the height asked; pacing resumes with the next
         * block once the viewfinder draws again. The same commands in the same order: the photo is the same.
         */
        private final java.util.function.BooleanSupplier hidden;
        long unpaced;

        public Pacer(Gpu gpu, int inFlight) {
            this(gpu, inFlight, 0f);
        }

        public Pacer(Gpu gpu, int inFlight, float bandMs) {
            this(gpu, inFlight, bandMs, () -> false);
        }

        public Pacer(Gpu gpu, int inFlight, float bandMs, java.util.function.BooleanSupplier hidden) {
            this(gpu, inFlight, bandMs, hidden, BAND_STEP);
        }

        Pacer(Gpu gpu, int inFlight, float bandMs, java.util.function.BooleanSupplier hidden, int minBandRows) {
            this.gpu = gpu;
            this.inFlight = Math.max(1, inFlight);
            this.bandNs = bandMs > 0f ? (long) (bandMs * 1e6) : 0L;
            this.hidden = hidden != null ? hidden : () -> false;
            this.minBandRows = minBandRows;
        }

        /** A block was submitted: its fence, then the wait for the oldest beyond {@link #inFlight}. */
        public void submitted() {
            submitted(null, 0L);
        }

        /** P668: a band of {@code pixels} of the program {@code pass} was submitted (its GPU time is measured when waited for). */
        public boolean submitted(String pass, long pixels) {
            if (pass != null && pixels > 0) count(GLGpuTimer.currentKey(), pass, pixels);
            if (hidden.getAsBoolean()) { unpaced++; return false; }
            final long f = gpu.fence();
            if (f == 0) return true; // the commands are still flushed
            fences++;
            pending.addLast(new Block(f, pass, pixels, gpu.nanoTime()));
            while (pending.size() > inFlight) {
                final long t0 = gpu.nanoTime();
                final Block b = pending.pollFirst();
                final boolean waited = waitFor(b.fence);
                gpu.delete(b.fence);
                final long now = gpu.nanoTime();
                if (waited) {
                    final long ns = now - t0;
                    waits++;
                    waitedNs += ns;
                    maxWaitNs = Math.max(maxWaitNs, ns);
                    // P668: the block ran from when the one before it was seen done (or from its submission, if later) until now: a
                    // lower bound of its GPU time (the one before may have ended earlier than it was seen; this one is seen within a
                    // poll's POLL_NS), close when the thread waited for that one too. Only a block whose fence was not yet signalled
                    // tells anything.
                    if (b.pass != null && b.pixels > 0 && lastDoneNs > 0) {
                        final long ran = now - Math.max(lastDoneNs, b.submittedNs);
                        if (ran > 0) {
                            NS_PER_PIXEL.put(b.pass, (float) ran / b.pixels);
                            LAST_WALL.put(b.pass, new long[]{ran, b.pixels});
                            if (ran < minWallNs) minWallNs = ran;
                            measured++;
                        }
                    }
                }
                lastDoneNs = now;
            }
            return true;
        }

        /**
         * P668: the rows of the next band of {@code pass}, {@code width} wide: about {@link #bandNs} of GPU time by the pass's last
         * measured time per pixel, a multiple of {@link #BAND_STEP}, at least that, at most {@code maxRows} (as asked without a
         * measurement, without band sizing or when {@code maxRows} is below the step).
         */
        public int bandRows(String pass, int width, int maxRows) {
            return bandRows(pass, width, maxRows, maxRows);
        }

        /** P724: the rows of {@code pass} whose wall time beyond the smallest band's stays under the ceiling (infinite: unknown). */
        double wallCeilingRows(String pass, int width) {
            final long[] wall = LAST_WALL.get(pass);
            final long floor = minWallNs;
            if (wall == null || wall[1] <= 0 || floor == Long.MAX_VALUE) return Double.POSITIVE_INFINITY;
            final double nsPerPixel = (double) Math.max(0L, wall[0] - floor) / wall[1];
            return nsPerPixel > 0 ? WALL_CEILING_BANDS * (double) bandNs / (nsPerPixel * width) : Double.POSITIVE_INFINITY;
        }

        /** P724: the span drew {@code pixels} of {@code pass} (a null span: no timer run). */
        void count(String span, String pass, long pixels) {
            if (span == null) return;
            Drawn d = drawn.get(span);
            if (d == null) drawn.put(span, d = new Drawn());
            if (d.pass == null && !d.mixed) d.pass = pass;
            else if (d.pass != null && !d.pass.equals(pass)) { d.pass = null; d.mixed = true; }
            d.pixels += pixels;
        }

        /**
         * P724: {@link #bandRows(String, int, int)} with a program the GPU timer measured: about {@link #bandNs} of its GPU time, a
         * multiple of {@link #BAND_STEP}, between the minimum band and {@code limitRows} (which may be above {@code maxRows}, the
         * height of an unmeasured program's bands).
         */
        public int bandRows(String pass, int width, int maxRows, int limitRows) {
            if (bandNs <= 0 || pass == null || width <= 0 || hidden.getAsBoolean()) return maxRows;
            final Float gpuNs = GPU_NS_PER_PIXEL.get(pass);
            if (gpuNs != null && gpuNs > 0f && !gpuNs.isInfinite()) {
                final int limit = Math.max(maxRows, limitRows);
                if (limit <= minBandRows) return maxRows;
                final double rows = Math.min(bandNs / ((double) gpuNs * width), wallCeilingRows(pass, width));
                final int r = rows >= limit ? limit : Math.max(minBandRows, (int) rows / BAND_STEP * BAND_STEP);
                gpuSized++;
                if (r < maxRows) {
                    int[] n = narrowed.get(pass);
                    if (n == null) narrowed.put(pass, n = new int[]{r, 0, maxRows});
                    n[0] = Math.min(n[0], r);
                    n[1]++;
                }
                return r;
            }
            if (maxRows <= minBandRows) return maxRows;
            final Float nsPerPixel = NS_PER_PIXEL.get(pass);
            if (nsPerPixel == null || !(nsPerPixel > 0f)) return maxRows;
            final double rows = bandNs / ((double) nsPerPixel * width);
            if (rows >= maxRows) return maxRows;
            final int r = Math.max(minBandRows, (int) rows / BAND_STEP * BAND_STEP);
            int[] n = narrowed.get(pass);
            if (n == null) {
                narrowed.put(pass, n = new int[]{r, 0, maxRows});
                if (BANDS_LOGGED.compareAndSet(false, true))
                    Log.i(TAG, String.format(Locale.ROOT, "post GPU bands: %s draws a %d-row band of %s %d px wide in %.0f ms (over the %.0f ms"
                                    + " aimed at): the paced post's bands are sized to %.0f ms of this GPU from now on, %d rows here (the viewfinder"
                                    + " waits behind at most %d of them; scam_dev post_band_ms 0: 256-row bands)",
                            renderer, maxRows, pass, width, nsPerPixel * width * maxRows / 1e6, bandNs / 1e6, bandNs / 1e6, r, inFlight));
            }
            n[0] = Math.min(n[0], r);
            n[1]++;
            return r;
        }

        /** Everything submitted so far is done (a glFinish's meaning) by polling a fence; the driver's finish without one. */
        public void finish() {
            final long t0 = gpu.nanoTime();
            final long f = gpu.fence();
            if (f == 0) {
                gpu.finish();
            } else {
                final long before = givenUp;
                waitFor(f);
                gpu.delete(f);
                if (givenUp != before) gpu.finish(); // a fence given up: the driver's finish, a finish stays a finish
            }
            while (!pending.isEmpty()) gpu.delete(pending.pollFirst().fence); // all older than the finish: done
            finishes++;
            final long now = gpu.nanoTime();
            finishNs += now - t0;
            lastDoneNs = now; // P668: the GPU is idle from here
        }

        /** The pending fences dropped (the run ends; their commands are queued and finish on their own). */
        void close() {
            while (!pending.isEmpty()) gpu.delete(pending.pollFirst().fence);
        }

        int pendingCount() {
            return pending.size();
        }

        /** True when the fence was not signalled at the first poll (the thread waited). */
        private boolean waitFor(long f) {
            if (gpu.signalled(f)) return false;
            final long start = gpu.nanoTime();
            while (!gpu.signalled(f)) {
                if (gpu.nanoTime() - start > GIVE_UP_NS) {
                    givenUp++;
                    break;
                }
                gpu.pause(POLL_NS);
            }
            return true;
        }

        String summary() {
            final StringBuilder bands = new StringBuilder();
            if (bandNs > 0) {
                final long floor = minWallNs;
                bands.append(String.format(Locale.ROOT, "; bands of %.0f ms (%d measured, %d sized by the GPU timer up to %d rows, the"
                                + " shortest band's wait %s)", bandNs / 1e6, measured, gpuSized, WIDE_BAND_ROWS,
                        floor == Long.MAX_VALUE ? "none" : String.format(Locale.ROOT, "%.1f ms", floor / 1e6)));
                bands.append(scissor ? ", scissored" : ", not scissored");
                if (minBandRows > BAND_STEP) bands.append(", minimum ").append(minBandRows).append(" rows");
                if (narrowed.isEmpty()) bands.append(": none narrowed");
                else {
                    bands.append(", narrowed:");
                    for (java.util.Map.Entry<String, int[]> e : narrowed.entrySet())
                        bands.append(' ').append(e.getKey()).append(' ').append(e.getValue()[2]).append("->").append(e.getValue()[0])
                                .append(" rows x").append(e.getValue()[1]);
                }
            }
            return String.format(Locale.ROOT, "post GPU pace: at most %d blocks in flight, %d fences, %d waits %.0f ms (max %.1f), %d finishes polled %.0f ms%s%s%s",
                    inFlight, fences, waits, waitedNs / 1e6, maxWaitNs / 1e6, finishes, finishNs / 1e6,
                    givenUp > 0 ? ", " + givenUp + " fences given up after " + GIVE_UP_NS / 1_000_000 + " ms" : "",
                    unpaced > 0 ? ", " + unpaced + " blocks unpaced (the viewfinder paused, P685)" : "", bands);
        }
    }

    private static final ThreadLocal<Pacer> CURRENT = new ThreadLocal<>();
    private static final ThreadLocal<Boolean> REPLAY = new ThreadLocal<>();

    private GpuPace() {}

    /** Exercise the capture queue policy in the laboratory, where the viewfinder is hidden. */
    public static void replayPacing(boolean enabled) {
        if (enabled) REPLAY.set(true);
        else REPLAY.remove();
    }

    /**
     * The blocks in flight for the scam_dev value {@code setting} (NaN: absent) on a GPU named {@code renderer}: 0 = no pacing.
     */
    public static int inFlightFor(float setting, String renderer) {
        if (!Float.isNaN(setting)) return setting >= 1f ? Math.min(64, Math.round(setting)) : 0;
        return renderer != null && renderer.toLowerCase(Locale.ROOT).contains("adreno") ? DEFAULT_IN_FLIGHT : 0;
    }

    /** P668: the band time (ms) for the scam_dev value {@code setting} (NaN: absent): 0 = bands as asked. */
    public static float bandMsFor(float setting) {
        if (Float.isNaN(setting)) return DEFAULT_BAND_MS;
        return setting > 0f ? Math.min(1000f, Math.max(1f, setting)) : 0f;
    }

    static int minBandRowsFor(String gpu, float bandSetting) {
        if (!Float.isNaN(bandSetting) || gpu == null) return BAND_STEP;
        final java.util.regex.Matcher model = ADRENO_MODEL.matcher(gpu);
        // Older Adreno drivers can spend tens of milliseconds per submitted band even after shrinking it to 16 rows.
        return model.find() && Integer.parseInt(model.group(1)) <= 640 ? LEGACY_ADRENO_MIN_BAND_ROWS : BAND_STEP;
    }

    /** P683: the first-run calibration's profile (GpuProfile) seeded into this process once. */
    private static final java.util.concurrent.atomic.AtomicBoolean SEEDED = new java.util.concurrent.atomic.AtomicBoolean();

    /**
     * P683: the GPU ns per pixel of programs measured by the first-run calibration (GpuProfile) as the starting values of the band
     * sizing - a program the post measured itself keeps its own value; the viewfinder's keys ("vf:") are not the post's.
     * Returns how many were taken.
     */
    static int seed(java.util.Map<String, Float> nsPerPixel) {
        int n = 0;
        if (nsPerPixel == null) return 0;
        for (java.util.Map.Entry<String, Float> e : nsPerPixel.entrySet()) {
            final Float v = e.getValue();
            if (e.getKey() == null || e.getKey().startsWith("vf:") || v == null || !(v > 0f) || Float.isInfinite(v)) continue;
            GPU_NS_PER_PIXEL.putIfAbsent(e.getKey(), v); // P724: the calibration's time is the GPU timer's
            if (NS_PER_PIXEL.putIfAbsent(e.getKey(), v) == null) n++;
        }
        return n;
    }

    /** P668: the last measured GPU ns per pixel of {@code pass}, or null (tests). */
    static Float measuredNsPerPixel(String pass) {
        return pass == null ? null : NS_PER_PIXEL.get(pass);
    }

    /** P724: the GPU timer's ns per pixel of {@code pass}, or null (tests). */
    static Float gpuNsPerPixel(String pass) {
        return pass == null ? null : GPU_NS_PER_PIXEL.get(pass);
    }

    /**
     * P724: the GPU time of the last run's timer spans ("node/program" -> ns, GLGpuTimer.report) against the pixels each drew in
     * bands: the ns per pixel of every program whose spans drew only its own bands (at least {@link #LEARN_MIN_PIXELS} and
     * {@link #LEARN_MIN_NS}), for the band sizing from the next band on. A span's time also holds what it issued besides the
     * bands (uploads, read-backs, other draws): an upper bound, never a narrower band than its real time. Returns how many.
     */
    static int learnGpuTime(java.util.Map<String, Long> spanNs) {
        final java.util.Map<String, Drawn> drawn = LAST_RUN.get();
        LAST_RUN.remove();
        if (drawn == null || spanNs == null) return 0;
        final java.util.HashMap<String, long[]> byPass = new java.util.HashMap<>();
        for (java.util.Map.Entry<String, Drawn> e : drawn.entrySet()) {
            final Drawn d = e.getValue();
            final Long ns = spanNs.get(e.getKey());
            if (d.pass == null || ns == null || !e.getKey().endsWith("/" + d.pass)) continue;
            final long[] sum = byPass.computeIfAbsent(d.pass, k -> new long[2]);
            sum[0] += ns;
            sum[1] += d.pixels;
        }
        int n = 0;
        for (java.util.Map.Entry<String, long[]> e : byPass.entrySet()) {
            final long[] sum = e.getValue();
            if (sum[1] < LEARN_MIN_PIXELS || sum[0] < LEARN_MIN_NS) continue;
            GPU_NS_PER_PIXEL.put(e.getKey(), (float) ((double) sum[0] / sum[1]));
            n++;
        }
        return n;
    }

    /** P724: what the run's bands drew by timer span, for {@link #learnGpuTime} after the timer's report. */
    static void rememberRun(Pacer p) {
        if (p == null || p.drawn.isEmpty()) LAST_RUN.remove();
        else LAST_RUN.set(new java.util.HashMap<>(p.drawn));
    }

    /** P724: a run's spans dropped without timer results (the timer off or disjoint). */
    static void forgetRun() {
        LAST_RUN.remove();
    }

    /** P724: whether bands are scissored (GLProg.band). */
    public static boolean scissor() {
        return scissor;
    }

    /** P668: the measurements forgotten (tests). */
    static void forgetBands() {
        NS_PER_PIXEL.clear();
        GPU_NS_PER_PIXEL.clear();
        LAST_WALL.clear();
        minWallNs = Long.MAX_VALUE;
        LAST_RUN.remove();
        SEEDED.set(false);
        BANDS_LOGGED.set(false);
    }

    /** The post run on this thread starts (its context current): pacing on as the setting and the GPU say. */
    public static void begin() {
        final Pacer old = CURRENT.get();
        if (old != null) old.close();
        CURRENT.remove();
        int n;
        float bandMs;
        int minBandRows = BAND_STEP;
        try {
            final String gpu = android.opengl.GLES20.glGetString(android.opengl.GLES20.GL_RENDERER);
            renderer = gpu != null ? gpu : "";
            n = inFlightFor(com.scamera.app.settings.PreferenceKeys.scamDevNumber("post_gpu_pace", Float.NaN), gpu);
            final float bandSetting = com.scamera.app.settings.PreferenceKeys.scamDevNumber("post_band_ms", Float.NaN);
            bandMs = bandMsFor(bandSetting);
            minBandRows = minBandRowsFor(gpu, bandSetting);
            scissor = com.scamera.app.settings.PreferenceKeys.scamDevSwitch("post_scissor", true);
        } catch (RuntimeException | LinkageError e) {
            n = 0;
            bandMs = 0f;
        }
        if (n > 0) CURRENT.set(new Pacer(GL, n, bandMs, Boolean.TRUE.equals(REPLAY.get()) ? () -> false
                : com.scamera.app.ui.camera.views.viewfinder.VfDrawMeter::hiddenNow, minBandRows));
        // P683: the first shot of a process starts from the first-run calibration's ns per pixel (GpuProfile), not from 256 rows
        if (n > 0 && bandMs > 0f && SEEDED.compareAndSet(false, true)) {
            try {
                final int seeded = seed(GpuProfile.current());
                if (seeded > 0) Log.i(TAG, "post GPU bands: " + seeded + " programs start from the first-run GPU calibration " + GpuProfile.current());
            } catch (RuntimeException | LinkageError ignored) {
            }
        }
    }

    /** The post run on this thread ends: the pace's line, pacing off. */
    public static void end() {
        final Pacer p = CURRENT.get();
        CURRENT.remove();
        if (p == null) return;
        p.close();
        rememberRun(p);
        Log.i(TAG, p.summary());
    }

    /** Submits a block without a timing sample. */
    public static void flushBlock() {
        flushBlock(null, 0L);
    }

    /** Submits a band with one flush, placing its fence first when pacing is active. */
    public static void flushBlock(String pass, long pixels) {
        final Pacer p = CURRENT.get();
        if (p == null || !p.submitted(pass, pixels)) android.opengl.GLES30.glFlush();
    }

    /** P668: the next band's rows for the program {@code pass} {@code width} wide - {@code maxRows} unless paced and measured slow. */
    public static int bandRows(String pass, int width, int maxRows) {
        final Pacer p = CURRENT.get();
        return p != null ? p.bandRows(pass, width, maxRows) : maxRows;
    }

    /** P724: {@link #bandRows(String, int, int)}, a program the GPU timer measured up to {@code limitRows}. */
    public static int bandRows(String pass, int width, int maxRows, int limitRows) {
        final Pacer p = CURRENT.get();
        return p != null ? p.bandRows(pass, width, maxRows, limitRows) : maxRows;
    }

    /** A block of a pass drawn without a flush of its own (a pass's row loop): flushed and paced while pacing is on, else nothing. */
    public static void block() {
        final Pacer p = CURRENT.get();
        if (p != null && !p.submitted(null, 0L)) android.opengl.GLES30.glFlush();
    }

    /**
     * P724: a band of {@code pixels} of {@code pass} drawn without a flush of its own: flushed, paced and counted for the band sizing
     * while pacing is on, else nothing (as {@link #block()}).
     */
    public static void block(String pass, long pixels) {
        final Pacer p = CURRENT.get();
        if (p != null && !p.submitted(pass, pixels)) android.opengl.GLES30.glFlush();
    }

    /** glFinish of the post: a polled fence while pacing is on, else glFinish. */
    public static void finish() {
        final Pacer p = CURRENT.get();
        if (p != null) p.finish();
        else android.opengl.GLES30.glFinish();
    }

    public static boolean active() {
        return CURRENT.get() != null;
    }

    private static final Gpu GL = new Gpu() {
        @Override
        public long fence() {
            final long f = android.opengl.GLES30.glFenceSync(android.opengl.GLES30.GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
            android.opengl.GLES30.glFlush();
            return f;
        }

        @Override
        public boolean signalled(long fence) {
            final int r = android.opengl.GLES30.glClientWaitSync(fence, 0, 0L);
            return r != android.opengl.GLES30.GL_TIMEOUT_EXPIRED; // ALREADY_SIGNALED / CONDITION_SATISFIED; WAIT_FAILED: no wait
        }

        @Override
        public void delete(long fence) {
            android.opengl.GLES30.glDeleteSync(fence);
        }

        @Override
        public void finish() {
            android.opengl.GLES30.glFinish();
        }

        @Override
        public void pause(long ns) {
            java.util.concurrent.locks.LockSupport.parkNanos(ns);
        }

        @Override
        public long nanoTime() {
            return System.nanoTime();
        }
    };
}
