# iOS processing pipeline: architecture against the Android tables (2026-11-15)

Targets (A17 Pro and newer, 12 MP «Быстрый»): hold <= 400, merge <= 1200, post <= 900, save <= 50, press -> file <= 3 s, cold <= +300.
48 MP: merge <= 5000, post <= 2500, save <= 150. The comparison line is SHOT SUMMARY (below), the same fields as Android's.

## SHOT SUMMARY (in the session log, one line per SHDR shot)
`SHOT SUMMARY ms: hold= prep= merge= (front= ctx= upload= submit= readback=) gap= post= save= (encode= library=) total= cold= | post nodes: <node> <ms>, ...`
- hold: press -> the burst captured (CameraModel.captureShdr; the brackets included).
- prep: BurstProcessor up to the merge (levels, P558 white, black floor, the NCH stream's end, facts, lab files, faces).
- merge: the GPU merge (ScamMergeCore: hybridReconstruct). «Быстрый»: front / ctx (context + objects) / upload / submit / readback
  from the merge's own «HYBRID FAST MERGE ms» line (the same code as Android, the same meaning); «Качество»: align / merge.
- gap: the merge's end -> the post pipeline (worker output, the post context, the shot's Parameters, the merged DNG when RAW).
- post: the post pipeline and its tail; post nodes: each node's wall ms, the slowest first (ScamRgb, ScamHdrDenoise, WhyMsDenoise,
  WhyStats, WhyFusion, WhyCombine, WhyLumaSharpen, ... and «output»: the final draw and readback). Beside it «GPU ms»: each stage's
  GPU time from the command buffers (GPUEndTime - GPUStartTime).
- save: HEIC / JPEG encode (ImageIO, hardware HEVC) + the Photos library write. Android's save is encode + file write.
- cold: compile ms the shot spent itself (programs not built by the warm-up yet).
- os_signpost category PERF has the same intervals for Instruments.

## Where iOS stands (iPad M1 logs, before this round) and what is structural
| Stage | iPad M1 | Android 8 Elite (X200 Ultra) | Note |
|---|---|---|---|
| hold | 1.9-2.4 s (23 frames) | 391 ms | Android takes N frames from a ZSL RAW ring (already captured). iOS has no RAW ring: AVCaptureVideoDataOutput gives no Bayer RAW, AVCapturePhotoOutput's zero shutter lag / responsive capture are for processed photos. Every RAW frame is captured after the press: ~43 ms a frame at the sensor's rate + ~150 ms a bracket request (log fit). 20 N frames alone are >= 0.7 s. |
| merge «Быстрый» | 1.46 s (shot without the warm-up), 2.0-3.3 s with it | 1183 ms | Same shared C++; upload 0.94-1.07 s, front 25 vs 541-577 ms (page-ins). |
| post | 1.57 s (157 programs kept) | 1001 ms | GPU bound; node split from the next log. |
| save | encode ~0.2-0.3 s (HEIC) + library 0.1 s (~3 s on a launch's first save: the system's library alert) | 14 ms (file only) | |
| cold | first-run dialog 7.8-9.8 s; then the warm-up 9.7-11.2 s each launch (before the translation cache) | 350-2423 ms | |

## Architecture
1. Capture (hold). Keep AVCapturePhotoOutput bracketed Bayer RAW (AVCapturePhotoBracketSettings, manual exposure per frame):
   ProRAW is demosaiced linear RGB through Apple's own pipeline - not the Bayer data the merge needs, and not on non-Pro models.
   The press -> burst time is the frame count x the frame time; what can still go: prepare the bracket settings ahead
   (setPreparedPhotoSettingsArray at mode entry: the first request's +233 ms), no processed HEVC on the bracket requests (the frame
   0 DNG gives the EXIF; needs a camera-HEIC fallback first), the copies off the delegate path (issue the next request first).
   Those change the frames' timing and must pass the owner's motion / detail A/B; until then hold stays capture-bound.
   On iPhones with 4:3 48 MP, 12 MP binned Bayer is the RAW stream; 48 MP is one frame per request (memory, bandwidth).
2. Frames to the GPU (upload). Today: the CVPixelBuffer's rows -> Swift Data (CPU copy) -> the NCH file (streamed during the
   capture) -> mmap in the merge -> its upload ring (CPU copy into a shared MTLBuffer). Planned: the frames as IOSurface-backed
   buffers wrapped without a copy (MTLBuffer newBufferWithBytesNoCopy on the page-aligned base address, or CVMetalTextureCache), the
   NCH written from them in the background for the lab / «Сохранять RAW-серию». Needs a frame-source hook in ScamMergeCore
   (the shared merge reads uint16 planes through MappedHybridBurst: a pointer table instead of a file).
3. Merge as frames arrive. The fast merge's per-frame loop (front end, homography, accumulate) can start on frame k while k+1..n
   are captured; needs the same frame-source hook and the selector's base pick from the first frames (a behaviour change: the
   base frame rule - A/B first).
4. No readback between merge and post (readback, gap). Android's merge runs in a worker process and hands the RGB over a memfd;
   iOS runs both in one process on one MTLDevice: the merge's result buffer can be the post's ScamRgb input (texture from the
   same MTLBuffer), skipping the 72 MB readback (~370 ms on the M1) and the re-upload. Needs the shared merge's output to stay
   a GL buffer (an iOS-only hook in ScamMergeCore) - the largest single cut left in merge + post.
5. GPU work (submit, post). ScamGL (GLES on Metal): per-resource waits (a readback waits for its own command buffer),
   private textures (lossless compression), single-target full draws without a tile load, concurrent compute dispatch with
   glMemoryBarrier as the encoder barrier, whole-frame post draws, unsynchronised upload maps, staging pool. The viewfinder draws
   on its own MTLCommandQueue; the merge's dispatches go per pass (gpuPace 0). Next: MTLHeap for the post's ping-pong textures.
6. Compile (cold). The translations (GLSL -> SPIR-V -> MSL) are cached on disk; the warm-up builds every program and render
   pipeline state of the last runs at launch. Next: translate the whole shader set at build time into a .metallib and an
   MTLBinaryArchive of the pipeline states (CI), loaded at camera open: cold becomes the binary archive's load.
7. Encode (save). HEIC through ImageIO (hardware HEVC); JPEG through ImageIO. The library write is on its own ordered queue
   beside the next shot's merge. The first save of a launch waits for the system's limited-library alert (not changed: the
   alert is the system's UI).
8. Memory. The 547 MB of Swift planes are released before the merge (the NCH holds them); the post's buffers are moved, not
   copied; with (2) the planes would never be copied at all.

## Measuring
- On the device: the SHOT SUMMARY line and «GPU ms» per stage; Instruments os_signpost (PERF).
- CI (macOS runner, paravirtual Apple GPU): the Metal replay of 5 real bursts against Mesa (output identity: PSNR of every
  comparison) and the merges' stage times; XCTest PerfTests (clock / CPU / memory).
- Host: the post port bit for bit against the Android pipeline (5 references), image_metrics for any change that is not.
