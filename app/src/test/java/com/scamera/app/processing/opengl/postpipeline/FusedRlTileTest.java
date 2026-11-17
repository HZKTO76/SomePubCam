package com.scamera.app.processing.opengl.postpipeline;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

/** P725: which RL stages why/sharp_rl_cs takes, and its tile for the shared memory a GPU has (the rest keep the fragment passes). */
public class FusedRlTileTest {
    @Test public void defaultStagesFitTheTileOfThirtyTwoIn32KB() {
        // half 2, 3 iterations: (32 + 24)^2 x 2 planes x 4 bytes = 25 KB
        assertEquals(32, WhyLumaSharpen.fusedRlTile(2, 3, 0f, 32768));
        assertEquals(32, WhyLumaSharpen.fusedRlTile(1, 3, 0f, 32768));
    }

    @Test public void theSpecMinimumOf16KBTakesTheTileOfSixteen() {
        // (16 + 24)^2 x 8 = 12.8 KB; (32 + 24)^2 x 8 = 25 KB does not fit
        assertEquals(16, WhyLumaSharpen.fusedRlTile(2, 3, 0f, 16384));
        assertEquals(0, WhyLumaSharpen.fusedRlTile(2, 4, 0f, 16384));
    }

    @Test public void computeStageByDefaultOnlyOnAdreno700AndNewer() {
        org.junit.Assert.assertTrue(WhyLumaSharpen.fusedRlByDefault("Adreno (TM) 830"));
        org.junit.Assert.assertTrue(WhyLumaSharpen.fusedRlByDefault("Adreno (TM) 710"));
        org.junit.Assert.assertFalse("LG V50: slower than the fragment passes", WhyLumaSharpen.fusedRlByDefault("Adreno (TM) 640"));
        org.junit.Assert.assertFalse(WhyLumaSharpen.fusedRlByDefault("Adreno (TM) 650"));
        org.junit.Assert.assertFalse(WhyLumaSharpen.fusedRlByDefault("Mali-G925-Immortalis MC12"));
        org.junit.Assert.assertFalse(WhyLumaSharpen.fusedRlByDefault(null));
    }

    @Test public void dampingWiderPsfsAndLongStagesKeepTheFragmentPasses() {
        assertEquals("TV damping", 0, WhyLumaSharpen.fusedRlTile(2, 3, 0.5f, 32768));
        assertEquals("half 3 and up", 0, WhyLumaSharpen.fusedRlTile(3, 3, 0f, 1 << 20));
        assertEquals("more than 4 iterations", 0, WhyLumaSharpen.fusedRlTile(2, 5, 0f, 1 << 20));
        assertEquals("no iteration", 0, WhyLumaSharpen.fusedRlTile(2, 0, 0f, 32768));
        assertEquals("no compute shared memory known", 0, WhyLumaSharpen.fusedRlTile(2, 3, 0f, 0));
    }
}
