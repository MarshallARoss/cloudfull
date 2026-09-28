#!/bin/zsh
# Cloudfull
# Copyright (C) 2026 Marshall Ross.
# SPDX-License-Identifier: GPL-3.0-or-later

# Full-suite gate script. It runs 2 consecutive standard rounds, then 1
# scale round, and exits non-zero on the first failure.
#
# This script proves which exact source tree it tested. `source_fence`
# hashes the path, mtime, and size of the source files the build and the
# gate use into one SHA-256 value. The script prints this fence at the
# start and again at completion, and exits 9 if the value changed during
# the run. The completion banner prints the final fence, so a reader of
# the log can match it against the exact source tree. Edit any source
# file afterward, even a comment, and you must re-run the gate before you
# cite that log again.
#
# A log is valid only for the tree whose fence it prints.
#
# Each standard round reseeds the library, then compares the seeder
# count, Photos.sqlite, and the app's reported library count. It then
# runs, in order: M8Tests, M6Tests, M3ShrinkTests, M4Tests, M5Tests, and
# finally M1ExitTests together with M2TrashTests.
#
# M8Tests runs first, right after the reseed. It needs three tests live
# and unqueued: testShrinkableFilterNarrowsPoolAndEveryPageMatches,
# testBigAndLongFiltersMatchTheirPredicate, and
# testFiltersCombineWithAndAndTypeNarrowsToo. These use the 4K and
# 1080p fixtures, and M2TrashTests deletes 17 of those fixtures later
# in the round. M6Tests runs next because M2TrashTests, M3ShrinkTests,
# and M5Tests all destroy or shrink the fixtures M6Tests targets.
# M3ShrinkTests runs after that, and the gate checks the HDR
# replacement with ffprobe.
#
# M4Tests runs next, and the gate then counts the album M4Tests
# created. M5Tests runs after that, skipping its scale-only performance
# test. M1ExitTests and M2TrashTests run last together, and the gate
# then verifies that M2TrashTests' bin-emptying deleted and restored
# the correct assets. It compares each id with Photos.sqlite.
#
# Each standard round runs 30 tests. It runs 8 from M8Tests, 4 from
# M6Tests, 4 from M3ShrinkTests, 3 from M4Tests, 7 from M5Tests, and 4
# from M1ExitTests and M2TrashTests together.
#
# The gate runs these suites as separate xcodebuild invocations, in this
# fixed order, for two reasons. First, M2TrashTests queues 20 videos and
# permanently deletes 17. M5Tests' testSpaceCounterCountsEveryByteOnce
# deletes 4 more. The feed order selects which videos, so M3ShrinkTests
# or M5Tests would probably lose a fixture they need if those suites ran
# after M2TrashTests.
#
# Second, M4Tests' add-to-album test needs a full, undepleted library,
# for the same reason M3ShrinkTests and M5Tests do, so it also runs
# before M1ExitTests and M2TrashTests. Alphabetical class order alone
# puts M2TrashTests before M3ShrinkTests, M4Tests, and M5Tests, so a
# single xcodebuild invocation cannot express this required order.
#
# Every suite runs every round. Only the M5Tests scale test waits for
# the scale round.
#
# The scale round seeds a pool of 320 videos (POOL_TARGET=320) and runs
# only M5Tests' launch-time performance test and M1ExitTests. The app
# must launch in under 3 seconds with a pool of 300 or more videos. The
# M1ExitTests scroll test must stay green at that pool size. A 320 pool
# in the standard rounds makes the gate much slower.
#
# M1ExitTests already swipes pool + max(10, pool/4) pages. The gate
# requires two passes only for the standard rounds. Most regressions
# occur there. Running the large-pool check once, instead of twice like
# the standard rounds, is a deliberate tradeoff between coverage and
# gate runtime.
#
# Exit codes:
#   1  a test invocation exited non-zero, reported the wrong number of
#      tests executed, reported a failure, or found no test-summary
#      line in the log
#   2  disk free below 4 GiB
#   3  reseed (scripts/seed_m3.sh) failed
#   4  build-for-testing failed
#   6  the HDR ffprobe proof failed. No app container existed, or the
#      export never wrote the replacement. The replacement's color
#      transfer, primaries, color space, pixel format, or dimensions
#      did not match the HDR source
#   7  the pool cross-check failed: the seeder count, the app's reported
#      library count, and Photos.sqlite disagree, or the app never
#      reported its pool
#   8  this script ran from somewhere other than the repo copy beside
#      Cloudfull.xcodeproj
#   9  source under Cloudfull/, CloudfullUITests/, scripts/, or
#      Cloudfull.xcodeproj/ changed during the run
#   10 the empty-bin identity proof failed. One of four checks failed:
#        - the deleted or restored id count is wrong
#        - an id appears in both sets
#        - a deleted asset is still live in Photos
#        - a restored asset did not survive
#   11 photo access was not .authorized at the start of a round. A prior
#      test, most likely M5Tests' Settings-driven Limited-access flow,
#      left the simulator unable to run any later round correctly
#   12 host load average above 32; video export is too slow for the
#      test timeouts
set -uo pipefail

