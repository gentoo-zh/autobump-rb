#!/usr/bin/env python3
"""Wake autobump.yml for the issues one of its runs left waiting on a bundle.

    wait.py --repo OWNER/REPO --run-id ID [--overlay DIR] [--interval 120] [--deadline 10800] [--dry-run]

The items come from that run's artifacts: autobump-bundles (bundles.json targets still pending)
and every autobump-delta-* (the `waits` a shard wrote for a per-version deps artifact that
answered 404), for packages with `autobump` set in overlay.toml. Each round drops the items whose
issue is closed, judges the rest, and once no autobump.yml run is active dispatches autobump.yml
once with every issue that became ready. An item is woken once; at the deadline the ones left
are printed. --dry-run judges one round and dispatches nothing.

GH_TOKEN is the overlay's token. The bundle reads take GH_TOKEN_<OWNER>, as bundles.py does.
"""
import argparse
import datetime
import io
import json
import os
from pathlib import Path
import re
import sys
import time
import tomllib
import urllib.error
import urllib.request
import zipfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import bundles  # noqa: E402

WORKFLOW = "autobump.yml"
BUSY = {"queued", "in_progress", "waiting", "pending", "requested"}
CHECK = 30
TRIES = 3
sleep, now = time.sleep, time.time


class DropAuthorization(urllib.request.HTTPRedirectHandler):
    # an artifact download redirects to signed blob storage, which refuses the GitHub token
    def redirect_request(self, request, fp, code, message, headers, url):
        follow = super().redirect_request(request, fp, code, message, headers, url)
        if follow is not None:
            follow.remove_header("Authorization")
            # before Python 3.13 a redirected HEAD became a GET, which downloads the whole asset
            follow.method = request.get_method()
        return follow


def fetch(url, method="GET", token=None):
    """(status, body) following redirects; status None when nothing answered."""
    headers = {"User-Agent": "gentoo-zh-wait"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers, method=method)
    try:
        with urllib.request.build_opener(DropAuthorization).open(request, timeout=bundles.TIMEOUT) as reply:
            return reply.status, reply.read() if method == "GET" else b""
    except urllib.error.HTTPError as error:
        error.close()
        return error.code, b""
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        return None, str(error).encode()


def documents(api, repo, run_id, token):
    """(artifact name, JSON document) for every file of the artifacts the waiter reads."""
    listed, page = [], 1
    # a run with many shards has more artifacts than one page holds
    while True:
        listing = api.request("GET", repo, f"/repos/{repo}/actions/runs/{run_id}/artifacts?per_page=100&page={page}")
        if not listing.ok:
            bundles.die(f"artifacts of run {run_id}: {listing.describe()}", 1)
        artifacts = listing.field("artifacts", list) or []
        listed += artifacts
        if len(artifacts) < 100:
            break
        page += 1
    for artifact in listed:
        name = artifact.get("name", "")
        if name != "autobump-bundles" and not name.startswith("autobump-delta-"):
            continue
        status, data = fetch(artifact["archive_download_url"], token=token)
        if status != 200:
            bundles.die(f"artifact {name}: download answered {status}", 1)
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for member in archive.namelist():
                if member.endswith(".json"):
                    yield name, json.loads(archive.read(member))


def wait_items(found, opted_in):
    items = {}
    for name, document in found:
        if name == "autobump-bundles":
            targets = document.get("targets", [])
            entries = [t for t in targets if t.get("state") == "pending" and t.get("issue")]
        else:
            entries = document.get("waits", [])
        for entry in entries:
            item = {"issue": str(entry["issue"]), "package": entry["package"], "version": entry["version"],
                    "url": entry.get("url")}
            if item["package"] in opted_in:
                items.setdefault((item["issue"], item["package"], item["version"]), item)
    return list(items.values())


def ready(item, reads, index):
    if item["url"]:
        return fetch(item["url"], method="HEAD")[0] == 200
    spec = index.get(item["package"])
    if spec is None:
        return False
    result = bundles.process_target(reads, spec, item, mode="status", events=[], run="wait")[0]
    return result["state"] == "ready"


