#!/usr/bin/env python3
#
# Cloudfull
#
# Copyright (C) 2026 Marshall Ross.
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""Builds the Cloudfull usage dashboard HTML page from one data pull, so
every number on the page agrees with every other number -- and with
scripts/usage_report.py's own text report, which it reuses for every
definition (actions, shrink funnel, after-delete windows, reminder funnel,
bin empties, bytes freed, first-deal timing, health).

Usage:
  CLOUDFULL_TEAM_ID=... python3 scripts/usage_dashboard.py --out ~/Desktop/usage-dashboard.html
  CLOUDFULL_TEAM_ID=... python3 scripts/usage_dashboard.py --env production --month 2026-10 --channel appStore --out ~/Desktop/usage-dashboard.html
  python3 scripts/usage_dashboard.py --from-json ~/Desktop/usage-pull.json --month 2026-10 --out ~/Desktop/usage-dashboard.html   # offline, no cktool call
  CLOUDFULL_TEAM_ID=... python3 scripts/usage_dashboard.py --dump-json ~/Desktop/usage-pull.json --out ~/Desktop/usage-dashboard.html   # save the pull for later --from-json runs

This script never hand-types a number onto the page. Every tile, bar,
funnel, and table cell is computed from the same list of session dicts
(`S`). Before the page is written, the script also runs
scripts/usage_report.py's own main() over that exact same session list
(by swapping in its fetch() so it never hits the network) and compares
its printed totals -- phones/sessions, the Q1 action lines, the shrink
funnel, and the bytes-freed total -- against the page's own numbers.
That is a real cross-check between two independently written scripts,
not just two code paths in this file re-deriving the same sum; the
script exits loudly if the two disagree about the same data, instead of
writing a page nobody can trust.

When --channel appStore is in effect (the default), a TestFlight tester
who later installs the real App Store build keeps the same installId,
so a plain per-session channel filter lets them leak onto the page. The
script instead pulls every month from APP_STORE_LAUNCH (or --launch)
through --month and drops an install -- not just a session -- the moment
any of its sessions in that whole pull was not an appStore session, or
any of its appStore sessions claims to be older than launch day allows.
"""
import argparse, collections, contextlib, datetime, html as html_mod, io, json, os, re, sys

# The day Cloudfull went live on the App Store. An install whose own
# appStore sessions claim to predate this (allowing a day of time-zone
# slack) was not a real customer for that whole stretch -- see
# determine_surviving_installs().
APP_STORE_LAUNCH = "2026-10-29"


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", default="production", choices=["development", "production"])
    ap.add_argument("--channel", default="appStore", choices=["appStore", "testFlight", "unknown", "all"],
                     help="Only sessions whose installChannel fact has this value. 'all' disables the filter.")
    ap.add_argument("--month", default=datetime.date.today().strftime("%Y-%m"), help="YYYY-MM")
    ap.add_argument("--launch", default=APP_STORE_LAUNCH, help="YYYY-MM-DD. Used only with --channel appStore.")
    ap.add_argument("--out", required=True, help="Where to write the HTML page.")
    ap.add_argument("--from-json", help="Read session dicts from this file instead of calling cktool (offline).")
    ap.add_argument("--dump-json", help="Save the pulled session dicts to this file.")
    return ap.parse_args()


ARGS = parse_args()

# usage_report.py sys.exit()s at import time if CLOUDFULL_TEAM_ID is unset --
# fine when we are about to hit the network, but it would needlessly block
# an offline --from-json run (which never calls fetch()) from even importing
# device_name()/pct()/avg(). Guard the real requirement ourselves, first.
if not ARGS.from_json and not os.environ.get("CLOUDFULL_TEAM_ID") and not os.environ.get("CLOUDKIT_KEY_ID"):
    sys.exit("Set CLOUDFULL_TEAM_ID (cktool on a Mac) or CLOUDKIT_KEY_ID + CLOUDKIT_KEY_PATH (server-to-server key).")
os.environ.setdefault("CLOUDFULL_TEAM_ID", "OFFLINE-FROM-JSON")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import usage_report  # noqa: E402  (must come after the TEAM_ID guard above)

def esc(s):
    return html_mod.escape(str(s))

CHANNEL_LABEL = {
    "appStore": "App Store customers only",
    "testFlight": "TestFlight testers only",
    "unknown": "Install channel unknown",
    "all": "Every install channel",
}
CHANNEL_INTRO = {
    "appStore": "Only real App Store downloads. TestFlight, App Review, and the owner's debug builds are left out.",
    "testFlight": "Only TestFlight builds. App Store customers and the owner's debug builds are left out.",
    "unknown": "Only sessions whose install channel could not be determined.",
    "all": "Every install channel -- App Store, TestFlight, and unknown -- combined.",
}
CHANNEL_SAMPLE_WORD = {
    "appStore": "App Store",
    "testFlight": "TestFlight",
    "unknown": "install-channel-unknown",
    "all": "",
}

# Value -> display label for the small set of enum facts the Q2 panel
# shows. Anything not listed falls through to humanize().
SPECIAL_LABELS = {
    "iPhone": "iPhone", "iPadCompat": "iPad (compatibility mode)", "mac": "Mac", "other": "Other",
    "videos": "Videos", "photos": "Photos",
}


def humanize(v):
    """Turns a raw camelCase/boolean fact value into a short display label.
    Leaves acronyms and already-cased tokens (XL, US, iPhone) alone."""
    if v is None or v == "":
        return "None"
    if v in SPECIAL_LABELS:
        return SPECIAL_LABELS[v]
    if v in ("0", "1"):
        return {"0": "off", "1": "on"}[v]
    spaced = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", v)
    if spaced == v:
        # No camelCase boundary found -- either a plain lowercase word
        # ("random") or an acronym/mixed token ("XL", "US"). Only the
        # former should be capitalized; leave the rest untouched.
        return v[0].upper() + v[1:] if v.islower() else v
    words = spaced.split()
    return " ".join([words[0][0].upper() + words[0][1:]] + [w.lower() for w in words[1:]])


def gb(b):
    return f"{b / 1e9:.2f} GB"


def largest_remainder_pcts(counts, total):
    """Rounds each count's share of `total` to a whole percent so the
    parts sum to exactly 100 (the largest-remainder / Hamilton method),
    instead of rounding each one separately with usage_report.pct(),
    which can drift a point or two off 100 once several parts are shown
    side by side. Returns one int per entry in `counts`, same order."""
    if not total:
        return [0] * len(counts)
    raw = [100 * c / total for c in counts]
    floors = [int(r) for r in raw]
    remainder = 100 - sum(floors)
    order = sorted(range(len(counts)), key=lambda i: raw[i] - floors[i], reverse=True)
    out = list(floors)
    for i in order[:remainder]:
        out[i] += 1
    return out


def month_name(month):
    y, m = int(month[:4]), int(month[5:7])
    return datetime.date(y, m, 1).strftime("%B %Y")


def render_dist(counter, label_fn=None, top_n=8):
    """"<b>62%</b> On this date · 38% None" -- most-common value bold, the
    rest in order, every label escaped."""
    label_fn = label_fn or (lambda v: v if v not in (None, "") else "None")
    total = sum(counter.values())
    if not total:
        return "<b>–</b>"
    parts = []
    for i, (v, n) in enumerate(counter.most_common(top_n)):
        p = usage_report.pct(n, total)
        lbl = esc(label_fn(v))
        parts.append(f"<b>{p}</b> {lbl}" if i == 0 else f"{p} {lbl}")
    return " · ".join(parts)


# ---------------------------------------------------------------------------
# Data loading and filtering -- the one data pull everything else reads from.
# ---------------------------------------------------------------------------

def month_range(launch_date, month):
    """Every "YYYY-MM" from the launch month through `month`, inclusive.
    If `launch_date` falls after `month` (viewing a month before launch),
    there is no real range -- just `month` itself."""
    ly, lm = int(launch_date[:4]), int(launch_date[5:7])
    ty, tm = int(month[:4]), int(month[5:7])
    y, m = (ly, lm) if (ly, lm) <= (ty, tm) else (ty, tm)
    months = []
    while (y, m) <= (ty, tm):
        months.append(f"{y:04d}-{m:02d}")
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)
    return months


def load_sessions(args):
    if args.from_json:
        with open(args.from_json, "r", encoding="utf-8") as f:
            raw = json.load(f)
    elif args.channel == "appStore":
        # The per-install tester rule (see determine_surviving_installs)
        # needs every session an install has ever made, not just this
        # month's -- a tester's install can look spotless in isolation
        # in the one month we would otherwise have pulled.
        raw = []
        for m in month_range(args.launch, args.month):
            raw.extend(usage_report.fetch(args.env, m))
    else:
        raw = usage_report.fetch(args.env, args.month)
    if args.dump_json:
        with open(args.dump_json, "w", encoding="utf-8") as f:
            json.dump(raw, f, indent=2)
    return raw


def days_since_launch(day, launch_date):
    """Whole days from `launch_date` to a session's `day` (YYYY-MM-DD).
    None if `day` is missing, blank, or not a real date (a malformed
    pull record should never crash this, just fail to vote either way)."""
    if not day:
        return None
    try:
        return (datetime.date.fromisoformat(day) - datetime.date.fromisoformat(launch_date)).days
    except ValueError:
        return None


def tester_reason(sessions, launch_date):
    """None if this install's sessions, taken over the whole pull, look
    like a real App Store customer. Otherwise the reason to drop it:
    - "predates launch": one of its own appStore sessions claims a
      daysSinceInstall further back than launch day allows (plus a
      day of time-zone slack) -- the install existed before the App
      Store build did, so it was not using the App Store build then.
    - "non-appStore session": at least one of its sessions in the pull
      was not installChannel appStore at all (TestFlight, unknown, or
      the fact missing entirely)."""
    predates_launch = False
    has_non_app_store = False
    for r in sessions:
        if r["facts"].get("installChannel") != "appStore":
            has_non_app_store = True
            continue
        dsi = r.get("daysSinceInstall")
        if not isinstance(dsi, int):
            continue
        elapsed = days_since_launch(r.get("day"), launch_date)
        if elapsed is None:
            continue
        if dsi > elapsed + 1:
            predates_launch = True
    if predates_launch:
        return "predates launch"
    if has_non_app_store:
        return "non-appStore session"
    return None


def determine_surviving_installs(raw, launch_date):
    """Applies the per-install tester rule over the WHOLE pull (every
    month from launch through the target month), not just the month
    being displayed. Returns (surviving install ids, [reason per
    dropped install worth reporting]).

    Every dropped install is excluded from `survivors` -- that part has
    to look at the whole pull regardless of whether the install ever
    had an appStore session. But an install with no appStore session
    anywhere in the pull (plain TestFlight/dev noise) was never a
    candidate to leak onto an App Store page in the first place, so it
    is left out of the reported reasons -- those are for the installs
    that could actually have been mistaken for a real customer."""
    by_install = collections.defaultdict(list)
    for r in raw:
        by_install[r["install"]].append(r)
    survivors, dropped = set(), []
    for install, sessions in by_install.items():
        reason = tester_reason(sessions, launch_date)
        if reason is None:
            survivors.add(install)
            continue
        if any(r["facts"].get("installChannel") == "appStore" for r in sessions):
            dropped.append(reason)
    return survivors, dropped


def print_dropped(dropped):
    """stdout only, never the page, and never an install id -- just how
    many installs the tester rule dropped and why."""
    if not dropped:
        return
    n = len(dropped)
    reasons = collections.Counter(dropped)
    if len(reasons) == 1:
        why = next(iter(reasons))
    else:
        why = ", ".join(f"{cnt} {reason}" for reason, cnt in reasons.most_common())
    print(f"dropped {n} install{'s' if n != 1 else ''}: {why}")


def filter_sessions(raw, args):
    month, channel = args.month, args.channel
    S_month = [r for r in raw if r["day"].startswith(month)]
    if channel == "appStore":
        survivors, dropped = determine_surviving_installs(raw, args.launch)
        print_dropped(dropped)
        S = [r for r in S_month if r["install"] in survivors]
    elif channel != "all":
        S = [r for r in S_month if r["facts"].get("installChannel") == channel]
    else:
        S = S_month
    if not S:
        sys.exit(f"no UsageSession records for {month}" + (f" with installChannel {channel}" if channel != "all" else ""))
    # Same Duo pose-twin split usage_report.py's main() does, so a Duo
    # session's `action.videos.keep@1V` twin never double-counts a plain
    # `action.videos.keep` the dashboard reads out of `counts`.
    for r in S:
        r["poseCounts"] = {k: v for k, v in r["counts"].items() if "@" in k}
        r["counts"] = {k: v for k, v in r["counts"].items() if "@" not in k}
    return S


def compute_core(S):
    """The shared aggregates every section below reads from -- one pass
    over S, exactly as usage_report.py's main() builds them."""
    M = {}
    M["n_phones"] = len({r["install"] for r in S})
    latest = {}
    for r in sorted(S, key=lambda r: r["startedAt"] or ""):
        latest[r["install"]] = r
    M["latest"] = latest
    C = collections.Counter()
    for r in S:
        C.update(r["counts"])
    M["C"] = C
    F = collections.defaultdict(collections.Counter)
    for r in S:
        for k, v in r["facts"].items():
            F[k][v] += 1
        for k in ("country", "photoPermissionAtStart", "endReason", "daysSinceInstall"):
            if r.get(k) is not None:
                F[k][str(r[k])] += 1
    M["F"] = F

    def fnums(key):
        return [int(r["facts"][key]) for r in S if key in r["facts"] and r["facts"][key].lstrip("-").isdigit()]
    M["fnums"] = fnums
    secs = [r["sessionSeconds"] for r in S if isinstance(r.get("sessionSeconds"), int)] or fnums("sessionSeconds")
    M["secs"] = secs
    return M


