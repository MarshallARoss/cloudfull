#!/bin/zsh
# Cloudfull
# Copyright (C) 2026 Marshall Ross.
# SPDX-License-Identifier: GPL-3.0-or-later

# Preflight gate for a TestFlight upload. The TestFlight upload recipe
# calls this script first, before anything else. `xcodebuild archive`
# must not run unless this script exits 0.
#
# Runs, in order, and stops at the first failure:
#   (0) the ad-measurement key checks (see "Ad keys" below)
#   (a) the CloudfullTests unit test target, on one simulator, and the
#       count of tests it ran
#   (b) scripts/gate_all.sh, the full UI test gate (2 standard rounds
#       plus 1 scale round; see that script's own header for what it
#       covers)
#
# Exit codes:
#   1  CloudfullTests failed, or the unit test invocation itself failed
#      to run
#   2  scripts/gate_all.sh exited non-zero
#   3  an ad key is empty in Config/Cloudfull.xcconfig + Config/AdKeys.xcconfig
#   4  Cloudfull/GoogleService-Info.plist is missing, unreadable, or its
#      BUNDLE_ID is not com.cloudfull.app
#   5  CloudfullTests ran a different number of tests than
#      EXPECTED_UNIT_TESTS, or printed no test count
#   8  this script ran from somewhere other than the repo copy beside
#      Cloudfull.xcodeproj
set -uo pipefail

# Project paths come from the location of this script. `${0:a:h}` is the
# absolute directory of this file.
HERE=${0:a:h}
PROJ=${HERE:h}

# Repo-copy self-check, same rule as scripts/gate_all.sh: stop if this is
# not the repo copy. The check requires that the script is in a `scripts`
# directory and that Cloudfull.xcodeproj is in the parent directory.
if [[ ! -d "$PROJ/Cloudfull.xcodeproj" || "${0:a:h:t}" != "scripts" ]]; then
  echo "## PREFLIGHT FAILURE: run the repo copy that sits beside Cloudfull.xcodeproj, not ${0:a}"
  exit 8
fi

# Another script, not a person, may run this script. It does not
# reliably inherit the full PATH an interactive shell builds from its
# startup files. Set it explicitly.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

UDID=42D5A716-ECE0-4E28-8F4A-148A9A38A6CE
DEST="platform=iOS Simulator,id=$UDID"
DD="$PROJ/build"
LOGDIR="$PROJ/build/preflight-logs"
mkdir -p "$LOGDIR"

# Build "17" was the only paid build of 1.0 (StoreProducts.paidBuilds).
# The legacy rule reads AppTransaction.originalAppVersion, which
# holds only the build number, so a later version numbered 17 would
# unlock every new free install for life. The unit test guards this
# too; this check runs even when the tests are skipped by hand.
BUILD_NUMBER=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);.*/\1/p' "$PROJ/Cloudfull.xcodeproj/project.pbxproj" | sort -u)
if [[ -z "$BUILD_NUMBER" ]]; then
  echo "## PREFLIGHT FAILURE: no integer CURRENT_PROJECT_VERSION found in project.pbxproj, so the paid-build check cannot run"
  exit 1
fi
# One value per line. Each is compared whole, so 117 or 170 never match 17.
while IFS= read -r BUILD; do
  if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "## PREFLIGHT FAILURE: CURRENT_PROJECT_VERSION value '$BUILD' is not an integer"
    exit 1
  fi
  for PAID in 17; do
    if [[ "$BUILD" == "$PAID" ]]; then
      echo "## PREFLIGHT FAILURE: CURRENT_PROJECT_VERSION is $BUILD, which was a paid 1.0 build; a free build may never carry it (see StoreProducts.paidBuilds)"
      exit 1
    fi
  done
done <<< "$BUILD_NUMBER"
echo "## build number $BUILD_NUMBER is not a paid 1.0 build"

# --- Ad keys ------------------------------------------------------------
# With an empty key the ad SDK for that network stays off, which is right
# for a Debug build and wrong for an upload: the owner would ship a build
# that cannot tell which buyers came from an ad. The effective value is the
# LAST assignment, because Config/Cloudfull.xcconfig ends with
# `#include? "AdKeys.xcconfig"` (the key file overrides the empty defaults).
# Both files hold only plain `NAME = value` lines; a `//` starts a comment.
xcconfig_value() {
  local name=$1 line value=""
  for f in "$PROJ/Config/Cloudfull.xcconfig" "$PROJ/Config/AdKeys.xcconfig"; do
    [[ -f "$f" ]] || continue
    line=$(grep -E "^[[:space:]]*${name}[[:space:]]*=" "$f" | tail -1) || true
    [[ -n "$line" ]] || continue
    value=$(print -r -- "${line#*=}" | sed -E 's://.*$::; s:^[[:space:]]+::; s:[[:space:]]+$::')
  done
  print -r -- "$value"
}
AD_KEYS=(META_APP_ID META_CLIENT_TOKEN TIKTOK_APPLE_APP_ID TIKTOK_APP_ID TIKTOK_ACCESS_TOKEN)
for KEY in $AD_KEYS; do
  if [[ -z "$(xcconfig_value "$KEY")" ]]; then
    echo "## PREFLIGHT FAILURE: ad key $KEY is empty; fill it in Config/AdKeys.xcconfig (see Config/AdKeys.example.xcconfig)"
    exit 3
  fi
