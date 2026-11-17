package com.scamera.app.processing.opengl.postpipeline;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

/** P728: the Ultra HDR knee (the boost only above the SDR's knee) and the median of the knee's measure. */
public class UltraHdrKneeTest {
    @Test public void defaultsAndBounds() {
        assertArrayEquals(new float[]{0.3f, 0.7f}, SceneGainMap.kneeOf(SceneGainMap.KNEE_LO, SceneGainMap.KNEE_HI), 0f);
        assertArrayEquals("0: off, the median anchor as before", new float[]{0f, 0f}, SceneGainMap.kneeOf(0f, 0.7f), 0f);
        assertArrayEquals(new float[]{0f, 0f}, SceneGainMap.kneeOf(Float.NaN, 0.7f), 0f);
        assertArrayEquals("hi at least a little above lo", new float[]{0.5f, 0.52f}, SceneGainMap.kneeOf(0.5f, 0.2f), 1e-6f);
        assertArrayEquals("at most 1", new float[]{0.95f, 1f}, SceneGainMap.kneeOf(2f, 3f), 1e-6f);
    }

    @Test public void medianOfTheBlocksAtTheKneeOnly() {
        int[][] h = new int[3][256];
        for (int c = 0; c < 3; c++) {
            h[c][0] = 100000;  // blocks away from the knee: never counted
            h[c][100] = 10;
            h[c][128] = 30;
            h[c][200] = 10;
        }
        assertEquals(128 / 255f, SceneGainMap.medianAbove(h, 1, 20f), 1e-6f);
        assertTrue("fewer blocks at the knee than asked: none", Float.isNaN(SceneGainMap.medianAbove(h, 1, 51f)));
        assertTrue(Float.isNaN(SceneGainMap.medianAbove(new int[3][256], 1, 0f)));
    }
}
