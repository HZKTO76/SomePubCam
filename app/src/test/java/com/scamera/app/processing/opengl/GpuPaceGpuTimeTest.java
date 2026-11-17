package com.scamera.app.processing.opengl;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import org.junit.After;
import org.junit.Test;

import java.util.HashMap;
import java.util.Map;

/**
 * P724: the paced post's bands sized by the programs' GPU time (the timer queries' spans against the pixels each drew), not by
 * the waits - those also hold each submission's own cost (LG V50: tens of ms a band whatever its height), which narrowed the
 * bands and multiplied the submissions. Unmeasured programs keep the bands as asked; the photo is the same either way.
 */
public class GpuPaceGpuTimeTest {
    @After public void forget() { GpuPace.forgetBands(); }

    private static GpuPace.Pacer pacer(int minRows) {
        return new GpuPace.Pacer(new GpuPaceTest.FakeGpu(0L), 2, 10f, () -> false, minRows);
    }

    @Test public void gpuTimeOfARunSizesTheNextBandsUpToTheWideLimit() {
        GpuPace.forgetBands();
        final GpuPace.Pacer run = pacer(16);
        final long frame = 4032L * 3024;
        run.count("WhyStats/why/sharp_rl", "why/sharp_rl", 12 * frame);
        GpuPace.rememberRun(run);
        final Map<String, Long> spans = new HashMap<>();
        spans.put("WhyStats/why/sharp_rl", (long) (2.9 * 12 * frame)); // V50: 428 ms over 12 passes
        assertEquals(1, GpuPace.learnGpuTime(spans));
        assertEquals(2.9f, GpuPace.gpuNsPerPixel("why/sharp_rl"), 1e-4f);

        final GpuPace.Pacer next = pacer(128);
        assertEquals("10 ms of 2.9 ns/px at 4032 wide: 855 rows, down to a multiple of 16", 848,
                next.bandRows("why/sharp_rl", 4032, 256, GpuPace.WIDE_BAND_ROWS));
        assertEquals("never above the limit", 256, next.bandRows("why/sharp_rl", 4032, 256));
        assertEquals("an unmeasured program: as asked", 256, next.bandRows("why/lpyr", 4032, 256, GpuPace.WIDE_BAND_ROWS));
        assertEquals("400 wide: 8620 rows, the wide limit", GpuPace.WIDE_BAND_ROWS, next.bandRows("why/sharp_rl", 400, 256, GpuPace.WIDE_BAND_ROWS));
        assertEquals("never above the caller's limit", 1024, next.bandRows("why/sharp_rl", 4032 / 10, 256, 1024));
        next.close();
    }

    @Test public void slowProgramStillGetsTenMillisecondBandsAboveTheMinimum() {
        GpuPace.forgetBands();
        final Map<String, Float> seed = new HashMap<>();
        seed.put("why/combine", 20f);
        GpuPace.seed(seed);
        final GpuPace.Pacer p = pacer(128);
        assertEquals("1e7 / (20 x 4032) = 124 rows: the minimum", 128, p.bandRows("why/combine", 4032, 256, GpuPace.WIDE_BAND_ROWS));
        assertEquals("a region shorter than the minimum: as asked", 64, p.bandRows("why/combine", 4032, 64, 64));
        p.close();
    }

    @Test public void wallTimeBeyondTheSubmissionCostCapsAWideBand() {
        GpuPace.forgetBands();
        final Map<String, Float> seed = new HashMap<>();
        seed.put("why/sharp_rl", 0.1f); // the timer: 10 ms would be 24800 rows
        GpuPace.seed(seed);
        // the fake GPU: every band costs 30 ms of submission plus 30 ns a pixel the timer did not see
        final GpuPaceTest.FakeGpu gpu = new GpuPaceTest.FakeGpu(0L);
        final GpuPace.Pacer p = new GpuPace.Pacer(gpu, 1, 10f, () -> false, 16);
        assertEquals("unknown wall time: the wide limit", GpuPace.WIDE_BAND_ROWS, p.bandRows("why/sharp_rl", 4032, 256, GpuPace.WIDE_BAND_ROWS));
        // a tiny program's band: 30 ms, the submission's cost
        gpu.queueBlock(30_000_000L);
        p.submitted("scamhdr/tiny", 256L * 16);
        gpu.queueBlock(30_000_000L);
        p.submitted("scamhdr/tiny", 256L * 16);
        for (int i = 0; i < 3; i++) {
            final int rows = p.bandRows("why/sharp_rl", 4032, 256, GpuPace.WIDE_BAND_ROWS);
            gpu.queueBlock(30_000_000L + (long) (30.0 * 4032 * rows));
            p.submitted("why/sharp_rl", 4032L * rows);
        }
        p.finish();
        final int rows = p.bandRows("why/sharp_rl", 4032, 256, GpuPace.WIDE_BAND_ROWS);
        // 40 ms of 30 ns a pixel at 4032 wide: 330 rows -> 320
        assertEquals(320, rows);
        p.close();
    }

    @Test public void spansOfOtherProgramsOrMixedProgramsTeachNothing() {
        GpuPace.forgetBands();
        final GpuPace.Pacer run = pacer(16);
        final long frame = 4032L * 3024;
        // the combine drawn beside the final output's tiles (GLDeferredDraw): its time is the output span's
        run.count("final output/(node)", "why/combine", frame);
        run.count("WhyFusion/why/lpyr", "why/lpyr", frame);
        run.count("WhyFusion/why/lpyr", "why/other", frame);
        run.count("ScamRgb/scamhdr/clipband", "scamhdr/clipband", 1000);
        run.count(null, "why/sharp_rl", frame);
        GpuPace.rememberRun(run);
        final Map<String, Long> spans = new HashMap<>();
        spans.put("final output/(node)", 1_000_000_000L);
        spans.put("WhyFusion/why/lpyr", 10_000_000L);
        spans.put("ScamRgb/scamhdr/clipband", 10_000_000L);
        assertEquals(0, GpuPace.learnGpuTime(spans));
        assertNull(GpuPace.gpuNsPerPixel("why/combine"));
        assertNull(GpuPace.gpuNsPerPixel("why/lpyr"));
        assertNull(GpuPace.gpuNsPerPixel("scamhdr/clipband"));
        assertEquals("the run is used once", 0, GpuPace.learnGpuTime(spans));
    }

    @Test public void oneProgramInSeveralNodesIsSummed() {
        GpuPace.forgetBands();
        final GpuPace.Pacer run = pacer(16);
        run.count("WhyStats/why/low", "why/low", 2_000_000L);
        run.count("WhyCombine/why/low", "why/low", 2_000_000L);
        GpuPace.rememberRun(run);
        final Map<String, Long> spans = new HashMap<>();
        spans.put("WhyStats/why/low", 1_000_000L);
        spans.put("WhyCombine/why/low", 3_000_000L);
        assertEquals(1, GpuPace.learnGpuTime(spans));
        assertEquals(1f, GpuPace.gpuNsPerPixel("why/low"), 1e-6f);
    }
}
