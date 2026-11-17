# SCAMERA iOS changes

English copy of ios/CHANGELOG.md; the build post carries both, section for section (same version, same place).

## 0.3.7 — Android updates
- The merge and processing as Android's of 17.11: less ghosting in motion, «Why тон» V2 by default, detail in a bright window.
- «Шумоподавление и склейка»: the motion SNR curve and adaptive «Слияние светов».
- RAW (DNG) in full colour at the chosen «Разрешение» 1× / 1.5× / 2×.

## 0.3.6 — fixes
- iPhone 15 Pro: no more green / black bands at the photo's edge and no pink highlights.
- ProRAW is taken at 48 MP with «Детально · 48 Мп».
- «Включить логирование» and keeping RAW series work; «СкаМастер» as on Android, the style shows in the viewfinder.
- The merge no longer fails when the app goes to the background with a shot queued.

## 0.3.5 — the shot at the press
- The shot is built on the frames at the press, not at the series' end: moving the camera during the capture keeps what was aimed at.
- Lens vignetting is corrected from the camera's data.

## 0.3.4 — capture fixes
- «Спорт»: the shutter is again no longer than the one set (with «Мерцание ламп: Авто» it was rounded to 1/100).
- The exposure no longer changes in the middle of a series; the series no longer hangs for seconds.

## 0.3.3 — capture as on Android
- The series' normal frames are single auto-exposure requests (the system may serve them with zero shutter lag) and are selected as on Android; the focus holds during the series.
- «Auto» lamp flicker follows the region; the camera remembers the ISO and shutter the lens really gives.

## 0.3.2 — speed
- Faster merge and processing with the same result; the first shots after launch no longer wait for the warm-up.
- Less memory per series; the camera no longer stutters while saving.

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
