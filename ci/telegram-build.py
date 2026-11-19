#!/usr/bin/env python3
"""Deliver exactly one checked APK through the existing pinned-source bot module.

No Telegram/GitHub access occurs in --self-test. Only receipt count is public;
the controller must keep this helper's diagnostics out of public build logs.
"""
import argparse
import asyncio
import hashlib
import importlib.util
import pathlib
import re
import subprocess
import sys
import tempfile
import types
import unittest

# Fixture text for the self-tests; the caption takes whatever the newest section of CHANGELOG.md says (Russian only).
RU_ITEMS = ["Камера переименована в PronCam.", "Оптимизация и ускорение работы приложения."]
APK_NAME = re.compile(r"(?:PronCam|SomeCam)-[A-Za-z0-9._-]+-[0-9]+-SCAM\.apk")
SHA = re.compile(r"[0-9a-f]{40}")


def checked_source(directory, revision):
    directory = pathlib.Path(directory)
    if directory.is_symlink():
        raise ValueError("Unsafe source directory")
    directory = directory.resolve(strict=True)
    if not SHA.fullmatch(revision):
        raise ValueError("Invalid source revision")
    result = subprocess.run(["git", "-C", str(directory), "rev-parse", "HEAD"],
                            check=True, capture_output=True, text=True)
    if result.stdout.strip() != revision:
        raise ValueError("Pinned source revision differs")
    guarded = ("tools/telegram_publish.py", "CHANGELOG.md")
    for relative in guarded:
        target = directory / relative
        if target.is_symlink() or not target.is_file() or not target.resolve().is_relative_to(directory):
            raise ValueError("Unsafe pinned source file")
    subprocess.run(["git", "-C", str(directory), "ls-files", "--error-unmatch", "--", *guarded],
                   check=True, capture_output=True)
    subprocess.run(["git", "-C", str(directory), "diff", "--quiet", "HEAD", "--", *guarded],
                   check=True, capture_output=True)
    return directory


def checked_apk(directory):
    directory = pathlib.Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Unsafe publication directory")
    files = list(directory.iterdir())
    apks = [f for f in files if APK_NAME.fullmatch(f.name)]
    if len(files) != 2 or len(apks) != 1 or {f.name for f in files} != {apks[0].name, "SHA256SUMS.txt"}:
        raise ValueError("Unexpected publication files")
    if any(f.is_symlink() or not f.is_file() for f in files):
        raise ValueError("Unsafe publication file")
    with apks[0].open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    expected = digest + "  " + apks[0].name + "\n"
    if (directory / "SHA256SUMS.txt").read_text(encoding="utf-8") != expected:
        raise ValueError("APK digest differs")
    return apks[0], digest


def read_sections(path):
    """The newest section of a changelog: its heading and its lines (bullets or plain text); older sections are left out."""
    text = pathlib.Path(path).read_text(encoding="utf-8")
    section = None
    title = "PronCam"
    items = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("## "):
            if section is not None:
                break
            section = line[3:].strip()
        elif line.startswith("# ") and section is None:
            title = line[2:].strip() or title
        else:
            if section is None:
                section = title
            items.append(line[2:].strip() if line[:2] in ("- ", "* ") else line)
    items = [item for item in items if item]
    if not items:
        raise ValueError("Empty changelog")
    return [(section, items)]


def make_local_post(publisher, source):
    ru = read_sections(source / "CHANGELOG.md")

    def make_post(args, digest, settings):
        if not settings["commits"]:
            return publisher.build_caption(args.apk, digest, [], settings), []
        return publisher.changelog_post(args.apk, digest, ru, settings, english=[])

    return make_post


def load_publisher(source):
    spec = importlib.util.spec_from_file_location("proncam_pinned_telegram_publish", source / "tools/telegram_publish.py")
    if spec is None or spec.loader is None:
        raise ValueError("Cannot load pinned publisher")
    publisher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(publisher)
    publisher.make_post = make_local_post(publisher, source)
    return publisher


def send(publisher, apk, digest, revision):
    args = argparse.Namespace(apk=apk, to_rev=revision, from_rev="", subject=[], force=True,
                              notify="all", dry_run=False, settings_json="")
    receipt = asyncio.run(publisher.publish(args, digest))
    if not isinstance(receipt, list) or not receipt or any(type(value) is not int or value <= 0 for value in receipt):
        raise RuntimeError("Telegram delivery was not confirmed")
    return len(receipt)


