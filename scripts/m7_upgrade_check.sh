#!/bin/zsh
# Cloudfull
# Copyright (C) 2026 Marshall Ross.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# M7 Step G1: proves the 1.0 -> 1.1 store-split upgrade. Installs a 1.1
# Debug build over a fixture copied from a real 1.0 store
# (scripts/fixtures/store-1.0/default.store*, made once by hand — see
# design/M7_SPEC.md Step G1 item 1, not automated here), launches with
# -cloudfull-report-store, and checks the reported row counts against
# scripts/fixtures/store-1.0/COUNTS.txt. Then launches once more,
# normally, and screenshots it so a person can confirm the deck resumed
# instead of showing onboarding.
#
# Usage:
#   scripts/m7_upgrade_check.sh                 # local-only, with the 1.0 fixture (the main proof)
#   scripts/m7_upgrade_check.sh --no-fixture     # the split flag pre-set, no local.store, no fixture: must not crash
#   scripts/m7_upgrade_check.sh --cloudkit       # same as the default, but CloudKit on (sim must already be signed in)
#
# COUNTS.txt format: one "ZNAME=count" line per table named in
# design/M7_SPEC.md Step G1 item 1 (ZSEENENTRY, ZLIKEDENTRY,
# ZTRASHENTRY, ZPHOTOSEENENTRY). This script sources the file directly,
# so it must contain only lines of that shape.
#
# Exit codes:
#   1  usage error, or the fixture is missing (default/--cloudkit modes only)
#   2  the 1.1 Debug build is missing, or the app never produced a data container
#   4  a reported count does not match COUNTS.txt, or the mode field is wrong
#   5  default.store still has one of the 4 dropped local-model tables
#   6  the app never logged a store_report_ line (it must, even in --no-fixture mode)
set -uo pipefail

# Another script, not a person, runs this script. See make_seed_clip.sh
# for why PATH is set explicitly.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

UDID=E2DAB7E8-649E-4F1A-BBA9-676236EB075A
BUNDLE_ID=com.cloudfull.app

HERE=${0:a:h}
PROJ=${HERE:h}
DD="$PROJ/build"
APP="$DD/Build/Products/Debug-iphonesimulator/Cloudfull.app"
FIXTURE="$PROJ/scripts/fixtures/store-1.0"
COUNTS="$FIXTURE/COUNTS.txt"
LOGDIR="$DD/gate-logs"
mkdir -p "$LOGDIR"

MODE="default"
case "${1:-}" in
  --no-fixture) MODE="no-fixture" ;;
  --cloudkit)   MODE="cloudkit" ;;
  "") ;;
  *) echo "## usage: $0 [--no-fixture|--cloudkit]"; exit 1 ;;
esac
echo "## m7_upgrade_check: mode=$MODE"

if [[ "$MODE" != "no-fixture" && ! -f "$FIXTURE/default.store" ]]; then
  echo "## GATE FAILURE: no fixture at $FIXTURE/default.store — see design/M7_SPEC.md Step G1 item 1"
  exit 1
fi
if [[ ! -d "$APP" ]]; then
  echo "## GATE FAILURE: no Debug build at $APP — build for the sim first (xcodebuild build-for-testing, as gate_all.sh does)"
  exit 2
fi

xcrun simctl uninstall "$UDID" "$BUNDLE_ID" > /dev/null 2>&1
xcrun simctl install "$UDID" "$APP"

container=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data) \
  || { echo "## GATE FAILURE: no app container after install"; exit 2; }
SUPPORT="$container/Library/Application Support"
mkdir -p "$SUPPORT"

if [[ "$MODE" != "no-fixture" ]]; then
  cp "$FIXTURE"/default.store* "$SUPPORT/" 2>/dev/null
else
  # Simulates a device that already ran the store split once (the flag
  # reads true) but has no local.store — for example a container
  # restored from a backup that did not carry it. No fixture is copied
  # either, so default.store starts empty too. The only requirement
  # here is that the app does not crash.
  xcrun simctl spawn "$UDID" defaults write "$BUNDLE_ID" storage.splitV1Done -bool YES
fi

report_args=(-cloudfull-report-store)
[[ "$MODE" != "cloudkit" ]] && report_args+=(-cloudfull-local-only)
xcrun simctl launch "$UDID" "$BUNDLE_ID" "${report_args[@]}" > /dev/null 2>&1
sleep 5

report=$(xcrun simctl spawn "$UDID" log show --last 1m \
  --predicate 'subsystem == "com.cloudfull.app" and category == "StoreReport"' --style compact \
  | grep -oE 'store_report_[a-zA-Z]+_[0-9]+_[0-9]+_[0-9]+_[0-9]+_[0-9]+_[0-9]+_[0-9]+_[0-9]+_[0-9]+' | tail -1)