def closed(api, repo, item):
    response = api.request("GET", repo, f"/repos/{repo}/issues/{item['issue']}")
    return response.ok and response.field("state") == "closed"


def connect(token):
    """A fresh client: GitHub caches its reads, and stops asking an owner once throttled."""
    return lambda: bundles.GitHub(token=lambda owner: token)


def autobump_runs(api, repo, query=""):
    path = f"/repos/{repo}/actions/workflows/{WORKFLOW}/runs?per_page=50{query}"
    return api.request("GET", repo, path).runs()


def busy(api, repo):
    runs = autobump_runs(api, repo)
    return runs is None or any(run["status"] in BUSY for run in runs)


def stamp(seconds):
    return datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run_name(issues):
    # autobump.yml names a run dispatched with issues this way, so concurrent waiters tell their runs apart
    return f"autobump issues: {issues}"


def started(client, repo, issues, since, until):
    """Whether the run dispatched at `since` started; None when it was not seen by `until`."""
    while now() < until:
        sleep(CHECK)
        runs = autobump_runs(client(), repo, "&event=workflow_dispatch") or []
        ours = [run for run in runs
                if run.get("display_title") == run_name(issues) and (run["created_at"] or "") >= since]
        run = min(ours, key=lambda r: r["created_at"], default=None)
        if run and run["status"] == "in_progress":
            return True
        if run and run["status"] == "completed":
            return run["conclusion"] != "cancelled"
    return None


def wake(client, repo, issues, until):
    for attempt in range(1, TRIES + 1):
        # a dispatch while one is queued would take its place in the concurrency group
        while busy(client(), repo):
            if now() >= until:
                print(f"deadline: autobump.yml still busy, issues {issues} not woken")
                return
            sleep(CHECK)
        api = client()
        since = stamp(now())
        info = api.request("GET", repo, f"/repos/{repo}")
        branch = info.field("default_branch")
        if not branch:
            print(f"dispatch {attempt}: no default branch for {repo} ({info.describe()})")
            continue
        response = api.request("POST", repo, f"/repos/{repo}/actions/workflows/{WORKFLOW}/dispatches",
                               {"ref": branch, "inputs": {"issues": issues}})
        print(f"dispatch {attempt}: autobump.yml issues={issues}: {response.describe()}")
        if response.ok and started(client, repo, issues, since, until) is not False:
            return
    print(f"issues {issues}: autobump.yml did not start after {TRIES} dispatches")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--overlay", default=".")
    parser.add_argument("--interval", type=int, default=120)
    parser.add_argument("--deadline", type=int, default=10800)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv[1:])
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo):
        parser.error(f"--repo {args.repo!r} is not owner/name")
    token = os.environ.get("GH_TOKEN") or bundles.token_from_gh()
    if not token:
        bundles.die("set GH_TOKEN to the overlay's token")
    toml = Path(args.overlay, bundles.DEFAULT_TOML)
    opted_in = {p for p, t in tomllib.loads(toml.read_text()).items()
                if isinstance(t, dict) and t.get("autobump") not in (None, False)}
    index, _ = bundles.load_index(toml)
    client = connect(token)

    items = wait_items(documents(client(), args.repo, args.run_id, token), opted_in)
    until = now() + args.deadline
    while items:
        api, reads = client(), bundles.GitHub()
        woken, waiting = [], []
        for item in items:
            label = f"#{item['issue']} {item['package']} {item['version']}"
            if closed(api, args.repo, item):
                print(f"closed: {label}")
            elif ready(item, reads, index):
                print(f"ready: {label}")
                woken.append(item)
            else:
                print(f"waiting: {label}")
                waiting.append(item)
        issues = " ".join(sorted({item["issue"] for item in woken}, key=int))
        if issues and args.dry_run:
            print(f"would dispatch autobump.yml issues={issues}")
        elif issues:
            wake(client, args.repo, issues, until)
        items = waiting
        if args.dry_run or not items or now() >= until:
            break
        sleep(args.interval)
    for item in items:
        print(f"left waiting: #{item['issue']} {item['package']} {item['version']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