# Project paths come from the location of this script. `${0:a:h}` is the
# absolute directory of this file.
HERE=${0:a:h}
PROJ=${HERE:h}

# Repo-copy self-check: stop if this is not the repo copy. The check
# requires that the script is in a `scripts` directory and that
# Cloudfull.xcodeproj is in the parent directory. It does not use an
# absolute path, so it still works if someone renames the containing
# folder.
if [[ ! -d "$PROJ/Cloudfull.xcodeproj" || "${0:a:h:t}" != "scripts" ]]; then
  echo "## GATE FAILURE: run the repo copy that sits beside Cloudfull.xcodeproj, not ${0:a}"
  exit 8
fi

# Another script, not a person, runs this script. It does not reliably
# inherit the full PATH an interactive shell builds from its startup
# files. Set it explicitly.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

UDID=E2DAB7E8-649E-4F1A-BBA9-676236EB075A
DEST="platform=iOS Simulator,id=$UDID"
DD="$PROJ/build"
BUNDLE_ID=com.cloudfull.app
LOGDIR="$PROJ/build/gate-logs"
PHOTOS_DB="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Media/PhotoData/Photos.sqlite"
FFPROBE=/opt/homebrew/bin/ffprobe

mkdir -p "$LOGDIR"

# --- Source fence -----------------------------------------------------
# The fence is a SHA-256 hash of the sorted "path:mtime:size" for the
# source files that the build or the gate uses. These files are
# Cloudfull/ (source, plists, entitlements, and the asset catalog),
# CloudfullUITests/, scripts/ (including scripts/fixtures/), and
# Cloudfull.xcodeproj/.
# Hashing path, mtime, and size together, rather than only the newest
# mtime, also detects a deleted file or an mtime moved backward.
#
# The fence includes scripts/fixtures/ so that it detects a changed seed
# fixture. `seed_m3.sh`'s own `validate_fixture` can legitimately
# regenerate a fixture, for example on a fresh checkout with no fixtures
# yet. A fence trip caused by that regeneration reads as a source change
# during the run and costs a re-run, never a false pass. Failing safe in
# that direction is the intended tradeoff.
source_fence() {
  {
    find "$PROJ/Cloudfull" \( -name '*.swift' -o -name '*.plist' -o -name '*.entitlements' \) -type f -print0 2>/dev/null
    find "$PROJ/Cloudfull/Assets.xcassets" -type f -print0 2>/dev/null
    find "$PROJ/CloudfullUITests" -name '*.swift' -type f -print0 2>/dev/null
    find "$PROJ/scripts" \( -name '*.sh' -o -path '*/fixtures/*' \) -type f -print0 2>/dev/null
    find "$PROJ/Cloudfull.xcodeproj" -type f -print0 2>/dev/null
  } | { local f m s
    while IFS= read -r -d '' f; do
      m=$(stat -f%m "$f" 2>/dev/null) || continue
      s=$(stat -f%z "$f" 2>/dev/null) || continue
      printf '%s:%s:%s\n' "$f" "$m" "$s"
    done
  } | sort | shasum -a 256 | awk '{print $1}'
}

FENCE_START=$(source_fence)
echo "## SOURCE FENCE (start): $FENCE_START"

