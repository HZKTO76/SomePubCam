# SCAMERA iOS

## 0.3.1 — fixes
- «Быстрый» merge on iPhone and iPad now matches Android (night shots were noisy).
- iPad: no more black / green photos from a shaken series.
- App icon: the SCAMERA camera in the iOS style.
- SHDR at 1.5x / 2x zoom works; the size badge shows «Разрешение» 1.5x / 2x.
- iPad: portrait screen, upright controls when the window turns; vignetting calibration for lenses without a lens map.
- Long bracket frame really brighter (shutter, not ISO); ETTR works.
- DCP colour profiles, noise model profiles, «Чёрный из данных», the fringe net («Нейросеть») and the lab (merge the last series again).
- Ultrashort frames and highlight recovery work on iPhone / iPad (white level from the frame, as on Android).
- Faster processing: whole-frame GPU passes, cached shader translations, frames written during capture.
- «Стиль» Vivid / Normal / Neutral; «Проявка» of any DNG; RAW series and processing stages can be kept.
- Settings apply at once; options the iPhone cannot use are hidden; 16:9 viewfinder frame.

## 0.3 — Android updates of 2026-11-14
- iPad: a native iPad app - full-screen camera, wider gallery grids, settings and editor sized for the tablet.
- Noise reduction keeps shadow texture; tone V1 noise, detail and colour as tone V2; V2 without glow beside dark objects.
- Night merge handles moving objects better.
- Gallery editor: the «Develop» tab develops SCAMERA DNGs again with every processing setting of the camera.
- RAW saved with an SHDR shot is now the merged burst DNG, as on Android, with the photo as its preview.
- Camera screen as on Android: LUT tray and swipe, quick settings, inline Pro panel, editable top row, face and subject tracking.
- Settings as on Android: search, help on a long press, exact values, layout, accent, photo names, modules, developer page, LUT previews.
- Gallery as on Android: Grid / List / Timeline, search by the text on photos, full-resolution zoom, HDR, background and picture-in-picture video, Roboto Flex.

## 0.2 — the Android photo processing
- SHDR photos are processed exactly as on Android: the same merge, denoise, sharpening and «Why» tone.

## 0.1 — SHDR on the iPhone
- «SHDR» button: a RAW series merged on the GPU by the same merge as on Android, then the «Why» tone.

## 0.1 — «Why» tone on the GPU
- With RAW on, the photo gets the «Why» V2 tone rendered on the GPU (button «Why»).

## 0.1 — first build
- Camera with lens modules (including in-sensor zoom), full resolution and RAW (Bayer / ProRAW) saved next to the HEIC.
- Session log with sharing from the camera screen.
