package com.scamera.app.ui.camera;

import android.content.Context;
import android.util.AttributeSet;
import android.view.View;
import android.view.ViewGroup;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.constraintlayout.widget.ConstraintLayout;
import androidx.core.graphics.Insets;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;

import com.scamera.app.R;
import com.scamera.app.ui.camera.views.viewfinder.GLPreview;

/**
 * Root view of {@code camera_screen.xml}.
 * <p>
 * The Android Studio layout editor cannot run fragments, viewmodels or the
 * data-binding pipeline, so the camera UI would be laid out with un-evaluated
 * bindings. On inflation for a preview this view asks {@link CameraFragment}
 * to apply its default configuration, reusing the exact binding adapters that
 * run at runtime (no duplicated layout code).
 */
public class CameraLayout extends ConstraintLayout {
    private View stage, frame, shutter, shutterBox, bottomRow, modeSwitch, lenses, grabber, sheetHandle;
    private GLPreview preview;

    public CameraLayout(@NonNull Context context) {
        super(context);
    }

    public CameraLayout(@NonNull Context context, @Nullable AttributeSet attrs) {
        super(context, attrs);
    }

    public CameraLayout(@NonNull Context context, @Nullable AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    @Override
    protected void onFinishInflate() {
        super.onFinishInflate();
        stage = findViewById(R.id.camera_stage);
        frame = findViewById(R.id.frame_anchor);
        shutter = findViewById(R.id.shutter_row);
        shutterBox = findViewById(R.id.shutter_box);
        bottomRow = findViewById(R.id.bottom_row);
        modeSwitch = findViewById(R.id.mode_switch);
        lenses = findViewById(R.id.lens_strip);
        grabber = findViewById(R.id.more_button);
        sheetHandle = findViewById(R.id.settings_sheet_handle_slot);
        preview = findViewById(R.id.texture);
        if (isInEditMode()) {
            CameraFragment.preparePreviewLayout(this);
        } else {
            ViewCompat.setOnApplyWindowInsetsListener(this, (view, insets) -> {
                Insets safe = insets.getInsets(WindowInsetsCompat.Type.systemBars() | WindowInsetsCompat.Type.displayCutout());
                if (getPaddingLeft() != safe.left || getPaddingTop() != safe.top
                        || getPaddingRight() != safe.right || getPaddingBottom() != safe.bottom) {
                    setPadding(safe.left, safe.top, safe.right, safe.bottom);
                }
                return insets;
            });
        }
    }

    @Override
    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        super.onMeasure(widthMeasureSpec, heightMeasureSpec);
        if (frame == null || preview == null) return;

        LayoutParams anchor = (LayoutParams) frame.getLayoutParams();
        int width = stage.getMeasuredWidth();
        // The first pass may already have clipped the shutter row to the room below the preview.
        int minShutter = shutterBox.getLayoutParams().width + modeSwitch.getLayoutParams().height
                + ((ViewGroup.MarginLayoutParams) bottomRow.getLayoutParams()).topMargin;
        int controls = Math.max(shutter.getMeasuredHeight(), minShutter)
                + grabber.getLayoutParams().height + sheetHandle.getLayoutParams().height;
        if (lenses.getVisibility() != GONE) {
            controls += lenses.getMeasuredHeight() + ((ViewGroup.MarginLayoutParams) lenses.getLayoutParams()).bottomMargin;
            controls += Math.round(com.scamera.app.ui.camera.views.BottomChrome.CLEARANCE_DP * getResources().getDisplayMetrics().density);
        }
        int limit = compactPreviewHeight(width, stage.getMeasuredHeight(), controls, anchor.dimensionRatio);
        // The wide preview extends under the bottom bar. Reserve room for the controls via the anchor.
        boolean remeasure = preview.setHeightLimit(preview.usesWideAspect() ? 0 : limit);
        if (anchor.height != limit) {
            anchor.height = limit;
            frame.requestLayout();
            remeasure = true;
        }
        if (remeasure) super.onMeasure(widthMeasureSpec, heightMeasureSpec);
    }

    /** Zero keeps the normal anchor and preview geometry. */
    static int compactPreviewHeight(int width, int height, int controls, @Nullable String ratio) {
        if (width <= 0 || height <= 0 || ratio == null) return 0;
        int available = Math.max(1, height - controls);
        final float aspect;
        final int separator = ratio.indexOf(':');
        try {
            aspect = separator < 0 ? Float.parseFloat(ratio)
                    : Float.parseFloat(ratio.substring(0, separator)) / Float.parseFloat(ratio.substring(separator + 1));
        } catch (NumberFormatException invalid) {
            return 0;
        }
        return aspect > 0 && Math.round(width / aspect) > available ? available : 0;
    }
}
