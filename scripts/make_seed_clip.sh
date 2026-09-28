#!/bin/bash
#
#  make_seed_clip.sh
#  Cloudfull
#
#  Copyright (C) 2026 Marshall Ross.
#  SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage: make_seed_clip.sh <kind> <output_path> [duration_seconds] [creation_time]
#
# Generates a synthetic seed clip for the shrink tests.
#
# `creation_time` (ISO 8601 UTC, for example 2024-01-01T00:00:00Z) is
# embedded through ffmpeg's `-metadata creation_time`, which PhotoKit reads
# into `PHAsset.creationDate` at import. A caller that seeds more than one
# fixture in the same run must pass a distinct value for each clip. Without
# it, ffmpeg emits no creation timestamp, and PhotoKit falls back to the
# import time. Fixtures added seconds apart can then land on the identical
# creation date. A shrink job's `dateMatches` check then cannot tell a
# matching original apart from a different fixture imported at the same
# moment. The default is the current time, so a single ad hoc call still
# works without the argument.
#
#   4k             : h264 High, yuv420p, 3840x2160, 30fps, structured
#                    detail at 20 Mbit/s
#   hdr            : hevc Main10, yuv420p10le, bt2020nc/arib-std-b67/bt2020,
#                    3840x2160, 30fps, structured detail at 20 Mbit/s
#   incompressible : 4K HEVC 10-bit with a white "EFF" text overlay, at
#                    8fps, about 13.5 KB for 4s. This stays at or below
#                    16,600 bytes, 50% or more below the ~33.3 KB refusal
#                    boundary. It is also below any 1080p re-encode, so it
#                    exercises the net-savings guard's refusal path.
#   1080p          : h264 High, yuv420p, 1080x1920, 30fps — filler, not
#                    shrinkable
#
# Bitrate: `AVAssetExportPresetHEVC1920x1080` encodes at a fixed target of
# roughly 7 to 8 Mbit/s. `ShrinkService` refuses to swap unless the export
# comes out at least 10% smaller than the original. A 4K seed clip only
# exercises the success path when its own bitrate is well above that
# target.
set -euo pipefail

# A script invoked as a subprocess of another script does not reliably
# inherit the interactive shell's full PATH. Some callers omit even
# `/usr/bin`, which breaks `stat`. Set an explicit PATH up front instead of
# relying on the caller's environment.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Use an absolute path on top of that, since this script needs the Homebrew
# ffmpeg specifically, not whatever a PATH lookup for `ffmpeg` might find.
FFMPEG=/opt/homebrew/bin/ffmpeg

# This script resolves its own location from `BASH_SOURCE`, so it finds
# the repo correctly no matter which directory it is run from.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(dirname "$HERE")"

kind="$1"
out="$2"
dur="${3:-4}"
created="${4:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# Balances two constraints: high enough that a 1080p re-encode is clearly
# smaller and clears the 10% net-savings floor. Also low enough that the
# simulator can decode the source and encode the replacement inside the
# test time budget. The simulator has no hardware video path, so its CPU
# speed limits how fast this encode runs. 20 Mbit/s of structured detail
# exports to roughly a third of its size and completes in seconds.
RATE=20M

# testsrc2 is detailed but structured, so it decodes cheaply. It carries no
# film-grain layer on purpose: grain defeats inter-frame prediction, which
# raises the bitrate but also slows decode and encode too much for the
# simulator.
ENTROPY="testsrc2=size=3840x2160:rate=30:duration=${dur}"

