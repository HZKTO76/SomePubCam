# Эталон склейки «Быстрый» с телефона: Mali-G925, vivo V2419A, 2026-11-10 17:17:11

Вход: `2026-11-10_17-17-11/burst.nch` (624 132 096 байт, sha256 в burst.nch.sha256) — ровно тот вход, который получил воркер
на телефоне (копия лаборатории, «SCAM KEEP: burst kept ...» в phone/native-report.txt). Файл большой, лежит в архиве владельца
на Google Drive (id 1ozT5lGLNxNpjIdO9b64GA6S3anT8ey4Y, zip; внутри папка 2026-11-10_17-17-11/).

Сборка на телефоне: SCAMERA 0.98 (31251), коммит 2554639f, воркер v31, GPU Mali-G925-Immortalis MC12, загрузка кадров (AHB),
выход в cached hardware buffers, RGB в half float.

## phone/
- native-report.txt — полный отчёт воркера телефона (все строки HYBRID, CLIP FLAGS, HIGHLIGHT MASK, EFFECTIVE MAP, SCAM RGB mean/max).
- 02-after-ivst.pfm — RGB-выход воркера телефона, 1000x750: сэмплы (x*4, y*4) из 4000x3000 (ScamDiagnostics: step =
  (max(w,h)+1023)/1024 = 4, ближайший пиксель, без фильтра), значения — half float телефона, переведённые в float32.
  PFM little-endian, строки снизу вверх, ориентация сенсора.
- README.txt, stages.txt, frames.txt — описание дампа телефона.
- SCAMERA_Log_2026-11-10.txt — лог телефона за сессию; meta.json — настройки снимка.
- Чего нет: полного RGB 4000x3000, карты эффективных кадров, флагов клипа и маски светов попиксельно — телефон дал
  только их сводные числа (native-report.txt).

## host/
- hybrid_tuning.txt — настройки воркера телефона один в один (из строки CLIENT ... tuning= отчёта; fastMerge 1).
- Запуск: `g++ -pthread -std=c++17 -O2 app/src/main/cpp/scam-neural-worker.cpp -ldl -lEGL -lGLESv2 -o worker` на 2554639f;
  job-папка: hybrid_tuning.txt + маркеры cre-off, clip-flags, hl-mask;
  `SCAM_HYBRID=1 EGL_PLATFORM=surfaceless LIBGL_ALWAYS_SOFTWARE=1 ./worker --scam-capture job burst.nch host.out` (Mesa llvmpipe).
- host.log — его отчёт; host-llvmpipe-sampled.pfm — его RGB в тех же точках (через half, как у телефона); compare.py — сверка.

## Телефон (Mali) против llvmpipe, тот же вход и код
| | телефон | llvmpipe |
|---|---|---|
| EFFECTIVE MAP median / code scale | 20.375 / 3.141104 | 20.375 / 3.141104 |
| HIGHLIGHT MASK mean / cells >= 0.005 | 0.00408 / 0.493 % | 0.00408 / 0.493 % |
| CLIP FLAGS R / G / B / border | 2440 / 7201 / 3923 / 13776 | 2416 / 7309 / 3938 / 13906 |
| SCAM RGB mean / max | 0.030926 / 16.625 | 0.030974 / 16.609 |
| HIGHLIGHT short 20: motion / clip / cells | 2.57 % / 10.56 % / 231.4 | 2.58 % / 10.58 % / 231.3 |
| HOMOGRAPHY 20s / 1 / 9 (inliers/tracked) | 82/145, 131/152, 91/142 | 79/142, 131/149, 87/139 |

Попиксельно по 750 000 сэмплам — см. compare.txt.
