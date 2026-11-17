#!/usr/bin/env python3
"""Offline integration with an existing telegram_publish.py and fake Telegram I/O."""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import sys
import tempfile
import types
from unittest import mock


def module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publisher", type=Path, required=True)
    args = parser.parse_args()
    helper = module(Path(__file__).with_name("telegram-build.py"), "delivery_helper")
    publisher = module(args.publisher, "tested_publisher")
    with tempfile.TemporaryDirectory(prefix="proncam-telegram-publisher-test-") as folder:
        root = Path(folder)
        for name, values in (("CHANGELOG.md", helper.RU_ITEMS), ("CHANGELOG.en.md", helper.EN_ITEMS)):
            (root / name).write_text("# Changes\n\n## 2026-11-17\n\n" + "\n".join("- " + s for s in values) + "\n")
        publisher.make_post = helper.make_local_post(publisher, root)
        calls = []

        class Client:
            def __init__(self, *args): pass
            async def start(self, **kwargs): calls.append("start")
            async def get_input_entity(self, ref): return "fixture-owner"
            async def send_file(self, chat, media, **kwargs):
                assert kwargs["reply_to"] == 15
                caption = kwargs["caption"]
                assert "owner header" in caption
                assert "Камера переименована в PronCam." in caption
                assert "Оптимизация и ускорение работы приложения." in caption
                assert "Application optimization and acceleration." in caption
                assert "SHA-256" not in caption
                calls.append("file")
                return types.SimpleNamespace(id=123, media="fixture-media")
            async def pin_message(self, *args, **kwargs): calls.append("pin")
            async def send_message(self, *args, **kwargs): calls.append("notify")
            async def log_out(self): calls.append("logout")

        telegram = types.ModuleType("telethon")
        telegram.TelegramClient = Client
        sessions = types.ModuleType("telethon.sessions")
        sessions.StringSession = lambda: "fixture-session"
        async def settings(client, owner):
            return dict(auto=False, targets=[dict(chat=-100123, topic=15, where="fixture")],
                        commits=True, sha=False, header="owner header", lang="ru")
        publisher.read_settings = settings
        apk = root / "PronCam-0.98-31306-SCAM.apk"
        apk.write_bytes(b"checked fixture APK")
        env = dict(TELEGRAM_BOT_TOKEN="fixture-not-a-token", TELEGRAM_API_ID="1",
                   TELEGRAM_API_HASH="fixture-not-a-hash", TELEGRAM_OWNER="fixture_owner")
        with mock.patch.dict(sys.modules, {"telethon": telegram, "telethon.sessions": sessions}), \
             mock.patch.dict(os.environ, env, clear=True), \
             mock.patch("urllib.request.urlopen", side_effect=AssertionError("Network forbidden")), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            count = helper.send(publisher, apk, hashlib.sha256(apk.read_bytes()).hexdigest(), "a" * 40)
        assert count == 1
        assert calls == ["start", "file", "pin", "notify", "logout"], calls
    print("PASS: existing publisher with offline fake Telegram, pinned local caption, owner settings and confirmed receipt")


if __name__ == "__main__":
    main()
