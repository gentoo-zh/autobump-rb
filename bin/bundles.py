#!/usr/bin/env python3
"""Find, check and prepare the vendor bundles an ebuild downloads from gentoo-deps and
gentoo-zh-drafts releases.

    bundles.py list [--markdown]                  # the whole index from overlay.toml
    bundles.py has <atom>                         # yes or no; an unreadable entry is an error
    bundles.py where <atom> [--version V]         # repo, workflow, inputs, release, last run
    bundles.py status <atom>... [--version V] [--out FILE]    # read-only
    bundles.py prepare <atom>... [--version V] [--out FILE]   # dispatch what is missing
    bundles.py plan --targets JSON --ledger FILE --out FILE --delta FILE   # autobump.yml plan

It reads the overlay checkout in the current directory, or the one --overlay DIR names.

overlay.toml is the index. A package whose bundle gentoo-deps' generator.yml makes names its
language in `deps`:

    deps = "golang"          # or javascript, javascript(pnpm), rust, dart
    deps = { lang = "golang", vendordir = "{P}" }                  # workdir too
    deps = { lang = "golang", modules = ["service", "core"] }     # one bundle per directory

The source repo is the table's `github`, the tag its `prefix` followed by {PV}; `repo` and `tag`
in `deps` set them for a package tracked another way. A producer with its own workflow, such as
a gentoo-zh-drafts repo, lists its bundles in `bundle`, one inline table each:

    bundle = [
      { id = "node_modules", repo = "gentoo-zh-drafts/pkg", workflow = "node_modules.yml", tag = "v{PV}", inputs = { version = "{PV}" } },
    ]

Either form may rewrite the version for its bundles with `bundle_pv = [["_rc", "-rc."]]`.
Templates take {PN} {PV} {P} and {bundle_pv}. `workflow` is dispatched when no release carries
the tag; `producers` names every workflow that must finish for it, `workflow` included (the
default).

The snapshot (--out) is bundles.json schema 1, read by autobump-rb --bundle-status. The ledger
(--ledger, --delta) holds one line per event, `<package> <version> <kind> <date> <run>`, with
kind observe, dispatch, escalate or reset. A dispatch line is one request: its run carries the
attempt (`<run>.<attempt>`) and it ends with the bundle id. A target with `retry` set in the
targets JSON starts over from its reset line, and so does any target once it is ready.

Tokens come from GH_TOKEN_<OWNER> (GH_TOKEN_GENTOO_ZH, GH_TOKEN_GENTOO_ZH_DRAFTS), locally
from `gh auth token`; without one the reads go out anonymously and nothing is dispatched.
"""
import datetime
import http.client
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib
from typing import NamedTuple
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_TOML = ".github/workflows/overlay.toml"
API = os.environ.get("BUNDLES_API_URL", "https://api.github.com")
SERVER = "https://github.com"
OVERLAY = "gentoo-zh/overlay"
SCHEMA = 1

# the owners a DRAFTS_BOT token is minted for; a bundle elsewhere could never be dispatched
OWNERS = ("gentoo-zh", "gentoo-zh-drafts")
ENTRY_KEYS = {"id", "repo", "workflow", "tag", "inputs", "producers"}
DEPS_IDS = {"golang": "vendor", "javascript": "node_modules", "javascript(pnpm)": "node_modules",
            "rust": "crates", "dart": "pubcache"}
DEPS_KEYS = {"lang", "vendordir", "workdir", "modules", "repo", "tag"}
FIELDS = {"PN", "PV", "P", "bundle_pv"}
ACTIVE = {"queued", "in_progress"}
CONCLUSIONS = {"success", "failure", "cancelled", "skipped", "timed_out", "neutral", "action_required",
               "stale", "startup_failure"}
ISO_TIME = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)")
SEVERITY = ("ready", "pending", "unknown", "escalate")
OBSERVATION_LIMIT = 4
DISPATCH_LIMIT = 3
TIMEOUT = 30
RUN_FIELDS = ("status", "conclusion", "head_branch", "display_title", "html_url", "created_at", "updated_at",
              "run_started_at")


class ConfigError(ValueError):
    pass


def check_template(where, text):
    if not isinstance(text, str) or not text.strip():
        raise ConfigError(f"{where} is empty")
    stripped = re.sub(r"\{(\w+)\}", lambda m: "" if m.group(1) in FIELDS else "\0", text)
    if "\0" in stripped or "{" in stripped or "}" in stripped:
        raise ConfigError(f"{where} {text!r}: templates take only {{PN}} {{PV}} {{P}} {{bundle_pv}}")
    return text


