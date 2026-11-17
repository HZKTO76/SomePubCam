package com.scamera.app.api;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import android.app.Application;
import android.hardware.camera2.CameraCharacteristics;
import android.util.Range;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

/** P732: HONOR WKL-AN80 lists a range with lower > upper; CameraCharacteristics.get threw at start and the app closed. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 35, application = Application.class)
public class SafeRangesTest {
    private static AssertionError marshalFailure() {
        return new AssertionError(new IllegalArgumentException("lower must be less than or equal to upper"));
    }

    @Test
    public void unorderedRangesAreReadOrderedFromTheirRawValues() {
        final CameraCharacteristics c = mock(CameraCharacteristics.class);
        when(c.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)).thenThrow(marshalFailure());
        when(c.get(new CameraCharacteristics.Key<>(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE.getName(), int[].class)))
                .thenReturn(new int[]{6400, 50});
        when(c.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)).thenThrow(marshalFailure());
        when(c.get(new CameraCharacteristics.Key<>(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE.getName(), long[].class)))
                .thenReturn(new long[]{1_000_000_000L, 10_000L});
        when(c.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)).thenThrow(marshalFailure());
        when(c.get(new CameraCharacteristics.Key<>(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE.getName(), float[].class)))
                .thenReturn(new float[]{10f, 0.6f});
        when(c.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)).thenThrow(marshalFailure());
        when(c.get(new CameraCharacteristics.Key<>(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES.getName(), int[].class)))
                .thenReturn(new int[]{15, 30, 30, 24});

        assertEquals(new Range<>(50, 6400), SafeRanges.get(c, CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE));
        assertEquals(new Range<>(10_000L, 1_000_000_000L), SafeRanges.get(c, CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE));
        assertEquals(new Range<>(0.6f, 10f), SafeRanges.get(c, CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE));
        final Range<Integer>[] fps = SafeRanges.get(c, CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES);
        assertEquals(2, fps.length);
        assertEquals(new Range<>(15, 30), fps[0]);
        assertEquals(new Range<>(24, 30), fps[1]);
    }

    @Test
    public void unreadableEitherWayIsAbsentAndAValidRangeIsUntouched() {
        final CameraCharacteristics c = mock(CameraCharacteristics.class);
        when(c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)).thenThrow(marshalFailure());
        when(c.get(new CameraCharacteristics.Key<>(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE.getName(), int[].class)))
                .thenThrow(new IllegalArgumentException("broken"));
        assertNull(SafeRanges.get(c, CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE));
        final Range<Integer> iso = new Range<>(100, 3200);
        when(c.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)).thenReturn(iso);
        assertSame(iso, SafeRanges.get(c, CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE));
        assertNull(SafeRanges.get(null, CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE));
    }

    @Test
    public void theLensDirectoryReadsAnUnorderedHalWithoutThrowing() {
        final CameraCharacteristics c = mock(CameraCharacteristics.class);
        when(c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)).thenReturn(new float[]{5.6f});
        when(c.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)).thenThrow(marshalFailure());
        when(c.get(new CameraCharacteristics.Key<>(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE.getName(), int[].class)))
                .thenReturn(new int[]{6400, 50});
        when(c.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)).thenThrow(marshalFailure());
        assertFalse(CameraManager2.isAuxiliarySensor(c));
    }
}
