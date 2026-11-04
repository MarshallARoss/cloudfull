#!/bin/zsh
# Cloudfull
# Copyright (C) 2026 Marshall Ross.
# SPDX-License-Identifier: GPL-3.0-or-later

# Preflight gate for a TestFlight upload. The TestFlight upload recipe
# calls this script first, before anything else. `xcodebuild archive`
# must not run unless this script exits 0.
#
# Runs, in order, and stops at the first failure:
#   (a) the CloudfullTests unit test target, on one simulator
#   (b) scripts/gate_all.sh, the full UI test gate (2 standard rounds
#       plus 1 scale round; see that script's own header for what it
#       covers)
#
# Exit codes:
#   1  CloudfullTests failed, or the unit test invocation itself failed
#      to run
#   2  scripts/gate_all.sh exited non-zero
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

UDID=A0EFC6FE-B596-451E-A14C-753B52155B12
DEST="platform=iOS Simulator,id=$UDID"
DD="$PROJ/build"
LOGDIR="$PROJ/build/preflight-logs"
mkdir -p "$LOGDIR"

# Build "17" was the only paid build of 1.0 (StoreProducts.paidBuilds).
# The grandfather rule reads AppTransaction.originalAppVersion, which
# holds only the build number, so a later version numbered 17 would
# unlock every new free install for life. The unit test guards this
# too; this check runs even when the tests are skipped by hand.
BUILD_NUMBER=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' "$PROJ/Cloudfull.xcodeproj/project.pbxproj" | sort -u)
for PAID in 17; do
  if [[ "$BUILD_NUMBER" == *"$PAID"* ]]; then
    echo "## PREFLIGHT FAILURE: CURRENT_PROJECT_VERSION is $BUILD_NUMBER, which was a paid 1.0 build; a free build may never carry it (see StoreProducts.paidBuilds)"
    exit 1
  fi
done
echo "## build number $BUILD_NUMBER is not a paid 1.0 build"

echo "################ UNIT TESTS (CloudfullTests) ################"
if ! xcodebuild test -project "$PROJ/Cloudfull.xcodeproj" -scheme Cloudfull \
    -only-testing:CloudfullTests -destination "$DEST" -derivedDataPath "$DD" \
    > "$LOGDIR/unit_tests.log" 2>&1; then
  echo "## PREFLIGHT FAILURE: CloudfullTests failed — see $LOGDIR/unit_tests.log"
  tail -60 "$LOGDIR/unit_tests.log"
  exit 1
fi
echo "## CloudfullTests passed"

echo "################ FULL UI TEST GATE (scripts/gate_all.sh) ################"
if ! "$PROJ/scripts/gate_all.sh"; then
  echo "## PREFLIGHT FAILURE: scripts/gate_all.sh failed"
  exit 2
fi

echo "################ PREFLIGHT COMPLETE — unit tests + full gate passed ################"
