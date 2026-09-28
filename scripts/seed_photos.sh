#!/bin/zsh
# Cloudfull
# Copyright (C) 2026 Marshall Ross.
# SPDX-License-Identifier: GPL-3.0-or-later

# `M11Tests` needs photos with different creation dates, in HEIC and
# JPEG, and at least one with GPS EXIF. Its header-row tests need a real
# place and the "Unknown place" fallback. This script makes 8 synthetic
# stills. It imports them with `xcrun simctl addmedia`, the same way
# `seed_m3.sh` imports videos, but for `ZKIND=0` (photo) rows.
#
# It also seeds one Live Photo: a still and video pair that share a
# content identifier and a still-image-time metadata track. PhotoKit then
# imports it as one ZKINDSUBTYPE=2/ZPLAYBACKSTYLE=3 asset instead of two
# unpaired ones. Two Live Photo tests in `M11Tests` skip without one real
# Live Photo in the simulator library. A synthetic still or a plain video
# does not satisfy PhotoKit's pairing rule. This script compiles
# scripts/fixtures/LivePhotoGen.swift on demand and remuxes an ffmpeg clip
# through it. See that file's header for how the pairing works.
#
# Run this once, by hand, before running `M11Tests`. Never call it from a
# test body, and never erase or reset the simulator.
#
# Each run adds 8 more stills and one Live Photo, on top of what the
# library already holds. `M11Tests` reads counts from probes like
# `photo_pool_<n>`, so extra runs do not break the tests. Extra runs only
# use more storage.
set -euo pipefail

# See make_seed_clip.sh: a script invoked as a subprocess of another script
# does not reliably inherit the interactive shell's full PATH.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

UDID=E2DAB7E8-649E-4F1A-BBA9-676236EB075A
DB="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Media/PhotoData/Photos.sqlite"
FONT=/System/Library/Fonts/Helvetica.ttc
FF=/opt/homebrew/bin/ffmpeg

# Find the repo root from the path of this script, not from the working
# directory, so the Live Photo generator's source and its compiled binary
# resolve the same way regardless of where this script runs. See
# seed_m3.sh.
HERE=${0:a:h}
PROJ=${HERE:h}
LIVEGEN_SRC="$PROJ/scripts/fixtures/LivePhotoGen.swift"
LIVEGEN_BUILD="$PROJ/build/seed-fixtures"

command -v python3 >/dev/null 2>&1 \
  || { echo "python3 not found on PATH — install it (brew install python3)" >&2; exit 1; }
python3 -c "import PIL" >/dev/null 2>&1 \
  || { echo "python3's Pillow module is required: pip3 install pillow" >&2; exit 1; }
[[ -x "$FF" ]] \
  || { echo "ffmpeg not found at $FF — install it (brew install ffmpeg)" >&2; exit 1; }
command -v xcrun >/dev/null 2>&1 \
  || { echo "xcrun not found on PATH — install the Xcode command line tools" >&2; exit 1; }

# A temporary working directory for the generated originals. Nothing here is
# checked in; PhotoKit owns the only copy that matters once addmedia returns.
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/cloudfull-seed-photos.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

# Counts the photos (ZKIND=0) that are not in the trash. Here, "live"
# means "not trashed", not a Live Photo.
live_photo_count() {
  sqlite3 "$DB" "select count(*) from ZASSET where ZKIND=0 and ZTRASHEDSTATE=0;"
}

# name.jpg (always .jpg — the generator writes JPEG regardless of the
# target format below) | target extension (jpg/heic) | width | height |
# ISO 8601 local date and time, no zone (EXIF carries none) | "lat,lon" or
# empty for no GPS | hex fill color | large centered label drawn on the
# image.
#
# Eight distinct creation dates, spanning 2021 to 2025: four HEIC and four
# JPEG. Two stills carry real GPS EXIF, a US-west-coast pair, for
# PlaceLookup. Six have no GPS, for the "Unknown place" fallback. The
# aspect ratios vary, from portrait to a 5712x4284 landscape, to test the
# post's own `aspectRatio(.fit)` letterboxing.
typeset -a SPECS=(
  "photo_01.jpg|jpg|3024|4032|2021-06-01T09:15:00||#2f6fed|1"
  "photo_02.jpg|heic|4032|3024|2021-11-22T14:30:00||#eb5b3c|2"
  "photo_03.jpg|jpg|4032|3024|2022-03-08T18:05:00|34.0522,-118.2437|#3ccf91|3"
  "photo_04.jpg|heic|3024|3024|2022-07-19T11:45:00|37.7749,-122.4194|#f2b134|4"
  "photo_05.jpg|jpg|4284|5712|2023-01-05T08:00:00||#8a4fd1|5"
  "photo_06.jpg|heic|5712|4284|2023-09-30T20:10:00||#1fb5c9|6"
  "photo_07.jpg|jpg|4032|3024|2024-04-14T16:22:00||#d1495b|7"
  "photo_08.jpg|heic|4032|3024|2025-08-01T07:55:00||#5c8001|8"
)