def parse_rewrites(value):
    if value is None:
        return []
    if not isinstance(value, list) or not all(
            isinstance(pair, list) and len(pair) == 2 and all(isinstance(s, str) for s in pair) and pair[0]
            for pair in value):
        raise ConfigError("bundle_pv must be a list of [from, to] string pairs")
    return [tuple(pair) for pair in value]


def parse_entry(raw):
    if not isinstance(raw, dict):
        raise ConfigError("a bundle entry is not a table")
    unknown = set(raw) - ENTRY_KEYS
    if unknown:
        raise ConfigError(f"unknown bundle keys {sorted(unknown)}")
    for key in ("id", "repo", "workflow", "tag"):
        if not isinstance(raw.get(key), str) or not raw[key].strip():
            raise ConfigError(f"bundle {key} is missing or empty")
    ident, repo, workflow = raw["id"], raw["repo"], raw["workflow"]
    if not re.fullmatch(r"[A-Za-z0-9_-]+", ident):
        raise ConfigError(f"bundle id {ident!r} is not a plain word")
    owner, _, name = repo.partition("/")
    if owner not in OWNERS or not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
        raise ConfigError(f"bundle {ident}: repo {repo!r} is not under {' or '.join(OWNERS)}")
    producers = raw.get("producers", [workflow])
    if not isinstance(producers, list) or workflow not in producers:
        # a dispatched run the plan does not watch looks like no run, and is dispatched again
        raise ConfigError(f"bundle {ident}: producers must be a list that includes {workflow}")
    for file in [workflow, *producers]:
        if not isinstance(file, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+\.ya?ml", file):
            raise ConfigError(f"bundle {ident}: {file!r} is not a workflow file name")
    tag = check_template(f"bundle {ident} tag", raw["tag"])
    inputs = raw.get("inputs", {})
    if not isinstance(inputs, dict):
        raise ConfigError(f"bundle {ident}: inputs must be a table")
    for key, value in inputs.items():
        check_template(f"bundle {ident} input {key}", value)
    return {"id": ident, "repo": repo, "owner": owner, "workflow": workflow,
            "producers": list(dict.fromkeys(producers)), "tag": tag, "inputs": dict(inputs)}


def deps_entries(table):
    """The `bundle` entries a `deps` shorthand stands for: gentoo-deps' generator.yml."""
    deps = table["deps"] if isinstance(table["deps"], dict) else {"lang": table["deps"]}
    if set(deps) - DEPS_KEYS:
        raise ConfigError(f"unknown deps keys {sorted(set(deps) - DEPS_KEYS)}")
    lang = deps.get("lang")
    if not isinstance(lang, str) or lang not in DEPS_IDS:
        raise ConfigError(f"deps lang {lang!r} is not one of {', '.join(DEPS_IDS)}")
    repo = deps.get("repo", table.get("github") if table.get("source") == "github" else None)
    if repo is None:
        raise ConfigError("deps needs repo: the package's source is not github")
    if not isinstance(repo, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ConfigError(f"deps repo {repo!r} is not owner/name")
    if "tag" not in deps and {"from_pattern", "to_pattern"} & set(table):
        raise ConfigError("deps needs tag: from_pattern or to_pattern makes the version differ from the tag")
    inputs = {"LANG": lang, "REPO": repo, "TAG": deps.get("tag", f"{table.get('prefix', '')}{{PV}}"), "P": "{P}"}
    entry = {"repo": "gentoo-zh/gentoo-deps", "workflow": "generator.yml"}
    if "modules" not in deps:
        paths = {key.upper(): deps[key] for key in ("vendordir", "workdir") if key in deps}
        return [entry | {"id": DEPS_IDS[lang], "tag": "{P}", "inputs": inputs | paths}]
    modules = deps["modules"]
    if not isinstance(modules, list) or not modules or not all(isinstance(m, str) for m in modules):
        raise ConfigError("deps modules must be a non-empty list of directory names")
    if "vendordir" in deps or "workdir" in deps:
        raise ConfigError("deps modules sets each bundle's vendordir and workdir itself")
    return [entry | {"id": m, "tag": f"{{PN}}-{m}-{{PV}}",
                     "inputs": inputs | {"P": f"{{PN}}-{m}-{{PV}}", "WORKDIR": m, "VENDORDIR": f"{{P}}/{m}"}}
            for m in modules]


def parse_package(table):
    if "deps" in table and "bundle" in table:
        raise ConfigError("use one of deps or bundle")
    entries = deps_entries(table) if "deps" in table else table.get("bundle")
    if not isinstance(entries, list) or not entries:
        raise ConfigError("bundle must be a non-empty list of tables")
    bundles = [parse_entry(raw) for raw in entries]
    ids = [b["id"] for b in bundles]
    duplicate = sorted({i for i in ids if ids.count(i) > 1})
    if duplicate:
        raise ConfigError(f"duplicate bundle id {', '.join(duplicate)}")
    if "bundle_pv" in table and not any("{bundle_pv}" in s for b in bundles
                                        for s in [b["tag"], *b["inputs"].values()]):
        raise ConfigError("bundle_pv is set but no template uses {bundle_pv}")
    return {"bundles": bundles, "rewrites": parse_rewrites(table.get("bundle_pv")),
            "autobump": table.get("autobump") not in (None, False)}


def load_index(path=DEFAULT_TOML):
    """Every package with `deps` or `bundle`, and the ones whose entry is wrong: (index, errors)."""
    with open(path, "rb") as f:
        document = tomllib.load(f)
    index, errors = {}, {}
    for package, table in document.items():
        if not isinstance(table, dict) or not {"deps", "bundle", "bundle_pv"} & set(table):
            continue
        try:
            index[package] = parse_package(table)
        except ConfigError as error:
            errors[package] = str(error)
    return index, errors


def template_values(package, version, rewrites):
    pn = package.split("/")[-1]
    bundle_pv = version
    for old, new in rewrites:
        bundle_pv = bundle_pv.replace(old, new)
    return {"PN": pn, "PV": version, "P": f"{pn}-{version}", "bundle_pv": bundle_pv}


def expand(text, values):
    return re.sub(r"\{(\w+)\}", lambda m: values[m.group(1)], text)


def expanded_bundles(spec, package, version):
    values = template_values(package, version, spec["rewrites"])
    bundles = []
    for b in spec["bundles"]:
        tag = expand(b["tag"], values)
        # autobump-rb matches release URIs as releases/download/<tag>/<file>
        if "/" in tag:
            raise ConfigError(f"bundle {b['id']}: tag {tag!r} contains '/'")
        bundles.append(b | {"tag": tag, "p": values["P"],
                            "inputs": {k: expand(v, values) for k, v in b["inputs"].items()}})
    return bundles


SUFFIX_RANK = {"alpha": 0, "beta": 1, "pre": 2, "rc": 3, "p": 5}
VERSION = re.compile(r"(\d+(?:\.\d+)*)([a-z]?)((?:_(?:alpha|beta|pre|rc|p)\d*)*)(?:-r(\d+))?")


def version_key(version):
    match = VERSION.fullmatch(version)
    if not match:
        return ((), "", (), 0)
    numbers, letter, suffixes, revision = match.groups()
    ranked = [(SUFFIX_RANK[name], int(number or 0))
              for name, number in re.findall(r"_(alpha|beta|pre|rc|p)(\d*)", suffixes)]
    return (tuple(int(n) for n in numbers.split(".")), letter, (*ranked, (4, 0)), int(revision or 0))


def tree_version(package, root="."):
    """The newest release ebuild of a package, for commands run without --version."""
    pn = package.split("/")[-1]
    versions = [path.name[len(pn) + 1:-len(".ebuild")]
                for path in Path(root, package).glob(f"{pn}-*.ebuild")]
    versions = [re.sub(r"-r\d+$", "", v) for v in versions if not re.fullmatch(r"9{4,}(?:-r\d+)?", v)]
    return max(versions, key=version_key) if versions else None


class Response:
    def __init__(self, status, headers=None, body=None, cause=None):
        # cause: the reply that stopped the owner, for a request held back because of it
        self.status, self.headers, self.body, self.cause = status, headers or {}, body, cause

    @property
    def ok(self):
        return self.status is not None and 200 <= self.status < 300

    def rate_limited(self):
        """GitHub asked to wait: the next run asks again, so this one does not fail."""
        if self.cause:
            return self.cause.rate_limited()
        if self.status == 429:
            return True
        return self.status == 403 and (
            "retry-after" in self.headers or self.headers.get("x-ratelimit-remaining") == "0")

    def throttled(self):
        """Rate limited or refused outright: the owner's other calls would fail the same way."""
        return self.status == 401 or self.rate_limited()

    def describe(self):
        if self.status is None:
            return f"no response ({self.body})"
        message = self.field("message")
        return f"HTTP {self.status}" + (f": {message}" if message else "")

    def field(self, key, kind=object):
        """body[key] if the body is an object and the value a `kind`, else None."""
        value = self.body.get(key) if isinstance(self.body, dict) else None
        return value if isinstance(value, kind) else None

    def runs(self):
        """A successful run listing's runs, each field a string or None; None if unreadable."""
        listed = self.field("workflow_runs", list) if self.ok else None
        if listed is None or not all(isinstance(run, dict) for run in listed):
            return None
        return [{key: run[key] if isinstance(run.get(key), str) else None for key in RUN_FIELDS}
                for run in listed]


def urllib_send(method, url, headers, data):
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    # the outer handler also takes a body cut short while an error reply is read
    try:
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as reply:
                return reply.status, dict(reply.headers), reply.read()
        except urllib.error.HTTPError as error:
            return error.code, dict(error.headers or {}), error.read()
    except (urllib.error.URLError, TimeoutError, OSError, http.client.HTTPException) as error:
        return None, {}, str(getattr(error, "reason", error)).encode()


def token_from_gh():
    try:
        result = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return None
    return result.stdout.strip() or None


def owner_token(owner):
    token = os.environ.get("GH_TOKEN_" + owner.upper().replace("-", "_"))
    if token:
        return token
    # in CI GH_TOKEN is the overlay's own token, which can neither dispatch nor be trusted to read here
    if os.environ.get("GITHUB_ACTIONS") == "true":
        return None
    return token_from_gh()


class GitHub:
    """GET and dispatch per owner. An owner that is throttled once is not asked again this run."""

    def __init__(self, send=urllib_send, token=owner_token):
        self.send, self.token = send, token
        self.tokens, self.stopped, self.cache = {}, {}, {}

    def owner_token(self, owner):
        if owner not in self.tokens:
            self.tokens[owner] = self.token(owner)
        return self.tokens[owner]

    def request(self, method, owner, path, body=None, anonymous=False):
        if owner in self.stopped:
            cause = self.stopped[owner]
            return Response(None, body=f"{owner} stopped after {cause.describe()}", cause=cause)
        headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
                   "User-Agent": "gentoo-zh-bundles"}
        token = None if anonymous else self.owner_token(owner)
        if token:
            headers["Authorization"] = f"Bearer {token}"
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        status, raw_headers, raw = self.send(method, API + path, headers, data)
        response = Response(status, {k.lower(): v for k, v in raw_headers.items()}, parse_body(raw))
        if response.throttled():
            self.stopped[owner] = response
        return response

    def get(self, owner, path):
        if path not in self.cache:
            self.cache[path] = self.request("GET", owner, path)
        return self.cache[path]

    def release(self, owner, repo, tag):
        path = f"/repos/{repo}/releases/tags/{urllib.parse.quote(tag, safe='')}"
        response = self.get(owner, path)
        # DRAFTS_BOT holds no contents permission; the releases are public either way
        if response.status in (401, 403) and not response.throttled():
            response = self.cache[path] = self.request("GET", owner, path, anonymous=True)
        return response

    def runs(self, owner, repo, workflow):
        # the newest page: a producer still at work, or the run that just made a release, is on it
        return self.get(owner, f"/repos/{repo}/actions/workflows/{workflow}/runs?per_page=100")

    def dispatch(self, owner, repo, workflow, inputs):
        """(response, sent): a request that was never sent cannot have started a run."""
        if not self.owner_token(owner):
            return Response(None, body=f"no token for {owner}"), False
        info = self.get(owner, f"/repos/{repo}")
        if not info.ok:
            return info, False
        ref = info.field("default_branch")
        if not ref:
            return Response(None, body=f"{repo} has no default branch in its metadata"), False
        sent = owner not in self.stopped
        return self.request("POST", owner, f"/repos/{repo}/actions/workflows/{workflow}/dispatches",
                            {"ref": ref, "inputs": inputs}), sent


def parse_body(raw):
    if isinstance(raw, (dict, list)) or raw is None:
        return raw
    try:
        return json.loads(raw) if raw else None
    except (ValueError, UnicodeDecodeError):
        return raw.decode(errors="replace") if isinstance(raw, bytes) else raw


def mentions(title, needle):
    """`needle` as a whole word of a run name: v1.2 is not in v1.2.1, but is in dart-sdk-v1.2."""
    return re.search(rf"(?<![A-Za-z0-9._+]){re.escape(needle)}(?![A-Za-z0-9._+-])", title or "") is not None


def run_matches(run, bundle):
    tag = bundle["tag"]
    needles = {tag, bundle["p"]}
    if re.fullmatch(r"v\d.*", tag):
        needles.add(tag[1:])
    return run.get("head_branch") == tag or any(mentions(run.get("display_title"), n) for n in needles)


def producer_view(workflow, runs, bundle):
    """The newest run of `workflow` for this bundle, in the words autobump-rb accepts."""
    matched = [run for run in runs if run_matches(run, bundle)]
    if not matched:
        return {"workflow": workflow, "run_url": None, "status": "missing", "conclusion": None,
                "completed_at": None}
    # an older run still at work can yet replace the assets a newer one released
    active = [run for run in matched if run["status"] != "completed"]
    run = max(active or matched, key=lambda r: r["created_at"] or "")
    url = run["html_url"]
    if run["status"] != "completed":
        # waiting, requested and pending runs have not started either
        status = "in_progress" if run["status"] == "in_progress" else "queued"
        return {"workflow": workflow, "run_url": url, "status": status, "conclusion": None,
                "completed_at": None}
    conclusion = run["conclusion"] if run["conclusion"] in CONCLUSIONS else None
    # a completed run has no completed_at of its own; its last update is when it finished
    stamps = [run[key] for key in ("updated_at", "run_started_at", "created_at")]
    finished = next((t for t in stamps if t and ISO_TIME.fullmatch(t)), None)
    return {"workflow": workflow, "run_url": url, "status": "completed", "conclusion": conclusion,
            "completed_at": finished}


def gather(api, bundle):
    """What GitHub says about one bundle: (release response, {workflow: response})."""
    owner, repo = bundle["owner"], bundle["repo"]
    release = api.release(owner, repo, bundle["tag"])
    runs = {workflow: api.runs(owner, repo, workflow) for workflow in bundle["producers"]}
    return release, runs


class Verdict(NamedTuple):
    state: str
    reason: str
    producers: tuple = ()
    release_url: str | None = None
    wants_dispatch: bool = False
    rate_limited: bool = False


def judge_bundle(bundle, release, runs):
    """What the facts alone say about one bundle."""
    where = f"{bundle['repo']}@{bundle['tag']}"
    failed = [r for r in [release, *runs.values()] if not r.ok and r.status != 404]
    if failed:
        return Verdict("unknown", f"{where}: {failed[0].describe()}",
                       rate_limited=all(r.rate_limited() for r in failed))
    listed = {}
    for workflow, response in runs.items():
        if response.status == 404:
            return Verdict("escalate", f"{bundle['repo']} has no workflow {workflow}")
        listed[workflow] = response.runs()
        if listed[workflow] is None:
            return Verdict("unknown", f"{where}: unreadable run list of {workflow}")
    producers = [producer_view(wf, listed[wf], bundle) for wf in bundle["producers"]]
    active = [p for p in producers if p["status"] in ACTIVE]
    release_url = None
    if release.ok:
        release_url = release.field("html_url") or f"{SERVER}/{bundle['repo']}/releases/tag/{bundle['tag']}"
    if active:
        reason = f"{where}: {active[0]['workflow']} {active[0]['status']}"
        return Verdict("pending", reason, producers, release_url)
    if release.ok:
        unseen = [p["workflow"] for p in producers if p["status"] == "missing"]
        # a later stage (workflow_run) may not have started yet; the first stage alone is not enough
        if len(producers) > 1 and unseen:
            reason = f"{where}: released, {', '.join(unseen)} not seen yet"
            return Verdict("pending", reason, producers, release_url)
        return Verdict("ready", f"{where}: released", producers, release_url)
    return Verdict("pending", f"{where}: no release and no producer at work", producers, wants_dispatch=True)


def worst(states):
    return max(states, key=SEVERITY.index) if states else "ready"


def history_of(lines, package, version):
    """(kind, run[, bundle]) events for one target since its last reset, in ledger order."""
    events = []
    for line in lines:
        fields = line.split()
        if len(fields) not in (5, 6) or fields[0] != package or fields[1] != version:
            continue
        if fields[2] == "reset":
            events = []
        else:
            events.append((fields[2], *fields[4:]))
    return events


def runs_with(events, kind):
    return {event[1] for event in events if event[0] == kind}


def dispatches_of(events, ident):
    return {event[1] for event in events if event[0] == "dispatch" and event[2:] == (ident,)}


def ledger_line(package, version, kind, run, *extra):
    return " ".join([package, version, kind, datetime.date.today().isoformat(), run, *extra])


def bundle_view(bundle, verdict):
    run_url = next((p["run_url"] for p in verdict.producers if p["run_url"]), None)
    return {"id": bundle["id"], "repo": bundle["repo"], "workflow": bundle["workflow"],
            "release_tag": bundle["tag"], "state": verdict.state, "reason": verdict.reason,
            "producers": list(verdict.producers), "release_url": verdict.release_url, "run_url": run_url}


def dispatch_bundle(api, bundle):
    """(state, reason, counted, rate_limited) after asking for the producer run."""
    where = f"{bundle['repo']}@{bundle['tag']}"
    response, sent = api.dispatch(bundle["owner"], bundle["repo"], bundle["workflow"], bundle["inputs"])
    if response.ok:
        return "pending", f"{where}: dispatched {bundle['workflow']}", True, False
    if response.status in (400, 404, 422):
        reason = f"{where}: {bundle['workflow']} refused the dispatch ({response.describe()})"
        return "escalate", reason, False, False
    # a lost reply or a 5xx may still have started the run; only a 4xx refused it
    counted = sent and (response.status is None or response.status >= 500)
    reason = f"{where}: dispatch not confirmed ({response.describe()})"
    return "unknown", reason, counted, response.rate_limited()


def invalid_target(target, error):
    view = {"id": "-", "repo": "-", "workflow": "-", "release_tag": "-", "state": "escalate",
            "reason": f"overlay.toml: {error}", "producers": [], "release_url": None, "run_url": None}
    return target_result(target, "escalate", [view])


def target_result(target, state, views, observations=0, dispatched=(), escalated_now=False):
    # `reason` and each bundle's `run_url` are what the sweep puts in its issue comments
    reason = "; ".join(v["reason"] for v in views if v["state"] != "ready") or state
    result = {"package": target["package"], "version": target["version"], "state": state, "reason": reason,
              "bundles": views, "observations": observations, "observation_limit": OBSERVATION_LIMIT,
              "dispatched": list(dispatched), "escalated_now": escalated_now}
    if target.get("issue"):
        result["issue"] = str(target["issue"])
    return result


def process_target(api, spec, target, *, mode, events, run, attempt="1"):
    """Judge one (package, version): (snapshot target, ledger lines, failures, warnings).

    mode is status (read-only), prepare (dispatch, no ledger) or plan (dispatch + ledger)."""
    package, version = target["package"], target["version"]
    lines = []
    latched = bool(runs_with(events, "escalate"))
    try:
        bundles = expanded_bundles(spec, package, version)
    except ConfigError as error:
        result = invalid_target(target, error)
        result = latch(result, lines, mode=mode, latched=latched, run=run)
        return result, lines, [f"overlay.toml: {error}"], []

    views, dispatched, deferred = [], [], []
    for bundle in bundles:
        verdict = judge_bundle(bundle, *gather(api, bundle))
        view = bundle_view(bundle, verdict)
        views.append(view)
        if verdict.rate_limited:
            deferred.append(view)
        if not verdict.wants_dispatch:
            continue
        # a rerun keeps its run ID, so the attempt tells its dispatches from the first one's
        sent = dispatches_of(events, bundle["id"])
        if mode == "status":
            view["reason"] += "; prepare would dispatch it"
        elif latched:
            view["reason"] += "; escalated earlier, not dispatched again"
        elif len(sent) >= DISPATCH_LIMIT:
            view["reason"] += f"; dispatched {len(sent)} times already, not again"
        else:
            view["state"], view["reason"], counted, rate_limited = dispatch_bundle(api, bundle)
            if rate_limited:
                deferred.append(view)
            if view["state"] == "pending":
                dispatched.append(bundle["id"])
            if counted and mode == "plan":
                lines.append(ledger_line(package, version, "dispatch", f"{run}.{attempt}", bundle["id"]))
    # judged before the observation limit turns waiting into escalate: these are the broken ones
    failures = [v["reason"] for v in views if v["state"] in ("unknown", "escalate") and v not in deferred]
    warnings = [v["reason"] for v in deferred]

    state = worst([v["state"] for v in views])
    observed = runs_with(events, "observe")
    if mode == "plan" and state == "ready" and (latched or observed):
        # the wait, and any escalation, ends here; a later wait starts over
        lines.append(ledger_line(package, version, "reset", run))
        observed = set()
    if mode == "plan" and state == "pending" and not latched:
        observed = observed | {run}
        lines.append(ledger_line(package, version, "observe", run))
    if state == "pending" and (latched or len(observed) >= OBSERVATION_LIMIT):
        state = "escalate"
        for view in views:
            if view["state"] == "pending":
                view["state"] = "escalate"
                view["reason"] += f"; not ready after {len(observed)} observations"
    result = target_result(target, state, views, len(observed), dispatched)
    return latch(result, lines, mode=mode, latched=latched, run=run), lines, failures, warnings


def latch(result, lines, *, mode, latched, run):
    """An escalation is announced once; it holds until the target becomes ready or is retried."""
    if mode == "plan" and result["state"] == "escalate" and not latched:
        result["escalated_now"] = True
        lines.append(ledger_line(result["package"], result["version"], "escalate", run))
    return result


def run_targets(api, index, errors, targets, *, mode, ledger_lines=(), run="local", attempt="1"):
    """Every target on its own: one package or owner failing never stops the rest.

    A failure ends the run red; a warning is rate limiting, which the next run asks again."""
    results, delta, failures, warnings = [], [], [], []
    # two issues can name one version; it is judged, and dispatched, once
    unique = {}
    for target in targets:
        unique.setdefault((target["package"], target["version"]), target)
    for target in unique.values():
        package, version = target["package"], target["version"]
        if package not in errors and package not in index:
            continue
        events = history_of(ledger_lines, package, version)
        if mode == "plan" and target.get("retry"):
            events = []
            delta.append(ledger_line(package, version, "reset", run))
        if package in errors:
            result, lines = invalid_target(target, errors[package]), []
            latch(result, lines, mode=mode, latched=bool(runs_with(events, "escalate")), run=run)
            failed, waited = [f"overlay.toml: {errors[package]}"], []
        else:
            result, lines, failed, waited = process_target(api, index[package], target, mode=mode,
                                                           events=events, run=run, attempt=attempt)
        results.append(result)
        delta.extend(lines)
        failures.extend(f"{package} {version}: {reason}" for reason in failed)
        warnings.extend(f"{package} {version}: {reason}" for reason in waited)
    for owner, cause in api.stopped.items():
        message = f"{owner}: stopped asking after {cause.describe()}"
        (warnings if cause.rate_limited() else failures).append(message)
    return results, delta, failures, warnings


def snapshot(results, run):
    return {"schema": SCHEMA, "controller_run": run,
            "observed_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "targets": results}


def markdown_link(label, url):
    return f"[{label}]({url})" if url else ""


def summary_table(results):
    rows = ["| package | version | repo | workflow | state | run | release |",
            "|---|---|---|---|---|---|---|"]
    for target in results:
        for b in target["bundles"]:
            release = markdown_link(b["release_tag"], b["release_url"])
            rows.append(f"| `{target['package']}` | {target['version']} | {b['repo']} | {b['workflow']} "
                        f"| {b['state']} | {markdown_link('run', b['run_url'])} | {release} |")
    return "\n".join(rows)


def index_markdown(index, errors):
    rows = ["| package | autobump | id | repo | workflow | producers | tag | inputs |",
            "|---|---|---|---|---|---|---|---|"]
    for package in sorted(index):
        spec = index[package]
        for b in spec["bundles"]:
            inputs = ", ".join(f"{k}={v}" for k, v in b["inputs"].items())
            rows.append(f"| `{package}` | {'yes' if spec['autobump'] else 'no'} | {b['id']} "
                        f"| [{b['repo']}]({SERVER}/{b['repo']}) | {b['workflow']} "
                        f"| {', '.join(b['producers'])} | `{b['tag']}` | {inputs} |")
    for package, error in sorted(errors.items()):
        rows.append(f"| `{package}` | | | | | | | **invalid:** {error} |")
    return "\n".join(rows)


def append_summary(text):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a") as f:
            f.write(text + "\n")


def print_results(results):
    for target in results:
        print(f"{target['package']} {target['version']}: {target['state']}")
        for b in target["bundles"]:
            print(f"  {b['id']}: {b['state']} - {b['reason']}")
            for p in b["producers"]:
                print(f"    {p['workflow']}: {producer_line(p)}")


def producer_line(p):
    return f"{p['status']} {p['conclusion'] or ''} {p['run_url'] or ''}".rstrip()


def write_json(path, value):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(value, indent=1) + "\n")


def report(failures, warnings):
    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    for failure in failures:
        print(f"failed: {failure}", file=sys.stderr)


def die(message, code=2):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def take(argv, flag):
    if flag not in argv:
        return None
    at = argv.index(flag)
    if at + 1 >= len(argv) or argv[at + 1].startswith("--"):
        die(f"{flag} needs a value")
    value = argv[at + 1]
    del argv[at:at + 2]
    return value


def atom_targets(atoms, version, index, errors, overlay):
    if not atoms:
        die("name at least one category/package")
    if version and len(atoms) > 1:
        die("--version applies to one package")
    targets = []
    for atom in atoms:
        if not re.fullmatch(r"[a-z0-9-]+/[A-Za-z0-9_.+-]+", atom):
            die(f"not a category/package: {atom}")
        if atom not in index and atom not in errors:
            die(f"{atom} has no bundle in {DEFAULT_TOML}")
        found = version or tree_version(atom, overlay)
        if not found:
            die(f"{atom}: no ebuild to take a version from; pass --version")
        targets.append({"package": atom, "version": found})
    return targets


def command_list(argv, index, errors):
    if "--markdown" in argv:
        print(index_markdown(index, errors))
    else:
        for package in sorted(index):
            for b in index[package]["bundles"]:
                print(f"{package}\t{b['id']}\t{b['repo']}\t{b['workflow']}\t{b['tag']}")
    for package, error in sorted(errors.items()):
        print(f"{package}: {error}", file=sys.stderr)
    return 2 if errors else 0


def command_has(argv, index, errors):
    if len(argv) != 1:
        die("has takes one category/package")
    (package,) = argv
    if package in errors:
        die(f"{package}: {errors[package]}")
    print("yes" if package in index else "no")
    return 0


def command_where(argv, index, errors, api, overlay):
    version = take(argv, "--version")
    (target,) = atom_targets(argv[:1], version, index, errors, overlay)
    if target["package"] in errors:
        die(f"{target['package']}: {errors[target['package']]}")
    print(f"{target['package']} {target['version']}")
    for b in expanded_bundles(index[target["package"]], target["package"], target["version"]):
        release, runs = gather(api, b)
        verdict = judge_bundle(b, release, runs)
        recent = runs[b["workflow"]].runs()
        last = recent[0] if recent else None
        print(f"  {b['id']}: {SERVER}/{b['repo']}  workflow {b['workflow']}  tag {b['tag']}")
        print(f"    inputs: {json.dumps(b['inputs'])}")
        print(f"    release: {verdict.release_url or 'none'}  state: {verdict.state} ({verdict.reason})")
        for p in verdict.producers:
            print(f"    this tag's {p['workflow']}: {producer_line(p)}")
        if last:
            print(f"    last {b['workflow']} run: {last['display_title']} {last['status']} "
                  f"{last['conclusion'] or ''} {last['html_url']}")
    print(f"  prepare by hand: {SERVER}/{OVERLAY}/actions/workflows/bundles.yml "
          f"(packages={target['package']})")
    return 0


def command_check(argv, index, errors, api, mode, overlay):
    version = take(argv, "--version")
    out = take(argv, "--out")
    targets = atom_targets(argv, version, index, errors, overlay)
    run = os.environ.get("GITHUB_RUN_ID") or "local"
    results, _, failures, warnings = run_targets(api, index, errors, targets, mode=mode, run=run)
    print_results(results)
    if out:
        write_json(out, snapshot(results, run))
    append_summary(f"## bundles {mode}\n\n{summary_table(results)}\n")
    report(failures, warnings)
    return 1 if failures else 0


def command_plan(argv, index, errors, api):
    paths = {flag: take(argv, flag) for flag in ("--targets", "--ledger", "--out", "--delta")}
    missing = [flag for flag, path in paths.items() if not path]
    if missing or argv:
        die(f"plan needs {' '.join(missing) or 'no other arguments'}")
    targets = json.loads(Path(paths["--targets"]).read_text())
    ledger = Path(paths["--ledger"])
    lines = ledger.read_text().splitlines() if ledger.exists() else []
    run = os.environ.get("GITHUB_RUN_ID") or f"p{os.getpid()}"
    results, delta, failures, warnings = run_targets(
        api, index, errors, targets, mode="plan", ledger_lines=lines, run=run,
        attempt=os.environ.get("GITHUB_RUN_ATTEMPT") or "1")
    write_json(paths["--out"], snapshot(results, run))
    # the same shape as a sweep worker's delta, so collect merges it with theirs
    write_json(paths["--delta"], {"done": [], "attempts": [], "bundles": delta, "results": {},
                                  "status_comment_failed": []})
    print_results(results)
    append_summary(f"## bundles\n\n{summary_table(results)}\n\n<details><summary>bundle index</summary>\n\n"
                   f"{index_markdown(index, errors)}\n</details>\n")
    report(failures, warnings)
    return 1 if failures else 0


def main(argv):
    argv = list(argv[1:])
    overlay = take(argv, "--overlay") or "."
    toml = take(argv, "--toml") or Path(overlay, DEFAULT_TOML)
    if not argv:
        die(__doc__.strip())
    command, rest = argv[0], argv[1:]
    index, errors = load_index(toml)
    api = GitHub()
    if command == "list":
        return command_list(rest, index, errors)
    if command == "has":
        return command_has(rest, index, errors)
    if command == "where":
        return command_where(rest, index, errors, api, overlay)
    if command in ("status", "prepare"):
        return command_check(rest, index, errors, api, command, overlay)
    if command == "plan":
        return command_plan(rest, index, errors, api)
    die(f"unknown command {command}")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
