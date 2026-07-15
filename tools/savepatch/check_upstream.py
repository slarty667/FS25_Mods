#!/usr/bin/env python3
"""
check_upstream.py -- proactive upstream-update detector for our personal FS25 mod forks.

THE PROBLEM this solves (that check_forks.py does NOT):
  We patch several third-party mods. Mod-update managers compare a HASH/checksum, so a patched
  mod ALWAYS shows "update available" (our patch changed the bytes) even when upstream released
  nothing new. That signal is therefore useless for our forks -- it's permanently on. And we
  deliberately ignore it (applying it would revert our patch), so we would also miss a REAL
  upstream release.

THE APPROACH:
  Don't compare "patched vs upstream" (always differs). Compare "upstream NOW" vs
  "upstream WHEN WE FORKED" (baseline_version in fork_upstream.json). If upstream moved past our
  baseline -> a real update dropped -> re-fork needed (mirror new zip, re-run patch script, relink).

SOURCES (per fork, from fork_upstream.json):
  * modhub : reads the public ModHub mod page (mod.php?mod_id=...) and extracts the version.
  * github : reads the GitHub Releases API (releases/latest -> tag_name).
  Both are public, read-only. On any fetch failure it degrades to printing the search_query so
  SAM/Markus can just web-search it (the manual method, made repeatable).

Network, read-only. Safe while FS is running.
Exit 0 = every fork at/above baseline (nothing to do). Exit 1 = at least one real upstream update.

Usage:
    python3 check_upstream.py            # check all forks
    python3 check_upstream.py --offline  # skip fetching, just print baselines + search queries
"""

import argparse
import json
import os
import re
import ssl
import sys
import urllib.request
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
REGISTRY = os.path.join(HERE, "fork_upstream.json")
LIBRARY = os.path.expanduser("~/FS25_ModLibrary")
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) fsmods-fork-checker/1.0"
TIMEOUT = 12


def _ssl_context():
    """macOS system Python often lacks CA certs -> use certifi's bundle if available."""
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


SSL_CTX = _ssl_context()


def ver_tuple(v):
    """'1.10.2' -> (1,10,2). Non-numeric parts drop to 0. Pads for safe compare."""
    parts = re.findall(r"\d+", v or "")
    return tuple(int(p) for p in parts) if parts else (0,)


def cmp_ver(a, b):
    ta, tb = ver_tuple(a), ver_tuple(b)
    n = max(len(ta), len(tb))
    ta += (0,) * (n - len(ta))
    tb += (0,) * (n - len(tb))
    return (ta > tb) - (ta < tb)


def http_get(url, accept=None):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    if accept:
        req.add_header("Accept", accept)
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=SSL_CTX) as r:
        return r.read().decode("utf-8", "ignore")


def modhub_version(mod_id):
    """Best-effort parse of the current version from a ModHub mod page."""
    url = "https://www.farming-simulator.com/mod.php?mod_id=%s&title=fs2025" % mod_id
    html = http_get(url)
    # ModHub renders the version in the table-cell AFTER a "<b>Version</b>" label cell.
    pats = [
        r"<b>\s*Version\s*</b>\s*</div>\s*<div[^>]*>\s*([0-9]+(?:\.[0-9]+){1,3})",
        r"Version\s*</[^>]+>\s*</div>\s*<div[^>]*>\s*([0-9]+(?:\.[0-9]+){1,3})",
        r"\"version\"\s*:\s*\"([0-9]+(?:\.[0-9]+){1,3})\"",
    ]
    for p in pats:
        m = re.search(p, html, re.IGNORECASE)
        if m:
            return m.group(1), url
    return None, url


def github_version(repo):
    """Latest release tag via the GitHub API."""
    url = "https://api.github.com/repos/%s/releases/latest" % repo
    data = json.loads(http_get(url, accept="application/vnd.github+json"))
    tag = (data.get("tag_name") or "").lstrip("vV")
    return (tag or None), "https://github.com/%s/releases" % repo