# Draws one solid-color still per spec with a large centered number label.
# Writes EXIF (Make, Model, lens, exposure), so `PhotoMetadata.Tier2` has
# real data to parse, not only "—". The script writes DateTimeOriginal
# into the Exif sub-IFD specifically, through `exif.get_ifd(IFD.Exif)`.
# `CGImageSourceCopyPropertiesAtIndex` only reports a
# kCGImagePropertyExifDictionary when the tag lives there. A plain
# `img.getexif()[DateTimeOriginal] = ...` lands it in bare IFD0 instead,
# where ImageIO and PhotoKit's own importer never look.
python3 - "$WORKDIR" "$FONT" "${SPECS[@]}" <<'PYEOF'
import sys, os
from PIL import Image, ImageDraw, ImageFont
from PIL.ExifTags import Base, GPS, IFD
from PIL.TiffImagePlugin import IFDRational


def R(n, d=1):
    return IFDRational(n, d)


def dms(decimal):
    negative = decimal < 0
    decimal = abs(decimal)
    deg = int(decimal)
    minutes_full = (decimal - deg) * 60
    minutes = int(minutes_full)
    seconds = (minutes_full - minutes) * 60
    return (R(deg), R(minutes), R(int(round(seconds * 1000)), 1000)), negative


def hex_to_rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def iso_to_exif_dt(iso):
    date_part, time_part = iso.split('T')
    return date_part.replace('-', ':') + ' ' + time_part


