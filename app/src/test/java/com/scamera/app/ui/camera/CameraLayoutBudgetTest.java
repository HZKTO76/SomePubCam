package com.scamera.app.ui.camera;

import org.junit.Test;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class CameraLayoutBudgetTest {
    @Test
    public void normalAnchorWhenTheFixedRowsFit() {
        assertEquals(0, CameraLayout.compactAnchorHeight(390, 735, 205, "3:4"));
        assertEquals(0, CameraLayout.compactAnchorHeight(360, 670, 190, "3:4"));
    }

    @Test
    public void shortWindowKeepsEnoughRoomForFixedRows() {
        assertEquals(445, CameraLayout.compactAnchorHeight(390, 650, 205, "3:4"));
        assertEquals(445, CameraLayout.compactAnchorHeight(390, 650, 205, "9:16"));
    }

    @Test
    public void portraitPhoneAndCoverKeepTheirFullWidth() {
        assertFalse(CameraLayout.wideWindow(390, 735));
        assertFalse(CameraLayout.wideWindow(360, 880));
        assertFalse(CameraLayout.wideWindow(600, 800));
    }

    @Test
    public void openFoldAndWideTabletCenterTheCameraColumn() {
        assertTrue(CameraLayout.wideWindow(832, 920));
        assertEquals(462, CameraLayout.cameraColumnWidth(832, 840, 224, 430));
        assertTrue(CameraLayout.wideWindow(1280, 800));
        assertEquals(486, CameraLayout.cameraColumnWidth(1280, 708, 240, 486));
        assertEquals(0, CameraLayout.cameraColumnWidth(290, 275, 200, 306));
    }
}
