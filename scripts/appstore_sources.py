#!/usr/bin/env python3
#
# Cloudfull
#
# Copyright (C) 2026 Marshall Ross.
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""Reads Apple's own aggregate numbers on where Cloudfull downloads come
from, from the App Store Connect Analytics Reports API. READ-ONLY.

What it returns (plain rows, no app change needed):
  * downloads by Source Type (App Store search, App Store browse, App
    referrer, Web referrer, ...), from the "App Store Downloads" report.
  * downloads, purchases, proceeds and paying users by Campaign (the `ct`
    value of a tagged App Store link), from the DETAILED "App Store
    Downloads" and "App Store Purchases" reports. Apple puts the Campaign
    column in the Detailed reports only.

This script sends GET requests only. It never sends POST, PATCH or
DELETE. Creating the analytics report request is a POST that changes the
App Store Connect account, so this script does not do it. If no report
request exists, it says so and prints the one request the owner must
create (see design/ADS_NOTES_SOURCES.md).

Usage:
  python3 scripts/appstore_sources.py                # Last 30 days, readable text.
  python3 scripts/appstore_sources.py --days 14 --json

Auth is the same as scripts/sales_report.py: ASC_KEY_ID, ASC_ISSUER_ID,
ASC_VENDOR_NUMBER (checked only so the dashboard treats all App Store
Connect numbers the same way) and ASC_KEY_PATH or ASC_KEY_P8_B64. The key
and the signed token are never printed or logged. The API key needs the
Admin, Sales and Reports, or Finance role to list and download reports.
"""
import argparse, collections, csv, datetime, gzip, io, json, os, sys
import urllib.error, urllib.parse, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sales_report  # noqa: E402  (reuse the exact App Store Connect signing code)

API = "https://api.appstoreconnect.apple.com"
APP_ID = "6816547769"
DEFAULT_DAYS = 30

# The one request the owner must create (a POST; this script never sends it).
REQUIRED_REQUEST = {
    "POST": f"{API}/v1/analyticsReportRequests",
    "body": {"data": {
        "type": "analyticsReportRequests",
        "attributes": {"accessType": "ONGOING"},
        "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}},
    }},
    "key_role": "Admin (only an Admin key can create or delete a report request)",
}
NOT_SET_UP_REQUEST = (
    "No analytics report request exists for the app yet. Apple makes no reports until the owner "
    "creates one request: POST /v1/analyticsReportRequests with accessType ONGOING for app "
    f"{APP_ID} (see design/ADS_NOTES_SOURCES.md). The first report arrives in 1 to 2 days."
)


class SourcesError(Exception):
    """A short, key-free reason the numbers could not be read."""


# ---------------------------------------------------------------------------
# HTTP (GET only)
# ---------------------------------------------------------------------------

def _get_json(url, key_id, issuer_id):
    token = sales_report._make_jwt(key_id, issuer_id)  # fresh token per request; never printed
    req = urllib.request.Request(url, method="GET", headers={"Authorization": f"Bearer {token}", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise SourcesError(f"Apple refused the request ({e.code}). The API key needs the Admin, Sales and Reports, or Finance role.")
        raise SourcesError(f"App Store Connect returned {e.code} {e.reason} for {url.split('?')[0].replace(API, '')}")
    except OSError as e:
        raise SourcesError(f"App Store Connect request failed (network/timeout): {e}")


def _get_all(url, key_id, issuer_id, max_pages=20):
    # Follows Apple's links.next paging. Returns the list of "data" objects.
    out, pages = [], 0
    while url and pages < max_pages:
        doc = _get_json(url, key_id, issuer_id)
        out.extend(doc.get("data", []))
        url = (doc.get("links") or {}).get("next")
        pages += 1
    return out


def _download_segment(url):
    # Segment URLs are pre-signed by Apple (valid 5 minutes); no auth header.
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            raw = resp.read()
    except (urllib.error.URLError, OSError) as e:
        raise SourcesError(f"Report segment download failed: {e}")
    try:
        raw = gzip.decompress(raw)
    except (OSError, EOFError):
        pass  # not gzip; use as is
    return raw.decode("utf-8-sig", errors="replace")


# ---------------------------------------------------------------------------
# Parsing (offline-testable)
# ---------------------------------------------------------------------------

def parse_report_text(text):
    """Report file text -> list of dicts keyed by column NAME (Apple warns
    that column positions can change). Tab or comma separated."""
    lines = text.splitlines()
    if not lines:
        return []
    delim = "\t" if "\t" in lines[0] else ","
    return [dict(r) for r in csv.DictReader(io.StringIO("\n".join(lines)), delimiter=delim)]


def _col(row, name):
    # Column names are matched case-insensitively ("Report values are not case sensitive").
    for k, v in row.items():
        if k and k.strip().lower() == name.lower():
            return (v or "").strip()
    return ""


def _num(s):
    try:
        return float(s.replace(",", ""))
    except (ValueError, AttributeError):
        return 0.0


def dedupe_newest(rows_by_instance):
    """rows_by_instance: list of (processingDate, rows), any order. A later
    instance can restate rows of an earlier one, so rows with the same full
    key (all non-metric columns) keep the value from the newest instance."""
    metric = {"counts", "unique counts", "purchases", "proceeds in usd", "sales in usd", "paying users"}
    seen = {}
    for pdate, rows in sorted(rows_by_instance, key=lambda t: t[0]):
        for r in rows:
            key = tuple(sorted((k.strip().lower(), (v or "").strip()) for k, v in r.items() if k and k.strip().lower() not in metric))
            seen[key] = r  # newest wins because we sorted oldest to newest
    return list(seen.values())


def summarize(download_rows, purchase_rows):
    """Plain summary for the dashboard.

    by_source:   {source type: first-time downloads}
    by_campaign: {campaign token: {downloads, redownloads, purchases, proceeds, paying_users}}
    Rows with no Campaign are not listed under a token (they are still in by_source).
    Paying users are added up across rows; Apple says they are not summable, so the
    figure can count one person twice."""
    by_source = collections.Counter()
    by_campaign = collections.defaultdict(lambda: {"downloads": 0, "redownloads": 0, "purchases": 0,
                                                   "proceeds": 0.0, "paying_users": 0})
    redownloads = 0
    dates = []
    has_campaign_column = False
    for r in download_rows:
        d = _col(r, "Date")
        if d:
            dates.append(d)
        n = _num(_col(r, "Counts"))
        dtype = _col(r, "Download Type").lower()
        src = _col(r, "Source Type") or "Unavailable"
        camp = _col(r, "Campaign")
        if any((k or "").strip().lower() == "campaign" for k in r):
            has_campaign_column = True
        if dtype == "first-time download":
            by_source[src] += n
            if camp:
                by_campaign[camp]["downloads"] += n
        elif dtype == "redownload":
            redownloads += n
            if camp:
                by_campaign[camp]["redownloads"] += n
    purchases_total = 0
    for r in purchase_rows:
        d = _col(r, "Date")
        if d:
            dates.append(d)
        camp = _col(r, "Campaign")
        if any((k or "").strip().lower() == "campaign" for k in r):
            has_campaign_column = True
        p = _num(_col(r, "Purchases"))
        purchases_total += p
        if camp:
            c = by_campaign[camp]
            c["purchases"] += p
            c["proceeds"] += _num(_col(r, "Proceeds in USD"))
            c["paying_users"] += _num(_col(r, "Paying Users"))
    return {
        "by_source": {k: int(round(v)) for k, v in by_source.items()},
        "by_campaign": {k: {"downloads": int(round(v["downloads"])), "redownloads": int(round(v["redownloads"])),
                            "purchases": int(round(v["purchases"])), "proceeds": round(v["proceeds"], 2),
                            "paying_users": int(round(v["paying_users"]))} for k, v in by_campaign.items()},
        "redownloads": int(round(redownloads)),
        "purchases": int(round(purchases_total)),
        "date_from": min(dates) if dates else None,
        "date_to": max(dates) if dates else None,
        "has_campaign_column": has_campaign_column,
    }


def summarize_texts(download_texts, purchase_texts):
    """For tests: lists of report file texts -> summary (no network)."""
    d = [r for t in download_texts for r in parse_report_text(t)]
    p = [r for t in purchase_texts for r in parse_report_text(t)]
    return summarize(d, p)


# ---------------------------------------------------------------------------
# Live read (GET only)
# ---------------------------------------------------------------------------

def _creds():
    key_id = os.environ.get("ASC_KEY_ID")
    issuer_id = os.environ.get("ASC_ISSUER_ID")
    vendor = os.environ.get("ASC_VENDOR_NUMBER")
    if not (key_id and issuer_id and vendor):
        raise SourcesError("ASC_KEY_ID / ASC_ISSUER_ID / ASC_VENDOR_NUMBER not set")
    if not (os.environ.get("ASC_KEY_PATH") or os.environ.get("ASC_KEY_P8_B64")):
        raise SourcesError("ASC_KEY_PATH or ASC_KEY_P8_B64 not set")
    return key_id, issuer_id


def list_report_requests(key_id, issuer_id, app_id=APP_ID):
    url = f"{API}/v1/apps/{app_id}/analyticsReportRequests?limit=200"
    return _get_all(url, key_id, issuer_id)


def _want(report_name):
    """Which reports matter: (kind, detailed?) or None. UNVERIFIED exact names:
    Apple's page titles are 'App Store Downloads' / 'App Store Purchases', and
    the API report names carry a Standard or Detailed suffix, so match loosely."""
    n = (report_name or "").lower()
    detailed = "detailed" in n
    if "download" in n and "pre-order" not in n and "preorder" not in n:
        return ("downloads", detailed)
    if "purchase" in n and "pre-order" not in n and "preorder" not in n:
        return ("purchases", detailed)
    return None


def fetch_sources(days=DEFAULT_DAYS, app_id=APP_ID):
    """Live, read-only. Returns {"status": "ok"|"not_set_up"|"no_data", "reason": str, "summary": dict|None}.
    Never raises for expected problems."""
    try:
        key_id, issuer_id = _creds()
    except SourcesError as e:
        return {"status": "not_set_up", "reason": str(e), "summary": None}
    try:
        requests_ = list_report_requests(key_id, issuer_id, app_id)
        if not requests_:
            return {"status": "not_set_up", "reason": NOT_SET_UP_REQUEST, "summary": None}
        active = [r for r in requests_ if not (r.get("attributes") or {}).get("stoppedDueToInactivity")]
        ongoing = [r for r in active if (r.get("attributes") or {}).get("accessType") == "ONGOING"] or active
        if not ongoing:
            return {"status": "not_set_up", "reason": "The report request stopped (stoppedDueToInactivity). The owner must create a new one; see design/ADS_NOTES_SOURCES.md.", "summary": None}
        cutoff = (datetime.date.today() - datetime.timedelta(days=days)).isoformat()
        # kind -> {detailed: [(processingDate, rows)]}
        collected = {"downloads": {True: [], False: []}, "purchases": {True: [], False: []}}
        found_reports = 0
        for req in ongoing:
            for rep in _get_all(f"{API}/v1/analyticsReportRequests/{req['id']}/reports?limit=200", key_id, issuer_id):
                want = _want((rep.get("attributes") or {}).get("name"))
                if not want:
                    continue
                found_reports += 1
                kind, detailed = want
                insts = _get_all(f"{API}/v1/analyticsReports/{rep['id']}/instances?filter[granularity]=DAILY&limit=200", key_id, issuer_id)
                insts = [i for i in insts if (i.get("attributes") or {}).get("processingDate", "") >= cutoff]
                for inst in insts:
                    pdate = (inst.get("attributes") or {}).get("processingDate", "")
                    for seg in _get_all(f"{API}/v1/analyticsReportInstances/{inst['id']}/segments?limit=200", key_id, issuer_id):
                        seg_url = (seg.get("attributes") or {}).get("url")
                        if seg_url:
                            collected[kind][detailed].append((pdate, parse_report_text(_download_segment(seg_url))))
        if found_reports == 0:
            return {"status": "no_data", "reason": "The report request exists, but Apple has not listed the download or purchase reports yet. The first report arrives 1 to 2 days after the request.", "summary": None}
        # Campaign lives in the Detailed reports; use them when present, else the Standard ones (source type only).
        def rows(kind):
            use = collected[kind][True] or collected[kind][False]
            return dedupe_newest(use)
        dl, pu = rows("downloads"), rows("purchases")
        if not dl and not pu:
            return {"status": "no_data", "reason": f"The reports exist, but no daily report instance in the last {days} days has data yet (Apple hides rows with fewer than 5 users).", "summary": None}
        return {"status": "ok", "reason": "", "summary": summarize(dl, pu)}
    except SourcesError as e:
        return {"status": "not_set_up" if "refused" in str(e) else "no_data", "reason": str(e), "summary": None}
    except SystemExit as e:  # sales_report._load_asc_key exits when the key is missing
        return {"status": "not_set_up", "reason": str(e) or "App Store Connect key not set", "summary": None}
    except Exception as e:  # a bad key file, a changed Apple format: show the reason, never crash the page
        return {"status": "no_data", "reason": f"could not read Apple's reports ({type(e).__name__})", "summary": None}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=int, default=DEFAULT_DAYS)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--list-requests", action="store_true", help="Only list the report requests (GET) and print the count and states.")
    a = ap.parse_args()
    if a.list_requests:
        try:
            k, i = _creds()
            reqs = list_report_requests(k, i)
        except SourcesError as e:
            sys.exit(str(e))
        print(f"{len(reqs)} report request(s)")
        for r in reqs:
            at = r.get("attributes") or {}
            print(f"  {r.get('id')}  accessType={at.get('accessType')}  stoppedDueToInactivity={at.get('stoppedDueToInactivity')}")
        if not reqs:
            print(NOT_SET_UP_REQUEST)
        return
    res = fetch_sources(a.days)
    if a.json:
        print(json.dumps(res, indent=2))
        return
    if res["status"] != "ok":
        print(f"{res['status']}: {res['reason']}")
        sys.exit(0 if res["status"] == "no_data" else 2)
    s = res["summary"]
    print(f"Apple's numbers, {s['date_from']} to {s['date_to']}")
    for k, v in sorted(s["by_source"].items(), key=lambda kv: -kv[1]):
        print(f"  {k}: {v}")
    for k, v in sorted(s["by_campaign"].items()):
        print(f"  campaign {k}: {v}")


if __name__ == "__main__":
    main()
