package com.scamera.app.gallery.views;

import android.content.Context;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.ViewParent;

import androidx.recyclerview.widget.RecyclerView;

import java.util.function.Consumer;

/** The photo grid's two-finger zoom owns its gesture before RecyclerView splits events among its cells. */
public final class PinchRecyclerView extends RecyclerView {
    private final ScaleGestureDetector detector;
    private boolean pinching;

    public PinchRecyclerView(Context context, Consumer<Boolean> zoomStep) {
        super(context);
        detector = new ScaleGestureDetector(context, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            private float scale;

            @Override
            public boolean onScaleBegin(ScaleGestureDetector detector) {
                scale = 1f;
                return true;
            }

            @Override
            public boolean onScale(ScaleGestureDetector detector) {
                scale *= detector.getScaleFactor();
                if (scale > 1.25f || scale < .8f) {
                    zoomStep.accept(scale > 1.25f);
                    scale = 1f;
                }
                return true;
            }
        });
        detector.setQuickScaleEnabled(false);
        detector.setStylusScaleEnabled(false);
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent event) {
        final int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_DOWN && pinching) endPinch();
        if (!pinching && action == MotionEvent.ACTION_POINTER_DOWN) {
            // Cancel the cell's click, RecyclerView's drag and the pending long press exactly once.
            final MotionEvent cancel = MotionEvent.obtain(event);
            cancel.setAction(MotionEvent.ACTION_CANCEL);
            try {
                super.dispatchTouchEvent(cancel);
            } finally {
                cancel.recycle();
            }
            stopScroll();
            android.transition.TransitionManager.endTransitions(this);
            pinching = true;
            final ViewParent parent = getParent();
            if (parent != null) parent.requestDisallowInterceptTouchEvent(true);
        }
        detector.onTouchEvent(event);
        if (!pinching) return super.dispatchTouchEvent(event);
        if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) endPinch();
        return true;
    }

    private void endPinch() {
        pinching = false;
        final ViewParent parent = getParent();
        if (parent != null) parent.requestDisallowInterceptTouchEvent(false);
    }

    @Override
    protected void onDetachedFromWindow() {
        if (pinching) endPinch();
        super.onDetachedFromWindow();
    }
}