# Runs one xcodebuild invocation and captures its full output to $1.
# The gate fails unless the process exits 0. The gate also fails unless
# the summary line reports exactly the expected number of tests
# executed and reports zero failures. $2 is a human-readable label; $3
# is the expected "Executed N tests" count. The arguments after $3 are
# the command to run. Prints the pass/fail lines for a person reading
# the console, plus the parsed verdict.
run_and_check() {
  local logfile="$1" label="$2" expected="$3"
  shift 3

  "$@" > "$logfile" 2>&1
  local xc_status=$?

  grep -E "^Test Case .*(passed|failed)|error:|TEST (SUCCEEDED|FAILED)" "$logfile"

  if (( xc_status != 0 )); then
    echo "## GATE FAILURE: $label — xcodebuild exited $xc_status"
    return 1
  fi

  # xctest prints one "Executed N tests, with F failures" line at each
  # summary level:
  #   - per class
  #   - per bundle
  #   - once for the outermost "Selected tests" suite, which wraps
  #     every -only-testing target in this invocation
  # The last match in the log is always that outermost total.
  local summary
  summary=$(grep -E "Executed [0-9]+ tests?, with [0-9]+ failures?" "$logfile" | tail -1)
  if [[ -z "$summary" ]]; then
    echo "## GATE FAILURE: $label — no 'Executed N tests' summary line found (log: $logfile)"
    return 1
  fi

  local executed failures
  executed=$(echo "$summary" | sed -E 's/.*Executed ([0-9]+) tests?,.*/\1/')
  failures=$(echo "$summary" | sed -E 's/.*with ([0-9]+) failures?.*/\1/')
  echo "## $label: executed=$executed failures=$failures (expected=$expected, 0)"

  if (( executed != expected )); then
    echo "## GATE FAILURE: $label — executed $executed tests, expected $expected"
    return 1
  fi
  if (( failures != 0 )); then
    echo "## GATE FAILURE: $label — reported $failures failure(s)"
    return 1
  fi
  return 0
}

# --- Probe values -----------------------------------------------------
# Collects the "## PROBE name=value" lines a test prints at the moment
# it asserts on a probe reading. A log then carries the real numbers,
# not only a pass or fail result. Reads the invocation logs
# `run_and_check` already wrote, so this needs no extra launch. The
# number printed is always the same number the assertion used.
export_probe_values() {
  local label="$1"; shift
  local found=0 line
  for logfile in "$@"; do
    [[ -f "$logfile" ]] || continue
    while IFS= read -r line; do
      echo "## PROBE [$label] ${line#\#\# PROBE }"
      found=1
    done < <(grep -h '^## PROBE ' "$logfile" 2>/dev/null)
  done
  (( found )) || echo "## PROBE [$label] (none emitted)"
}

# --- Pool cross-check ---------------------------------------------------
# Compares `CLOUDFULL_POOL_AFTER_SEED`, the seeder's own count, against
# Photos.sqlite directly, then compares Photos.sqlite against the app's
# own `fetchAllVideoIDs()` count, read through the `-cloudfull-report-pool`
# DEBUG launch argument. This detects an app that drops a class of
# videos. The seeder and the app can agree and both be wrong.
run_pool_crosscheck() {
  local db_total
  db_total=$(sqlite3 "$PHOTOS_DB" "select count(*) from ZASSET where ZKIND=1 and ZTRASHEDSTATE=0;")
  if (( db_total != CLOUDFULL_POOL_AFTER_SEED )); then
    echo "## GATE FAILURE: seeder reported $CLOUDFULL_POOL_AFTER_SEED, DB has $db_total"
    exit 7
  fi

  xcrun simctl launch "$UDID" "$BUNDLE_ID" -cloudfull-reset-deck-state -cloudfull-report-pool > /dev/null 2>&1
  sleep 8
  local report
  report=$(xcrun simctl spawn "$UDID" log show --last 2m \
    --predicate 'subsystem == "com.cloudfull.app" and category == "PoolReport"' --style compact \
    | grep -oE 'pool_report_[0-9]+_[0-9]+' | tail -1)
  if [[ -z "$report" ]]; then
    echo "## GATE FAILURE: app never reported its pool"
    exit 7
  fi
  local app_lib app_pool
  app_lib=$(echo "$report" | cut -d_ -f3)
  app_pool=$(echo "$report" | cut -d_ -f4)
  echo "## pool cross-check: Photos.sqlite=$db_total app library=$app_lib app pool=$app_pool"
  # The gate prints `app_pool` but does not check it. A fresh store has
  # no shields or queues, so it always equals `app_lib`, and checking
  # that would compare the value against itself. The important check
  # compares the library count with Photos.sqlite.
  if (( app_lib != db_total )); then
    echo "## GATE FAILURE: fetchAllVideoIDs sees $app_lib of $db_total videos"
    exit 7
  fi
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" > /dev/null 2>&1
}