ACTION_CATS = ("delete", "shrink", "keep", "share", "album")


# ---------------------------------------------------------------------------
# Tiles
# ---------------------------------------------------------------------------

def build_tiles(M, S):
    C = M["C"]
    deleted_b, shrunk_b, total_b = C.get("bytesFreed.byDelete", 0), C.get("bytesFreed.byShrink", 0), C.get("bytesFreed.total", 0)

    binLatest = {}
    for r in sorted(S, key=lambda r: r["startedAt"] or ""):
        if "binItemsAtEnd" in r["facts"]:
            binLatest[r["install"]] = r
    never = [r for r in binLatest.values() if int(r["facts"].get("binItemsAtEnd", "0") or 0) > 0
             and not any(x["counts"].get("bin.emptiedCount") for x in S if x["install"] == r["install"])]
    # Bytes waiting is summed only over the phones actually counted in
    # `never` below -- summing every phone with a binBytesAtEnd fact (most
    # of which DID empty the bin this month) would report more bytes than
    # the "N phones that..." sentence is about.
    never_bin_waiting = sum(int(r["facts"].get("binBytesAtEnd", "0") or 0) for r in never)
    empties = C.get("bin.emptiedCount", 0)
    saved_note = f"{gb(deleted_b)} deleted + {gb(shrunk_b)} shrunk. "
    if empties:
        saved_note += f"The bin has been emptied {empties} time{'s' if empties != 1 else ''} this month. "
    else:
        saved_note += "Nobody emptied the bin this month. "
    if never:
        saved_note += f"{gb(never_bin_waiting)} waits in the bin on {len(never)} phone{'s' if len(never) != 1 else ''} that did not empty it this month."
    else:
        saved_note += "No bytes are waiting in the bin."

    cat_totals = {cat: sum(C.get(f"action.{m}.{cat}", 0) for m in ("videos", "photos")) for cat in ACTION_CATS}
    grand = sum(cat_totals.values())
    ranked = sorted(cat_totals.items(), key=lambda kv: -kv[1])
    top_cat, _ = ranked[0]
    if grand == 0:
        action_note = "No actions recorded yet."
    else:
        # Largest-remainder rounding so these percentages add up to
        # exactly 100, instead of each one rounding independently.
        pcts = largest_remainder_pcts([n for _, n in ranked], grand)
        action_note = (
            f"{pcts[0]}% of all actions. " +
            ", ".join(f"{humanize(c)} {p}%" for (c, _), p in zip(ranked[1:], pcts[1:])) + "."
        )

    dels = C.get("action.videos.delete", 0) + C.get("action.photos.delete", 0)
    restores = C.get("bin.restore", 0)

    return f"""
  <div class="tiles">
    <div class="tile">
      <div class="q">Total space saved</div>
      <div class="big">{gb(total_b)}</div>
      <div class="note">{esc(saved_note)}</div>
    </div>
    <div class="tile">
      <div class="q">Most used action</div>
      <div class="big">{esc(humanize(top_cat)) if grand else "–"}</div>
      <div class="note">{esc(action_note)}</div>
    </div>
    <div class="tile">
      <div class="q">Bin restores</div>
      <div class="big">{restores}</div>
      <div class="note">{esc(usage_report.pct(restores, dels))} of deletes.</div>
    </div>
  </div>""", {"cat_totals": cat_totals}


