# iOS speed / memory plan (2026-11-15)

Gate for every change (ios/tools/image_metrics.cpp, CI ios-post-check): SSIM >= 0.995, PSNR >= 45 dB, mean dE2000 <= 1.0,
max dE2000 <= 3.0, banding <= x1.05 against the reference; changes below are meant bit-identical (host Mesa: 0 values differ;
CI: Metal replay vs Mesa, the post port vs the Android pipeline). Timing: os_signpost category PERF (Perf.swift), XCTest
PerfTests (clock / CPU / memory, CI simulator), the session log's stage lines.

Measurement limits: no device, no Instruments here. Device numbers come from the owner's iPad M1 logs (builds before
deae98b3); new device numbers only from the next log. The CI macOS runner (paravirtual GPU) gives relative merge times only.

## Baseline (iPad M1 logs of 2026-11-14; shot 2 = no warm-up running)
| Stage | Numbers |
|---|---|
| Burst capture (23 frames) | 1.9-2.4 s; requests 8/8/4/3: 561-761 / 344 / 305-326 ms; ~0.44 s of gaps between requests |
| NCH write | 0.74-0.80 s (now streamed during the capture: deae98b3) |
| Fast merge | 1.46 s (shot 2) / 2.05-3.25 s (warm-up running); front (thumbnails) 25 vs 541-577 ms; uploads 944-1065 ms |
| Quality merge | 5.0 s (align 2.0 s, GPU pace waits 2.1 s: gpuPace 0 since) |
| Post | 1.57 s (157 kept programs) / 2.8-4.4 s (programs still learned) |
| Library save | 0.1 s; ~3 s for the first save of a launch (scene inactive: the system's limited-library alert) |
| Warm-up | 9.7-11.2 s every launch (translations cached since deae98b3) |
| Peak RAM | 1716 MB (the 547 MB Swift planes stay alive through merge, post, encode, save) |
| Swift CPU stats (host, 12 MP) | RawWhite.histogram 1.4 ms, blackFloor 1.0 ms, FrameMeasure 0.4 ms: not worth changing |

## Findings (audit 2026-11-15), by gain / risk
| # | File:function | Problem | Evidence | Expected gain | Output | Batch |
|---|---|---|---|---|---|---|
| 1 | ScamGL.mm glMapBufferRange / glReadPixels | a read map / readback waits for every command buffer, holding gLock | KLT 38-46 ms first frames, then 140-319; "first readback waited 310 ms" | quality align 0.2-0.6 s; fast merge 40-100 ms | none | 1 |
| 2 | ScamGL.mm link + scamgl_warm_programs | compile under the global gLock: a shot's GL calls wait behind the warm-up | merge 2.05-3.25 s with the warm-up vs 1.46 s | 0.6-1.8 s on shots in the first ~10 s | none | 1 |
| 3 | ScamGL.mm glBufferSubData / glTexSubImage | a new MTLBuffer per upload while work is in flight (LaGpu 24 MB per frame) | code | 0.1-0.4 s quality route | none | 1 |
| 4 | NCH page-ins (ShotRun / HybridSelect / fast merge thumbnails, uploads) | the frames are re-read from flash after the capture | front 25 ms vs 541-577 ms for the same work | up to ~0.5 s (cold shots) | none | 2 |
| 5 | CameraModel / BurstProcessor | 547 MB Swift planes alive during the whole processing | memory 1716 MB | peak -547 MB | none | 2 |
| 6 | FirstRunCompile / ScamWarmUp | warm-up at background QoS holding processLock; a shot waits | as 2 | with 2 | none | 1 |
| 7 | scam-pool.h thread team QoS (shared) | the team inherits its creator's QoS (the background warm-up) | code | if it triggers: CPU passes at background QoS | none | 1 |
| 8 | Recipes / render pipeline states | post programs learned at shot time; render pipeline states made at the first draw | post 4.4 / 2.8 / 1.57 s | 1.2-2.8 s of post on the first shots after install | none | 3 |
| 9 | ScamShot.mm / MergeStamp / PhotoWatermark | 2-3 extra 48 MB copies of the RGBA (+ the DNG) | code | 15-40 ms, -100 MB transient | none | 4 |
| 10 | LinearExposure readback (Ultra HDR) | RGBA16F read as float, converted twice on the CPU | code | 150-300 ms with Ultra HDR | none | 4 |
| 11 | PhotoEncoding heif10 | a CIContext per shot | code | 50-200 ms with HEIC 10 bit | none | 4 |
| 12 | CameraModel main-actor work | DNG write, RAW-only thumbnail / Data(contentsOf:), camera-route thumbnails on main | code | 20-150 ms UI hitches | none | 4 |
| 13 | SettingsCatalog first parse on main | 0.9 MB JSON decoded at the first shade / settings open | code | one 50-150 ms hitch | none | 4 |
| 14 | ManualPanel / DeviceHud | the collapsed panel rebuilt ~6.7 /s from the HUD sample | code | small main-thread time, energy | none | 4 |
| 15 | ShotTransport writeTransport | the zoom crop rewritten row by row through ofstream | code | 150-400 ms on zoom shots | none | 4 |
| 16 | BayerBurst capture | per-request HEVC photo, no prepared settings, work between requests | 1st request +233 ms; 0.44 s gaps | 0.2-0.7 s capture | input timing changes | 5 (only setPreparedPhotoSettingsArray: same frames) |
| 17 | processingTail | the next merge waits for the previous save | code | 0.1-3 s per queued shot | none | 5 |
| 18 | Private textures / pooling | shared storage blocks GPU compression; no texture pool | code | 5-15 % GPU (speculative) | pooling: undefined texels risk | 6 (only if measurable) |
| 19 | Release C/C++ -Os | the CPU C++ built for size | project.yml | 0-20 % of the CPU C++ (speculative) | none expected | 6 |

Not done (they change what the user sees or the captured input): removing the limited-library alert
(PHPhotoLibraryPreventAutomaticLimitedAccessAlert), dropping the bracket's HEVC photo (the merge-failure fallback), issuing the
next bracket before the previous is handled (frame spacing changes the merge input), throttling on thermalState, capping the
processing ring's animation rate.

GPU: the heavy work (merge, alignment, post, film) already runs on the GPU. The CPU stages left are the shared merge's
(Android code: thumbnails, RAW CA 102 ms, MOCHI 236 ms, Bento blend 275 ms and the plain chroma median - the last two beside
the GPU merge) and the Swift stats (< 3 ms). Moving the shared ones means changing the Android merge core (not this port's).

## Batches
- 0 (774dfbff): PERF signposts, PerfTests (XCTest clock / CPU / memory), image_metrics gate in CI.
- 1 ScamGL waits and locks: 1, 2, 3, 6, 7.
- 2 Frames in memory: 4, 5.
- 3 Pipeline states ahead: 8.
- 4 Copies and main-thread work: 9-15.
- 5 Capture / save ordering without changing the frames: 16 (prepared settings only), 17.
- 6 Only with a measured gain: 18, 19.

## Results
| Batch / change | Gain (numbers) | Checks | Kept |
|---|---|---|---|
| 0 tooling | - | image_metrics self-test (CIEDE2000 table pairs exact); a +-1 noise copy PASS, a 4-level posterised copy FAIL (banding x1.33) | yes |
| 1 ScamGL resource waits, link outside gLock, staging pool | CI Metal, 5 real bursts (sums of the logs' stage times): «Качество» 22.9 -> 20.4 s (-11 %; the runner's CPU compile -6 % that run: ~-5 % net), align 15.7 -> 7.9 s; «Быстрый» 9.80 -> 9.41 s (-4 %, ~+2 % net: noise). The first version left the recorded work uncommitted during a wait (GPU idle): «Быстрый» +17 / +40 % in two runs - fixed (d392cdcd) | Metal vs Mesa: all 15 comparisons' PSNR identical to the run before (the same output); unit tests pass; review: an earlier buffer's GPU error now reported at a readback, last-use entries dropped with their objects | yes |
| 1 thread teams at user-initiated QoS, warm-up at utility | [не измерено] (device only) | - | yes |
| 2 planes released before the merge | peak RAM -547 MB expected (the planes' size in the log) [не измерено] | the Swift plane users checked (faces / lens shading before the release) | yes |
| 2 NCH madvise(WILLNEED) | [не измерено] (page-ins on the device) | output unchanged (no data change) | yes |
| 4 transport crop gathered per frame | host: rows 344-637 ms vs frames 477-1076 ms (no gain) | bytes identical | reverted |
| 4 UHDR halves readback, HEIC 10-bit context, off-main thumbnails / DNG write, no-copy NSData, settings tree ahead | [не измерено] (device) | base0 via the new ShotRun: 0 values differ | yes |
| 3 render pipeline states in the warm-up | [не измерено] (first shots after an install) | - | yes |
| 5 saves beside the processing | [не измерено] | saves stay in shot order (the raw-only save waits for them: review) | yes |
| ManualPanel HUD reads | not done: the collapsing panel's chips would change for its 0.2 s exit | - | - |
| -O3 C++, private textures / pooling, prepared photo settings | not done: unmeasurable here, risky (settings / memory / preview) | - | - |
