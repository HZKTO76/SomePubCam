#!/usr/bin/env python3
"""Fail-closed public Actions host gate. No artifacts or Telegram access."""
import argparse
import json
import os
import re
import sys
import time
import unittest
import urllib.request

REPOSITORY = "HZKTO76/SomePubCam"
EXPECTED = frozenset("host (" + lane + ")" for lane in
                     ("shaders", "native-a", "native-b", "native-c", "strip-trailers", "codecs"))
POLL_SECONDS = 20
MAX_SECONDS = 1800


class GateError(RuntimeError):
    pass


def context(repository, run):
    if repository != REPOSITORY or not re.fullmatch(r"[1-9][0-9]{0,19}", str(run)):
        raise GateError("Invalid build context")
    return str(run)


def completed(jobs):
    """Missing/queued jobs are pending; duplicate or unsuccessful jobs fail closed."""
    found = {}
    ids = set()
    for job in jobs:
        if not isinstance(job, dict):
            raise GateError("Invalid job response")
        if job.get("id") is not None:
            if job["id"] in ids:
                raise GateError("Duplicate job response")
            ids.add(job["id"])
        name = job.get("name")
        if name not in EXPECTED:
            continue
        if name in found:
            raise GateError("Duplicate required host job")
        found[name] = job
        status, result = job.get("status"), job.get("conclusion")
        if result not in (None, "success") or (status == "completed" and result != "success"):
            raise GateError("A required host job did not succeed")
        if status not in ("queued", "waiting", "requested", "pending", "in_progress", "completed"):
            raise GateError("Invalid required host job status")
    return sum(j["status"] == "completed" and j.get("conclusion") == "success" for j in found.values())


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, target):
        return None


def github_jobs(run, token, deadline):
    opener = urllib.request.build_opener(NoRedirect())
    all_jobs = []
    page = 1
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise GateError("Host gate deadline exceeded")
        url = ("https://api.github.com/repos/" + REPOSITORY + "/actions/runs/" + run
               + "/jobs?filter=latest&per_page=100&page=" + str(page))
        request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token,
            "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "SomeCam-host-gate"})
        try:
            with opener.open(request, timeout=min(30, remaining)) as response:
                data = json.load(response)
        except Exception:
            # Never expose response bodies, request headers or exception text.
            raise GateError("Public host status request failed") from None
        if (not isinstance(data, dict) or not isinstance(data.get("jobs"), list)
                or type(data.get("total_count")) is not int or data["total_count"] < 0):
            raise GateError("Invalid public host status response")
        jobs = data["jobs"]
        if len(jobs) > 100 or (not jobs and len(all_jobs) < data["total_count"]):
            raise GateError("Incomplete public host status response")
        if any(not isinstance(j, dict) or str(j.get("run_id")) != run for j in jobs):
            raise GateError("Public job belongs to another run")
        all_jobs.extend(jobs)
        if len(all_jobs) >= data["total_count"]:
            return all_jobs
        page += 1


def wait(fetch, timeout=MAX_SECONDS, clock=time.monotonic, sleep=time.sleep, report=print):
    if not 0 < timeout <= MAX_SECONDS:
        raise GateError("Invalid host gate deadline")
    deadline = clock() + timeout
    previous = None
    while clock() < deadline:
        count = completed(fetch(deadline))
        if clock() > deadline:
            break
        if count != previous:
            report("Host checks succeeded: " + str(count) + "/6.")
            previous = count
        if count == len(EXPECTED):
            return
        remaining = deadline - clock()
        if remaining > 0:
            sleep(min(POLL_SECONDS, remaining))
    raise GateError("Required host checks did not finish before the deadline")


class Contract(unittest.TestCase):
    def jobs(self):
        return [dict(id=n, name=name, status="completed", conclusion="success")
                for n, name in enumerate(sorted(EXPECTED), 1)]

    def test_success_and_unrelated_jobs(self):
        jobs = self.jobs() + [dict(id=100, name="build", status="in_progress", conclusion=None)]
        self.assertEqual(6, completed(jobs))

    def test_pending_and_missing(self):
        self.assertEqual(0, completed([]))
        self.assertEqual(5, completed(self.jobs()[:-1]))
        jobs = self.jobs()
        jobs[-1].update(status="queued", conclusion=None)
        self.assertEqual(5, completed(jobs))

    def test_all_unsuccessful_results_reject(self):
        for result in ("failure", "cancelled", "timed_out", "skipped", "neutral", None):
            jobs = self.jobs()
            jobs[0]["conclusion"] = result
            with self.assertRaises(GateError): completed(jobs)

    def test_duplicate_name_or_id_rejects(self):
        jobs = self.jobs()
        with self.assertRaises(GateError): completed(jobs + [dict(jobs[0], id=200)])
        with self.assertRaises(GateError): completed(jobs + [dict(jobs[0], name="build")])

    def test_wrong_context_rejects(self):
        self.assertEqual("123", context(REPOSITORY, "123"))
        for repo, run in (("other/repo", "123"), (REPOSITORY, "0"), (REPOSITORY, "1/../2")):
            with self.assertRaises(GateError): context(repo, run)

    def test_poll_transition_and_missing_deadline(self):
        now = [0]
        def sleep(seconds): now[0] += seconds
        samples = iter([[], self.jobs()])
        wait(lambda deadline: next(samples), timeout=40, clock=lambda: now[0], sleep=sleep, report=lambda text: None)
        self.assertEqual(20, now[0])
        with self.assertRaises(GateError):
            wait(lambda deadline: [], timeout=40, clock=lambda: now[0], sleep=sleep, report=lambda text: None)
        self.assertEqual(60, now[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--timeout-seconds", type=int, default=MAX_SECONDS)
    args = parser.parse_args()
    if args.self_test:
        result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(Contract))
        return 0 if result.wasSuccessful() else 1
    try:
        run = context(os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_RUN_ID", ""))
        token = os.environ.get("GH_TOKEN", "").strip()
        if not token:
            raise GateError("Host gate token is not configured")
        wait(lambda deadline: github_jobs(run, token, deadline), timeout=args.timeout_seconds)
    except GateError as failure:
        print("Host publication gate refused: " + str(failure), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
