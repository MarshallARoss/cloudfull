#!/bin/zsh
# Cloudfull
# Copyright (C) 2026 Marshall Ross.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Reseeds the simulator library for a gate run and prints the asset ids of
# the clips it just added, as shell exports.
#
# Why this exists: the trash-deletion suite queues 20 videos and
# permanently deletes 17 of them, chosen by whatever order the deck deals.
# The space-counter suite's `testSpaceCounterCountsEveryByteOnce` empties
# 4 more. The trash-deletion suite and the space-counter suite can delete
# any fixture that the shrink suite or the space-counter suite needs.
# These fixtures are the HDR clip, a clip that actually shrinks, and the
# deliberately incompressible one. The gate must reseed them before those
# suites run. The gate reseeds, captures new ids, and runs the shrink
# suite and the space-counter suite before the trash-deletion suite.
set -euo pipefail

# See make_seed_clip.sh for why. A script invoked as a subprocess of
# another script does not reliably inherit the interactive shell's full
# PATH.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

UDID=E2DAB7E8-649E-4F1A-BBA9-676236EB075A

# Find the repo from this script's location. Every path below is relative
# to the repo.
HERE=${0:a:h}
PROJ=${HERE:h}
SEEDS="$PROJ/scripts/fixtures/seed4k"
FILLER="$PROJ/build/gate-filler"
DB="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Media/PhotoData/Photos.sqlite"
FF=/opt/homebrew/bin/ffmpeg
FFPROBE=/opt/homebrew/bin/ffprobe
FONT=/System/Library/Fonts/Helvetica.ttc

# The target size of the live pool before the run. The tests delete
# 17 + 4 = 21 clips, and the shrink suite needs 25 after that, so the
# minimum is 46. The default of 52 adds a margin of 6.
POOL_TARGET=${POOL_TARGET:-52}

live_count() {
  sqlite3 "$DB" "select count(*) from ZASSET where ZKIND=1 and ZTRASHEDSTATE=0;"
}

# Adds one file and echoes the local identifier PhotoKit gave it. The
# script adds assets one at a time. This lets it match each new row to
# its file. A batch addmedia call leaves no way to tell which uuid is
# which.
add_one() {
  local file="$1"
  local before
  before=$(sqlite3 "$DB" "select coalesce(max(Z_PK),0) from ZASSET;")
  xcrun simctl addmedia "$UDID" "$file"
  local uuid=""
  for _ in {1..40}; do
    uuid=$(sqlite3 "$DB" "select ZUUID from ZASSET where Z_PK > $before and ZKIND=1 order by Z_PK desc limit 1;")
    [[ -n "$uuid" ]] && break
    sleep 0.25
  done
  if [[ -z "$uuid" ]]; then
    echo "FAILED to resolve asset id for $file" >&2
    exit 1
  fi
  echo "${uuid}/L0/001"
}

# Each fixture gets a distinct creation_time (ISO 8601 UTC). Without it,
# ffmpeg writes no timestamp and PhotoKit uses the import time. Fixtures
# imported in the same second then share one creationDate, and
# `dateMatches` in the shrink suite cannot tell them apart. The dates are
# one day apart.
typeset -A FIXTURE_DATES=(
  hi_4k_1.mp4         2024-01-01T00:00:00Z
  hi_4k_2.mp4         2024-01-02T00:00:00Z
  hi_4k_3.mp4         2024-01-03T00:00:00Z
  hi_4k_hdr.mp4       2024-01-04T00:00:00Z
  lo_4k_efficient.mp4 2024-01-05T00:00:00Z
  spot_1080p_1.mp4    2024-01-06T00:00:00Z
  spot_1080p_2.mp4    2024-01-07T00:00:00Z
)

