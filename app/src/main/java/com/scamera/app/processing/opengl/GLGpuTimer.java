package com.scamera.app.processing.opengl;

import android.opengl.GLES30;

import com.scamera.app.settings.PreferenceKeys;
import com.scamera.app.util.Log;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

/**
 * P479 (speed, profiling only): the GPU time of every program switch of the post pipeline, by GL_EXT_disjoint_timer_query
 * (GL_TIME_ELAPSED_EXT): one query from each
 * {@link #mark} to the next (a program's draws or dispatches, the uploads and read-backs issued before the next program), the
 * results read once at the end of the run and logged as one SCAM_PIPELINE line per node / program, slowest first. It only
 * measures: no draw, no texture and no uniform changes, so the pixels are those of a run without it. Off: every call returns at
 * once.
 * <p>
 * P671 (owner, 2026-11-13: speed on older GPUs, «замерь каждый проход»): on by default on Adreno (the paced post keeps that GPU
 * busy, so a query's span is the program's GPU time), as «PERF post GPU» lines - the nodes' sums, then the programs - so every
 * phone log shows where the GPU time goes and an A/B of a scam_dev speed switch shows its gain. scam_dev post_gpu_timer 0: off,
 * 1: on on any GPU with the extension.
 */
public final class GLGpuTimer {
    private GLGpuTimer() {}

    private static final int TIME_ELAPSED_EXT = 0x88BF, GPU_DISJOINT_EXT = 0x8FBB;
    private static final int QUERIES_PER_BATCH = 32;
    private static final ThreadLocal<Run> CURRENT = new ThreadLocal<>();
    private static volatile Support support;

    private static final class Support {
        final boolean timerQueries, adreno;

        Support() {
            final String extensions = GLES30.glGetString(GLES30.GL_EXTENSIONS);
            timerQueries = extensions != null && extensions.contains("GL_EXT_disjoint_timer_query");
            final String renderer = GLES30.glGetString(GLES30.GL_RENDERER);
            adreno = renderer != null && renderer.contains("Adreno");
        }
    }

    private static final class Run {
        final ArrayList<String> names = new ArrayList<>();
        int[] queries = new int[QUERIES_PER_BATCH];
        int reserved;
        boolean active;
        String node = "", current;
        long allocNs, allocBytes, freeNs;
        int allocs;

        void beginQuery(String name) {
            if (names.size() == reserved) {
                if (reserved == queries.length) queries = Arrays.copyOf(queries, queries.length * 2);
                GLES30.glGenQueries(QUERIES_PER_BATCH, queries, reserved);
                reserved += QUERIES_PER_BATCH;
            }
            GLES30.glBeginQuery(TIME_ELAPSED_EXT, queries[names.size()]);
            active = true;
            names.add(node + "/" + name);
        }

        void endQuery() {
            if (!active) return;
            active = false;
            GLES30.glEndQuery(TIME_ELAPSED_EXT);
        }

        void release() {
            try {
                endQuery();
            } finally {
                if (reserved != 0) GLES30.glDeleteQueries(reserved, queries, 0);
            }
        }
    }

    /** This thread's run starts with its GL context current. */
    public static void begin() {
        discard();
        Support device = support;
        if (device == null) support = device = new Support();
        if (!device.timerQueries
                || (!PostGlMode.syncNodes() && !PreferenceKeys.scamDevSwitch("post_gpu_timer", device.adreno))) return;
        GLES30.glGetIntegerv(GPU_DISJOINT_EXT, new int[1], 0); // clears the flag
        CURRENT.set(new Run());
    }

    /** Whether this thread's run is measured (for the CPU time of texture storage, {@link #alloc} / {@link #free}). */
    public static boolean measuring() {
        return CURRENT.get() != null;
    }

    /** CPU time of one texture's storage (glTexStorage2D without data) of {@code bytes}. */
    public static void alloc(long ns, long bytes) {
        final Run run = CURRENT.get();
        if (run == null) return;
        run.allocNs += ns;
        run.allocBytes += bytes;
        run.allocs++;
    }

    /** CPU time of one texture's delete. */
    public static void free(long ns) {
        final Run run = CURRENT.get();
        if (run != null) run.freeNs += ns;
    }

    /** The node whose programs follow. */
    public static void node(String name) {
        final Run run = CURRENT.get();
        if (run == null) return;
        run.node = name;
        mark("(node)");
    }

    /** From here on the GPU time is {@code what}'s (of the current node); returns the previous name (for {@link #mark} back). */
    public static String mark(String what) {
        final Run run = CURRENT.get();
        if (run == null) return null;
        final String previous = run.current;
        run.endQuery();
        run.beginQuery(what);
        run.current = what;
        return previous;
    }

    /** P724: the span the GPU time goes to now ("node/program", as reported), or null when not measuring. */
    static String currentKey() {
        final Run run = CURRENT.get();
        return run == null || !run.active || run.names.isEmpty() ? null : run.names.get(run.names.size() - 1);
    }