if [[ -z "$report" ]]; then
  echo "## GATE FAILURE: app never logged a store_report_ line"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" > /dev/null 2>&1
  exit 6
fi
echo "## report: $report"

mode_field=$(echo "$report"  | cut -d_ -f3)
seen=$(echo "$report"        | cut -d_ -f4)
liked=$(echo "$report"       | cut -d_ -f5)
trash=$(echo "$report"       | cut -d_ -f6)
photoSeen=$(echo "$report"   | cut -d_ -f7)
deckState=$(echo "$report"   | cut -d_ -f8)
deckOrder=$(echo "$report"   | cut -d_ -f9)
photoDeck=$(echo "$report"   | cut -d_ -f10)
meta=$(echo "$report"        | cut -d_ -f11)
trashOwned=$(echo "$report"  | cut -d_ -f12)

if [[ "$MODE" == "no-fixture" ]]; then
  echo "## --no-fixture: app reported without crashing (mode=$mode_field) — PASS, not checking counts"
else
  source "$COUNTS"
  fail=0
  [[ "$seen"       == "$ZSEENENTRY" ]]      || { echo "## MISMATCH seen: got $seen, expected $ZSEENENTRY"; fail=1; }
  [[ "$liked"      == "$ZLIKEDENTRY" ]]     || { echo "## MISMATCH liked: got $liked, expected $ZLIKEDENTRY"; fail=1; }
  [[ "$trash"      == "$ZTRASHENTRY" ]]     || { echo "## MISMATCH trash: got $trash, expected $ZTRASHENTRY"; fail=1; }
  [[ "$photoSeen"  == "$ZPHOTOSEENENTRY" ]] || { echo "## MISMATCH photoSeen: got $photoSeen, expected $ZPHOTOSEENENTRY"; fail=1; }
  [[ "$deckState"  == "1" ]] || { echo "## MISMATCH deckState: got $deckState, expected 1"; fail=1; }
  [[ "$deckOrder"  == "1" ]] || { echo "## MISMATCH deckOrder: got $deckOrder, expected 1"; fail=1; }
  [[ "$photoDeck"  == "1" ]] || { echo "## MISMATCH photoDeck: got $photoDeck, expected 1"; fail=1; }
  [[ "$meta"       == "0" ]] || { echo "## MISMATCH meta: got $meta, expected 0"; fail=1; }
  [[ "$trashOwned" == "$trash" ]] || { echo "## MISMATCH trashOwned ($trashOwned) != trash ($trash)"; fail=1; }
  if [[ "$MODE" == "cloudkit" ]]; then
    [[ "$mode_field" == "cloudKit" ]] || { echo "## MISMATCH mode: got $mode_field, expected cloudKit"; fail=1; }
  else
    [[ "$mode_field" == "localOnly" ]] || { echo "## MISMATCH mode: got $mode_field, expected localOnly"; fail=1; }
  fi
  if (( fail )); then
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" > /dev/null 2>&1
    exit 4
  fi

  dropped=$(sqlite3 "$SUPPORT/default.store" \
    "select count(*) from sqlite_master where name in ('ZDECKSTATE','ZDECKORDER','ZPHOTODECKSTATE','ZPHOTOMETARECORD');")
  if (( dropped != 0 )); then
    echo "## GATE FAILURE: default.store still has $dropped of the 4 local-model tables"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" > /dev/null 2>&1
    exit 5
  fi
  echo "## counts match COUNTS.txt; the 4 local-model tables are gone from default.store"
fi

xcrun simctl terminate "$UDID" "$BUNDLE_ID" > /dev/null 2>&1

echo "## launching normally to confirm the deck resumes (not onboarding)"
normal_args=()
[[ "$MODE" != "cloudkit" ]] && normal_args+=(-cloudfull-local-only)
if (( ${#normal_args} )); then
  xcrun simctl launch "$UDID" "$BUNDLE_ID" "${normal_args[@]}" > /dev/null 2>&1
else
  xcrun simctl launch "$UDID" "$BUNDLE_ID" > /dev/null 2>&1
fi
sleep 5
shot="$LOGDIR/m7_upgrade_resume_${MODE}.png"
xcrun simctl io "$UDID" screenshot "$shot" > /dev/null 2>&1
echo "## screenshot saved to $shot — confirm by eye it shows a page_, not the onboarding welcome screen"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" > /dev/null 2>&1

echo "## m7_upgrade_check ($MODE): PASS"
