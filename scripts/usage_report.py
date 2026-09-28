#!/usr/bin/env python3
#
# Cloudfull
#
# Copyright (C) 2026 Marshall Ross.
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""Reads the UsageSession records for one month from the CloudKit
public database and prints a report.

Setup, once per Mac:
  xcrun cktool save-token          # Gets a CloudKit management token
                                    # from https://icloud.developer.apple.com, under Manage Tokens.
Usage:
  python3 scripts/usage_report.py                       # This month, development environment.
  python3 scripts/usage_report.py --env production --month YYYY-MM
"""
import argparse, json, os, subprocess, sys, collections, datetime

# Your Apple Developer Team ID. Set it in the environment before you run this script.
TEAM = os.environ.get("CLOUDFULL_TEAM_ID") or sys.exit("Set CLOUDFULL_TEAM_ID to your Apple Developer Team ID.")
CONTAINER = "iCloud.com.cloudfull.app"

def fetch(env, month):
    # Limits the query to one month on the server, so the report does
    # not download all records. `cktool` needs a TIMESTAMP filter as a
    # number in milliseconds.
    y, m = int(month[:4]), int(month[5:7])
    lo = int(datetime.datetime(y, m, 1, tzinfo=datetime.timezone.utc).timestamp()) * 1000
    hi = int(datetime.datetime(y + (m == 12), (m % 12) + 1, 1, tzinfo=datetime.timezone.utc).timestamp()) * 1000
    out, cursor = [], None
    while True:
        cmd = ["xcrun", "cktool", "query-records", "--team-id", TEAM, "--container-id", CONTAINER,
               "--database-type", "public", "--environment", env, "--zone-name", "_defaultZone",
               "--record-type", "UsageSession", "--limit", "200",
               "--filters", f"startedAt >= {lo}", "--filters", f"startedAt < {hi}"]
        if cursor: cmd += ["--continuation-token", cursor]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"cktool failed: {r.stderr.strip()}\n(run `xcrun cktool save-token` once)")
        try:
            data = json.loads(r.stdout)
        except json.JSONDecodeError:
            sys.exit("cktool returned something that is not JSON — first lines:\n" + "\n".join(r.stdout.splitlines()[:5]))
        for rec in data.get("records", []):
            f = rec.get("fields", {})
            g = lambda k: f.get(k, {}).get("value")
            started = g("startedAt")
            out.append({
                "id": rec.get("recordName"), "install": g("installId"),
                "startedAt": started, "day": (started or "")[:10],
                "coldStart": g("coldStart"), "app": g("app"), "ios": g("ios"), "device": g("device"),
                "libraryCount": g("libraryCount"), "sessionSeconds": g("sessionSeconds"), "daysSinceInstall": g("daysSinceInstall"), "country": g("country"),
                "photoPermissionAtStart": g("photoPermissionAtStart"), "endReason": g("endReason"), "schema": g("schema"),
                "counts": json.loads(g("counts") or "{}"), "facts": json.loads(g("facts") or "{}"),
            })
        cursor = data.get("continuationToken")
        if not cursor: break
    return out

DEVICE_NAMES = {
    "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air",
    "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
    "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max", "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
    "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
    "arm64": "Simulator",
}
def device_name(ident): return DEVICE_NAMES.get(ident, ident)

def pct(n, d): return f"{(100*n/d):.0f}%" if d else "–"
def avg(xs): return f"{sum(xs)/len(xs):.0f}" if xs else "–"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", default="development", choices=["development", "production"])
    ap.add_argument("--month", default=datetime.date.today().strftime("%Y-%m"))
    a = ap.parse_args()
    S = [r for r in fetch(a.env, a.month) if r["day"].startswith(a.month)]
    if not S: sys.exit(f"no UsageSession records for {a.month} in {a.env}")

    phones = {r["install"] for r in S}
    latest = {}   # The latest session per phone, for this month.
    for r in sorted(S, key=lambda r: r["startedAt"] or ""): latest[r["install"]] = r
    days = {(r["install"], r["day"]) for r in S}
    C = collections.Counter()
    for r in S: C.update(r["counts"])
    F = collections.defaultdict(collections.Counter)
    for r in S:
        for k, v in r["facts"].items(): F[k][v] += 1
        # Schema 3 stores these values as record fields, not in
        # `facts`. Count them with the facts.
        for k in ("country", "photoPermissionAtStart", "endReason", "daysSinceInstall"):
            if r.get(k) is not None: F[k][str(r[k])] += 1
    def fnums(key): return [int(r["facts"][key]) for r in S if key in r["facts"] and r["facts"][key].lstrip("-").isdigit()]
    secs = [r["sessionSeconds"] for r in S if isinstance(r.get("sessionSeconds"), int)] or fnums("sessionSeconds")
    idle = [r["sessionSeconds"] - int(r["facts"]["lastEventSeconds"]) for r in S if isinstance(r.get("sessionSeconds"), int) and r["facts"].get("lastEventSeconds","").isdigit()]

    print(f"Cloudfull usage · {a.month} · {a.env}")
    # Retention: how many phones still open the app N or more days
    # after install. Uses daysSinceInstall from each phone's latest
    # session this month.
    dsi = {i: r["daysSinceInstall"] for i, r in latest.items() if isinstance(r.get("daysSinceInstall"), int)}
    print("still active N+ days after install: " + "  ".join(f"{n}d={pct(sum(1 for v in dsi.values() if v >= n), len(dsi))}" for n in (1, 7, 30)) + f"   one session ever: {sum(1 for r in latest.values() if r['facts'].get('sessionsBefore') == '0')}/{len(latest)}")
    if idle: print(f"idle tail after the last event: avg {avg(idle)} s   sessions with >120 s idle tail: {sum(1 for i in idle if i > 120)}/{len(idle)}")
    print(f"phones: {len(phones)}   phone-days: {len(days)}   sessions: {len(S)}   "
          f"avg session {avg(secs)} s   sessions/phone-day {len(S)/max(len(days),1):.1f}\n")

    print("Q1 · actions")
    for m in ("videos", "photos"):
        print(f"  {m:7} " + "  ".join(f"{k}={C.get(f'action.{m}.{k}',0)}" for k in ("keep","delete","share","album","shrink","unkeep")))
    print(f"  keep source photos: doubleTap={C.get('keepSource.photos.doubleTap',0)} rail={C.get('keepSource.photos.rail',0)}   videos: doubleTap={C.get('keepSource.videos.doubleTap',0)} rail={C.get('keepSource.videos.rail',0)}")
    dels = C.get('action.videos.delete',0)+C.get('action.photos.delete',0)
    pulled = C.get('keepPulledFromBin.videos',0)+C.get('keepPulledFromBin.photos',0)
    print(f"  bin restores (a real tap on Restore): {C.get('bin.restore',0)}   = {pct(C.get('bin.restore',0), dels)} of deletes")
    print(f"  keeps that pulled something back out of the bin: {pulled}   = {pct(pulled, dels)} of deletes")
    for m in ("videos","photos"):
        ad = {k: C.get(f"afterDelete.{m}.{k}",0) for k in ("back","swipe","stay")}; t = sum(ad.values())
        if t: print(f"  after a delete in {m} (5 s): back={pct(ad['back'],t)} on={pct(ad['swipe'],t)} stay={pct(ad['stay'],t)}  (n={t})")
    binLatest = {}   # The newest session per phone that carries bin facts. A crash session has none.
    for r in sorted(S, key=lambda r: r["startedAt"] or ""):
        if "binItemsAtEnd" in r["facts"]: binLatest[r["install"]] = r
    never = [r for r in binLatest.values() if int(r["facts"].get("binItemsAtEnd","0") or 0) > 0 and not any(x["counts"].get("bin.emptiedCount") for x in S if x["install"] == r["install"])]
    print(f"  phones with items in the bin and NO empty ever this month: {len(never)}/{len(latest)}   bin bytes waiting: {sum(int(r['facts'].get('binBytesAtEnd','0') or 0) for r in binLatest.values())/1e9:.2f} GB")
    for m in ("videos","photos"):
        res = collections.Counter({k.rsplit('.',1)[1]: n for k,n in C.items() if k.startswith(f"deleted.{m}.res.")}); t = sum(res.values())
        if t: print(f"  deleted {m} sizes: " + "  ".join(f"{k}={n}" for k,n in res.most_common(6)) + f"   size unknown at tap: {C.get(f'deleted.{m}.sizeUnknown',0)}" + (f"   avg length {C.get('deleted.videos.durationMsSum',0)/1000/max(C.get('deleted.videos.durationCount',0),1):.1f} s" if m == "videos" else ""))
        ec = C.get(f'bin.emptied.{m}.sizedItemCount',0)
        if ec: print(f"  deleted {m} average file size: {C.get(f'bin.emptied.{m}.bytesSum',0)/ec/1e6:.1f} MB  (n={ec}, measured at bin empty)")
    ps = C.get('postsSeen.videos',0)
    served = {k.rsplit('.',1)[1]: n for k,n in C.items() if k.startswith("video.served.")}
    if served:
        print(f"  played at: " + "  ".join(f"{k}={n}" for k,n in sorted(served.items(), key=lambda x: -x[1])[:8]) + "   (vs the asset's own size in 'deleted videos sizes' above)")
    logged, nolog = C.get('video.clipsLogged',0), C.get('video.clipsNoLog',0)
    if logged or nolog:
        trouble = C.get('video.clipsWithTrouble',0)
        st, dr, sec = C.get('video.logStalls',0), C.get('video.droppedFrames',0), C.get('video.secondsLogged',0)
        cause = ("the data ran out" if st and not dr else "something took the decoder" if dr and not st
                 else "both" if st and dr else "clean")
        print(f"  playback log: {logged} clips over {sec}s  ({nolog} gave no log)   trouble in {trouble}  stalls {st}  dropped frames {dr}   -> {cause}")
    if ps: print(f"  video loops {C.get('video.loops',0)}  = {C.get('video.loops',0)/ps:.2f} per video seen   mid-play stalls {C.get('video.stalledMidPlay',0)}")
    print(f"  bin empties: {C.get('bin.emptiedCount',0)}  items: {C.get('bin.emptied.videos.itemCount',0)+C.get('bin.emptied.photos.itemCount',0)}  bytes: {C.get('bytesFreed.byDelete',0)/1e9:.2f} GB  longest in bin before an empty: max {max([r['counts'].get('bin.emptiedOldestDaysMax',0) for r in S] or [0])} d  avg of session maxes {avg([r['counts']['bin.emptiedOldestDaysMax'] for r in S if 'bin.emptiedOldestDaysMax' in r['counts']])} d")
    print(f"  pull refresh v={C.get('pullRefresh.videos',0)} p={C.get('pullRefresh.photos',0)}   pinch {C.get('photoPinchZoom',0)}\n")

    vol = [float(r["facts"]["volumeAtStart"]) for r in S if r["facts"].get("volumeAtStart","?").replace(".","").isdigit()]
    fs = [float(r["facts"]["freeSpaceGBAtStart"]) for r in S if r["facts"].get("freeSpaceGBAtStart","?").replace(".","").isdigit()]
    print("Q2 · defaults and device (per session)")
    # Uses each phone's latest session for the reminder switch and hour.
    on = [r for r in latest.values() if r["facts"].get("dailyReminderSetting") == "1"]
    hours = collections.Counter(r["facts"].get("dailyReminderHourSetting", "?") for r in on)
    for m, keys in (("videos", ("sort.videos","filters.videos","types.videos")), ("photos", ("sort.photos","filters.photos","types.photos"))):
        cfg = collections.Counter()
        for r in latest.values():
            f = r["facts"]; vals = [f.get(k, "") for k in keys]
            if any(v and v != "random" for v in vals): cfg[" | ".join(f"{k.split('.')[0]}={v or '-'}" for k, v in zip(keys, vals))] += 1
        print(f"  {m} filter configs in use (phones with a non-default set, latest session): {sum(cfg.values())}/{len(latest)}   " + "   ".join(f"[{c}] ×{n}" for c, n in cfg.most_common(5)))
    print(f"  daily reminder on: {len(on)}/{len(latest)} phones ({pct(len(on), len(latest))})   hour set: " + "  ".join(f"{h}:00={n}" for h, n in sorted(hours.items(), key=lambda x: (x[0] == '?', int(x[0]) if x[0].isdigit() else 0))))
    if fs: print(f"  free space GB   avg {sum(fs)/len(fs):.1f}  median {sorted(fs)[len(fs)//2]:.1f}  min {min(fs):.1f}")
    if vol: print(f"  volume          avg {sum(vol)/len(vol):.2f}  at zero {sum(1 for v in vol if v < 0.01)}/{len(vol)}")
    fe = [float(r["facts"]["freeSpaceGBAtEnd"]) for r in S if r["facts"].get("freeSpaceGBAtEnd","?").replace(".","").isdigit()]
    if fe: print(f"  free space GB at end   avg {sum(fe)/len(fe):.1f}  (start minus end, summed: {sum(fs)-sum(fe):.1f} GB freed while in the app)" if len(fe) == len(fs) else f"  free space GB at end   avg {sum(fe)/len(fe):.1f}")
    for k in ("defaultTabSetting","openMutedSetting","liveDefaultSetting","dailyReminderSetting","dailyReminderHourSetting","albumSort","keepsAlbumSetting","appIconSetting",
              "sort.videos","filters.videos","types.videos","sort.photos","filters.photos","types.photos",
              "photoPermissionAtStart","photoPermissionAfterSettings","daysSinceInstall",
              "darkModeSetting","reduceMotion","lowPowerAtStart","textSize","language","country","timeZone","utcOffsetMinutes","startHour","startWeekday",
              "audioRouteAtStart","audioRouteAtEnd","networkAtStart","networkExpensive","lowDataMode","networkAtEnd"):
        c = F.get(k, {}); t = sum(c.values())
        if t: print(f"  {k:15} " + "  ".join(f"{v}={pct(n,t)}" for v, n in c.most_common(8)))
    dv = collections.Counter(device_name(r["device"]) for r in S); print("  device          " + "  ".join(f"{k}={n}" for k, n in dv.most_common(6)))
    ap_ = collections.Counter(r["app"] for r in S); print("  app             " + "  ".join(f"{k}={n}" for k, n in ap_.most_common(6)))
    print()

    kf = {k: C.get(f"afterPhotoKeep.{k}", 0) for k in ("swipe","stay","back")}; t = sum(kf.values())
    print(f"Q3 · after a Keep in Photos (5 s): swipe={pct(kf['swipe'],t)} stay={pct(kf['stay'],t)} back={pct(kf['back'],t)}  (n={t})\n")

    print("First run and gates")
    for g in ("welcome","limited","denied"):
        sh = C.get(f"gateScreen.{g}.shown",0)
        if sh: print(f"  {g}: shown={sh} continue={C.get(f'gateScreen.{g}.continue',0)} openSettings={C.get(f'gateScreen.{g}.openSettings',0)} avg {C.get(f'gateScreen.{g}.seconds',0)/sh:.0f} s")
    pa = {k: C.get(f"photoPermission.{k}",0) for k in ("full","limited","denied","restricted","other")}; t = sum(pa.values())
    if t: print(f"  permission: full={pct(pa['full'],t)} limited={pct(pa['limited'],t)} denied={pct(pa['denied'],t)}  avg {C.get('photoPermission.seconds',0)/t:.0f} s to answer")
    if F["photoPermissionAfterSettings"]: print("  after Settings: " + "  ".join(f"{v}={n}" for v,n in F['photoPermissionAfterSettings'].most_common()))
    print(f"  onboarding shown={C.get('onboarding.shown',0)} completed={C.get('onboarding.completed',0)}")
    for w in ("delete","keep","binEmpty"):
        xs = fnums(f"daysToFirst.{w}")
        if xs: print(f"  days to first {w}: avg {avg(xs)} (n={len(xs)})")
    print()

    print("Waiting")
    for m in ("videos","photos"):
        xs = fnums(f"firstLoadMs.{m}")
        if xs or C.get(f'firstLoadSpannedSessions.{m}',0): print(f"  first deal {m}: avg {avg(xs)} ms (n={len(xs)})  crossed a background, not timed: {C.get(f'firstLoadSpannedSessions.{m}',0)}  loading taps {C.get(f'loadingTaps.{m}',0)}")
    xs = fnums("secondsToFirstAction");  print(f"  open → first action: avg {avg(xs)} s (n={len(xs)})")
    xs = fnums("notificationToFirstAction"); print(f"  notification → first action: avg {avg(xs)} s (n={len(xs)})\n")

    print("Feed")
    for m in ("videos","photos"):
        sw = C.get(f"swipes.{m}",0); tot = sum(secs) or 1
        print(f"  {m}: posts seen {C.get(f'postsSeen.{m}',0)}  swipes {sw}  back {pct(C.get(f'swipesBack.{m}',0), sw)}  "
              f"filter changes {C.get(f'filterChange.{m}',0)} resets {C.get(f'filterReset.{m}',0)} posts seen before a reset (avg per reset) {C.get(f'postsSeenBeforeFilterReset.{m}',0)/max(C.get(f'filterReset.{m}',1),1):.0f}")
    print()

    print("Share / album")
    tg = {k[len("shareTarget."):]: n for k,n in C.items() if k.startswith("shareTarget.")}
    print("  target: " + "  ".join(f"{k}={n}" for k,n in sorted(tg.items(), key=lambda kv: -kv[1])))
    print("  kind: " + "  ".join(f"{k.split('.')[-1]}={n}" for k,n in C.items() if k.startswith("shareKind.")) + f"   failed {C.get('shareFailed',0)}")
    raw = {k[len("shareTargetRaw."):]: n for k,n in C.items() if k.startswith("shareTargetRaw.")}
    if raw: print("  'other' was: " + "  ".join(f"{k}={n}" for k,n in sorted(raw.items(), key=lambda kv: -kv[1])[:8]))
    print(f"  album new={C.get('album.new',0)} existing={C.get('album.existing',0)}\n")

    print("Reminder")
    for at in ("firstDelete","endPage"):
        y = C.get(f"dailyReminderAsk.{at}.yes",0); n = C.get(f"dailyReminderAsk.{at}.notNow",0)
        if y+n: print(f"  ask at {at}: yes={y} notNow={n} ({pct(y,y+n)} yes)")
    fromNote = F.get("openedFromNotification", {}).get("1", 0)
    print(f"  sessions opened from a notification: {fromNote}/{len(S)}")
    print(f"  iOS 'Allow notifications?' box: allowed={C.get('notificationPermission.allowed',0)} denied={C.get('notificationPermission.denied',0)}   taps " + "  ".join(f"{k.split('.',1)[1]}={n}" for k,n in C.items() if k.startswith('notificationTap.')) + f"   opened near reminder {C.get('openedNearDailyReminder',0)}")
    for m in ("videos","photos"):
        print(f"  end page {m}: reached={C.get(f'onThisDateEndPage.{m}.reached',0)} keepScrolling={C.get(f'onThisDateEndPage.{m}.keepScrolling',0)} toOtherMode={C.get(f'onThisDateEndPage.{m}.toPhotos' if m == 'videos' else f'onThisDateEndPage.{m}.toVideos',0)}")
    print("  mode switches: " + "  ".join(f"{v}={C.get(f'modeSwitch.{v}',0)}" for v in ("chin","quickAction","notification","endPage")) +
          f"   quick actions v={C.get('quickAction.videos',0)} p={C.get('quickAction.photos',0)}\n")

    print("Storage saved (exact, all sessions this month)")
    gb = lambda b: f"{b/1e9:.2f} GB"
    print(f"  bin empty tapped {C.get('bin.emptyTapped',0)}  confirmed {C.get('bin.emptiedCount',0)}  ({pct(C.get('bin.emptiedCount',0), C.get('bin.emptyTapped',0))} through the iOS confirm sheet)   first sessions {F.get('sessionsBefore',{}).get('0',0)}")
    print(f"  deleted {gb(C.get('bytesFreed.byDelete',0))}   shrinks {gb(C.get('bytesFreed.byShrink',0))}   TOTAL {gb(C.get('bytesFreed.total',0))}")
    lc = [r["libraryCount"] for r in S if isinstance(r.get("libraryCount"), int) and r["libraryCount"] >= 0]
    if lc: print(f"  library size: avg {sum(lc)/len(lc):.0f}  median {sorted(lc)[len(lc)//2]}  max {max(lc)}")
    print()
    print("Taps and sheets")
    icons = {k.split('.',1)[1]: n for k,n in C.items() if k.startswith("appIcon.")}
    if icons: print("  app icon changed to: " + "  ".join(f"{k}={n}" for k,n in icons.items()))
    print(f"  switcher opens {C.get('modeSwitcherOpened',0)}   mode switches to: videos {C.get('modeSwitchTo.videos',0)} photos {C.get('modeSwitchTo.photos',0)}   settings opens {C.get('settingsOpened',0)}   " + "  ".join(f"{k.split('.',1)[1]}={n}" for k,n in C.items() if k.startswith("setting.")))
    ka = {k: C.get(f"keepAlbum.{k}",0) for k in ("added","alreadyThere","removed","failed")}
    if any(ka.values()): print(f"  keeps album: filed {ka['added']}  already there {ka['alreadyThere']}  taken out {ka['removed']}  refused {ka['failed']}")
    print(f"  bin restores in the feed (a second trash tap): videos {C.get('unqueuedInFeed.videos',0)}")
    print(f"  bin opens {C.get('bin.open',0)}   bin previews {C.get('bin.preview',0)}   shrink sheet {C.get('shrink.sheet',0)} cancel {C.get('shrink.cancel',0)} started {C.get('action.videos.shrink',0)} done {C.get('shrink.done',0)} failed {C.get('shrink.failed',0)} originalKept " + " ".join(f"{k.split('.')[-1]}={n}" for k,n in C.items() if k.startswith('shrink.originalKept.')) + f"   album cancel {C.get('album.cancel',0)}")
    print(f"  keep taps on already-kept: videos {C.get('keepTapOnAlreadyKept.videos',0)} photos {C.get('keepTapOnAlreadyKept.photos',0)}")
    print(f"  video: 2x holds {C.get('video.fastForwardHold',0)}  scrubs {C.get('video.scrub',0)}  mute {C.get('muteButton.muted',0)} unmute {C.get('muteButton.unmuted',0)}  fullscreen {C.get('video.rotatedToFullscreen',0)}")
    print(f"  live: on {C.get('liveSwitch.turnedOn',0)} off {C.get('liveSwitch.turnedOff',0)}  plays by tap {C.get('livePlay.tap',0)} auto {C.get('livePlay.auto',0)}")
    for m in ("videos","photos"):
        print(f"  seconds in {m}: {C.get(f'secondsIn.{m}',0)}   filters turned on: " + "  ".join(f"{k.split('.')[-1]}={n}" for k,n in C.items() if k.startswith(f"filterOn.{m}."))
              + "   turned off: " + "  ".join(f"{k.split('.')[-1]}={n}" for k,n in C.items() if k.startswith(f"filterOff.{m}."))
              + "   sort changed: " + "  ".join(f"{k.split('.')[-1]}={n}" for k,n in C.items() if k.startswith(f"sortChanged.{m}.")))
    print(f"  share sheet opened: videos {C.get('shareSheetOpened.videos',0)} photos {C.get('shareSheetOpened.photos',0)}   (finished on a target = action.<mode>.share above)")
    print(f"  network changes {C.get('networkChanges',0)}   audio route changes {C.get('audioRouteChanges',0)}")
    print()
    print("Health")
    print(f"  photo load failed {C.get('photoLoadFailedCount',0)}   video load failed {C.get('videoLoadFailedCount',0)}   slow downloads {C.get('slowDownloadCount',0)}   "
          f"stalls>250ms {sum(fnums('mainThreadStallsOver250ms'))}   ended by: " + "  ".join(f"{v}={n}" for v,n in F['endReason'].most_common()))
    cold = sum(1 for r in S if r["coldStart"]); print(f"  cold opens {cold} / {len(S)}")
    sch = collections.Counter(str(r.get("schema")) for r in S); print("  schema versions " + "  ".join(f"{k}={n}" for k, n in sch.most_common()))
    # Finds counts this script never names, so a new key is never silently dropped.
    named = set()
    import re as _re
    src = open(__file__).read()
    for lit in _re.findall(r"""C\.get\(f?['"]([^'"]+)['"]""", src): named.add(_re.sub(r"\{[^}]*\}", "*", lit))
    import fnmatch as _fn
    # Key families the script matches with `startswith`, instead of naming each key.
    scanned = ["setting.", "filterOn.", "filterOff.", "sortChanged.", "shareTarget", "shareTargetRaw.", "shareKind.", "shrink.originalKept.", "notificationTap.", "deleted.videos.res.", "deleted.photos.res.", "video.served.", "daysToFirst."]
    unread = sorted(k for k in C if k not in named and not any(_fn.fnmatch(k, n) for n in named if "*" in n) and not any(k.startswith(p) for p in scanned))
    if unread: print("  counts not read by this script: " + "  ".join(f"{k}={C[k]}" for k in unread))
    # Lists the facts whose names do not appear in this file. A name
    # anywhere in the file counts as read.
    mentioned = set(_re.findall(r"""['"]([A-Za-z][A-Za-z0-9._]*)['"]""", src))
    unreadFacts = sorted(k for k in F if k not in mentioned
                         and not any(k.startswith(p) for p in ("daysToFirst.", "firstLoadMs.", "sort.", "filters.", "types.")))
    if unreadFacts: print("  facts not read by this script: " + "  ".join(unreadFacts))

if __name__ == "__main__":
    main()
    # The usage dashboard is a private page. Only the maintainer can open it.
    # Set CLOUDFULL_DASHBOARD_URL to use a different page.
    dashboard = os.environ.get("CLOUDFULL_DASHBOARD_URL", "https://claude.ai/artifact/TME9cPtKC82fhePavDVhTJ")
    print(f"\nReminder: update the usage dashboard with these numbers: {dashboard}")