# `validate_fixture` calls `probe_fixture` below to re-check every
# fixture against its expected kind on every run, whether or not the
# file already exists. This finds a fixture that no longer matches its
# kind, even when the file exists.
#
# On any mismatch, `validate_fixture` regenerates the fixture once
# through make_seed_clip.sh and re-probes it. If it still does not
# match, the script exits 1 with the measured value in the message. A
# fixture this suite depends on must never be seeded silently wrong
# twice in a row.
probe_fixture() {
  # Prints a one-line failure reason to stdout and returns 1 on any
  # mismatch. Prints nothing and returns 0 when the fixture matches its
  # kind's table entry.
  #
  # This reads output with `-of default=noprint_wrappers=1` ("key=value"
  # per line) rather than `-of csv=p=0`. On this ffprobe build, CSV
  # output uses ffprobe's internal field order, not the `-show_entries`
  # order. A positional `read` would give values to the wrong variables.
  # Named key=value lines do not have this problem.
  #
  # Note: the fixture path is deliberately not named `path` or `fpath`.
  # Both are zsh special parameter names tied to `$PATH` and `$FPATH`. A
  # `local path=...` here silently overwrites `$PATH` for the rest of this
  # function. Testing confirmed this breaks `stat`, `head`, and `sqlite3`
  # lookups with "command not found," even though the caller's `$PATH`
  # looks correct.
  local fixture_path="$1" kind="$2" expected_date="$3" expected_duration="${4:-}"

  if [[ ! -f "$fixture_path" ]]; then
    echo "file missing"
    return 1
  fi

  local -A f=()
  local key val
  while IFS='=' read -r key val; do
    [[ -n "$key" ]] && f[$key]="$val"
  done < <($FFPROBE -v error -select_streams v:0 -show_entries \
    stream=width,height,codec_name,pix_fmt,color_transfer,color_primaries,color_space \
    -of default=noprint_wrappers=1 "$fixture_path" 2>/dev/null)
  if [[ -z "${f[codec_name]:-}" ]]; then
    echo "ffprobe failed to read the video stream"
    return 1
  fi

  local w="${f[width]:-}" h="${f[height]:-}" codec="${f[codec_name]:-}" pixfmt="${f[pix_fmt]:-}"
  local ctrans="${f[color_transfer]:-}" cprim="${f[color_primaries]:-}" cspace="${f[color_space]:-}"
  local size ctime dur
  size=$(stat -f%z "$fixture_path")
  ctime=$($FFPROBE -v error -show_entries format_tags=creation_time \
    -of default=noprint_wrappers=1:nokey=1 "$fixture_path" 2>/dev/null | head -1)
  dur=$($FFPROBE -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$fixture_path" 2>/dev/null)

  case "$kind" in
    4k)
      [[ "$w" == "3840" && "$h" == "2160" && "$codec" == "h264" ]] \
        || { echo "expected 3840x2160 h264, got ${w}x${h} $codec"; return 1; }
      # Without this check, a file with `pix_fmt=yuv420p10le` and HDR
      # color metadata, the exact encode of the `hdr` kind, would pass as
      # an SDR `4k` fixture. `make_seed_clip.sh` always encodes the `4k`
      # kind as `-pix_fmt yuv420p`, so this exact match is correct.
      [[ "$pixfmt" == "yuv420p" ]] \
        || { echo "pix_fmt=$pixfmt (want yuv420p — an HDR/10-bit file must not masquerade as the SDR shrinkable fixture)"; return 1; }
      (( size >= 8000000 )) || { echo "size $size < 8,000,000 bytes"; return 1; }
      ;;
    hdr)
      [[ "$w" == "3840" && "$h" == "2160" && "$codec" == "hevc" && "$pixfmt" == "yuv420p10le" ]] \
        || { echo "expected 3840x2160 hevc yuv420p10le, got ${w}x${h} $codec $pixfmt"; return 1; }
      [[ "$ctrans" == "arib-std-b67" ]] || { echo "color_transfer=$ctrans (want arib-std-b67)"; return 1; }
      [[ "$cprim" == "bt2020" ]] || { echo "color_primaries=$cprim (want bt2020)"; return 1; }
      [[ "$cspace" == bt2020* ]] || { echo "color_space=$cspace (want bt2020*)"; return 1; }
      (( size >= 8000000 )) || { echo "size $size < 8,000,000 bytes"; return 1; }
      ;;
    incompressible)
      [[ "$w" == "3840" && "$h" == "2160" && "$codec" == "hevc" && "$pixfmt" == "yuv420p10le" ]] \
        || { echo "expected 3840x2160 hevc yuv420p10le, got ${w}x${h} $codec $pixfmt"; return 1; }
      (( size <= 16600 )) || { echo "size $size > 16,600 bytes (>=50% margin required)"; return 1; }
      ;;
    1080p)
      local maxwh minwh
      maxwh=$(( w > h ? w : h ))
      minwh=$(( w < h ? w : h ))
      (( maxwh <= 1920 && minwh <= 1080 )) \
        || { echo "expected max(w,h)<=1920 and min(w,h)<=1080, got ${w}x${h}"; return 1; }
      [[ "$codec" == "h264" ]] || { echo "codec=$codec (want h264)"; return 1; }
      ;;
    *)
      echo "unknown fixture kind: $kind"
      return 1
      ;;
  esac

  # A correctly-dimensioned but wrong-duration clip, for example a stale
  # partial regeneration, could otherwise validate as correct. This check
  # confirms the duration against the actual file.
  if [[ -n "$expected_duration" ]]; then
    if [[ -z "$dur" ]]; then
      echo "ffprobe failed to read duration"
      return 1
    fi
    local within
    within=$(awk -v d="$dur" -v e="$expected_duration" 'BEGIN{diff=d-e; if (diff<0) diff=-diff; print (diff<=0.5)?1:0}')
    [[ "$within" == "1" ]] \
      || { echo "duration=${dur}s does not match expected ${expected_duration}s (+/-0.5s)"; return 1; }
  fi

  # `dateMatches` in the shrink suite depends entirely on every fixture
  # carrying its own distinct, correctly embedded creation_time.
  local expected_prefix="${expected_date%Z}"
  [[ "$ctime" == "${expected_prefix}"* ]] \
    || { echo "creation_time='$ctime' does not match expected '$expected_date'"; return 1; }

  return 0
}