# --- HDR passthrough proof -----------------------------------------------
# Runs ffprobe on the actual saved 1080p replacement for the known HDR
# seed clip. This catches an export preset change that tone-maps HDR to
# SDR.
run_hdr_proof() {
  echo "## --- HDR passthrough proof (ffprobe on the saved replacement) ---"
  local container probe
  container=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data) \
    || { echo "## GATE FAILURE: no app container"; exit 6; }
  probe="$container/Documents/hdr_probe.mov"
  rm -f "$probe"
  SIMCTL_CHILD_CLOUDFULL_HDR_ORIGINAL_ID="$TEST_RUNNER_CLOUDFULL_HDR_ASSET_ID" \
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -cloudfull-export-newest-replacement > /dev/null 2>&1

  local last=-1 sz
  for _ in $(seq 1 60); do
    if [[ ! -f "$probe" ]]; then sleep 1; continue; fi
    sz=$(stat -f%z "$probe")
    if (( sz > 0 && sz == last )); then break; fi
    last=$sz
    sleep 1
  done
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" > /dev/null 2>&1

  if [[ ! -s "$probe" ]]; then
    echo "## GATE FAILURE: HDR replacement was never exported"
    xcrun simctl spawn "$UDID" log show --last 5m \
      --predicate 'subsystem == "com.cloudfull.app" and category == "HDRProbe"' --style compact | tail -20
    exit 6
  fi

  # Reads ffprobe output as key=value lines, not positional CSV. This
  # build of ffprobe orders `-of csv=p=0` fields by its own fixed
  # internal template, not by the order that `-show_entries` assigns. A
  # positional `read` would therefore silently pair each value with the
  # wrong variable. `probe_fixture` in seed_m3.sh reads ffprobe output
  # the same way.
  local -A hv=()
  local key val
  while IFS='=' read -r key val; do
    [[ -n "$key" ]] && hv[$key]="$val"
  done < <($FFPROBE -v error -select_streams v:0 \
    -show_entries stream=color_transfer,color_primaries,color_space,pix_fmt,width,height \
    -of default=noprint_wrappers=1 "$probe" 2>/dev/null)
  local tf="${hv[color_transfer]:-}" prim="${hv[color_primaries]:-}" csp="${hv[color_space]:-}"
  local pixfmt="${hv[pix_fmt]:-}" w="${hv[width]:-}" h="${hv[height]:-}"
  echo "## HDR probe: transfer=$tf primaries=$prim space=$csp pix_fmt=$pixfmt ${w}x${h}"

  [[ "$tf" == "arib-std-b67" ]] || { echo "## GATE FAILURE: color_transfer=$tf (want arib-std-b67)"; exit 6; }
  [[ "$prim" == "bt2020" ]] || { echo "## GATE FAILURE: color_primaries=$prim (want bt2020)"; exit 6; }
  [[ "$csp" == bt2020* ]] || { echo "## GATE FAILURE: color_space=$csp (want bt2020nc)"; exit 6; }
  [[ "$pixfmt" == "yuv420p10le" || "$pixfmt" == "p010le" ]] \
    || { echo "## GATE FAILURE: pix_fmt=$pixfmt (want 10-bit)"; exit 6; }
  [[ ( "$w" == "1920" && "$h" == "1080" ) || ( "$w" == "1080" && "$h" == "1920" ) ]] \
    || { echo "## GATE FAILURE: replacement is ${w}x${h}, want exactly 1080p"; exit 6; }
}