# ---------------------------------------------------------------------------
# Q1 -- action bars, shrink funnel, after-delete split
# ---------------------------------------------------------------------------

def build_q1(M, S):
    C = M["C"]
    rows = []
    for cat in ACTION_CATS:
        v, p = C.get(f"action.videos.{cat}", 0), C.get(f"action.photos.{cat}", 0)
        rows.append((cat, v, p))
    rows.sort(key=lambda r: -(r[1] + r[2]))
    max_cell = max([v for _, v, p in rows] + [p for _, v, p in rows]) or 0

    bar_rows_html = []
    for cat, v, p in rows:
        wv = f"{100 * v / max_cell:.0f}" if max_cell else "0"
        wp = f"{100 * p / max_cell:.0f}" if max_cell else "0"
        bar_rows_html.append(
            f'<div class="row"><div class="label">{esc(humanize(cat))}</div>'
            f'<div class="track"><div class="bar v" style="width:{wv}%"></div><div class="bar p" style="width:{wp}%"></div></div>'
            f'<div class="num"><b class="v">{v}</b><b class="p">{p}</b></div></div>'
        )

    unknownV, unknownP = C.get("deleted.videos.sizeUnknown", 0), C.get("deleted.photos.sizeUnknown", 0)
    share_targets = {k[len("shareTarget."):]: n for k, n in C.items() if k.startswith("shareTarget.") and k != "shareTarget.cancelled"}
    top_share = max(share_targets.items(), key=lambda kv: kv[1]) if share_targets else None
    if max_cell:
        top_cat, top_v, top_p = rows[0]
        top_mode, top_n = ("videos", top_v) if top_v >= top_p else ("photos", top_p)
        note = f"Bar length uses one scale for all rows: the longest bar ({humanize(top_cat).lower()} {top_mode}, {top_n}) is 100%."
    else:
        note = "No actions recorded yet."
    if unknownV or unknownP:
        note += f" Size unknown at tap: {unknownV} videos, {unknownP} photos."
    if top_share:
        note += f" Most shares went to {esc(top_share[0])}, {top_share[1]}."

    action_bars_html = f"""
    <div class="panel">
      <div class="legend"><span class="v">Videos</span><span class="p">Photos</span></div>
      <div class="bars">
        {''.join(bar_rows_html)}
      </div>
      <p>{note}</p>
    </div>"""

    sheet = C.get("shrink.sheet", 0)
    started = C.get("action.videos.shrink", 0) + C.get("action.photos.shrink", 0)
    done = C.get("shrink.done", 0)
    failed = C.get("shrink.failed", 0)
    funnel_html = f"""
    <div class="panel">
      <h3>Shrink funnel</h3>
      <div class="funnel">
        <div class="step"><div class="n">{sheet}</div><div class="t">Opened the shrink sheet</div><div class="pct">&nbsp;</div></div>
        <div class="step"><div class="n">{started}</div><div class="t">Started a shrink</div><div class="pct">{esc(usage_report.pct(started, sheet))} of sheets opened</div></div>
        <div class="step"><div class="n">{done}</div><div class="t">Finished</div><div class="pct">{esc(usage_report.pct(done, started))} of starts</div></div>
        <div class="step"><div class="n">{failed}</div><div class="t">Failed</div><div class="pct">{esc(usage_report.pct(failed, started))} of starts</div></div>
      </div>
    </div>"""

    split_cols = []
    for m in ("videos", "photos"):
        ad = {k: C.get(f"afterDelete.{m}.{k}", 0) for k in ("back", "swipe", "stay")}
        t = sum(ad.values())
        title = f'<h3 style="margin-bottom:0">{m.capitalize()}' + (f' <small style="font-weight:400">(n={t})</small>' if t else "") + "</h3>"
        if not t:
            split_cols.append(f'<div>{title}<p style="margin-top:8px">No {m} deletes yet.</p></div>')
            continue
        stay, swipe, back = usage_report.pct(ad["stay"], t), usage_report.pct(ad["swipe"], t), usage_report.pct(ad["back"], t)

        def w(n):
            return f"{100 * n / t:.0f}"
        split_cols.append(
            f'<div>{title}<div class="stack {"vid" if m == "videos" else "pho"}" style="margin-top:8px">'
            f'<div class="a" style="width:{w(ad["stay"])}%">Stay · {stay}</div>'
            f'<div class="b" style="width:{w(ad["swipe"])}%">On · {swipe}</div>'
            f'<div class="c" style="width:{w(ad["back"])}%">Back · {back}</div>'
            f"</div></div>"
        )
    after_delete_html = f"""
    <div class="panel">
      <h3>After a delete, the next 5 seconds</h3>
      <div class="split">
        {''.join(split_cols)}
      </div>
      <p>Stay: the person stays on the next item. On: the person swipes forward to another item within 5 seconds. Back: the person goes back within 5 seconds.</p>
    </div>"""

    return f"""
  <section>
    <h2>Q1 · Which actions get used</h2>{action_bars_html}{funnel_html}{after_delete_html}
  </section>""", {
        "sheet": sheet, "cancel": C.get("shrink.cancel", 0), "started": started,
        "done": done, "failed": failed,
    }


# ---------------------------------------------------------------------------
# Q2 -- settings and device defaults
# ---------------------------------------------------------------------------

def build_q2(M, S):
    F, latest = M["F"], M["latest"]

    def row(label, small, value_html):
        small_html = f" <small>{esc(small)}</small>" if small else ""
        return f'<div class="def"><div class="k">{esc(label)}{small_html}</div><div class="v">{value_html}</div></div>'

    phone_groups = order_phone_groups(S)
    per_phone = [phone_facts(g, latest[g[0]["install"]]) for g in phone_groups]
    on_groups = [g for g, f in zip(phone_groups, per_phone) if f["reminder_on"]]
    hours = collections.Counter(latest[g[0]["install"]]["facts"].get("dailyReminderHourSetting", "?") for g in on_groups)
    hour_txt = f" · {hours.most_common(1)[0][0]}:00" if hours and hours.most_common(1)[0][0] != "?" else ""
    reminders_on = len(on_groups)
    n_phones = len(per_phone)
    reminder_html = f'<b>{reminders_on} of {n_phones}</b> phones ({usage_report.pct(reminders_on, n_phones)}){hour_txt}'

    rows = [
        row("Default tab", "Settings → Playback", render_dist(F.get("defaultTabSetting", collections.Counter()), humanize)),
        row("Open muted", None, render_dist(F.get("openMutedSetting", collections.Counter()), humanize)),
        row("Live Photos on entry", None, render_dist(F.get("liveDefaultSetting", collections.Counter()), humanize)),
        row("Daily reminder", None, reminder_html),
        row("Video sort", None, render_dist(F.get("sort.videos", collections.Counter()), humanize)),
        row("Video filters", "per session", render_dist(F.get("filters.videos", collections.Counter()), humanize)),
        row("Photo filters", "per session", render_dist(F.get("filters.photos", collections.Counter()), humanize)),
        row("Text size", None, render_dist(F.get("textSize", collections.Counter()), humanize)),
        row("Dark mode", None, render_dist(F.get("darkModeSetting", collections.Counter()), humanize)),
        row("Low Power Mode at start", None, render_dist(F.get("lowPowerAtStart", collections.Counter()), humanize)),
        row("Left-handed controls", None, render_dist(F.get("leftHandedSetting", collections.Counter()), humanize)),
        row("Runs on", None, render_dist(F.get("runsOn", collections.Counter()), humanize)),
    ]

    html = f"""
  <section>
    <h2>Q2 · Settings people have</h2>
    <div class="panel">
      <div class="defaults">
        {''.join(rows)}
      </div>
      <p>Each row counts sessions, not people, except Daily reminder, which counts phones. One phone that opens the app many times counts many sessions.</p>
    </div>
  </section>"""
    return html, {"reminders_on": reminders_on, "n_phones": n_phones}


