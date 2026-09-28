#!/bin/zsh
# Cloudfull
# Copyright (C) 2026 Marshall Ross.
# SPDX-License-Identifier: GPL-3.0-or-later

# Purges "Cloudfull UITest" albums from the simulator.
#
# Run this when the simulator is idle. iOS delays the consent alert
# after repeated triggers. After several runs, the alert can take about
# 100 seconds. On a first run it takes 4 to 12 seconds.
#
# PurgeAlbumsHelper (a UI test) answers the consent alert. This script
# checks the live album count in the Photos database before and after.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
HERE=${0:a:h}; PROJ=${HERE:h}
# The UDID of the target simulator. Change it for your machine.
UDID=E2DAB7E8-649E-4F1A-BBA9-676236EB075A
DB="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Media/PhotoData/Photos.sqlite"
Q="select count(*) from ZGENERICALBUM where ZTITLE like 'Cloudfull UITest%' and ZTRASHEDSTATE=0;"
echo "live before: $(sqlite3 "$DB" "$Q")"
xcodebuild test-without-building -project "$PROJ/Cloudfull.xcodeproj" -scheme Cloudfull \
  -only-testing:CloudfullUITests/PurgeAlbumsHelper \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$PROJ/build" \
  | grep -E "Test Case|TEST"
sleep 5
echo "live after: $(sqlite3 "$DB" "$Q")"
