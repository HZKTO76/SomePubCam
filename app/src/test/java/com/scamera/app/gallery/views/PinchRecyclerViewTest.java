package com.scamera.app.gallery.views;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import android.app.Activity;
import android.app.Application;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;

import androidx.annotation.NonNull;
import androidx.recyclerview.widget.GridLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.android.controller.ActivityController;
import org.robolectric.annotation.Config;

import java.util.concurrent.atomic.AtomicInteger;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 35, application = Application.class)
public class PinchRecyclerViewTest {
    @Test
    public void repeatedPinchAndCancelLeaveTheNextTapAndScrollWorking() {
        try (ActivityController<Activity> controller = Robolectric.buildActivity(Activity.class).setup()) {
            exercise(controller.get());
        }
    }

    private static void exercise(Activity context) {
        AtomicInteger steps = new AtomicInteger(), clicks = new AtomicInteger();
        GridLayoutManager layout = new GridLayoutManager(context, 4);
        PinchRecyclerView grid = new PinchRecyclerView(context, spread -> {
            steps.incrementAndGet();
            layout.setSpanCount(spread ? 3 : 4);
        });
        grid.setLayoutManager(layout);
        grid.setAdapter(new RecyclerView.Adapter<RecyclerView.ViewHolder>() {
            @NonNull @Override public RecyclerView.ViewHolder onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
                View cell = new View(parent.getContext());
                cell.setLayoutParams(new RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 100));
                cell.setOnClickListener(v -> clicks.incrementAndGet());
                return new RecyclerView.ViewHolder(cell) {};
            }
            @Override public void onBindViewHolder(@NonNull RecyclerView.ViewHolder holder, int position) {}
            @Override public int getItemCount() { return 120; }
        });
        context.setContentView(grid);
        int spec = View.MeasureSpec.makeMeasureSpec(600, View.MeasureSpec.EXACTLY);
        grid.measure(spec, spec);
        grid.layout(0, 0, 600, 600);

        for (boolean cancel : new boolean[]{false, true}) {
            int before = steps.get();
            long start = SystemClock.uptimeMillis();
            touch(grid, start, 0, MotionEvent.ACTION_DOWN, 245, 245);
            touch(grid, start, 10, MotionEvent.ACTION_POINTER_DOWN | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    245, 245, 355, 245);
            touch(grid, start, 20, MotionEvent.ACTION_MOVE, 195, 245, 405, 245);
            touch(grid, start, 30, MotionEvent.ACTION_MOVE, 130, 245, 470, 245);
            touch(grid, start, 40, MotionEvent.ACTION_MOVE, 45, 245, 555, 245);
            if (cancel) touch(grid, start, 50, MotionEvent.ACTION_CANCEL, 45, 245, 555, 245);
            else {
                touch(grid, start, 50, MotionEvent.ACTION_POINTER_UP | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                        45, 245, 555, 245);
                touch(grid, start, 60, MotionEvent.ACTION_UP, 45, 245);
            }
            assertTrue(steps.get() > before);
            assertEquals(0, clicks.get());
            assertFalse(grid.isLayoutSuppressed());
            grid.measure(spec, spec);
            grid.layout(0, 0, 600, 600);
        }

        long tap = SystemClock.uptimeMillis();
        touch(grid, tap, 0, MotionEvent.ACTION_DOWN, 60, 45);
        touch(grid, tap, 10, MotionEvent.ACTION_UP, 60, 45);
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        assertEquals(1, clicks.get());

        long scroll = SystemClock.uptimeMillis();
        touch(grid, scroll, 0, MotionEvent.ACTION_DOWN, 60, 480);
        touch(grid, scroll, 20, MotionEvent.ACTION_MOVE, 60, 360);
        touch(grid, scroll, 40, MotionEvent.ACTION_MOVE, 60, 180);
        touch(grid, scroll, 60, MotionEvent.ACTION_UP, 60, 180);
        assertTrue(grid.computeVerticalScrollOffset() > 0);
    }

    private static void touch(View view, long start, int elapsed, int action, float... xy) {
        int count = xy.length / 2;
        MotionEvent.PointerProperties[] properties = new MotionEvent.PointerProperties[count];
        MotionEvent.PointerCoords[] coords = new MotionEvent.PointerCoords[count];
        for (int i = 0; i < count; i++) {
            properties[i] = new MotionEvent.PointerProperties();
            properties[i].id = i;
            properties[i].toolType = MotionEvent.TOOL_TYPE_FINGER;
            coords[i] = new MotionEvent.PointerCoords();
            coords[i].x = xy[2 * i];
            coords[i].y = xy[2 * i + 1];
            coords[i].pressure = coords[i].size = 1f;
        }
        MotionEvent event = MotionEvent.obtain(start, start + elapsed, action, count,
                properties, coords, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0);
        try {
            view.dispatchTouchEvent(event);
        } finally {
            event.recycle();
        }
    }
}