# --- Test-album accounting -----------------------------------------------
# This function only counts and reports live test albums; it does not
# purge them. Purging inside the gate is not viable. PhotoKit's
# `deleteAssetCollections` always shows a consent alert. iOS
# rate-limits repeated consent alerts for the same app. The alert's
# render latency therefore grows with every gate run and never resets
# on reboot. No fixed timeout stays reliable under that growth.
#
# A live test album uses about 200 bytes and has no media. PhotoKit
# cannot skip the 30-day trash hold. A purged album therefore stays as a
# row with ZTRASHEDSTATE=1. This function counts only live rows. M4Tests
# creates at most one per round. Purge test albums manually with
# scripts/purge_albums.sh.
#
# $1 is not used; $2 is the label.
purge_test_albums() {
  local run_label="$2"
  local live
  live=$(sqlite3 "$PHOTOS_DB" "select count(*) from ZGENERICALBUM where ZTITLE like 'Cloudfull UITest%' and ZTRASHEDSTATE=0;" 2>/dev/null)
  echo "## test albums ($run_label): ${live:-unreadable} live (accumulation is expected; see scripts/purge_albums.sh)"
}

# --- Photo access check --------------------------------------------------
# Verifies Photos authorization is `.authorized` at the start of every
# round. An intermittent failure in the M5Tests Settings navigation
# (`setPhotoAccess`) can leave access at Limited or Denied. `simctl
# privacy grant` does not work on this runtime. Then every later round
# shows `limitedView` or `deniedView` and fails. `-cloudfull-report-auth`
# is a DEBUG launch argument that logs the live `PHAuthorizationStatus`
# and exits immediately, so this check does not depend on any UI.
verify_photo_access_authorized() {
  local label="$1"
  # A freshly interrupted xcodebuild can leave the simulator busy enough
  # that the report line lands late, even though the status is
  # `authorized`. Try 3 times, and wait 3, 6, then 9 seconds. The script
  # treats an empty read as this delay. Any other value that is not
  # 'authorized' fails immediately below.
  local auth_state=""
  local attempt
  for attempt in 1 2 3; do
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -cloudfull-report-auth > /dev/null 2>&1
    sleep $(( attempt * 3 ))
    auth_state=$(xcrun simctl spawn "$UDID" log show --last 1m \
      --predicate 'subsystem == "com.cloudfull.app" and category == "AuthReport"' --style compact \
      | grep -oE 'auth_report_[A-Za-z]+' | tail -1 | sed 's/auth_report_//')
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" > /dev/null 2>&1
    [[ -n "$auth_state" ]] && break
    echo "## photo access check ($label): empty read on attempt $attempt, retrying"
  done
  echo "## photo access check ($label): ${auth_state:-<none>}"
  if [[ "$auth_state" != "authorized" ]]; then
    echo "## GATE FAILURE: photo access is '${auth_state:-unknown}', not authorized, at $label — a" \
         "prior test (most likely M5's Settings-driven Limited-access flow) left the simulator" \
         "unable to run any later round correctly"
    exit 11
  fi
}