validate_fixture() {
  local name="$1" kind="$2" dur="$3"
  # Same reasoning as `probe_fixture` above: do not name this `path`.
  local fixture_path="$SEEDS/$name"
  local expected_date="${FIXTURE_DATES[$name]}"
  local reason

  if reason=$(probe_fixture "$fixture_path" "$kind" "$expected_date" "$dur"); then
    return 0
  fi
  echo "# regenerating $name ($kind): $reason" >&2
  "$PROJ/scripts/make_seed_clip.sh" "$kind" "$fixture_path" "$dur" "$expected_date" >/dev/null

  if reason=$(probe_fixture "$fixture_path" "$kind" "$expected_date" "$dur"); then
    return 0
  fi
  echo "fixture $name failed validation after regeneration: $reason" >&2
  exit 1
}

mkdir -p "$SEEDS"
validate_fixture hi_4k_1.mp4 4k 4
validate_fixture hi_4k_2.mp4 4k 4
validate_fixture hi_4k_3.mp4 4k 4
validate_fixture hi_4k_hdr.mp4 hdr 4
validate_fixture lo_4k_efficient.mp4 incompressible 4
validate_fixture spot_1080p_1.mp4 1080p 4
validate_fixture spot_1080p_2.mp4 1080p 5
echo "# all seed fixtures validated against spec (M5_SPEC §6.2.2)" >&2

# --- 1. Add cheap 1080p filler until the live pool reaches its target. ---
mkdir -p "$FILLER"
have=$(live_count)
need=$(( POOL_TARGET - have ))
if (( need > 0 )); then
  echo "# topping up pool: $have live, need $need more" >&2
  stamp=$(date +%s)
  batch=()
  for i in $(seq 1 $need); do
    outfile="$FILLER/fill_${stamp}_${i}.mp4"
    "$FF" -y -f lavfi -i "color=c=0x$(printf '%06x' $(( (i * 2654435761) % 16777215 ))):s=1080x1920:d=3:r=30" \
      -f lavfi -i "anullsrc=r=44100:cl=stereo" \
      -filter:v "drawtext=fontfile=${FONT}:text='F${i}':fontcolor=white:fontsize=300:x=(w-text_w)/2:y=(h-text_h)/2" \
      -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 96k "$outfile" -loglevel error
    batch+=("$outfile")
  done
  xcrun simctl addmedia "$UDID" "${batch[@]}"
  # The script regenerates filler clips every run and stores them under
  # the pinned derived-data root, not in scripts/. It removes them
  # immediately after addmedia.
  rm -rf "$FILLER"
else
  echo "# pool already at $have (target $POOL_TARGET)" >&2
fi

# --- 2. Add the shrink suite and space-counter suite fixtures and capture their ids. ---
shrinkable=()
for clip in hi_4k_1.mp4 hi_4k_2.mp4 hi_4k_3.mp4; do
  shrinkable+=("$(add_one "$SEEDS/$clip")")
done
hdr_id=$(add_one "$SEEDS/hi_4k_hdr.mp4")
incompressible_id=$(add_one "$SEEDS/lo_4k_efficient.mp4")

# Two pinned 1080p clips. The tests assert rail_shrink never appears on
# them.
known1080p=()
for n in 1 2; do
  known1080p+=("$(add_one "$SEEDS/spot_1080p_$n.mp4")")
done

final=$(live_count)
echo "# live pool after seeding: $final" >&2

printf 'export TEST_RUNNER_CLOUDFULL_SHRINKABLE_ASSET_IDS=%s\n' "${(j:,:)shrinkable}"
printf 'export TEST_RUNNER_CLOUDFULL_HDR_ASSET_ID=%s\n' "$hdr_id"
printf 'export TEST_RUNNER_CLOUDFULL_INCOMPRESSIBLE_ASSET_ID=%s\n' "$incompressible_id"
printf 'export TEST_RUNNER_CLOUDFULL_KNOWN_1080P_ASSET_IDS=%s\n' "${(j:,:)known1080p}"
printf 'export CLOUDFULL_POOL_AFTER_SEED=%s\n' "$final"