# ---------------------------------------------------------------------------
# Reminder funnel
# ---------------------------------------------------------------------------

def build_reminder(M, S):
    C, F = M["C"], M["F"]
    y = C.get("dailyReminderAsk.firstDelete.yes", 0)
    n = C.get("dailyReminderAsk.firstDelete.notNow", 0)
    asked = y + n
    allowed = C.get("notificationPermission.allowed", 0)
    denied = C.get("notificationPermission.denied", 0)
    yes_pct = usage_report.pct(y, asked)
    ios_txt = f" · iOS allowed {allowed} of {allowed + denied}" if (allowed + denied) else ""
    fromNote = F.get("openedFromNotification", {}).get("1", 0)
    reached = C.get("onThisDateEndPage.videos.reached", 0)

    return f"""
  <section>
    <h2>Reminder · from the first delete to the end page</h2>
    <div class="panel">
      <div class="funnel">
        <div class="step"><div class="n">{asked}</div><div class="t">Asked at first delete</div><div class="pct">&nbsp;</div></div>
        <div class="step"><div class="n">{y}</div><div class="t">Said yes</div><div class="pct">{esc(yes_pct)}{esc(ios_txt)}</div></div>
        <div class="step"><div class="n">{fromNote}/{len(S)}</div><div class="t">Sessions opened from a notification</div><div class="pct">{esc(usage_report.pct(fromNote, len(S)))} of sessions</div></div>
        <div class="step"><div class="n">{reached}</div><div class="t">Reached the end page (videos)</div><div class="pct">&nbsp;</div></div>
      </div>
    </div>
  </section>"""


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

def build_health(M, S):
    C, F, fnums = M["C"], M["F"], M["fnums"]
    photoFail, videoFail, slow = C.get("photoLoadFailedCount", 0), C.get("videoLoadFailedCount", 0), C.get("slowDownloadCount", 0)
    # mainThreadStallsOver250ms is DEBUG-only instrumentation and is
    # always 0 in an App Store build -- no row for it, and it never
    # enters the clean/not-clean summary below.
    midPlayStalls = C.get("video.stalledMidPlay", 0)
    crashKill = F.get("endReason", {}).get("crashOrKill", 0)
    cold = sum(1 for r in S if r["coldStart"])

    def first_shown(mode):
        xs = fnums(f"firstLoadMs.{mode}")
        if not xs:
            return "–", 0
        return f"{(sum(xs) / len(xs)) / 1000:.2f} s", len(xs)
    vid_s, vid_n = first_shown("videos")
    pho_s, pho_n = first_shown("photos")

    tipTap = {k[len("tip.tapped."):]: n for k, n in C.items() if k.startswith("tip.tapped.")}
    tipOut = {k[len("tip.outcome."):]: n for k, n in C.items() if k.startswith("tip.outcome.")}
    tipUn = {k[len("tip.unavailable."):]: n for k, n in C.items() if k.startswith("tip.unavailable.")}
    if not (tipTap or tipOut or tipUn):
        tips_html = "none yet."
    else:
        parts = []
        if tipTap:
            parts.append("taps " + ", ".join(f"{esc(k)}={n}" for k, n in sorted(tipTap.items())))
        if tipOut:
            parts.append("outcomes " + ", ".join(f"{esc(k)}={n}" for k, n in sorted(tipOut.items())))
        if tipUn:
            parts.append("unavailable " + ", ".join(f"{esc(k)}={n}" for k, n in sorted(tipUn.items())))
        tips_html = "; ".join(parts)

    rows = [
        ("Photo load failed", f"<b>{photoFail}</b>"),
        ("Video load failed", f"<b>{videoFail}</b>"),
        ("Slow downloads", f"<b>{slow}</b>"),
        ("Mid-play video stalls", f"<b>{midPlayStalls}</b>"),
        ("Sessions ended by crash or kill", f"<b>{crashKill} of {len(S)}</b> ({esc(usage_report.pct(crashKill, len(S)))})"),
        ("Cold opens", f"<b>{cold} of {len(S)}</b> ({esc(usage_report.pct(cold, len(S)))})"),
        ("First video shown, average", f"<b>{esc(vid_s)}</b> (n={vid_n})"),
        ("First photo shown, average", f"<b>{esc(pho_s)}</b> (n={pho_n})"),
        ("Tips", tips_html),
    ]
    rows_html = "".join(f'<div class="def"><div class="k">{esc(label)}</div><div class="v">{value}</div></div>' for label, value in rows)

    if crashKill == 0 and midPlayStalls == 0 and slow == 0 and photoFail == 0 and videoFail == 0:
        summary = f"All {len(S)} session{'s' if len(S) != 1 else ''} end cleanly. No crashes, no slow downloads, and no mid-play stalls."
    else:
        bits = []
        if crashKill: bits.append(f"{crashKill} ended by crash or kill")
        if slow: bits.append(f"{slow} slow download{'s' if slow != 1 else ''}")
        if midPlayStalls: bits.append(f"{midPlayStalls} mid-play stall{'s' if midPlayStalls != 1 else ''}")
        if photoFail or videoFail: bits.append(f"{photoFail + videoFail} load failure{'s' if (photoFail + videoFail) != 1 else ''}")
        summary = "Out of " + f"{len(S)} sessions this month: " + ", ".join(bits) + "."

    return f"""
  <section>
    <h2>Health</h2>
    <div class="panel">
      <div class="defaults">
        {rows_html}
      </div>
      <p>{esc(summary)}</p>
    </div>
  </section>"""


# ---------------------------------------------------------------------------
# Location
# ---------------------------------------------------------------------------

def build_location(M, S):
    F, latest = M["F"], M["latest"]
    rows = [
        ('<div class="def"><div class="k">Country</div><div class="v">' + render_dist(F.get("country", collections.Counter())) + "</div></div>"),
        ('<div class="def"><div class="k">Time zone</div><div class="v">' + render_dist(F.get("timeZone", collections.Counter())) + "</div></div>"),
        ('<div class="def"><div class="k">Language</div><div class="v">' + render_dist(F.get("language", collections.Counter())) + "</div></div>"),
    ]

    tz_by_phone = collections.Counter(r["facts"].get("timeZone", "?") for r in latest.values())
    tz_rows = "".join(
        f'<div class="def"><div class="k">{esc(tz)}</div><div class="v"><b>{n}</b> phone{"s" if n != 1 else ""}</div></div>'
        for tz, n in tz_by_phone.most_common()
    )

    return f"""
  <section>
    <h2>Location</h2>
    <div class="panel">
      <div class="defaults">
        {''.join(rows)}
      </div>
      <p>Per session, not per phone.</p>
    </div>
    <div class="panel">
      <h3>Phones per time zone</h3>
      <div class="defaults">
        {tz_rows}
      </div>
    </div>
  </section>""", {"tz_by_phone": tz_by_phone}