# --- Empty-bin identity proof --------------------------------------------
# The app logs the exact sets of ids it deleted and restored. This
# checks those sets directly against Photos.sqlite, so a correct
# deceased/restored count alone cannot hide the wrong assets being
# deleted or restored.
run_m2_identity_proof() {
  local since="$1"
  echo "## --- M2 identity proof: exact survivors and deceased vs Photos.sqlite ---"
  # Scopes the log read to `--start "$since"`, which the caller captures
  # immediately before this round's M1ExitTests + M2TrashTests
  # invocation. A wider window would also collect `trash_restored_`
  # lines from other tests or other rounds and inflate the restored
  # count. `deceased` uses `tail -1`. The bin-emptying call runs last in
  # the round. Its most recent line is from this invocation.
  local tlog
  tlog=$(xcrun simctl spawn "$UDID" log show --start "$since" \
    --predicate 'subsystem == "com.cloudfull.app" and category == "TrashService"' --style compact)

  local deceased restored nd nr
  deceased=$(echo "$tlog" | grep -oE 'emptybin_deleted_[^ ]+' | tail -1 \
    | sed 's/emptybin_deleted_//' | tr ',' '\n' | grep -v '^$' | sort -u)
  restored=$(echo "$tlog" | grep -oE 'trash_restored_[^ ]+' \
    | sed 's/trash_restored_//' | sort -u)

  nd=$(echo "$deceased" | grep -c .)
  nr=$(echo "$restored" | grep -c .)
  echo "## identity proof: $nd deceased, $nr restored"
  (( nd == 17 )) || { echo "## GATE FAILURE: expected 17 deceased ids, log carries $nd"; exit 10; }
  (( nr == 3 ))  || { echo "## GATE FAILURE: expected 3 restored ids, log carries $nr";  exit 10; }

  # An id cannot legitimately appear in both sets from the same
  # M1ExitTests + M2TrashTests invocation. If one does, either the log
  # scoping above is wrong, or the app reported the same id twice.
  local overlap
  overlap=$(comm -12 <(echo "$deceased") <(echo "$restored"))
  if [[ -n "$overlap" ]]; then
    echo "## GATE FAILURE: id(s) appear in both the deceased and restored sets: $overlap"
    exit 10
  fi

  # A local identifier is <UUID>/L0/001. ZASSET.ZUUID stores only the
  # UUID.
  local id u n
  for id in ${(f)deceased}; do
    u=${id%%/*}
    n=$(sqlite3 "$PHOTOS_DB" "select count(*) from ZASSET where ZUUID='$u' and ZTRASHEDSTATE=0;")
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "## GATE FAILURE: sqlite3 failed for $u"; exit 10; }
    (( n == 0 )) || { echo "## GATE FAILURE: emptied asset $u still live in Photos"; exit 10; }
  done

  for id in ${(f)restored}; do
    u=${id%%/*}
    n=$(sqlite3 "$PHOTOS_DB" "select count(*) from ZASSET where ZUUID='$u' and ZTRASHEDSTATE=0;")
    (( n == 1 )) || { echo "## GATE FAILURE: restored asset $u did not survive (count $n)"; exit 10; }
  done
  echo "## identity proof: 17/17 deceased gone, 3/3 restored alive"
}

echo "################ BUILD-FOR-TESTING ################"
if ! xcodebuild build-for-testing -project "$PROJ/Cloudfull.xcodeproj" -scheme Cloudfull \
    -destination "$DEST" -derivedDataPath "$DD" > "$LOGDIR/gate_build.log" 2>&1; then
  echo "## GATE FAILURE: build-for-testing failed — see $LOGDIR/gate_build.log"
  tail -60 "$LOGDIR/gate_build.log"
  exit 4
fi
echo "## build-for-testing succeeded"

# Runs 2 standard rounds, not more. Round 1 runs on a fresh pool. Round
# 2 runs on the state that round 1 leaves, to find failures that come
# from that state.
for run in 1 2; do
  echo "################ RUN $run ################"

  # M3ShrinkTests' export takes about 27 seconds on a quiet host. Under
  # heavy host load, it can take tens of minutes, which then reads as a
  # false app regression instead of a slow host. Above a load of 32,
  # the export cannot finish in the test timeout. The gate stops. Above 12,
  # it prints a warning.
  load1=$(sysctl -n vm.loadavg | awk '{print int($2)}')
  if (( load1 > 32 )); then
    echo "## GATE FAILURE: host load average $load1 (>32) — video encoding cannot run honestly; quit heavy apps (Chrome/Slack), check fileproviderd/mds_stores, re-run"
    exit 12
  elif (( load1 > 12 )); then
    echo "## WARNING: host load average $load1 — expect slow rounds"
  fi

  avail=$(df -g / | tail -1 | awk '{print $4}')
  echo "## disk free: ${avail} GiB"
  if (( avail < 4 )); then
    echo "## ABORTING: disk below 4 GiB"
    exit 2
  fi

  verify_photo_access_authorized "round $run start"

  echo "## reseeding"
  if ! "$PROJ/scripts/seed_m3.sh" > "$LOGDIR/m3env.sh" 2> "$LOGDIR/m3seed.err"; then
    echo "## RESEED FAILED"; cat "$LOGDIR/m3seed.err"; exit 3
  fi
  grep '^#' "$LOGDIR/m3seed.err"
  source "$LOGDIR/m3env.sh"
  echo "## pool after seed: $CLOUDFULL_POOL_AFTER_SEED"
  echo "## 4K fixtures: 3 shrinkable + 1 HDR + 1 already-efficient"

  echo "## --- Pool cross-check (Photos.sqlite vs seeder vs app) ---"
  run_pool_crosscheck

  # M8Tests runs first after the reseed and the pool cross-check.
  # testShrinkableFilterNarrowsPoolAndEveryPageMatches,
  # testBigAndLongFiltersMatchTheirPredicate, and
  # testFiltersCombineWithAndAndTypeNarrowsToo need the five 4K fixtures
  # and the two 1080p fixtures live and unqueued. M6Tests is
  # landscape-only and leaves those fixtures alone; M2TrashTests deletes
  # 17 videos later in this round.
  #
  # `source "$LOGDIR/m3env.sh"` above exports
  # TEST_RUNNER_CLOUDFULL_SHRINKABLE_ASSET_IDS,
  # TEST_RUNNER_CLOUDFULL_HDR_ASSET_ID,
  # TEST_RUNNER_CLOUDFULL_INCOMPRESSIBLE_ASSET_ID, and
  # TEST_RUNNER_CLOUDFULL_KNOWN_1080P_ASSET_IDS into this shell, from
  # `export` lines that seed_m3.sh prints. The three tests above read
  # the same names without the TEST_RUNNER_ prefix; xcodebuild passes
  # them to the test runner without the prefix.
  echo "## --- M8 ---"
  if ! run_and_check "$LOGDIR/gate_run${run}_m8.log" "run $run M8" 8 \
      xcodebuild test-without-building -project "$PROJ/Cloudfull.xcodeproj" -scheme Cloudfull \
      -only-testing:CloudfullUITests/M8Tests \
      -destination "$DEST" -derivedDataPath "$DD"; then
    exit 1
  fi

  echo "## --- M6 ---"
  if ! run_and_check "$LOGDIR/gate_run${run}_m6.log" "run $run M6" 4 \
      xcodebuild test-without-building -project "$PROJ/Cloudfull.xcodeproj" -scheme Cloudfull \
      -only-testing:CloudfullUITests/M6Tests \
      -destination "$DEST" -derivedDataPath "$DD"; then
    exit 1
  fi

  echo "## --- M3 ---"
  if ! run_and_check "$LOGDIR/gate_run${run}_m3.log" "run $run M3" 4 \
      xcodebuild test-without-building -project "$PROJ/Cloudfull.xcodeproj" -scheme Cloudfull \
      -only-testing:CloudfullUITests/M3ShrinkTests \
      -destination "$DEST" -derivedDataPath "$DD"; then
    exit 1
  fi

  run_hdr_proof

  echo "## --- M4 ---"
  if ! run_and_check "$LOGDIR/gate_run${run}_m4.log" "run $run M4" 3 \
      xcodebuild test-without-building -project "$PROJ/Cloudfull.xcodeproj" -scheme Cloudfull \
      -only-testing:CloudfullUITests/M4Tests \
      -destination "$DEST" -derivedDataPath "$DD"; then
    exit 1
  fi

  echo "## --- Purge leftover Cloudfull UITest albums (round $run) ---"
  # Reports the live test-album count immediately after M4Tests, since
  # M4Tests.testAddCurrentVideoToNewAlbum creates one album on every
  # round, including round 1. See `purge_test_albums` for why this only
  # counts and does not purge.
  purge_test_albums 1 "round $run"

  echo "## --- M5 ---"
  if ! run_and_check "$LOGDIR/gate_run${run}_m5.log" "run $run M5" 7 \
      xcodebuild test-without-building -project "$PROJ/Cloudfull.xcodeproj" -scheme Cloudfull \
      -only-testing:CloudfullUITests/M5Tests \
      -skip-testing:CloudfullUITests/M5Tests/testLargePoolLaunchesUnderThreeSeconds \
      -destination "$DEST" -derivedDataPath "$DD"; then
    exit 1
  fi

  echo "## --- M1 + M2 ---"
  m1m2_start=$(date "+%Y-%m-%d %H:%M:%S")
  if ! run_and_check "$LOGDIR/gate_run${run}_m1m2.log" "run $run M1+M2" 4 \
      xcodebuild test-without-building -project "$PROJ/Cloudfull.xcodeproj" -scheme Cloudfull \
      -only-testing:CloudfullUITests/M1ExitTests -only-testing:CloudfullUITests/M2TrashTests \
      -destination "$DEST" -derivedDataPath "$DD"; then
    exit 1
  fi

  run_m2_identity_proof "$m1m2_start"

  # `export_probe_values` forwards every "## PROBE " line. This includes
  # the m5_*, m6_*, and m8_* probes.
  export_probe_values "round $run" "$LOGDIR/gate_run${run}_m5.log" "$LOGDIR/gate_run${run}_m6.log" "$LOGDIR/gate_run${run}_m8.log"
done

echo "################ POST-LOOP HOUSEKEEPING PURGE ################"
# Reports the live test-album count once more after the loop. No
# M4Tests run happens immediately before this report, since round 2's
# own count already ran right after its M4Tests. This is a final
# report, not a new check.
purge_test_albums 0 "post-loop"

echo "################ SCALE ROUND (POOL_TARGET=320) ################"
avail=$(df -g / | tail -1 | awk '{print $4}')
echo "## disk free: ${avail} GiB"
if (( avail < 4 )); then
  echo "## ABORTING: disk below 4 GiB"
  exit 2
fi

verify_photo_access_authorized "scale round start"

echo "## reseeding at scale"
if ! POOL_TARGET=320 "$PROJ/scripts/seed_m3.sh" > "$LOGDIR/m3env_scale.sh" 2> "$LOGDIR/m3seed_scale.err"; then
  echo "## RESEED FAILED"; cat "$LOGDIR/m3seed_scale.err"; exit 3
fi
grep '^#' "$LOGDIR/m3seed_scale.err"
source "$LOGDIR/m3env_scale.sh"
echo "## pool after scale seed: $CLOUDFULL_POOL_AFTER_SEED"

echo "## --- M5 perf (scale) ---"
# `testLargePoolLaunchesUnderThreeSeconds` skips itself unless
# CLOUDFULL_RUN_SCALE_TEST is set. The scale round seeds POOL_TARGET=320
# for this test and for M1ExitTests. Without the variable, the round
# would skip its only test, report 0 executed, and fail the gate on a
# count mismatch. xcodebuild forwards `TEST_RUNNER_`-prefixed variables
# to the test runner without the prefix.
export CLOUDFULL_RUN_SCALE_TEST=1
export TEST_RUNNER_CLOUDFULL_RUN_SCALE_TEST=1
if ! run_and_check "$LOGDIR/gate_scale_m5perf.log" "scale M5 perf" 1 \
    xcodebuild test-without-building -project "$PROJ/Cloudfull.xcodeproj" -scheme Cloudfull \
    -only-testing:CloudfullUITests/M5Tests/testLargePoolLaunchesUnderThreeSeconds \
    -destination "$DEST" -derivedDataPath "$DD"; then
  exit 1
fi

export_probe_values "scale" "$LOGDIR/gate_scale_m5perf.log"

echo "## --- M1 (scale) ---"
if ! run_and_check "$LOGDIR/gate_scale_m1.log" "scale M1" 2 \
    xcodebuild test-without-building -project "$PROJ/Cloudfull.xcodeproj" -scheme Cloudfull \
    -only-testing:CloudfullUITests/M1ExitTests \
    -destination "$DEST" -derivedDataPath "$DD"; then
  exit 1
fi

echo "## --- Final album purge + DB check (scale round) ---"
purge_test_albums 0 "scale round"

FENCE_END=$(source_fence)
if [[ "$FENCE_END" != "$FENCE_START" ]]; then
  echo "## GATE FAILURE: source changed during the run (start: $FENCE_START, end: $FENCE_END)"
  exit 9
fi

FINISHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "################ GATE COMPLETE — 2/2 standard rounds + 1 scale round, 63/63 tests passed ################"
echo "## RECORD RULE: this log may be cited only while the source fence is still"
echo "##   $FENCE_END.  Gate finished $FINISHED_AT."
