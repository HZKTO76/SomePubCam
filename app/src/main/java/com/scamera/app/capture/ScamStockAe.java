package com.scamera.app.capture;

import android.hardware.camera2.*;
import android.os.SystemClock;
import com.scamera.app.processing.ImageFrame;
import com.scamera.app.util.Lang;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

public final class ScamStockAe {
    private ScamStockAe() {}

    private static final CaptureResult.Key<float[]> AEC=new CaptureResult.Key<>("vivo.control.Vivo3rdAlgoAECFrameControl",float[].class);

    public static final class Plan {
        public final long frameId,timestamp;final long received;public final int generation;
        public final String sceneDescription;
        private final long[] shutter=new long[4];private final int[] iso=new int[4];private final double[] product=new double[4];
        private final float[] gain=new float[4];
        private boolean degenerate;
        /** Built by the SCAMERA planner: verified against Camera2 exposure/ISO, not vivo AE tags. */
        private boolean camera2Domain;
        /**
         * The sensor cannot expose an L at or above N (the ISZ tele at night: the vendor AE runs N at a gain far above the
         * Camera2 sensitivity range, the longest shutter at the top ISO stays darker than N). L is left at the sensor
         * maximum and the capture builds the long frame from the ZSL N frames with {@link #longRatio()} instead.
         */
        public boolean longBeyondSensor;
        private double longTarget;
        Plan(byte[] data,ScamAeContext scamContext,long frameId,long timestamp,long received,int generation)throws IOException {
            if(scamContext==null)throw new IOException(Lang.t("SCAM HDR AE: контекст сцены не проверен","SCAM HDR AE: scene context not verified"));
            sceneDescription=scamContext.describe();
            this.frameId=frameId;this.timestamp=timestamp;this.received=received;this.generation=generation;
            ByteBuffer p=ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN);
            for(int i=0;i<4;i++) {
                float ns=p.getFloat(i*16),gain=p.getFloat(i*16+4);
                if(!Float.isFinite(ns)||!Float.isFinite(gain)||ns<=0||gain<=0)throw new IOException("Invalid stock exposure");
                shutter[i]=Math.round((double)ns);iso[i]=(int)Math.round((double)gain*50.);product[i]=(double)ns*gain;
                this.gain[i]=gain;
            }
            // Bright or flat scenes: the stock solver may return S/ES equal to
            // each other or to N. Kept, and repaired at capture time against
            // the sensor limits (withDistinctBracket); not a reason to drop the frame.
            degenerate=!(product[2]<product[1]&&product[1]<product[0]&&product[0]<=product[3]);
        }
        private Plan(Plan base) {
            frameId=base.frameId;timestamp=base.timestamp;received=base.received;generation=base.generation;
            sceneDescription=base.sceneDescription;degenerate=base.degenerate;camera2Domain=base.camera2Domain;
            longBeyondSensor=base.longBeyondSensor;longTarget=base.longTarget;
            System.arraycopy(base.shutter,0,shutter,0,4);System.arraycopy(base.iso,0,iso,0,4);
            System.arraycopy(base.product,0,product,0,4);System.arraycopy(base.gain,0,gain,0,4);
        }
        /** Handheld cap for the lengthened L; a longer stock L is never shortened. */
        private static final long LONG_BOOST_SHUTTER_CAP_NS=125_000_000L;
        /**
         * Copy with L (slot 3) lengthened by ev: shutter first up to
         * max(stock L, 1/8 s), the rest as gain within the sensor range.
         * Verification then checks the capture against these new values.
         */
        private static final double BRACKET_STEP=0.5; // -1 EV between N, S and ES when repairing
        private static final double DISTINCT=0.97;
        private Plan(long timestamp,int generation,String description) {
            frameId=-1;this.timestamp=timestamp;received=SystemClock.elapsedRealtimeNanos();this.generation=generation;
            sceneDescription=description;camera2Domain=true;
        }
        /**
         * P27: the Hybrid's plan holder. The Hybrid only reads N from it (frame time, gyro, AE restore); it never runs the SCAM
         * HDR S/ES/L planner, whose throws (bright scene, missing ranges, L beyond the sensor) cost Hybrid shots before.
         */
        public static Plan nOnly(long nShutter,int nIso,long timestamp,int generation) {
            if(nShutter<=0||nIso<=0)throw new IllegalStateException(Lang.t("Hybrid: нет экспозиции N","Hybrid: no N exposure"));
            Plan p=new Plan(timestamp,generation,"planner=HYBRID_N");
            for(int i=0;i<4;i++){p.shutter[i]=nShutter;p.iso[i]=nIso;p.gain[i]=nIso/50f;p.product[i]=(double)nShutter*nIso/50;}
            return p;
        }
        /** L exposure over N (products), as planned. */
        public double longRatio(){return longBeyondSensor&&longTarget>0?longTarget/product[0]:product[3]/product[0];}
        private static int slot(int index){if(index<0||index>=7)throw new IllegalArgumentException("SCAM request index");return index<4?0:index==4?3:index==5?1:2;}
        public long shutter(int index){return shutter[slot(index)];}
        public int iso(int index){return iso[slot(index)];}
        public ImageFrame.CaptureRole role(int index){return index<4?ImageFrame.CaptureRole.NORMAL:index==4?ImageFrame.CaptureRole.LONG:index==5?ImageFrame.CaptureRole.SHORT:ImageFrame.CaptureRole.EXTRA_SHORT;}
        // The vendor analog-gain domain is converted to Camera2 ISO with a fixed
        // gain*50 rounding (see the Plan constructor). That rounding can place a
        // value one or two units beyond the device's exposed SENSITIVITY_RANGE
        // even though the underlying vendor gain is genuinely at the sensor's
        // floor/ceiling. Only that specific rounding margin is clamped; a larger
        // gap (like a mismatched gain-domain conversion) must keep failing loudly.
        private static final int ISO_ROUNDING_TOLERANCE=2;
        private static final long SHUTTER_ROUNDING_TOLERANCE_NS=100_000L;
        private static long clampNear(long value,long lower,long upper,long tolerance,String what) {
            if(value<lower) {
                if(lower-value>tolerance)throw new IllegalStateException(Lang.t("Стоковая экспозиция вне диапазона Camera2: ","Stock exposure outside the Camera2 range: ")+what);
                return lower;
            }
            if(value>upper) {
                if(value-upper>tolerance)throw new IllegalStateException(Lang.t("Стоковая экспозиция вне диапазона Camera2: ","Stock exposure outside the Camera2 range: ")+what);
                return upper;
            }
            return value;
        }
        public void apply(CaptureRequest.Builder builder,int index,CameraCharacteristics characteristics) {
            int slot=slot(index);
            android.util.Range<Long> times=com.scamera.app.api.SafeRanges.get(characteristics, CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE);
            android.util.Range<Integer> gains=com.scamera.app.api.SafeRanges.get(characteristics, CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE);
            if(times==null||gains==null)throw new IllegalStateException(Lang.t("Стоковая экспозиция вне диапазона Camera2: диапазон недоступен","Stock exposure outside the Camera2 range: range unavailable"));
            long clampedShutter=clampNear(shutter[slot],times.getLower(),times.getUpper(),SHUTTER_ROUNDING_TOLERANCE_NS,Lang.t("выдержка","shutter"));
            int clampedIso=(int)clampNear(iso[slot],gains.getLower(),gains.getUpper(),ISO_ROUNDING_TOLERANCE,"ISO");
            builder.set(CaptureRequest.CONTROL_AE_MODE,CaptureRequest.CONTROL_AE_MODE_OFF);
            builder.set(CaptureRequest.CONTROL_AE_LOCK,false);builder.set(CaptureRequest.CONTROL_ENABLE_ZSL,false);
            builder.set(CaptureRequest.SENSOR_EXPOSURE_TIME,clampedShutter);builder.set(CaptureRequest.SENSOR_SENSITIVITY,clampedIso);
        }
        public void verify(CaptureRequest request,TotalCaptureResult result) {
            ImageFrame.ScamCaptureTag tag=(ImageFrame.ScamCaptureTag)request.getTag();
            int slot;
            switch(tag.role) {
                case NORMAL:slot=0;break;
                case SHORT:slot=1;break;
                case EXTRA_SHORT:slot=2;break;
                case LONG:slot=3;break;
                default:throw new IllegalStateException(Lang.t("SCAM HDR: неизвестная роль RAW","SCAM HDR: unknown RAW role"));
            }
            verifyExposure(result,slot,BRACKET_TOLERANCE_EV);
        }
        public void verifyZslNormal(CaptureResult result,long shutterTimestamp) {
            Long timestamp=result==null?null:result.get(CaptureResult.SENSOR_TIMESTAMP);
            if(timestamp==null || timestamp<=0 || timestamp>shutterTimestamp)
                throw new IllegalStateException(Lang.t("SCAM HDR ZSL: RAW не предшествует нажатию","SCAM HDR ZSL: the RAW does not precede the shutter press"));
            verifyExposure(result,0,ZSL_TOLERANCE_EV);
        }
        /**
         * Bracket frames (L/S/ES): below ~0.2 ms the sensor quantizes the shutter to
         * lines and makes up the rest with gain (e.g. 43 us ISO 72 -> ISO 86), so the
         * split and a few tenths of an EV of the product differ from the plan. The
         * pipeline uses the measured exposure, so only a frame that is clearly not
         * the requested one (another AE state) is rejected.
         */
        private static final double BRACKET_TOLERANCE_EV=0.4;
        /**
         * ZSL N: the preview AE and the plan can split the same product differently
         * (gain 1.458 vs 1.43 with a 2% shorter shutter, 0.00 EV). Rejecting those
         * threw away all 20 buffered RAWs and re-shot N after the press (+0.5 s).
         */
        private static final double ZSL_TOLERANCE_EV=0.05;
        private void verifyExposure(CaptureResult result,int slot,double tolerance) {
            if(camera2Domain) {
                Long ns=result.get(CaptureResult.SENSOR_EXPOSURE_TIME);Integer sensitivity=result.get(CaptureResult.SENSOR_SENSITIVITY);
                if(ns==null||sensitivity==null||ns<=0||sensitivity<=0)throw new IllegalStateException(Lang.t("SCAM HDR: нет экспозиции Camera2 в результате","SCAM HDR: no Camera2 exposure in the result"));
                boolean exact=Math.abs((double)ns/shutter[slot]-1.)<=.015 && Math.abs(sensitivity-iso[slot])<=Math.max(2,iso[slot]*.015);
                if(exact)return;
                double ev=Math.abs(Math.log((double)ns*sensitivity/((double)shutter[slot]*iso[slot]))/Math.log(2));
                String detail=" (slot "+slot+": ISO "+sensitivity+"/"+iso[slot]+", shutter "+ns+"/"+shutter[slot]
                        +String.format(java.util.Locale.ROOT,", %.2f EV)",ev);
                if(ev>tolerance)
                    throw new IllegalStateException((com.scamera.app.settings.PreferenceKeys.isHybridShot()?"Hybrid":"SCAM HDR")+Lang.t(": выдержка/ISO RAW не совпали с планом SomeCam",": RAW shutter/ISO do not match the SomeCam plan")+detail);
                android.util.Log.w("SCAM_CAPTURE","sensor rounding accepted"+detail);
                return;
            }
            float[] aec=result.get(AEC);
            if(aec==null||aec.length<35||!Float.isFinite(aec[2])||!Float.isFinite(aec[14])||aec[2]<=0||aec[14]<=0)
                throw new IllegalStateException(Lang.t("SCAM HDR: измеренный vendor gain отсутствует","SCAM HDR: measured vendor gain missing"));
            double actual=(double)aec[2]*aec[14];
            boolean exact=Math.abs(actual/product[slot]-1.)<=.015 && Math.abs((double)aec[2]/gain[slot]-1.)<=.015
                    && Math.abs((double)aec[14]/shutter[slot]-1.)<=.015;
            if(exact)return;
            double ev=Math.abs(Math.log(actual/product[slot])/Math.log(2));
            String detail=" (slot "+slot+": gain "+aec[2]+"/"+gain[slot]+", shutter "+aec[14]+"/"+shutter[slot]
                    +String.format(java.util.Locale.ROOT,", %.2f EV)",ev);
            if(ev>tolerance)
                throw new IllegalStateException(Lang.t("SCAM HDR: выдержка/gain RAW не совпали со стоковым планом","SCAM HDR: RAW shutter/gain do not match the stock plan")+detail);
            android.util.Log.w("SCAM_CAPTURE","sensor rounding accepted"+detail);
        }
    }
}
