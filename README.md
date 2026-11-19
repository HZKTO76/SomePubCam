# SomeCam build and delivery

This public repository holds no SomeCam sources: they live only in the private repository. What is here starts and
checks the builds and delivers the signed APK through the Telegram bot:

- `.github/workflows/build.yml`: builds a pinned private commit (`ci/build-request.json`), runs the host checks, signs
  the APK and sends it through the bot; private diagnostics never enter the public logs (`ci/public-build.sh`), and the
  APK is kept in the run's storage only sealed (the artifacts of a public repository are public).
- `.github/workflows/redeliver-apk.yml`: sends an already checked APK again (`ci/telegram-delivery.json`).
- `.github/workflows/telegram-bot.yml`, `tools/telegram_*.py`, `tools/telegram-worker/`: the bot (`docs/telegram-channel.md`).
