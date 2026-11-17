package com.scamera.app.api;

import android.hardware.camera2.CameraCharacteristics;
import android.util.Log;
import android.util.Range;

import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/**
 * P732 (owner, 2026-11-17, HONOR WKL-AN80, Android 17: the app closed at start): the HAL lists a range characteristic with its
 * lower bound above the upper, and CameraCharacteristics.get throws (AssertionError from the Range marshaller: «lower must be less
 * than or equal to upper») - in CameraManager2's lens directory, before any UI. Range keys are read here: a value the framework
 * cannot build is read again as its raw array and given back ordered (the same two numbers); a key that cannot be read either
 * way reads as absent (null), as on a HAL that does not list it.
 */
public final class SafeRanges {
    private static final String TAG = "SafeRanges";
    private static final Set<String> NOTED = Collections.synchronizedSet(new HashSet<>());

    private SafeRanges() {}

    public static <T> T get(CameraCharacteristics c, CameraCharacteristics.Key<T> key) {
        if (c == null || key == null) return null;
        try {
            return c.get(key);
        } catch (AssertionError | RuntimeException e) {
            final T fixed = repaired(c, key);
            if (NOTED.add(key.getName())) {
                Log.w(TAG, key.getName() + " unreadable (" + rootMessage(e) + "): " + (fixed == null ? "absent" : "read ordered " + describe(fixed)));
            }
            return fixed;
        }
    }

    @SuppressWarnings("unchecked")
    private static <T> T repaired(CameraCharacteristics c, CameraCharacteristics.Key<T> key) {
        final String name = key.getName();
        try {
            if (name.equals(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE.getName())) {
                return (T) ordered(c.get(new CameraCharacteristics.Key<>(name, long[].class)));
            }
            if (name.equals(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE.getName())) {
                return (T) ordered(c.get(new CameraCharacteristics.Key<>(name, float[].class)));
            }
            if (name.equals(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES.getName())) {
                return (T) orderedPairs(c.get(new CameraCharacteristics.Key<>(name, int[].class)));
            }
            if (name.equals(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE.getName())
                    || name.equals(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE.getName())
                    || name.equals(CameraCharacteristics.CONTROL_POST_RAW_SENSITIVITY_BOOST_RANGE.getName())) {
                return (T) ordered(c.get(new CameraCharacteristics.Key<>(name, int[].class)));
            }
        } catch (AssertionError | RuntimeException ignored) {
            // unreadable as an array too: absent
        }
        return null;
    }

    static Range<Integer> ordered(int[] raw) {
        if (raw == null || raw.length < 2) return null;
        return new Range<>(Math.min(raw[0], raw[1]), Math.max(raw[0], raw[1]));
    }

    static Range<Long> ordered(long[] raw) {
        if (raw == null || raw.length < 2) return null;
        return new Range<>(Math.min(raw[0], raw[1]), Math.max(raw[0], raw[1]));
    }

    static Range<Float> ordered(float[] raw) {
        if (raw == null || raw.length < 2 || Float.isNaN(raw[0]) || Float.isNaN(raw[1])) return null;
        return new Range<>(Math.min(raw[0], raw[1]), Math.max(raw[0], raw[1]));
    }

    @SuppressWarnings("unchecked")
    static Range<Integer>[] orderedPairs(int[] raw) {
        if (raw == null || raw.length < 2) return null;
        final Range<Integer>[] out = new Range[raw.length / 2];
        for (int i = 0; i < out.length; i++) out[i] = new Range<>(Math.min(raw[2 * i], raw[2 * i + 1]), Math.max(raw[2 * i], raw[2 * i + 1]));
        return out;
    }

    private static String describe(Object v) {
        if (v instanceof Object[]) return java.util.Arrays.toString((Object[]) v);
        return String.valueOf(v);
    }

    private static String rootMessage(Throwable e) {
        Throwable t = e;
        while (t.getCause() != null && t.getCause() != t) t = t.getCause();
        return t.getClass().getSimpleName() + ": " + t.getMessage();
    }
}
