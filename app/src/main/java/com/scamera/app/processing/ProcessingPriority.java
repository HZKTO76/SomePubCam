package com.scamera.app.processing;

import com.scamera.app.util.Log;

/**
 * P730 (owner, 2026-11-17: «На Арк камере на LG с таким же количеством кадров обработка занимает 3.6 секунд»; LG V50, Android 12:
 * the reference app's post 250 ms, ours 14.6 s, of which 13.0 s were the paced post's waits for its bands - 40 - 64 ms each while
 * the GPU timer counted 2.1 s of work). The processing thread ran at Java priority 4: nice 10, and on Android a thread at nice 10
 * or above goes into the background scheduling group (task profile SCHED_SP_BACKGROUND: the little cores and a 40 ms timer
 * slack). Every 0.25 ms sleep of the post's fence polls (GpuPace) then took up to 40 ms while the GPU, two bands ahead at most,
 * sat idle. The processing threads run at nice 9 instead: about the same share of the CPU below the viewfinder (nice -4) and
 * the UI (0), but the app's own scheduling group - the timer slack of a foreground thread (50 us). scam_dev processing_nice: the
 * nice value (10: as before).
 */
public final class ProcessingPriority {
    /** One step above the background group's threshold (THREAD_PRIORITY_BACKGROUND, 10). */
    public static final int NICE = 9;

    private ProcessingPriority() {}

    static int nice() {
        try {
            return Math.max(-8, Math.min(19, Math.round(com.scamera.app.settings.PreferenceKeys.scamDevNumber("processing_nice", NICE))));
        } catch (RuntimeException | LinkageError e) {
            return NICE;
        }
    }

    /** The calling thread at {@link #nice()} (best effort). */
    public static void apply() {
        final int nice = nice();
        try {
            android.os.Process.setThreadPriority(nice);
        } catch (RuntimeException | LinkageError e) {
            Log.w("SCAM_PIPELINE", "processing priority " + nice + " not applied: " + e);
        }
    }

    /** The calling thread's timer slack (ns) from /proc, or -1 where it cannot be read. */
    public static long timerSlackNs() {
        try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(
                "/proc/self/task/" + android.os.Process.myTid() + "/timerslack_ns"))) {
            final String line = r.readLine();
            return line == null ? -1 : Long.parseLong(line.trim());
        } catch (Exception | LinkageError e) {
            return -1;
        }
    }
}
