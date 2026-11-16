package com.scamera.app.ui.camera.views.viewfinder;

import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

/** The viewfinder renderer's ISP latch, its SurfaceTexture across contexts and the RAW draw count (MainRenderer). */
public class MainRendererLatchTest {
    private static String src() throws Exception {
        return new String(Files.readAllBytes(new File(
                "src/main/java/com/scamera/app/ui/camera/views/viewfinder/MainRenderer.java").toPath()), StandardCharsets.UTF_8);
    }

    private static String body(String s, String signature) {
        s = s.replace("\r\n", "\n");
        final int start = s.indexOf(signature);
        assertTrue(signature, start > 0);
        return s.substring(start, s.indexOf("\n    }\n", start));
    }

    /**
     * Bug viewfinder-ui-latch-without-egl: a latch queued by onFrameAvailable runs even while the GL thread is paused (GLThread
     * takes its events before the pause check), with no EGL context - updateTexImage threw on the GL thread (a crash).
     */
    @Test
    public void noLatchWithoutAContext() throws Exception {
        final String latch = body(src(), "private void latchIsp(boolean queued)");
        final int check = latch.indexOf("queued && android.opengl.EGL14.EGL_NO_CONTEXT.equals(android.opengl.EGL14.eglGetCurrentContext())");
        final int update = latch.indexOf("surface.updateTexImage();");
        final int clear = latch.indexOf("ispPending = false;");
        assertTrue("the context is checked before the latch", check > 0 && update > check);
        assertTrue("a failed latch is caught", latch.indexOf("catch (RuntimeException e)", update) > update);
        assertTrue("a frame arriving during the latch stays pending", clear > check && clear < update);
        assertTrue("failed work remains pending", latch.indexOf("ispPending = true;", update) > update);
    }

    @Test
    public void callbacksCoalesceOnlyForTheCurrentSurface() throws Exception {
        final String s = src();
        final String callback = body(s, "public void onFrameAvailable(SurfaceTexture st)");
        assertTrue(callback.contains("if (st != ispSurface || ispLatchTask == null) return;"));
        assertTrue(callback.contains("if (latchOnly && !ispLatchQueued)"));
        final String queued = body(s, "private void latchQueuedIsp(SurfaceTexture surface)");
        final int check = queued.indexOf("if (surface != ispSurface || ispLatchTask == null) return;");
        assertTrue(check > 0 && check < queued.indexOf("ispLatchQueued = false;"));
        assertTrue(queued.contains("latchIsp(true);"));
    }

    /** Missed bug: each new context made a new SurfaceTexture and left the old one (its BufferQueue, the last preview buffer). */
    @Test
    public void theOldSurfaceTextureIsReleased() throws Exception {
        final String created = body(src(), "public void onSurfaceCreated(GL10 gl, EGLConfig config)");
        final int release = created.indexOf("old.release();");
        assertTrue(created.indexOf("final SurfaceTexture old = ispSurface;") > 0 && release > 0);
        assertTrue(created.indexOf("old.setOnFrameAvailableListener(null);") < release);
        assertTrue("before the new one is made", release < created.indexOf("new SurfaceTexture(ispTex);"));
    }

    /**
     * Review: the pause destroys the EGL context (not preserved), so onSurfaceCreated makes a new SurfaceTexture on resume and
     * releases the old one; a GLPreview still reporting the old one as available let screenResumed open the camera against it.
     */
    @Test
    public void aPauseDropsTheSurfaceTexture() throws Exception {
        final String preview = body(new String(Files.readAllBytes(new File(
                "src/main/java/com/scamera/app/ui/camera/views/viewfinder/GLPreview.java").toPath()), StandardCharsets.UTF_8),
                "public void onPause()");
        final int dropped = preview.indexOf("surfaceReady = false;");
        assertTrue(dropped > 0 && dropped < preview.indexOf("super.onPause();"));
    }

    /** Bug viewfinder-ui-freeze-raw-only: every developed RAW frame on screen is counted (the frozen viewfinder watches it). */
    @Test
    public void rawDrawsAreCounted() throws Exception {
        final String s = src();
        final int shown = s.indexOf("mRawShownNs = rawActive ? System.nanoTime() : Long.MIN_VALUE / 2;");
        assertTrue(shown > 0);
        final int count = s.indexOf("sRawDraws++;", shown);
        assertTrue(count > shown && count < s.indexOf("mSubjectGrabber.afterDraw();", shown));
        assertTrue(s.substring(shown, count).contains("if (rawActive) {"));
    }
}