# ---------------------------------------------------------------------------
# Customers -- one line per phone, every phone in the same order, every
# phone showing the same fields in the same order, "0" / "off" / "-"
# where nothing happened. Replaces the old hand-written summary, where
# one phone showed shrinks, another showed the reminder setting, and a
# third showed seconds -- whatever that one phone happened to do.
# ---------------------------------------------------------------------------

def num_secs(group):
    return [r["sessionSeconds"] for r in group if isinstance(r.get("sessionSeconds"), int)]


def order_phone_groups(S):
    """Every phone's sessions, grouped by install and ordered by that
    phone's first session. Both the Customers section and the raw field
    table use this exact ordering, so "Phone N" means the same phone in
    both places."""
    by_install = collections.OrderedDict()
    for r in S:
        by_install.setdefault(r["install"], []).append(r)
    order = sorted(by_install.items(), key=lambda kv: min(x["startedAt"] or "" for x in kv[1]))
    return [sess for _, sess in order]


# facts.timeZone -> a short, friendly name. Anything not listed here
# falls through to the city part of the id itself (see tz_label()).
TZ_LABELS = {
    "America/Los_Angeles": "Pacific",
    "America/New_York": "Eastern",
    "America/Chicago": "Central",
    "America/Denver": "Mountain",
    "America/Phoenix": "Arizona",
    "Pacific/Honolulu": "Hawaii",
    "America/Anchorage": "Alaska",
}


def tz_label(tz):
    """A short, friendly name for a facts `timeZone` id -- the city part
    of the id (its last path segment, underscores turned to spaces) for
    a zone not in TZ_LABELS, and "-" when there is no zone fact at all."""
    if not tz:
        return "–"
    if tz in TZ_LABELS:
        return TZ_LABELS[tz]
    if tz.startswith("America/Indiana/"):
        return "Eastern"
    return tz.rsplit("/", 1)[-1].replace("_", " ")


def fmt_short_day(day):
    return datetime.date.fromisoformat(day).strftime("%-d %b")


def fmt_minutes(total_seconds):
    m = total_seconds / 60
    return f"{m:.1f}" if m < 10 else f"{m:.0f}"


def fmt_saved(b):
    """Same definition as the "Total space saved" tile: deleted bytes at
    bin empty plus shrink bytes. MB under 1 GB, else GB to 2 decimals --
    and plainly "0 MB", not "0.0 MB", when there is nothing."""
    if not b:
        return "0 MB"
    if b < 1e9:
        return f"{b / 1e6:.1f} MB"
    return f"{b / 1e9:.2f} GB"


def phone_facts(group, latest_session):
    """One phone's Customers numbers. Every phone computes every one of
    these fields the same way, whether or not it ever did any of them."""
    deletes = sum(r["counts"].get("action.videos.delete", 0) + r["counts"].get("action.photos.delete", 0) for r in group)
    shrinks = sum(r["counts"].get("shrink.done", 0) for r in group)
    keeps = sum(r["counts"].get("action.videos.keep", 0) + r["counts"].get("action.photos.keep", 0) for r in group)
    shares = sum(r["counts"].get("action.videos.share", 0) + r["counts"].get("action.photos.share", 0) for r in group)
    saved = sum(r["counts"].get("bytesFreed.byDelete", 0) + r["counts"].get("bytesFreed.byShrink", 0) for r in group)
    crashes = sum(1 for r in group if r.get("endReason") == "crashOrKill")
    asked_yes = any(
        k.startswith("dailyReminderAsk.") and k.endswith(".yes") and v > 0
        for k, v in latest_session["counts"].items()
    )
    return {
        "n": len(group), "secs": sum(num_secs(group)), "deletes": deletes, "shrinks": shrinks,
        "keeps": keeps, "shares": shares, "saved": saved, "crashes": crashes,
        "reminder_on": latest_session["facts"].get("dailyReminderSetting") == "1" or asked_yes,
    }


def customer_value_line(f, reminder_text=None):
    """The " · "-joined value line, in the one fixed order every phone
    row (and the All row) uses. Only the sessions number is bold."""
    n = f["n"]
    reminder = reminder_text if reminder_text is not None else ("reminder on" if f["reminder_on"] else "reminder off")
    return " · ".join([
        f'<b>{n}</b> session{"s" if n != 1 else ""}',
        f'{fmt_minutes(f["secs"])} min in app',
        f'{f["deletes"]} deletes',
        f'{f["shrinks"]} shrinks',
        f'{f["keeps"]} keeps',
        f'{f["shares"]} shares',
        f'{fmt_saved(f["saved"])} saved',
        reminder,
        f'{f["crashes"]} crashes',
    ])


def build_customers(M, S):
    latest = M["latest"]
    phone_groups = order_phone_groups(S)
    per_phone = [phone_facts(g, latest[g[0]["install"]]) for g in phone_groups]

    rows = []
    for i, (g, f) in enumerate(zip(phone_groups, per_phone), start=1):
        l = latest[g[0]["install"]]
        device = esc(usage_report.device_name(l["device"]))
        tz = esc(tz_label(l["facts"].get("timeZone")))
        since = esc(fmt_short_day(min(r["day"] for r in g)))
        k_html = f"Phone {i} <small>{device} · {tz} · since {since}</small>"
        rows.append(f'<div class="def"><div class="k">{k_html}</div><div class="v">{customer_value_line(f)}</div></div>')

    all_f = {k: sum(f[k] for f in per_phone) for k in ("n", "secs", "deletes", "shrinks", "keeps", "shares", "saved", "crashes")}
    reminders_on = sum(1 for f in per_phone if f["reminder_on"])
    all_line = customer_value_line(all_f, reminder_text=f"{reminders_on} of {len(per_phone)} reminders on")
    rows.append(f'<div class="def"><div class="k">All customers</div><div class="v">{all_line}</div></div>')

    html = f"""
  <section>
    <h2>Customers</h2>
    <div class="panel">
      <div class="defaults">
        {''.join(rows)}
      </div>
      <p>Every phone shows the same facts. A 0 means it did not happen.</p>
    </div>
  </section>"""

    check_info = {"n_phones": len(per_phone), "per_phone": per_phone, "all": all_f, "reminders_on": reminders_on}
    return html, check_info


# ---------------------------------------------------------------------------
# Raw fields -- the old "every customer, every field" table. It is just
# the DB readout, so it now lives tucked away at the end of the page
# (see build_raw_fields_details below) instead of being the main view.
# ---------------------------------------------------------------------------

def fmt_values(vals):
    vals = [v if v is not None else "–" for v in vals]
    if not vals:
        return "–"
    c = collections.Counter(vals)
    if len(c) == 1:
        return next(iter(c))
    return " · ".join(f"{v} ×{n}" for v, n in c.most_common())


def facts_val(group, key):
    vals = [r["facts"][key] for r in group if key in r["facts"]]
    return fmt_values(vals)


def with_mb(k, v):
    s = str(v)
    if "bytes" in k or "Bytes" in k:
        s += f" ({v / 1e6:.1f} MB)"
    return s


