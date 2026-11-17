package com.scamera.app.processing.opengl.postpipeline;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;

import com.scamera.app.processing.ChunkedBytes;
import com.scamera.app.util.Log;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Locale;
import java.util.Objects;

/** Full-resolution parity of the worker buffers and the JPEG encoder output from a laboratory replay. */
final class PerfReplay {
    private String rgbHash, mapHash, jpegHash;
    private double frames;
    private boolean frameMapExpected;
    private int width, height;

    void merge(ByteBuffer rgb, ByteBuffer frameMap, boolean expectMap, double frames) {
        rgbHash = hash(rgb);
        mapHash = hash(frameMap);
        frameMapExpected = expectMap;
        this.frames = frames;
    }

    Bitmap jpeg(ChunkedBytes encoded) throws IOException {
        if (encoded == null) throw new IOException("Performance replay produced neither JPEG nor bitmap");
        final byte[] bytes = encoded.toByteArray();
        jpegHash = hex(sha256().digest(bytes));
        final Bitmap bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        if (bitmap == null) throw new IOException("Performance replay JPEG could not be decoded");
        width = bitmap.getWidth();
        height = bitmap.getHeight();
        return bitmap;
    }

    static boolean report(String burst, PerfReplay a, PerfReplay b, ScamLabRun.Side reference, ScamLabRun.Side candidate) {
        final boolean frameMapAvailable = a.mapHash != null && b.mapHash != null;
        final boolean framesEqual = Double.isFinite(a.frames) && Double.compare(a.frames, b.frames) == 0
                && (!(a.frameMapExpected || b.frameMapExpected) || frameMapAvailable) && Objects.equals(a.mapHash, b.mapHash);
        final boolean rgbEqual = a.rgbHash != null && a.rgbHash.equals(b.rgbHash);
        final boolean encoded = a.jpegHash != null && b.jpegHash != null;
        final boolean exact = encoded && a.jpegHash.equals(b.jpegHash);
        Log.i("PERF", "replay " + burst + " A_merge_ms=" + reference.mergeMs + " A_post_ms=" + reference.postMs
                + " B_merge_ms=" + candidate.mergeMs + " B_post_ms=" + candidate.postMs);
        final String pixels = exact ? "max_delta=0 psnr_db=inf" : pixelDiff(a, b, reference.photo, candidate.photo);
        Log.i("PERF_VERIFY", "burst=" + burst + " jpeg_core=" + (!encoded ? "unavailable" : exact ? "exact" : "different")
                + " sha256_a=" + a.jpegHash + " sha256_b=" + b.jpegHash + " " + pixels
                + " frame_map_available=" + frameMapAvailable
                + " frame_map_and_count_equal=" + framesEqual + " merge_rgb_equal=" + rgbEqual);
        return exact && framesEqual && rgbEqual;
    }

    private static String pixelDiff(PerfReplay a, PerfReplay b, Bitmap first, Bitmap second) {
        if (a.width <= 0 || a.width != b.width || a.height != b.height || first.getWidth() != a.width
                || second.getWidth() != a.width || first.getHeight() != a.height || second.getHeight() != a.height) {
            return "pixel_comparison=unavailable";
        }
        final int[] left = new int[a.width], right = new int[a.width];
        long squared = 0;
        int maxDelta = 0;
        for (int y = 0; y < a.height; y++) {
            first.getPixels(left, 0, a.width, 0, y, a.width, 1);
            second.getPixels(right, 0, a.width, 0, y, a.width, 1);
            for (int x = 0; x < a.width; x++) {
                for (int channel = 0; channel < 24; channel += 8) {
                    final int delta = (left[x] >>> channel & 255) - (right[x] >>> channel & 255);
                    maxDelta = Math.max(maxDelta, Math.abs(delta));
                    squared += delta * delta;
                }
            }
        }
        final double psnr = squared == 0 ? Double.POSITIVE_INFINITY
                : 10 * Math.log10(255.0 * 255.0 * a.width * a.height * 3 / squared);
        return String.format(Locale.ROOT, "max_delta=%d psnr_db=%.3f", maxDelta, psnr);
    }

    static void recycle(ScamLabRun.Side side) {
        side.photo.recycle();
        if (side.frameMap != null) side.frameMap.recycle();
    }

    private static String hash(ByteBuffer data) {
        if (data == null) return null;
        final MessageDigest digest = sha256();
        final ByteBuffer src = data.duplicate();
        src.rewind();
        digest.update(src);
        return hex(digest.digest());
    }

    private static MessageDigest sha256() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    private static String hex(byte[] bytes) {
        final char[] result = new char[bytes.length * 2];
        for (int i = 0; i < bytes.length; i++) {
            result[2 * i] = Character.forDigit(bytes[i] >>> 4 & 15, 16);
            result[2 * i + 1] = Character.forDigit(bytes[i] & 15, 16);
        }
        return new String(result);
    }
}
