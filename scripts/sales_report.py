#!/usr/bin/env python3
#
# Cloudfull
#
# Copyright (C) 2026 Marshall Ross.
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""Pulls App Store Connect Sales and Trends DAILY SALES SUMMARY reports
and prints Cloudfull's downloads, re-downloads, updates, in-app purchase
(tip) units, and developer proceeds for a range of days.

Usage:
  python3 scripts/sales_report.py                              # Last 7 days, ending yesterday.
  python3 scripts/sales_report.py --days 30
  python3 scripts/sales_report.py --from 2026-10-29 --to 2026-11-01
  python3 scripts/sales_report.py --sku cloudfull-001 --json   # Machine-readable output.

Apple generates each day's Daily Sales Summary report the day after that
day, so the most recent day or two will normally come back from Apple as
"no report yet" -- this script treats that as a normal, empty day, never
as an error.

Auth: an ES256 (ECDSA P-256 / SHA-256) JSON Web Token, as the App Store
Connect API requires. See:
  https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests
Signed with the PyJWT package when it is installed, and with the
`cryptography` package otherwise -- either is enough; no extra
dependency has to be installed for this to work on a Mac with Xcode's
command line tools already in place. Set:
  ASC_KEY_ID         The key ID, from App Store Connect -> Users and
                     Access -> Integrations -> Keys.
  ASC_ISSUER_ID      The issuer ID, from that same page.
  ASC_VENDOR_NUMBER  Your vendor number, from App Store Connect ->
                     Reports -> Sales and Trends (top of the page, or
                     Payments and Financial Reports).
  ASC_KEY_PATH       Path to the key's private key .p8 file, OR
  ASC_KEY_P8_B64     the private key's .p8 file, base64-encoded, in the
                     environment. Exactly one of these two is needed.
                     The key is never printed or logged.

Rows are kept only when their SKU is the app itself (--sku, default
cloudfull-001) or their "Parent Identifier" names the app (an in-app
purchase, e.g. a tip) -- every other app or developer on the same
vendor account is dropped. "Developer Proceeds" in Apple's report is a
PER-UNIT amount; this script multiplies by Units itself and groups the
result by "Currency of Proceeds". Product Type Identifier codes are
mapped to downloads / re-downloads / updates / in-app purchases using
Apple's own table:
  https://developer.apple.com/help/app-store-connect/reference/product-type-identifiers