def build_phone_table(S, M):
    phone_groups = order_phone_groups(S)
    labels = [f"Phone {i}" for i in range(1, len(phone_groups) + 1)]
    n = len(phone_groups)

    rows = []
    rows.append(("group", "Phone"))
    rows.append(("row", "Device",
                 [fmt_values([usage_report.device_name(r["device"]) for r in g]) for g in phone_groups],
                 fmt_values([usage_report.device_name(r["device"]) for r in S])))
    rows.append(("row", "iOS", [fmt_values([r["ios"] for r in g]) for g in phone_groups], fmt_values([r["ios"] for r in S])))
    rows.append(("row", "App build", [fmt_values([r["app"] for r in g]) for g in phone_groups], fmt_values([r["app"] for r in S])))
    rows.append(("row", "Country", [fmt_values([r["country"] for r in g]) for g in phone_groups], fmt_values([r["country"] for r in S])))

    rows.append(("group", "Sessions"))
    rows.append(("row", "Sessions", [str(len(g)) for g in phone_groups], str(len(S))))
    rows.append(("row", "Total seconds", [str(sum(num_secs(g))) for g in phone_groups], str(sum(num_secs(S)))))

    def avg_secs(g):
        xs = num_secs(g)
        return f"{sum(xs) / len(xs):.0f}" if xs else "–"
    rows.append(("row", "Avg seconds", [avg_secs(g) for g in phone_groups], avg_secs(S)))
    rows.append(("row", "Cold starts", [str(sum(1 for r in g if r["coldStart"])) for g in phone_groups], str(sum(1 for r in S if r["coldStart"]))))
    rows.append(("row", "First day", [min(r["day"] for r in g) for g in phone_groups], min(r["day"] for r in S)))
    rows.append(("row", "Last day", [max(r["day"] for r in g) for g in phone_groups], max(r["day"] for r in S)))

    def dsi_max(g):
        xs = [r["daysSinceInstall"] for r in g if isinstance(r.get("daysSinceInstall"), int)]
        return str(max(xs)) if xs else "–"
    rows.append(("row", "Days since install (max)", [dsi_max(g) for g in phone_groups], dsi_max(S)))

    def lib_latest(g):
        v = M["latest"][g[0]["install"]].get("libraryCount")
        return str(v) if isinstance(v, int) else "–"

    def lib_latest_sum(groups):
        # The All column for a per-phone "latest session" field can
        # never be one phone's own value -- sum each phone's own latest
        # count instead, and say plainly that it is a sum.
        vals = [M["latest"][g[0]["install"]].get("libraryCount") for g in groups]
        vals = [v for v in vals if isinstance(v, int)]
        return f"sum {sum(vals)}" if vals else "–"
    rows.append(("row", "Library count (latest session)", [lib_latest(g) for g in phone_groups], lib_latest_sum(phone_groups)))
    rows.append(("row", "Photo permission at start",
                 [fmt_values([r["photoPermissionAtStart"] for r in g]) for g in phone_groups],
                 fmt_values([r["photoPermissionAtStart"] for r in S])))
    rows.append(("row", "End reason", [fmt_values([r["endReason"] for r in g]) for g in phone_groups], fmt_values([r["endReason"] for r in S])))
    rows.append(("row", "Schema", [fmt_values([r["schema"] for r in g]) for g in phone_groups], fmt_values([r["schema"] for r in S])))

    rows.append(("group", "Counts (summed)"))
    count_keys = sorted({k for r in S for k in r["counts"]})
    count_all_vals, count_phone_vals = {}, {k: [] for k in count_keys}
    for k in count_keys:
        for g in phone_groups:
            count_phone_vals[k].append(sum(r["counts"].get(k, 0) for r in g))
        count_all_vals[k] = sum(r["counts"].get(k, 0) for r in S)
    for k in count_keys:
        rows.append(("row", k, [with_mb(k, v) for v in count_phone_vals[k]], with_mb(k, count_all_vals[k])))

    rows.append(("group", "Facts"))
    fact_keys = sorted({k for r in S for k in r["facts"]})
    for k in fact_keys:
        rows.append(("row", k, [facts_val(g, k) for g in phone_groups], facts_val(S, k)))

    ncols = n + 2
    thead = "<tr><th>Field</th>" + "".join(f"<th>{esc(l)}</th>" for l in labels) + "<th>All</th></tr>"
    body_parts = []
    for item in rows:
        if item[0] == "group":
            body_parts.append(f'<tr class="group"><td colspan="{ncols}">{esc(item[1])}</td></tr>')
        else:
            _, label, phone_vals, all_val = item
            tds = "".join(f"<td>{esc(v)}</td>" for v in phone_vals)
            body_parts.append(f'<tr><td>{esc(label)}</td>{tds}<td class="all">{esc(all_val)}</td></tr>')
    table_html = f"<table><thead>{thead}</thead><tbody>{''.join(body_parts)}</tbody></table>"

    section_html = f"""
  <details>
    <summary>Raw fields (every count and fact)</summary>
    <p>Built by a script from the pulled sessions. Each phone column adds up to the All column. Counts are summed over the month. Facts show each value and how many sessions had it.</p>
    <div class="tablewrap">
      {table_html}
    </div>
  </details>"""

    check_info = {
        "count_keys": count_keys,
        "count_all_vals": count_all_vals,
        "n_phones": n,
        "session_total": sum(len(g) for g in phone_groups),
    }
    return section_html, check_info


# ---------------------------------------------------------------------------
# Static sections (sample-size line computed)
# ---------------------------------------------------------------------------

def build_static_sections(args, n_phones):
    channel_word = CHANNEL_SAMPLE_WORD[args.channel]
    sample_line = f"Much from a tiny sample. Only {n_phones} {channel_word + ' ' if channel_word else ''}phone{'s' if n_phones != 1 else ''} so far."
    return f"""
  <section>
    <h2>How the numbers get here</h2>
    <div class="panel">
      <div class="flow">
        <div class="box"><b>1 · On the phone</b><small>The phone keeps counters in memory during a session.</small></div>
        <div class="box"><b>2 · CloudKit public database</b><small>One <code>UsageSession</code> record per session, written when the app goes to background. Random install ID. No name, email, or Apple Account.</small></div>
        <div class="box"><b>3 · scripts/usage_report.py</b><small>Pulls the month on the Mac and computes the splits.</small></div>
        <div class="box"><b>4 · scripts/usage_dashboard.py</b><small>Builds this whole page from the same pull, so every number agrees.</small></div>
      </div>
      <h3>What a record holds</h3>
<pre>UsageSession                             <span class="c">// record type, public database</span>
  installId                              <span class="c">// random id per phone, made once</span>
  startedAt / endedAt                    <span class="c">// session start and end time</span>
  coldStart                              <span class="c">// true if launched from a cold start</span>
  schema                     3 or 4
  app / ios / device                     <span class="c">// build number, iOS version, device model</span>
  libraryCount                           <span class="c">// size of the photo library</span>
  sessionSeconds                         <span class="c">// length of the session</span>
  daysSinceInstall
  country                                <span class="c">// from the device locale</span>
  photoPermissionAtStart                 <span class="c">// full, limited, or not asked</span>
  endReason                              <span class="c">// background, crashOrKill, or reopen</span>
  counts        {{ }}                      <span class="c">// JSON, action and event counts</span>
  facts         {{ }}                      <span class="c">// JSON, settings and device facts</span></pre>
      <p>About 3 KB per session.</p>
    </div>
  </section>

  <section>
    <h2>What this cannot tell you</h2>
    <div class="panel">
      <ul class="plain">
        <li>Which photo or video anything happened to. This is never sent.</li>
        <li>Who a person is. The install ID is a random number. A reinstall makes a new one.</li>
        <li>Devices not signed into iCloud. Their writes fail quietly and they are simply missing.</li>
        <li>Anything in real time. The script runs when you run it.</li>
        <li>{esc(sample_line)}</li>
        <li>Phones that ran a TestFlight build, or that installed before launch day, are left out.</li>
      </ul>
    </div>
  </section>"""


# ---------------------------------------------------------------------------
# Cross-checks -- run scripts/usage_report.py's own, independently written
# aggregation over the exact same session list, and fail loudly if it
# disagrees with this script's own numbers, rather than write a page
# nobody can trust.
# ---------------------------------------------------------------------------

