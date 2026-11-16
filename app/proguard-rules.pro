# SCAMERA R8 shrinking and obfuscation. Keep the names used by reflection, JNI and saved data.
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod,SourceFile,LineNumberTable

# The settings annotations and the classes that read them by reflection. A class with fields annotated @Tunable / @SensorConfig
# keeps them (their names are the preference keys) and keeps itself (TunableInjector / SensorConfigInjector key them by the
# class's simple name: it must not be merged into another class). P662: was "-keep class * { ... }", which kept every class.
-keep class com.scamera.app.settings.annotations.** { *; }
-keepclasseswithmembers class * { @com.scamera.app.settings.annotations.Tunable <fields>; }
-keepclasseswithmembers class * { @com.scamera.app.settings.annotations.SensorConfig <fields>; }
-keepclassmembers class * { @com.scamera.app.settings.annotations.** <fields>; }
-keep class com.scamera.app.settings.TunableInjector,
            com.scamera.app.settings.TunablePreferenceGenerator,
            com.scamera.app.settings.TunablePreferenceGenerator$*,
            com.scamera.app.settings.TunableSettingsManager,
            com.scamera.app.settings.SettingsManagerExtensions,
            com.scamera.app.settings.TunableKeyManager,
            com.scamera.app.settings.SensorConfigInjector,
            com.scamera.app.settings.SensorConfigPreferenceGenerator,
            com.scamera.app.settings.SensorConfigPreferenceGenerator$*,
            com.scamera.app.settings.SensorConfigRegistry,
            com.scamera.app.settings.TunableRegistry,
            com.scamera.app.settings.FieldSpec,
            com.scamera.app.settings.SessionKeys { *; }
-keep class com.scamera.app.ui.settings.custompreferences.TunableSeekBarPreference,
            com.scamera.app.ui.settings.custompreferences.TunableKeyPreference,
            com.scamera.app.ui.settings.custompreferences.TunableKeyDialog { *; }
# PreferenceInflater loads custom preference tags from XML.
-keep class com.scamera.app.ui.settings.custompreferences.** extends androidx.preference.Preference {
    public <init>(android.content.Context, android.util.AttributeSet);
}

# GSON models (fields by name or @SerializedName, made without a constructor call): vendor tag lists and the lens table.
-keep class com.scamera.app.api.VendorTagUtils,
            com.scamera.app.api.VendorTagUtils$TunableKey { *; }
-keep class com.scamera.app.ui.camera.data.CameraLensData { *; }
-keepclassmembers,allowobfuscation class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
-keep class * extends com.google.gson.reflect.TypeToken

# The lab's parameter record: every instance field is written to and read from its JSON by reflection (ScamLabParams).
-keepclassmembers class com.scamera.app.processing.render.Parameters { <fields>; }

# Serializable (SettingsSearchFragment.Entry in a Bundle): the standard members.
-keepnames class com.scamera.app.ui.settings.SettingsSearchFragment$Entry
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
    <fields>;
}

# Classes a library instantiates from a Class object (newInstance): the gallery's region decoder (ImageAdapter ->
# SubsamplingScaleImageView.setRegionDecoderClass; R8 saw no "new" and removed its constructor and methods).
-keep class * implements com.davemorrissey.labs.subscaleview.decoder.ImageRegionDecoder { <init>(...); *; }
-keep class * implements com.davemorrissey.labs.subscaleview.decoder.ImageDecoder { <init>(...); *; }

# Navigation instantiates destinations by the names stored in gallery_nav_graph.xml.
-keep class com.scamera.app.gallery.ui.fragments.ImageViewerFragment,
            com.scamera.app.gallery.ui.fragments.ImageLibraryFragment,
            com.scamera.app.gallery.ui.fragments.ImageCompareFragment,
            com.scamera.app.gallery.editor.PhotoEditorFragment { public <init>(); }

# JNI: every class with native methods keeps its name and those methods (the C++ side is bound by Java_<class>_<method>).
-keepclasseswithmembers,includedescriptorclasses class * {
    native <methods>;
}
# The OCR runtime's native code calls back into its Java classes (TessBaseAPI.onProgressValues, fields read from C++); its AAR
# carries no rules.
-keep class com.googlecode.tesseract.android.** { *; }
-keep class com.googlecode.leptonica.android.** { *; }

# The lab activity is kept whole.
-keep class com.scamera.app.ui.settings.ScamActivity { *; }

# P582: the base theme names it in viewInflaterClass; AppCompat makes it by reflection.
-keep class com.scamera.app.ui.style.ConceptViewInflater { <init>(); }

# A commons-lang class a dependency refers to but never loads here.
-dontwarn org.apache.commons.lang.functor.Predicate