case "$kind" in
  4k)
    "$FFMPEG" -y -f lavfi -i "$ENTROPY" \
      -f lavfi -i "sine=frequency=440:duration=${dur}" \
      -c:v libx264 -profile:v high -pix_fmt yuv420p \
      -b:v $RATE -minrate $RATE -maxrate $RATE -bufsize 100M \
      -c:a aac -metadata creation_time="$created" -shortest "$out" -loglevel error
    ;;
  hdr)
    "$FFMPEG" -y -f lavfi -i "$ENTROPY" \
      -f lavfi -i "sine=frequency=440:duration=${dur}" \
      -filter:v "setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc" \
      -c:v libx265 -pix_fmt yuv420p10le \
      -b:v $RATE -x265-params "bitrate=$(echo $RATE | tr -d M)000:vbv-maxrate=$(echo $RATE | tr -d M)000:vbv-bufsize=100000" \
      -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc \
      -tag:v hvc1 -c:a aac -metadata creation_time="$created" -shortest "$out" -loglevel error
    ;;
  incompressible)
    # This content is already efficient: 4K HEVC 10-bit, deliberately far
    # below what the 1080p HEVC preset would spend. A low bitrate alone does
    # not defeat the shrink guard. A low-bitrate H.264 solid colour
    # re-encodes smaller at 1080p HEVC and passes the guard (measured:
    # 37 KB in, 23 KB out). What the guard cannot beat by 10% is content
    # already carried by the same modern codec at a bitrate below what the
    # 1080p preset would spend.
    #
    # An explicit low bitrate, rather than a quality-constant setting, makes
    # the original file's size deterministic. The 1080p HEVC re-encode of
    # this near-static "EFF" content measures about 30 KB regardless of the
    # source encoding choice. The guard refuses a shrink when
    # `newBytes >= 0.9 * referenceBytes`, so at that re-encode size the
    # refusal boundary is `referenceBytes <= 33,333`. This fixture targets a
    # 50% margin below that boundary, at or below 16,600 bytes, instead of a
    # margin close to the boundary.
    #
    # A low target bitrate alone does not reach that size. x265's rate
    # control on this content reaches its QP 51 quantizer ceiling regardless
    # of how low the requested bitrate is. It lands near 29 KB for 4 seconds
    # no matter how far `bitrate`/`vbv-maxrate` are lowered. Lowering the
    # AAC track barely moves it either. The silent `anullsrc` track already
    # encodes to a near-fixed rate of about 2 kbit/s.
    #
    # What actually reduces the size is the frame count per second, since
    # each frame still carries a fixed overhead at the QP 51 ceiling.
    # Dropping the source rate from 30fps to 8fps (`r=8` below) cuts the
    # 4-second clip from 120 encoded frames to 32. That measures about
    # 13.5 KB, under the 16,600-byte ceiling.
    #
    # This choice affects only how the fixture is generated. The resulting
    # file is still a normal, playable 3840x2160 HEVC clip. PhotoKit imports
    # it and the shrink export re-encodes it like any other.
    "$FFMPEG" -y -f lavfi -i "color=c=0x1E4D2B:s=3840x2160:d=${dur}:r=8" \
      -f lavfi -i "anullsrc=r=44100:cl=stereo" \
      -filter:v "drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='EFF':fontcolor=white:fontsize=400:x=(w-text_w)/2:y=(h-text_h)/2,setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc" \
      -c:v libx265 -pix_fmt yuv420p10le \
      -b:v 4k -x265-params "bitrate=4:vbv-maxrate=4:vbv-bufsize=1000" \
      -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc \
      -tag:v hvc1 -c:a aac -b:a 16k -metadata creation_time="$created" -shortest "$out" -loglevel error
    ;;
  1080p)
    "$FFMPEG" -y -f lavfi -i "testsrc2=size=1080x1920:rate=30:duration=${dur}" \
      -f lavfi -i "sine=frequency=440:duration=${dur}" \
      -c:v libx264 -profile:v high -pix_fmt yuv420p -c:a aac -metadata creation_time="$created" -shortest "$out" -loglevel error
    ;;
  *)
    echo "unknown kind: $kind (use 4k|hdr|incompressible|1080p)" >&2
    exit 1
    ;;
esac

bytes=$(stat -f%z "$out")

# Enforce the size margin in the generator itself, so the fixture cannot
# drift back toward the refusal boundary over time.
if [[ "$kind" == "incompressible" ]] && (( bytes > 16600 )); then
  echo "incompressible fixture is $bytes bytes, must be <= 16600 (>=50% below the ~33.3 KB flip point)" >&2
  exit 1
fi

echo "$kind -> $out ($bytes bytes)"