def run_cross_checks(args, S, M, q1_check):
    """Monkeypatches usage_report.fetch() to hand back this exact session
    list `S`, fakes sys.argv to match this run's --env/--month/--channel,
    and runs usage_report.main() for real, capturing its stdout. Parses
    that output and compares it to the numbers already on the page. This
    is a genuine cross-check against a second, separately maintained
    implementation of the same aggregation -- not two code paths in this
    file re-deriving the same sum from the same loop."""
    C = M["C"]
    orig_fetch, orig_argv = usage_report.fetch, sys.argv
    argv = ["usage_report.py", "--env", args.env, "--month", args.month]
    if args.channel != "all":
        argv += ["--channel", args.channel]
    usage_report.fetch = lambda env, month: S
    sys.argv = argv
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            usage_report.main()
    finally:
        usage_report.fetch, sys.argv = orig_fetch, orig_argv
    out = buf.getvalue()

    problems = []

    m = re.search(r"phones:\s*(\d+).*?sessions:\s*(\d+)", out)
    if not m:
        problems.append("usage_report.py printed no 'phones: N ... sessions: N' line to check against")
    else:
        rphones, rsessions = int(m.group(1)), int(m.group(2))
        if rphones != M["n_phones"]:
            problems.append(f"phones: usage_report.py printed {rphones} but the page has {M['n_phones']}")
        if rsessions != len(S):
            problems.append(f"sessions: usage_report.py printed {rsessions} but the page has {len(S)}")

    found_action_line = False
    for line in out.splitlines():
        lm = re.match(r"\s*(videos|photos)\s+((?:\w+=\d+\s*)+)$", line)
        if not lm:
            continue
        found_action_line = True
        mode = lm.group(1)
        for k, v in re.findall(r"(\w+)=(\d+)", lm.group(2)):
            expect, got = C.get(f"action.{mode}.{k}", 0), int(v)
            if expect != got:
                problems.append(f"action.{mode}.{k}: usage_report.py printed {got} but the page has {expect}")
    if not found_action_line:
        problems.append("usage_report.py printed no Q1 'videos ...' / 'photos ...' action line to check against")

    m = re.search(r"shrink sheet (\d+) cancel (\d+) started (\d+) done (\d+) failed (\d+)", out)
    if not m:
        problems.append("usage_report.py printed no shrink funnel line to check against")
    else:
        rsheet, rcancel, rstarted, rdone, rfailed = (int(x) for x in m.groups())
        for label, got, expect in (
            ("shrink sheet", rsheet, q1_check["sheet"]), ("shrink cancel", rcancel, q1_check["cancel"]),
            ("shrink started", rstarted, q1_check["started"]), ("shrink done", rdone, q1_check["done"]),
            ("shrink failed", rfailed, q1_check["failed"]),
        ):
            if got != expect:
                problems.append(f"{label}: usage_report.py printed {got} but the page has {expect}")

    m = re.search(r"TOTAL ([\d.]+) GB", out)
    if not m:
        problems.append("usage_report.py printed no 'TOTAL X GB' line to check against")
    else:
        rtotal, page_total = float(m.group(1)), C.get("bytesFreed.total", 0) / 1e9
        if abs(rtotal - page_total) > 0.005:
            problems.append(f"bytes freed TOTAL: usage_report.py printed {rtotal:.2f} GB but the page has {page_total:.2f} GB")

    if problems:
        sys.exit("CROSS-CHECK FAILED against usage_report.py -- not writing the dashboard:\n  " + "\n  ".join(problems))
    print(f"self-check: PASS (cross-checked against usage_report.py)   phones: {M['n_phones']}   sessions: {len(S)}")


def check_customers(M, S, customers_check, q1_check, tiles_check, q2_check):
    """Checks the Customers section's "All customers" row two ways:
    (1) it equals the sum of the individual phone rows, field by field,
    and (2) each field agrees with the matching total already shown
    elsewhere on the page (Q1's action bars, the shrink funnel's
    "Finished" step, the "Total space saved" tile, Health's crash/kill
    count, and the session count in the header). Also checks that Q2's
    "Daily reminder" phone count matches the Customers "x of N
    reminders on" count. Fails loudly, before the page is written,
    rather than publish numbers that disagree with themselves."""
    C, F = M["C"], M["F"]
    per_phone, all_f = customers_check["per_phone"], customers_check["all"]
    problems = []

    for key in ("n", "secs", "deletes", "shrinks", "keeps", "shares", "saved", "crashes"):
        summed = sum(f[key] for f in per_phone)
        if summed != all_f[key]:
            problems.append(f"Customers: All customers' {key} is {all_f[key]} but the phone rows sum to {summed}")

    for label, got, expect in (
        ("sessions", all_f["n"], len(S)),
        ("deletes", all_f["deletes"], tiles_check["cat_totals"]["delete"]),
        ("shrinks", all_f["shrinks"], q1_check["done"]),
        ("keeps", all_f["keeps"], tiles_check["cat_totals"]["keep"]),
        ("shares", all_f["shares"], tiles_check["cat_totals"]["share"]),
        ("bytes saved", all_f["saved"], C.get("bytesFreed.total", 0)),
        ("crashes", all_f["crashes"], F.get("endReason", {}).get("crashOrKill", 0)),
    ):
        if got != expect:
            problems.append(f"Customers {label}: All customers has {got} but the matching total on the page is {expect}")

    if q2_check["reminders_on"] != customers_check["reminders_on"] or q2_check["n_phones"] != customers_check["n_phones"]:
        problems.append(
            f"Q2 daily reminder is {q2_check['reminders_on']} of {q2_check['n_phones']} phones but "
            f"Customers has {customers_check['reminders_on']} of {customers_check['n_phones']} reminders on"
        )

    if problems:
        sys.exit("CUSTOMERS SELF-CHECK FAILED -- not writing the dashboard:\n  " + "\n  ".join(problems))
    print(f"customers self-check: PASS   phones: {customers_check['n_phones']}   sessions: {all_f['n']}")


# ---------------------------------------------------------------------------
# Page assembly
# ---------------------------------------------------------------------------