done
echo "## ad keys: all ${#AD_KEYS} are set"

# Firebase reads Cloudfull/GoogleService-Info.plist (git-ignored). A file
# from another app would send events to the wrong project.
GSI="$PROJ/Cloudfull/GoogleService-Info.plist"
if [[ ! -f "$GSI" ]]; then
  echo "## PREFLIGHT FAILURE: $GSI is missing; download it from the Firebase console"
  exit 4
fi
GSI_BUNDLE=$(plutil -extract BUNDLE_ID raw -o - "$GSI" 2>/dev/null) || GSI_BUNDLE=""
if [[ "$GSI_BUNDLE" != "com.cloudfull.app" ]]; then
  echo "## PREFLIGHT FAILURE: GoogleService-Info.plist BUNDLE_ID is '$GSI_BUNDLE', not com.cloudfull.app"
  exit 4
fi
# FirebaseApp.configure() raises (a crash in Release) when these are missing or empty.
for GSI_KEY in GOOGLE_APP_ID API_KEY GCM_SENDER_ID PROJECT_ID; do
  GSI_VALUE=$(plutil -extract "$GSI_KEY" raw -o - "$GSI" 2>/dev/null) || GSI_VALUE=""
  if [[ -z "${GSI_VALUE// /}" ]]; then
    echo "## PREFLIGHT FAILURE: GoogleService-Info.plist has no value for $GSI_KEY; download a fresh file from the Firebase console"
    exit 4
  fi
done
echo "## GoogleService-Info.plist is present, BUNDLE_ID is com.cloudfull.app, and the four Firebase ids are set"

# Number of tests the CloudfullTests target must run. Swift Testing prints
# "Test run with N tests"; N = 0 means a filter matched nothing. This build
# adds six suites (AdEventsTests, AppleAdsAttributionTests, AdRegionTests, AdConversionValueTests,
# AdLateStartTests, AdScreenshotBlockTests) and four tests inside EntitlementsStoreKitTests
# (AdTokenStoreKitTests.swift, an extension, so the StoreKit tests never run in parallel).
# Change this one value whenever a unit test is added or removed.
EXPECTED_UNIT_TESTS=168

echo "################ UNIT TESTS (CloudfullTests) ################"
if ! xcodebuild test -project "$PROJ/Cloudfull.xcodeproj" -scheme Cloudfull \
    -only-testing:CloudfullTests -destination "$DEST" -derivedDataPath "$DD" \
    > "$LOGDIR/unit_tests.log" 2>&1; then
  echo "## PREFLIGHT FAILURE: CloudfullTests failed — see $LOGDIR/unit_tests.log"
  tail -60 "$LOGDIR/unit_tests.log"
  exit 1
fi
RAN_UNIT_TESTS=$(sed -nE 's/.*Test run with ([0-9]+) tests?.*/\1/p' "$LOGDIR/unit_tests.log" | tail -1)
if [[ -z "$RAN_UNIT_TESTS" ]]; then
  echo "## PREFLIGHT FAILURE: no 'Test run with N tests' line in $LOGDIR/unit_tests.log"
  exit 5
fi
if [[ "$RAN_UNIT_TESTS" != "$EXPECTED_UNIT_TESTS" ]]; then
  echo "## PREFLIGHT FAILURE: CloudfullTests ran $RAN_UNIT_TESTS tests, expected $EXPECTED_UNIT_TESTS (EXPECTED_UNIT_TESTS in this script)"
  exit 5
fi
echo "## CloudfullTests passed ($RAN_UNIT_TESTS tests)"

echo "################ FULL UI TEST GATE (scripts/gate_all.sh) ################"
if ! "$PROJ/scripts/gate_all.sh"; then
  echo "## PREFLIGHT FAILURE: scripts/gate_all.sh failed"
  exit 2
fi

echo "################ PREFLIGHT COMPLETE — unit tests + full gate passed ################"