class Contract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="proncam-telegram-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)

    def stage(self):
        directory = self.root / "out"
        directory.mkdir()
        apk = directory / "PronCam-0.98-31306-SCAM.apk"
        apk.write_bytes(b"checked fixture APK")
        digest = hashlib.sha256(apk.read_bytes()).hexdigest()
        (directory / "SHA256SUMS.txt").write_text(digest + "  " + apk.name + "\n")
        return directory, apk, digest

    def test_apk_digest_extra_file_and_symlink(self):
        directory, apk, digest = self.stage()
        self.assertEqual((apk, digest), checked_apk(directory))
        apk.write_bytes(b"modified")
        with self.assertRaises(ValueError): checked_apk(directory)
        apk.write_bytes(b"checked fixture APK")
        extra = directory / "Source.java"
        extra.write_text("private canary")
        with self.assertRaises(ValueError): checked_apk(directory)
        extra.unlink()
        target = self.root / "real.apk"
        apk.rename(target)
        apk.symlink_to(target)
        with self.assertRaises(ValueError): checked_apk(directory)

    def test_any_changelog_newest_section(self):
        ru = self.root / "CHANGELOG.md"
        ru.write_text("# Изменения\n\n## 2026-11-19\n\n- Исправлены чёрные снимки.\nПлюс строка без маркера.\n"
                      "* Ещё пункт\n\n## 2026-11-18\n\n- старое\n")
        self.assertEqual([("2026-11-19", ["Исправлены чёрные снимки.", "Плюс строка без маркера.", "Ещё пункт"])],
                         read_sections(ru))
        self.assertEqual([("PronCam", ["Just text"])], read_sections(self._write("plain.md", "Just text\n")))
        self.assertEqual([("Изменения", ["Без даты"])], read_sections(self._write("t.md", "# Изменения\n\n- Без даты\n")))
        calls = []
        publisher = types.SimpleNamespace(
            changelog_post=lambda *a, **k: calls.append((a, k)) or ("caption", []))
        settings = dict(commits=True)
        make_local_post(publisher, self.root)(argparse.Namespace(apk=pathlib.Path("a.apk")), "d", settings)
        self.assertEqual("Исправлены чёрные снимки.", calls[-1][0][2][0][1][0])
        (self.root / "CHANGELOG.en.md").write_text("# Changes\n\n## 2026-11-19\n\n- Fixed black photos.\n")
        make_local_post(publisher, self.root)(argparse.Namespace(apk=pathlib.Path("a.apk")), "d", settings)
        self.assertEqual([], calls[-1][1]["english"])  # Russian only: an English file is never posted
        ru.write_text("# Изменения\n\n## 2026-11-19\n\n")
        with self.assertRaises(ValueError): make_local_post(publisher, self.root)  # nothing to post

    def _write(self, name, text):
        path = self.root / name
        path.write_text(text)
        return path

    def test_source_revision_and_publisher_are_pinned(self):
        source = self.root / "source"
        (source / "tools").mkdir(parents=True)
        (source / "tools/telegram_publish.py").write_text("# pinned fixture\n")
        (source / "CHANGELOG.md").write_text("fixture\n")
        subprocess.run(["git", "init", "--quiet", str(source)], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(source), "add", "."], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(source), "-c", "user.name=Fixture", "-c",
                        "user.email=fixture@local.invalid", "commit", "--quiet", "-m", "fixture"],
                       check=True, capture_output=True)
        revision = subprocess.run(["git", "-C", str(source), "rev-parse", "HEAD"],
                                  check=True, capture_output=True, text=True).stdout.strip()
        self.assertEqual(source, checked_source(source, revision))
        with self.assertRaises(ValueError): checked_source(source, "0" * 40)
        with self.assertRaises(ValueError): checked_source(source, "main; unexpected")
        (source / "tools/telegram_publish.py").write_text("# modified after checkout\n")
        with self.assertRaises(subprocess.CalledProcessError): checked_source(source, revision)

    def test_caption_uses_local_sections_and_settings(self):
        (self.root / "CHANGELOG.md").write_text("# Changes\n\n## 2026-11-17\n\n" + "\n".join("- " + s for s in RU_ITEMS) + "\n")
        calls = []
        publisher = types.SimpleNamespace(
            build_caption=lambda *args, **kwargs: calls.append(("caption", args, kwargs)) or "caption",
            changelog_post=lambda *args, **kwargs: calls.append(("changes", args, kwargs)) or ("caption", []))
        post = make_local_post(publisher, self.root)
        args = argparse.Namespace(apk=pathlib.Path("PronCam.apk"))
        settings = dict(commits=True, sha=False, header="owner header", lang="ru")
        self.assertEqual(("caption", []), post(args, "digest", settings))
        self.assertIs(settings, calls[-1][1][3])
        self.assertEqual([("2026-11-17", RU_ITEMS)], calls[-1][1][2])
        self.assertEqual([], calls[-1][2]["english"])
        settings["commits"] = False
        self.assertEqual(("caption", []), post(args, "digest", settings))
        self.assertEqual("caption", calls[-1][0])

    def test_missing_or_invalid_receipt_fails(self):
        for receipt in (None, [], "success", [0], [-1], [True]):
            async def publish(args, digest): return receipt
            with self.assertRaises(RuntimeError): send(types.SimpleNamespace(publish=publish), pathlib.Path("a.apk"), "digest", "a" * 40)
        async def publish(args, digest):
            self.assertTrue(args.force)
            self.assertEqual("all", args.notify)
            return [123, 456]
        self.assertEqual(2, send(types.SimpleNamespace(publish=publish), pathlib.Path("a.apk"), "digest", "a" * 40))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=pathlib.Path)
    parser.add_argument("--output-dir", type=pathlib.Path)
    parser.add_argument("--source-sha")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(Contract))
        return 0 if result.wasSuccessful() else 1
    if args.source_dir is None or args.output_dir is None or args.source_sha is None:
        parser.error("source-dir, output-dir and source-sha are required")
    try:
        source = checked_source(args.source_dir, args.source_sha)
        apk, digest = checked_apk(args.output_dir)
        publisher = load_publisher(source)
        send(publisher, apk, digest, args.source_sha)
    except Exception as failure:
        # Do not expose exception text: external libraries can include private peer information.
        print("Telegram delivery failed: " + type(failure).__name__, file=sys.stderr)
        return 1
    print("Checked APK delivered through Telegram bot.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