PAGE_CSS = """
  :root {
    --bg: #F6F5F1;
    --panel: #FFFFFF;
    --ink: #17191E;
    --ink-2: #5A5F6B;
    --ink-3: #8C919C;
    --line: #E1E0DA;
    --videos: #2F8F86;
    --photos: #C98A2B;
    --videos-soft: #D8ECE9;
    --photos-soft: #F3E6D0;
    --good: #2F8F86;
    --warn: #C98A2B;
    --sample: #B4462F;
    --sample-soft: #F7E2DC;
    color-scheme: light;
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      --bg: #0F1114;
      --panel: #171A1F;
      --ink: #EDEDEA;
      --ink-2: #A7ABB4;
      --ink-3: #6E737D;
      --line: #262A31;
      --videos: #5FC1B6;
      --photos: #E0A64B;
      --videos-soft: #1B3532;
      --photos-soft: #3A2C14;
      --good: #5FC1B6;
      --warn: #E0A64B;
      --sample: #E27A5F;
      --sample-soft: #3A1F18;
      color-scheme: dark;
    }
  }
  :root[data-theme="dark"] {
    --bg: #0F1114;
    --panel: #171A1F;
    --ink: #EDEDEA;
    --ink-2: #A7ABB4;
    --ink-3: #6E737D;
    --line: #262A31;
    --videos: #5FC1B6;
    --photos: #E0A64B;
    --videos-soft: #1B3532;
    --photos-soft: #3A2C14;
    --good: #5FC1B6;
    --warn: #E0A64B;
    --sample: #E27A5F;
    --sample-soft: #3A1F18;
    color-scheme: dark;
  }

  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--ink);
    font-family: "IBM Plex Sans", "Helvetica Neue", Arial, sans-serif;
    font-size: 15px;
    line-height: 1.5;
    padding-inline: 20px;
    padding-block: 32px 64px;
    font-variant-numeric: tabular-nums;
  }
  .wrap { max-width: 920px; margin: 0 auto; display: grid; gap: 28px; }

  h1, h2, h3 { font-family: "Sora", "IBM Plex Sans", sans-serif; text-wrap: balance; margin: 0; }
  h1 { font-size: 30px; font-weight: 700; letter-spacing: -0.01em; }
  h2 { font-size: 18px; font-weight: 600; }
  h3 { font-size: 14px; font-weight: 600; color: var(--ink-2); }
  p { margin: 0; max-width: 62ch; color: var(--ink-2); }
  .eyebrow { font-size: 11px; letter-spacing: 0.12em; text-transform: uppercase; color: var(--ink-3); font-weight: 600; }

  header { display: grid; gap: 10px; }
  .meta { display: flex; flex-wrap: wrap; gap: 8px 18px; color: var(--ink-2); font-size: 13px; align-items: center; }
  .sample {
    display: inline-flex; align-items: center; gap: 6px;
    background: var(--sample-soft); color: var(--sample);
    font-size: 11px; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase;
    padding: 4px 9px; border-radius: 4px;
  }
  .chip {
    display: inline-flex; align-items: center;
    background: var(--photos-soft); color: var(--warn);
    font-family: "IBM Plex Mono", monospace;
    font-size: 12px; font-weight: 600;
    padding: 2px 8px; border-radius: 4px;
  }

  .tiles { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }
  .tile { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 16px 18px; display: grid; gap: 6px; }
  .tile .q { font-size: 12px; color: var(--ink-3); font-weight: 500; }
  .tile .big { font-family: "Sora", sans-serif; font-size: 30px; font-weight: 600; line-height: 1.1; }
  .tile .note { font-size: 13px; color: var(--ink-2); }

  section { display: grid; gap: 14px; }
  .panel { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 18px 20px; display: grid; gap: 14px; }

  .legend { display: flex; gap: 16px; font-size: 12px; color: var(--ink-2); }
  .legend span::before { content: ""; display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 6px; vertical-align: -1px; }
  .legend .v::before { background: var(--videos); }
  .legend .p::before { background: var(--photos); }

  .bars { display: grid; gap: 10px; }
  .row { display: grid; grid-template-columns: 96px 1fr 64px; gap: 12px; align-items: center; font-size: 13px; }
  .row .label { color: var(--ink); font-weight: 500; }
  .row .track { display: grid; gap: 3px; }
  .row .bar { height: 10px; border-radius: 3px; }
  .row .bar.v { background: var(--videos); }
  .row .bar.p { background: var(--photos); }
  .row .num { text-align: right; font-family: "IBM Plex Mono", monospace; font-size: 11px; line-height: 1.4; display: grid; gap: 0; }
  .row .num b { display: block; font-weight: 600; }
  .row .num b.v { color: var(--videos); }
  .row .num b.p { color: var(--photos); }

  .split { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .stack { display: flex; height: 26px; border-radius: 6px; overflow: hidden; }
  .stack div { display: flex; align-items: center; padding-inline: 10px; font-size: 12px; font-weight: 600; color: #0F1114; white-space: nowrap; }
  .stack .b { color: var(--ink); }
  .stack .c { background: var(--line); color: var(--ink-2); }
  .stack.vid .a { background: var(--videos); }
  .stack.vid .b { background: var(--videos-soft); }
  .stack.pho .a { background: var(--photos); }
  .stack.pho .b { background: var(--photos-soft); }

  .defaults { display: grid; gap: 8px; }
  .def { display: grid; grid-template-columns: 1fr auto; gap: 10px; align-items: center; font-size: 13px; padding: 8px 0; border-bottom: 1px solid var(--line); }
  .def:last-child { border-bottom: 0; }
  .def .k { color: var(--ink); }
  .def .k small { display: block; color: var(--ink-3); font-size: 12px; }
  .def .v { font-family: "IBM Plex Mono", monospace; font-size: 12px; color: var(--ink-2); }
  .def .v b { color: var(--ink); font-weight: 600; }

  .funnel { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; }
  .step { border: 1px solid var(--line); border-radius: 8px; padding: 12px; display: grid; gap: 4px; }
  .step .n { font-family: "Sora", sans-serif; font-size: 22px; font-weight: 600; }
  .step .t { font-size: 12px; color: var(--ink-2); }
  .step .pct { font-size: 11px; color: var(--ink-3); }

  .flow { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; align-items: stretch; }
  .flow .box { border: 1px dashed var(--line); border-radius: 8px; padding: 12px; font-size: 13px; display: grid; gap: 4px; }
  .flow .box b { font-weight: 600; }
  .flow .box small { color: var(--ink-3); font-size: 12px; }

  pre {
    margin: 0; background: var(--bg); border: 1px solid var(--line); border-radius: 8px;
    padding: 14px 16px; font-family: "IBM Plex Mono", monospace; font-size: 12.5px; line-height: 1.55;
    overflow-x: auto; color: var(--ink);
  }
  pre .c { color: var(--ink-3); }

  ul.plain { margin: 0; padding-left: 18px; color: var(--ink-2); display: grid; gap: 4px; }
  ul.plain li { max-width: 62ch; }

  .tablewrap { overflow-x: auto; }
  table { border-collapse: collapse; width: 100%; font-size: 12px; }
  th, td { padding: 6px 10px; border-bottom: 1px solid var(--line); text-align: left; vertical-align: top; }
  td { font-family: "IBM Plex Mono", monospace; color: var(--ink-2); }
  td:first-child, th:first-child { position: sticky; left: 0; background: var(--panel); color: var(--ink); font-family: inherit; }
  tr.group td { font-family: "Sora", sans-serif; font-weight: 600; color: var(--ink); background: var(--bg); }
  td.all { color: var(--ink); font-weight: 600; }

  details { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 18px 20px; display: grid; gap: 14px; }
  details > summary { cursor: pointer; font-family: "Sora", "IBM Plex Sans", sans-serif; font-size: 14px; font-weight: 600; color: var(--ink); }

  @media (max-width: 640px) {
    .tiles, .split, .funnel, .flow { grid-template-columns: 1fr; }
    .row { grid-template-columns: 84px 1fr 56px; }
    h1 { font-size: 26px; }
  }
"""


def build_page(args, S, M, tiles_html, q1_html, q2_html, reminder_html, health_html, location_html, customers_html, static_html, raw_fields_html):
    channel_label = CHANNEL_LABEL[args.channel]
    intro = CHANNEL_INTRO[args.channel]
    pulled = datetime.datetime.now(datetime.timezone.utc).strftime("%-d %b %Y %H:%M UTC")
    n_phones, n_sessions = M["n_phones"], len(S)

    header = f"""
  <header>
    <div class="eyebrow">Cloudfull · anonymous usage · CloudKit public database</div>
    <h1>Cloudfull Usage Report</h1>
    <div class="meta">
      <span>{esc(channel_label)}</span>
      <span>{esc(month_name(args.month))}</span>
      <span>{n_phones} phone{'s' if n_phones != 1 else ''}</span>
      <span>{n_sessions} session{'s' if n_sessions != 1 else ''}</span>
      <span>Pulled {esc(pulled)}</span>
    </div>
    <p>{esc(intro)}</p>
  </header>"""

    return f"""<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Cloudfull Usage Report</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Sora:wght@500;600;700&family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap">
<style>:root{{color-scheme:light;box-sizing:border-box;padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}}html{{scroll-padding-top:env(safe-area-inset-top,0px)}}body{{margin:0;padding:0;font:14px -apple-system,BlinkMacSystemFont,sans-serif}}img{{max-width:100%}}[hidden]:not([hidden=until-found i]){{display:none!important}}</style>
<style>{PAGE_CSS}</style>
</head>
<body>
<div class="wrap">{header}{tiles_html}{q1_html}{q2_html}{reminder_html}{health_html}{location_html}{customers_html}{static_html}{raw_fields_html}
</div>
</body>
</html>
"""


def main():
    args = ARGS
    raw = load_sessions(args)
    S = filter_sessions(raw, args)
    M = compute_core(S)

    tiles_html, tiles_check = build_tiles(M, S)
    q1_html, q1_check = build_q1(M, S)
    q2_html, q2_check = build_q2(M, S)
    reminder_html = build_reminder(M, S)
    health_html = build_health(M, S)
    location_html, _loc_check = build_location(M, S)
    customers_html, customers_check = build_customers(M, S)
    raw_fields_html, _table_check = build_phone_table(S, M)
    static_html = build_static_sections(args, M["n_phones"])

    run_cross_checks(args, S, M, q1_check)
    check_customers(M, S, customers_check, q1_check, tiles_check, q2_check)

    page = build_page(args, S, M, tiles_html, q1_html, q2_html, reminder_html, health_html, location_html, customers_html, static_html, raw_fields_html)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(page)

    print(f"wrote {args.out}   phones: {M['n_phones']}   sessions: {len(S)}")


if __name__ == "__main__":
    main()
