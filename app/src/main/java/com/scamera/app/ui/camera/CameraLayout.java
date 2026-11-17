package com.scamera.app.ui.camera;

import android.content.Context;
import android.graphics.Rect;
import android.util.AttributeSet;
import android.view.View;
import android.view.ViewGroup;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.constraintlayout.widget.ConstraintLayout;
import androidx.core.graphics.Insets;
import androidx.core.view.DisplayCutoutCompat;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;

import com.scamera.app.R;
import com.scamera.app.ui.camera.views.BottomChrome;
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
    private View stage, topRow, frame, shutter, shutterBox, bottomRow, modeSwitch, lenses, grabber, sheetHandle;
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
        topRow = findViewById(R.id.top_row);
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
            final int gripWidth = findViewById(R.id.top_row_grabber).getLayoutParams().width;
            ViewCompat.setOnApplyWindowInsetsListener(this, (view, insets) -> {
                Insets safe = insets.getInsets(WindowInsetsCompat.Type.systemBars() | WindowInsetsCompat.Type.displayCutout());
                int top = insets.getInsets(WindowInsetsCompat.Type.systemBars()).top;
                // A small camera hole fits in the immersive top chrome. A wide notch needs space above the row.
                DisplayCutoutCompat cutout = insets.getDisplayCutout();
                if (cutout != null && top < safe.top) {
                    for (Rect bounds : cutout.getBoundingRects()) {
                        if (bounds.top < safe.top && bounds.width() >= gripWidth) {
                            top = safe.top;
                            break;
                        }
                    }
                }
                if (getPaddingLeft() != safe.left || getPaddingTop() != top
                        || getPaddingRight() != safe.right || getPaddingBottom() != safe.bottom) {
                    setPadding(safe.left, top, safe.right, safe.bottom);
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
        final int width = getMeasuredWidth() - getPaddingLeft() - getPaddingRight();
        final int height = getMeasuredHeight() - getPaddingTop() - getPaddingBottom();
        // The first pass may already have clipped the shutter row to the room below the preview.
        int minShutter = shutterBox.getLayoutParams().width + modeSwitch.getLayoutParams().height
                + ((ViewGroup.MarginLayoutParams) bottomRow.getLayoutParams()).topMargin;
        int fixedControls = Math.max(shutter.getMeasuredHeight(), minShutter) + grabber.getLayoutParams().height;
        int handleRoom = sheetHandle.getLayoutParams().height;
        if (lenses.getVisibility() != GONE) {
            fixedControls += lenses.getMeasuredHeight() + ((ViewGroup.MarginLayoutParams) lenses.getLayoutParams()).bottomMargin;
            handleRoom += Math.round(BottomChrome.CLEARANCE_DP * getResources().getDisplayMetrics().density);
        }
        final int controls = fixedControls + handleRoom;
        final int stageHeight = stage.getMeasuredHeight();
        final int column = wideWindow(width, height) ? cameraColumnWidth(width, stageHeight, controls,
                com.scamera.app.circularbarlib.ui.UiScale.dp(getContext(), 360)) : 0;
        final ViewGroup.LayoutParams stageParams = stage.getLayoutParams(), topParams = topRow.getLayoutParams();
        final boolean columnChanged = stageParams.width != column || topParams.width != column;
        if (columnChanged) {
            stageParams.width = topParams.width = column;
            stage.requestLayout();
            topRow.requestLayout();
        }
        // Keep the full preview when the fixed rows fit. BottomChrome can float the sheet handle in that case.
        final int previewWidth = column > 0 ? column : width;
        final int limit = compactAnchorHeight(previewWidth, stageHeight, fixedControls, anchor.dimensionRatio) == 0
                ? 0 : compactAnchorHeight(previewWidth, stageHeight, controls, anchor.dimensionRatio);
        final boolean previewChanged = preview.setHeightLimit(limit);
        final boolean anchorChanged = anchor.height != limit;
        if (anchorChanged) {
            anchor.height = limit;
            frame.requestLayout();
        }
        if (columnChanged || anchorChanged || previewChanged) super.onMeasure(widthMeasureSpec, heightMeasureSpec);
    }

    /** A 3:4 preview alone would be taller than the window at full width. */
    static boolean wideWindow(int width, int height) {
        return width > 0 && height > 0 && (long) width * 4 > (long) height * 3;
    }

    /** Fit the 3:4 camera column to the room above the controls. Zero keeps the full width. */
    static int cameraColumnWidth(int width, int stageHeight, int controls, int minimum) {
        // Controls keep enough width on a short window, where they can partly overlap the preview.
        final int fitted = (int) (Math.max(0, stageHeight - controls) * 3L / 4);
        final int column = Math.max(fitted, minimum);
        return column < width ? column : 0;
    }

    /** Zero keeps the anchor's normal constraint; a positive value gives the controls the room they need. */
    static int compactAnchorHeight(int width, int height, int controls, @Nullable String ratio) {
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