def main():
    workdir, font_path = sys.argv[1], sys.argv[2]
    for spec in sys.argv[3:]:
        name, _ext, w, h, iso, gps, color_hex, label = spec.split('|')
        w, h = int(w), int(h)
        img = Image.new("RGB", (w, h), color=hex_to_rgb(color_hex))
        draw = ImageDraw.Draw(img)
        font_size = max(72, min(w, h) // 6)
        try:
            font = ImageFont.truetype(font_path, font_size)
        except OSError:
            font = ImageFont.load_default()
        bbox = draw.textbbox((0, 0), label, font=font)
        tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
        draw.text(((w - tw) / 2, (h - th) / 2 - bbox[1]), label, fill=(255, 255, 255), font=font)

        exif = img.getexif()
        exif[Base.Make.value] = "Apple"
        exif[Base.Model.value] = "iPhone 15 Pro"
        dt = iso_to_exif_dt(iso)
        exif[Base.DateTime.value] = dt
        exif[Base.Orientation.value] = 1

        exif_ifd = exif.get_ifd(IFD.Exif)
        exif_ifd[Base.DateTimeOriginal.value] = dt
        exif_ifd[Base.DateTimeDigitized.value] = dt
        exif_ifd[Base.LensModel.value] = "iPhone 15 Pro back camera 6.765mm f/1.78"
        exif_ifd[Base.FocalLength.value] = R(24, 1)
        exif_ifd[Base.FNumber.value] = R(178, 100)
        exif_ifd[Base.ExposureTime.value] = R(1, 240)
        exif_ifd[Base.ISOSpeedRatings.value] = 32

        if gps:
            lat_s, lon_s = gps.split(',')
            lat_dms, lat_neg = dms(float(lat_s))
            lon_dms, lon_neg = dms(float(lon_s))
            exif[Base.GPSInfo.value] = {
                GPS.GPSLatitudeRef.value: "S" if lat_neg else "N",
                GPS.GPSLatitude.value: lat_dms,
                GPS.GPSLongitudeRef.value: "W" if lon_neg else "E",
                GPS.GPSLongitude.value: lon_dms,
            }

        img.save(os.path.join(workdir, name), "JPEG", quality=90, exif=exif)


if __name__ == "__main__":
    main()
PYEOF

# `sips` converts to HEIC and keeps all of the EXIF tags, including
# DateTimeOriginal, GPS, and the Exif sub-IFD.
for spec in "${SPECS[@]}"; do
  name="${spec%%|*}"; rest="${spec#*|}"; ext="${rest%%|*}"
  base="${name%.jpg}"
  if [[ "$ext" == "heic" ]]; then
    sips -s format heic "$WORKDIR/$name" --out "$WORKDIR/$base.heic" >/dev/null
    rm "$WORKDIR/$name"
  fi
done

before=$(live_photo_count)
echo "# live photo pool before seeding: $before" >&2

# Import one file at a time, as seed_m3.sh's add_one does. Then each new
# row maps to one file.
for spec in "${SPECS[@]}"; do
  name="${spec%%|*}"; rest="${spec#*|}"; ext="${rest%%|*}"
  base="${name%.jpg}"
  file="$WORKDIR/$base.$ext"

  before_pk=$(sqlite3 "$DB" "select coalesce(max(Z_PK),0) from ZASSET;")
  xcrun simctl addmedia "$UDID" "$file"
  uuid=""
  for _ in {1..40}; do
    uuid=$(sqlite3 "$DB" "select ZUUID from ZASSET where Z_PK > $before_pk and ZKIND=0 order by Z_PK desc limit 1;")
    [[ -n "$uuid" ]] && break
    sleep 0.25
  done
  if [[ -z "$uuid" ]]; then
    echo "FAILED to resolve asset id for $file" >&2
    exit 1
  fi
  echo "# $base.$ext -> ${uuid}/L0/001" >&2
done

after=$(live_photo_count)
echo "# live photo pool after seeding: $after (added $((after - before)))" >&2

# --- Live Photo: one still+video pair, paired through a matching content
# identifier and a still-image-time metadata track (see
# scripts/fixtures/LivePhotoGen.swift's header for how PhotoKit's pairing
# rule works). Two Live Photo tests in `M11Tests` skip without this:
# a synthetic still and a plain video import as two separate, unpaired
# assets, never as one ZPLAYBACKSTYLE=3 Live Photo.
echo "# building LivePhotoGen" >&2
mkdir -p "$LIVEGEN_BUILD"
xcrun -sdk macosx swiftc -O "$LIVEGEN_SRC" -o "$LIVEGEN_BUILD/LivePhotoGen"

# 2 seconds, H.264 and AAC. testsrc2 is a moving test pattern, and sine
# adds an audio track. The Live Photo test needs paired audio.
# make_seed_clip.sh uses the same testsrc2/sine convention for content
# that is cheap to decode but still structured.
live_uuid=$(uuidgen)
raw="$WORKDIR/live_raw.mov"
still="$WORKDIR/live_still.jpg"
motion="$WORKDIR/live_motion.mov"

# 1200x1600 is not arbitrary. LivePhotoGen writes its still at exactly
# that size. A Live Photo whose still and paired video disagree on aspect
# ratio letterboxes in the feed. PhotoPostView sizes the post from the
# still's dimensions, while the movie layer draws with `.resizeAspect`.
"$FF" -y -f lavfi -i "testsrc2=size=1200x1600:rate=30:duration=2" \
  -f lavfi -i "sine=frequency=880:duration=2" \
  -c:v libx264 -profile:v high -pix_fmt yuv420p \
  -c:a aac -shortest "$raw" -loglevel error

"$LIVEGEN_BUILD/LivePhotoGen" "$live_uuid" "$still" "$raw" "$motion"

live_before_pk=$(sqlite3 "$DB" "select coalesce(max(Z_PK),0) from ZASSET;")
xcrun simctl addmedia "$UDID" "$still" "$motion"

live_row=""
for _ in {1..40}; do
  live_row=$(sqlite3 "$DB" "select ZUUID from ZASSET where Z_PK > $live_before_pk and ZPLAYBACKSTYLE=3 order by Z_PK desc limit 1;")
  [[ -n "$live_row" ]] && break
  sleep 0.25
done

if [[ -n "$live_row" ]]; then
  echo "# Live Photo seeded OK: ZUUID=$live_row (ZPLAYBACKSTYLE=3)" >&2
else
  echo "FAILED: no ZASSET row with ZPLAYBACKSTYLE=3 appeared after addmedia" >&2
  exit 1
fi