    /** Releases this run's queries without waiting for results, on a failed pipeline while its context is current. */
    public static void discard() {
        GpuPace.forgetRun(); // P724: a run without a report teaches the band sizing nothing
        final Run run = CURRENT.get();
        if (run == null) return;
        CURRENT.remove();
        release(run);
    }

    private static void release(Run run) {
        try {
            run.release();
        } catch (RuntimeException | LinkageError e) {
            Log.w("SCAM_PIPELINE", "GPU timer cleanup: " + e);
        }
    }

    /** The end of a run: every query read (they wait for the GPU) and logged. */
    public static void report(String label) {
        final Run run = CURRENT.get();
        if (run == null) return;
        CURRENT.remove();
        try {
            report(label, run);
        } finally {
            release(run);
        }
    }

    private static void report(String label, Run run) {
        run.endQuery();
        final LinkedHashMap<String, long[]> sums = new LinkedHashMap<>();
        long total = 0;
        final int[] r = new int[1];
        for (int i = 0; i < run.names.size(); i++) {
            GLES30.glGetQueryObjectuiv(run.queries[i], GLES30.GL_QUERY_RESULT, r, 0);
            final long ns = r[0] & 0xFFFFFFFFL;
            total += ns;
            final long[] sample = sums.computeIfAbsent(run.names.get(i), k -> new long[2]);
            sample[0] += ns;
            sample[1]++;
        }
        GLES30.glGetIntegerv(GPU_DISJOINT_EXT, r, 0);
        final boolean disjoint = r[0] != 0;
        // P724: the programs' GPU time per pixel sizes the next bands (GpuPace); a disjoint run's times are not trusted
        if (disjoint) GpuPace.forgetRun();
        else {
            final LinkedHashMap<String, Long> spans = new LinkedHashMap<>();
            for (Map.Entry<String, long[]> e : sums.entrySet()) spans.put(e.getKey(), e.getValue()[0]);
            final int learnt = GpuPace.learnGpuTime(spans);
            if (learnt > 0) Log.i("SCAM_PIPELINE", "post GPU bands: " + learnt + " programs sized by their GPU time from the next band on");
        }
        final ArrayList<Map.Entry<String, long[]>> list = new ArrayList<>(sums.entrySet());
        list.sort((a, b) -> Long.compare(b.getValue()[0], a.getValue()[0]));
        Log.i("SCAM_PIPELINE", nodeLine(label, sums, total, disjoint));
        final StringBuilder sb = new StringBuilder("PERF ").append(label).append(" GPU programs, total ms=")
                .append(String.format(Locale.ROOT, "%.1f", total / 1e6)).append(disjoint ? " (disjoint)" : "")
                .append(String.format(Locale.ROOT, " cpu storage ms=%.1f (%d textures, %d MB) delete ms=%.1f",
                        run.allocNs / 1e6, run.allocs, run.allocBytes >> 20, run.freeNs / 1e6));
        sb.append(':');
        // a few long lines (the log quota): "node/program ms xN" by GPU time
        for (Map.Entry<String, long[]> e : list) {
            if (e.getValue()[0] < 200_000L) continue;
            if (sb.length() > 700) {
                Log.i("SCAM_PIPELINE", sb.toString());
                sb.setLength(0);
                sb.append("PERF ").append(label).append(" GPU programs ...");
            }
            sb.append(String.format(Locale.ROOT, " %s %.2f x%d;", e.getKey(), e.getValue()[0] / 1e6, e.getValue()[1]));
        }
        Log.i("SCAM_PIPELINE", sb.toString());
    }

    /**
     * P671: «PERF post GPU nodes ms total T: node a, node b, ...» - each node's queries summed ("node/program" names; the order of
     * the run), {@code total} in ns; tagged when the driver reported a disjoint (the times are then not to be trusted).
     */
    static String nodeLine(String label, Map<String, long[]> sums, long total, boolean disjoint) {
        final LinkedHashMap<String, Long> nodes = new LinkedHashMap<>();
        for (Map.Entry<String, long[]> e : sums.entrySet()) {
            final String key = e.getKey();
            final int slash = key.indexOf('/');
            final String node = slash > 0 ? key.substring(0, slash) : slash == 0 ? "(start)" : key;
            nodes.merge(node, e.getValue()[0], Long::sum);
        }
        final StringBuilder sb = new StringBuilder("PERF ").append(label).append(" GPU nodes ms total ")
                .append(String.format(Locale.ROOT, "%.1f", total / 1e6)).append(disjoint ? " (disjoint)" : "").append(':');
        boolean first = true;
        for (Map.Entry<String, Long> e : nodes.entrySet()) {
            sb.append(first ? " " : ", ").append(e.getKey()).append(' ').append(String.format(Locale.ROOT, "%.1f", e.getValue() / 1e6));
            first = false;
        }
        return sb.toString();
    }
}