Any code not in that table is shown labelled with its raw identifier,
rather than silently folded into another bucket or dropped.
"""
import argparse, base64, collections, datetime, gzip, json, os, sys
import urllib.error, urllib.parse, urllib.request
from decimal import Decimal, InvalidOperation

API_URL = "https://api.appstoreconnect.apple.com/v1/salesReports"
DEFAULT_SKU = "cloudfull-001"

# Apple's "Product type identifiers" table (Reporting -> Reference, App
# Store Connect help). Anything not listed here is left unmapped and
# shown with its raw code, instead of being guessed at.
PRODUCT_TYPE_CATEGORY = {
    # Free or paid app downloads, including bundles and custom apps.
    "1": "download", "1-B": "download", "F1-B": "download",
    "1E": "download", "1EP": "download", "1EU": "download",
    "1F": "download", "1T": "download", "F1": "download",
    # Re-downloads of a previously purchased app.
    "3": "redownload", "3F": "redownload",
    # Updates to an already-installed app.
    "7": "update", "7F": "update", "7T": "update", "F7": "update",
    # In-app purchases (consumable, non-consumable, and subscriptions).
    "FI1": "iap", "IA1": "iap", "IA1-M": "iap", "IA3": "iap",
    "IA9": "iap", "IA9-M": "iap", "IAY": "iap", "IAY-M": "iap",
}


def _load_asc_key():
    # Returns the App Store Connect API private key's .p8 PEM bytes.
    # Never printed or logged.
    path = os.environ.get("ASC_KEY_PATH")
    if path:
        path = os.path.expanduser(path)
        with open(path, "rb") as f:
            return f.read()
    b64 = os.environ.get("ASC_KEY_P8_B64")
    if b64:
        return base64.b64decode(b64)
    sys.exit("Set ASC_KEY_PATH or ASC_KEY_P8_B64 to your App Store Connect API private key (.p8).")


def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _make_jwt(key_id, issuer_id):
    # Builds the short-lived ES256 JWT the App Store Connect API wants
    # on every request. Apple caps a token's lifetime at 20 minutes;
    # this script asks for a fresh one before every HTTP request
    # instead of trying to reuse one across a whole run, so a long
    # --days range never risks signing a request with an expired token.
    now = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer_id, "iat": now, "exp": now + 19 * 60, "aud": "appstoreconnect-v1"}
    pem = _load_asc_key()
    try:
        import jwt as pyjwt
    except ImportError:
        pyjwt = None
    if pyjwt is not None:
        token = pyjwt.encode(payload, pem, algorithm="ES256", headers=header)
        return token.decode() if isinstance(token, bytes) else token
    # No PyJWT -- sign by hand with `cryptography`, then convert its
    # DER-encoded ECDSA signature to the raw r||s form a JWT needs.
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
    key = serialization.load_pem_private_key(pem, password=None)
    signing_input = (
        _b64url(json.dumps(header, separators=(",", ":")).encode()) + "." +
        _b64url(json.dumps(payload, separators=(",", ":")).encode())
    )
    der_sig = key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der_sig)
    raw_sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return signing_input + "." + _b64url(raw_sig)


def _fetch_report_day(key_id, issuer_id, vendor_number, date_str):
    # Returns the raw (decompressed) TSV bytes for one day's Daily Sales
    # Summary report, or None when Apple has no report yet for that day
    # -- either it has not been generated yet (Apple posts each day's
    # report the day after) or there were truly no transactions that
    # day. Apple returns a 404 for both, so any 404 here is treated as
    # "no report yet", never as a crash.
    params = urllib.parse.urlencode({
        "filter[frequency]": "DAILY",
        "filter[reportDate]": date_str,
        "filter[reportSubType]": "SUMMARY",
        "filter[reportType]": "SALES",
        "filter[vendorNumber]": vendor_number,
        "filter[version]": "1_1",
    })
    token = _make_jwt(key_id, issuer_id)
    req = urllib.request.Request(
        f"{API_URL}?{params}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/a-gzip"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return gzip.decompress(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        sys.exit(f"App Store Connect request failed for {date_str}: {e.code} {e.reason}\n{e.read().decode(errors='replace')}")


def _parse_tsv(raw):
    # Reads the header row by name instead of by column position, so
    # this script keeps working if Apple ever reorders the columns.
    lines = raw.decode("utf-8-sig").splitlines()
    if not lines:
        return []
    header = lines[0].split("\t")
    rows = []
    for line in lines[1:]:
        if not line:
            continue
        cols = line.split("\t")
        rows.append({name: (cols[i] if i < len(cols) else "") for i, name in enumerate(header)})
    return rows


def _rows_for_sku(rows, sku):
    return [r for r in rows if r.get("SKU") == sku or r.get("Parent Identifier") == sku]


def _dec(s):
    try:
        return Decimal(s) if s else Decimal(0)
    except InvalidOperation:
        return Decimal(0)


def _day_stats(rows):
    downloads = redownloads = updates = Decimal(0)
    iap_units, proceeds, unmapped = collections.Counter(), collections.Counter(), collections.Counter()
    for r in rows:
        units = _dec(r.get("Units"))
        cat = PRODUCT_TYPE_CATEGORY.get(r.get("Product Type Identifier", ""))
        if cat == "download": downloads += units
        elif cat == "redownload": redownloads += units
        elif cat == "update": updates += units
        elif cat == "iap": iap_units[r.get("SKU") or "?"] += units
        else: unmapped[r.get("Product Type Identifier") or "?"] += units
        # "Developer Proceeds" is a PER-UNIT amount -- multiply by Units
        # ourselves and group the result by the currency Apple actually
        # pays out in, which need not match the customer's own currency.
        amount = units * _dec(r.get("Developer Proceeds"))
        if amount: proceeds[r.get("Currency of Proceeds") or "?"] += amount
    return {"downloads": downloads, "redownloads": redownloads, "updates": updates,
            "iap_units": iap_units, "proceeds": proceeds, "unmapped": unmapped}


def _aggregate(cache, days):
    agg = {"downloads": Decimal(0), "redownloads": Decimal(0), "updates": Decimal(0),
           "iap_units": collections.Counter(), "proceeds": collections.Counter(), "unmapped": collections.Counter()}
    pending = []
    for d in days:
        st = cache.get(d)
        if st is None:
            pending.append(d)
            continue
        agg["downloads"] += st["downloads"]; agg["redownloads"] += st["redownloads"]; agg["updates"] += st["updates"]
        agg["iap_units"].update(st["iap_units"]); agg["proceeds"].update(st["proceeds"]); agg["unmapped"].update(st["unmapped"])
    return agg, pending


def _fmt_units(d):
    return str(int(d)) if d == d.to_integral_value() else str(d.normalize())


def _num(d):
    return int(d) if d == d.to_integral_value() else float(d)


def _date_range(a):
    if a.date_from or a.date_to:
        if not (a.date_from and a.date_to):
            sys.exit("Pass both --from and --to, or neither.")
        try:
            lo, hi = datetime.date.fromisoformat(a.date_from), datetime.date.fromisoformat(a.date_to)
        except ValueError as e:
            sys.exit(f"Bad date: {e}")
        if lo > hi:
            sys.exit("--from must not be after --to.")
        return lo, hi
    hi = datetime.date.today() - datetime.timedelta(days=1)
    return hi - datetime.timedelta(days=a.days - 1), hi


def _print_day(day, stats):
    if stats is None:
        print(f"  {day}  no report yet (Apple posts it the day after)")
        return
    parts = [f"downloads={_fmt_units(stats['downloads'])}"]
    if stats["redownloads"]: parts.append(f"re-downloads={_fmt_units(stats['redownloads'])}")
    if stats["updates"]: parts.append(f"updates={_fmt_units(stats['updates'])}")
    if stats["iap_units"]: parts.append("IAP " + " ".join(f"{k}={_fmt_units(v)}" for k, v in sorted(stats["iap_units"].items())))
    if stats["unmapped"]: parts.append("unknown product type " + " ".join(f"{k}={_fmt_units(v)}" for k, v in sorted(stats["unmapped"].items())))
    proceeds = "  ".join(f"{v:.2f} {c}" for c, v in sorted(stats["proceeds"].items())) or "0.00"
    print(f"  {day}  " + "  ".join(parts) + f"   proceeds {proceeds}")


def _print_totals(title, totals, pending):
    print(title)
    parts = [f"downloads={_fmt_units(totals['downloads'])}"]
    if totals["redownloads"]: parts.append(f"re-downloads={_fmt_units(totals['redownloads'])}")
    if totals["updates"]: parts.append(f"updates={_fmt_units(totals['updates'])}")
    print("  " + "  ".join(parts))
    if totals["iap_units"]: print("  IAP units by product: " + "  ".join(f"{k}={_fmt_units(v)}" for k, v in sorted(totals["iap_units"].items())))
    if totals["unmapped"]: print("  unknown product type: " + "  ".join(f"{k}={_fmt_units(v)}" for k, v in sorted(totals["unmapped"].items())))
    proceeds = "  ".join(f"{v:.2f} {c}" for c, v in sorted(totals["proceeds"].items())) or "0.00"
    print(f"  proceeds: {proceeds}")
    if pending: print(f"  no report yet for: {', '.join(d.isoformat() for d in pending)}")


def _json_totals(totals):
    return {
        "downloads": _num(totals["downloads"]), "redownloads": _num(totals["redownloads"]), "updates": _num(totals["updates"]),
        "iap_units": {k: _num(v) for k, v in totals["iap_units"].items()},
        "proceeds": {c: float(v) for c, v in totals["proceeds"].items()},
        "unmapped_product_types": {k: _num(v) for k, v in totals["unmapped"].items()},
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=int, default=7, help="Days ending yesterday (default 7). Ignored if --from/--to are given.")
    ap.add_argument("--from", dest="date_from", metavar="YYYY-MM-DD", help="Start of range (inclusive).")
    ap.add_argument("--to", dest="date_to", metavar="YYYY-MM-DD", help="End of range (inclusive).")
    ap.add_argument("--sku", default=DEFAULT_SKU, help=f"The app's own SKU (default {DEFAULT_SKU}).")
    ap.add_argument("--json", action="store_true", help="Print machine-readable JSON instead of text.")
    a = ap.parse_args()

    key_id = os.environ.get("ASC_KEY_ID") or sys.exit("Set ASC_KEY_ID to your App Store Connect API key ID.")
    issuer_id = os.environ.get("ASC_ISSUER_ID") or sys.exit("Set ASC_ISSUER_ID to your App Store Connect API issuer ID.")
    vendor_number = os.environ.get("ASC_VENDOR_NUMBER") or sys.exit("Set ASC_VENDOR_NUMBER to your App Store Connect vendor number.")
    lo, hi = _date_range(a)

    cache = {}
    def ensure(day):
        if day not in cache:
            raw = _fetch_report_day(key_id, issuer_id, vendor_number, day.isoformat())
            cache[day] = None if raw is None else _day_stats(_rows_for_sku(_parse_tsv(raw), a.sku))

    range_days, d = [], lo
    while d <= hi:
        range_days.append(d); ensure(d); d += datetime.timedelta(days=1)
    mtd_start = hi.replace(day=1)
    mtd_days, d = [], mtd_start
    while d <= hi:
        mtd_days.append(d); ensure(d); d += datetime.timedelta(days=1)

    range_totals, range_pending = _aggregate(cache, range_days)
    mtd_totals, mtd_pending = _aggregate(cache, mtd_days)

    if a.json:
        out = {
            "sku": a.sku,
            "range": {"from": lo.isoformat(), "to": hi.isoformat()},
            "days": {
                d.isoformat(): ({"pending": True} if cache[d] is None else {
                    "downloads": _num(cache[d]["downloads"]), "redownloads": _num(cache[d]["redownloads"]), "updates": _num(cache[d]["updates"]),
                    "iap_units": {k: _num(v) for k, v in cache[d]["iap_units"].items()},
                    "proceeds": {c: float(v) for c, v in cache[d]["proceeds"].items()},
                    "unmapped_product_types": {k: _num(v) for k, v in cache[d]["unmapped"].items()},
                }) for d in range_days
            },
            "totals": {**_json_totals(range_totals), "pending_days": [d.isoformat() for d in range_pending]},
            "month_to_date": {"from": mtd_start.isoformat(), "to": hi.isoformat(), **_json_totals(mtd_totals),
                               "pending_days": [d.isoformat() for d in mtd_pending]},
        }
        print(json.dumps(out, indent=2))
        return

    print(f"Cloudfull sales · SKU {a.sku} · {lo} to {hi}\n")
    for d in range_days:
        _print_day(d, cache[d])
    print()
    _print_totals(f"Totals, {lo} to {hi}", range_totals, range_pending)
    print()
    _print_totals(f"Month-to-date, {mtd_start} to {hi}", mtd_totals, mtd_pending)


if __name__ == "__main__":
    main()