def lib_version(mod):
    """modDesc <version> from the library zip (sanity vs baseline)."""
    import zipfile
    path = os.path.join(LIBRARY, mod + ".zip")
    try:
        with zipfile.ZipFile(path) as z:
            md = z.read("modDesc.xml").decode("utf-8", "ignore")
        m = re.search(r"<version>\s*([^<\s]+)\s*</version>", md)
        return m.group(1) if m else "?"
    except Exception:
        return "n/a"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--offline", action="store_true")
    args = ap.parse_args()

    with open(REGISTRY, encoding="utf-8") as f:
        reg = json.load(f)

    updates = 0
    manual = 0
    print("FS25 fork UPSTREAM check (upstream-now vs our fork baseline)")
    print("=" * 64)

    for mod, spec in reg["forks"].items():
        baseline = spec["baseline_version"]
        libv = lib_version(mod)
        print("\n### %s" % mod)
        drift = "  (!! library %s != baseline %s)" % (libv, baseline) if libv not in (baseline, "n/a", "?") else ""
        print("    fork baseline : %s%s" % (baseline, drift))

        if args.offline:
            print("    upstream      : (offline) -> web-search: %s" % spec.get("search_query", mod))
            manual += 1
            continue

        best = None
        for src in spec.get("sources", []):
            try:
                if src["type"] == "modhub":
                    v, url = modhub_version(src["id"])
                elif src["type"] == "github":
                    v, url = github_version(src["repo"])
                else:
                    continue
            except (urllib.error.URLError, urllib.error.HTTPError, ValueError, TimeoutError) as e:
                print("    upstream      : %s fetch failed (%s)" % (src["type"], e))
                v, url = None, None
            if v:
                print("    upstream      : %-9s  [%s] %s" % (v, src["type"], url))
                if best is None or cmp_ver(v, best) > 0:
                    best = v

        if best is None:
            print("    >> could not auto-read upstream -> web-search: %s" % spec.get("search_query", mod))
            manual += 1
            continue

        c = cmp_ver(best, baseline)
        if c > 0:
            updates += 1
            print("    >> UPDATE: upstream %s > baseline %s -> RE-FORK." % (best, baseline))
            print("       mirror new zip into library, run %s --apply, then fsmods use <profile>,"
                  % spec.get("patch_script", "the patch script"))
            print("       then bump baseline_version in fork_upstream.json.")
        elif c < 0:
            print("    >> upstream %s < baseline %s (odd: baseline ahead of upstream? verify)." % (best, baseline))
        else:
            print("    == up to date (upstream == baseline).")

    # --- Watchlist: mods we do NOT patch, only monitor for maturity / new versions ---
    watch_updates = 0
    watchlist = reg.get("watchlist", {})
    if watchlist:
        print("\n" + "-" * 64)
        print("WATCHLIST (monitored for maturity -- NOT forks, no re-fork ever)")
        for mod, spec in watchlist.items():
            baseline = spec.get("baseline_version", "?")
            print("\n### %s" % mod)
            if spec.get("note"):
                print("    note          : %s" % spec["note"])
            print("    last seen     : %s" % baseline)

            if args.offline:
                print("    upstream      : (offline) -> web-search: %s" % spec.get("search_query", mod))
                manual += 1
                continue

            best = None
            for src in spec.get("sources", []):
                try:
                    if src["type"] == "modhub":
                        v, url = modhub_version(src["id"])
                    elif src["type"] == "github":
                        v, url = github_version(src["repo"])
                    else:
                        continue
                except (urllib.error.URLError, urllib.error.HTTPError, ValueError, TimeoutError) as e:
                    print("    upstream      : %s fetch failed (%s)" % (src["type"], e))
                    v, url = None, None
                if v:
                    print("    upstream      : %-9s  [%s] %s" % (v, src["type"], url))
                    if best is None or cmp_ver(v, best) > 0:
                        best = v

            if best is None:
                print("    >> could not auto-read upstream -> web-search: %s" % spec.get("search_query", mod))
                manual += 1
                continue

            if cmp_ver(best, baseline) > 0:
                watch_updates += 1
                print("    >> NEW VERSION: %s > last-seen %s -> REVISIT (evaluate switching; NOT a re-fork)." % (best, baseline))
                print("       if you adopt it, bump baseline_version in fork_upstream.json to %s." % best)
            else:
                print("    == no change since last seen (%s)." % baseline)

    print("\n" + "=" * 64)
    print("RESULT: %d real upstream update(s), %d watchlist update(s), %d need manual web-search."
          % (updates, watch_updates, manual))
    sys.exit(1 if (updates or watch_updates) else 0)


if __name__ == "__main__":
    main()
