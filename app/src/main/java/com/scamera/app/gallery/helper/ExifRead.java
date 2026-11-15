package com.scamera.app.gallery.helper;

import android.content.ContentResolver;
import android.net.Uri;
import android.os.ParcelFileDescriptor;

import androidx.annotation.Nullable;
import androidx.exifinterface.media.ExifInterface;

import java.io.IOException;
import java.io.InputStream;

/**
 * P721 (X300 Ultra log 2026-11-15 08:39: «OutOfMemoryError: Failed to allocate a 81920016 byte allocation» on ExifRead): an
 * ExifInterface over an InputStream skips through a large DNG with BufferedInputStream.skip, whose mark buffer grows to the
 * skipped size (80 MB of the Java heap per 50 MP DNG). Over a seekable file descriptor ExifInterface seeks instead and buffers
 * nothing; the stream stays only for a provider that gives no descriptor.
 */
public final class ExifRead {
    private ExifRead() {}

    /** The file's EXIF (read at once), null when the provider gives neither a descriptor nor a stream. */
    @Nullable
    public static ExifInterface open(ContentResolver resolver, Uri uri) throws IOException {
        ParcelFileDescriptor pfd = null;
        try {
            pfd = resolver.openFileDescriptor(uri, "r");
        } catch (IOException | RuntimeException noDescriptor) {
            // a provider without descriptors: the stream below
        }
        if (pfd != null) {
            try (ParcelFileDescriptor fd = pfd) {
                return new ExifInterface(fd.getFileDescriptor());
            } catch (IOException | RuntimeException notSeekable) {
                // a pipe: the stream below
            }
        }
        try (InputStream in = resolver.openInputStream(uri)) {
            return in == null ? null : new ExifInterface(in);
        }
    }
}
