package com.scamera.app.ui.settings.custompreferences;

import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.util.AttributeSet;
import android.view.View;
import android.widget.FrameLayout;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.preference.Preference;
import androidx.preference.PreferenceViewHolder;

import com.scamera.app.R;
import com.scamera.app.settings.PreferenceKeys;
import com.scamera.app.ui.settings.SettingsStyle;

/** Preview of the SNR curve edited by the sliders on the same page. */
public final class MotionDenoiseCurvePreference extends Preference
        implements SharedPreferences.OnSharedPreferenceChangeListener {
    @Nullable private CurveGraph graph;

    public MotionDenoiseCurvePreference(Context context, AttributeSet attrs) {
        super(context, attrs);
        setLayoutResource(R.layout.preference_motion_denoise_curve);
        setPersistent(false);
        setSelectable(false);
    }

    @Override
    public void onAttached() {
        super.onAttached();
        SharedPreferences prefs = getSharedPreferences();
        if (prefs != null) prefs.registerOnSharedPreferenceChangeListener(this);
    }

    @Override
    public void onDetached() {
        SharedPreferences prefs = getSharedPreferences();
        if (prefs != null) prefs.unregisterOnSharedPreferenceChangeListener(this);
        graph = null;
        super.onDetached();
    }

    @Override
    public void onSharedPreferenceChanged(SharedPreferences prefs, @Nullable String key) {
        if (graph != null && (key == null || key.startsWith(
                PreferenceKeys.HYBRID_PREFIX + PreferenceKeys.FAST_MOTION_DENOISE_PREFIX))) {
            graph.refresh();
        }
    }

    @Override
    public void onBindViewHolder(@NonNull PreferenceViewHolder holder) {
        super.onBindViewHolder(holder);
        View container = holder.findViewById(R.id.motion_denoise_curve_host);
        if (!(container instanceof FrameLayout)) container = holder.itemView;
        if (!(container instanceof FrameLayout)) {
            graph = null;
            return;
        }
        FrameLayout host = (FrameLayout) container;
        View child = host.getChildAt(0);
        if (child instanceof CurveGraph) {
            graph = (CurveGraph) child;
        } else {
            graph = new CurveGraph(host.getContext());
            host.addView(graph, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        }
        graph.setAlpha(isEnabled() ? 1f : 0.45f);
        graph.refresh();
    }

    private static final class CurveGraph extends View {
        private final float[] strengths = new float[PreferenceKeys.fastMotionDenoisePoints()];
        private final float[] positions = new float[strengths.length];
        private final String[] labels = new String[strengths.length];
        private final Path curve = new Path();
        private final Paint grid = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint line = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint dot = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint text = new Paint(Paint.ANTI_ALIAS_FLAG);

        CurveGraph(Context context) {
            super(context);
            final int accent = SettingsStyle.accent(context);
            grid.setColor(SettingsStyle.HAIRLINE);
            grid.setStrokeWidth(dp(1));
            line.setColor(accent);
            line.setStyle(Paint.Style.STROKE);
            line.setStrokeWidth(dp(2));
            line.setStrokeCap(Paint.Cap.ROUND);
            line.setStrokeJoin(Paint.Join.ROUND);
            dot.setColor(accent);
            text.setColor(SettingsStyle.SECTION);
            text.setTextSize(dp(11));
            final double first = PreferenceKeys.fastMotionDenoiseSnr(0);
            final double range = Math.log(PreferenceKeys.fastMotionDenoiseSnr(labels.length - 1) / first);
            for (int i = 0; i < labels.length; i++) {
                final int snr = PreferenceKeys.fastMotionDenoiseSnr(i);
                labels[i] = Integer.toString(snr);
                // Ratios of logarithms give normalized log2 positions, matching the merge.
                positions[i] = (float) (Math.log(snr / first) / range);
            }
            setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
        }

        void refresh() {
            for (int i = 0; i < strengths.length; i++) {
                strengths[i] = PreferenceKeys.fastMotionDenoisePercent(i) * 0.01f;
            }
            invalidate();
        }

        private float dp(float value) { return value * getResources().getDisplayMetrics().density; }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            text.setTextAlign(Paint.Align.RIGHT);
            final float left = dp(16) + text.measureText("100%");
            final float right = getWidth() - dp(18);
            final float top = dp(16);
            final float bottom = getHeight() - dp(38);
            if (left >= right || top >= bottom) return;
            canvas.drawText("100%", left - dp(6), top - (text.ascent() + text.descent()) / 2, text);
            canvas.drawText("0%", left - dp(6), bottom - (text.ascent() + text.descent()) / 2, text);
            for (int i = 0; i <= 4; i++) {
                final float y = top + (bottom - top) * i / 4f;
                canvas.drawLine(left, y, right, y, grid);
            }
            text.setTextAlign(Paint.Align.CENTER);
            final float width = right - left;
            final float labelGap = dp(3);
            float labelRowEnd = Float.NEGATIVE_INFINITY;
            float lowerLabelRowEnd = Float.NEGATIVE_INFINITY;
            curve.reset();
            for (int i = 0; i < strengths.length; i++) {
                final float x = left + positions[i] * width;
                final float y = bottom - (bottom - top) * strengths[i];
                canvas.drawLine(x, top, x, bottom, grid);
                final float halfLabel = 0.5f * text.measureText(labels[i]);
                if (x - halfLabel >= labelRowEnd + labelGap) {
                    canvas.drawText(labels[i], x, bottom + dp(16), text);
                    labelRowEnd = x + halfLabel;
                } else if (x - halfLabel >= lowerLabelRowEnd + labelGap) {
                    canvas.drawText(labels[i], x, bottom + dp(30), text);
                    lowerLabelRowEnd = x + halfLabel;
                }
                if (i == 0) curve.moveTo(x, y);
                else curve.lineTo(x, y);
            }
            canvas.drawPath(curve, line);
            for (int i = 0; i < strengths.length; i++) {
                canvas.drawCircle(left + positions[i] * width, bottom - (bottom - top) * strengths[i], dp(3), dot);
            }
        }
    }
}
