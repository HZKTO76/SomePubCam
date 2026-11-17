package com.scamera.app.processing;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

/** P730: the processing threads stay one step above Android's background group (nice 10: 40 ms timer slack, little cores). */
public class ProcessingPriorityTest {
    @Test public void niceNineByDefault() {
        assertEquals(9, ProcessingPriority.NICE);
        assertTrue("below THREAD_PRIORITY_BACKGROUND", ProcessingPriority.NICE < android.os.Process.THREAD_PRIORITY_BACKGROUND);
        assertTrue("still below the UI's default priority", ProcessingPriority.NICE > android.os.Process.THREAD_PRIORITY_DEFAULT);
    }
}
