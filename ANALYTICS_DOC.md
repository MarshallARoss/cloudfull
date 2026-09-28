# Cloudfull Analytics

This document lists exactly what Cloudfull's anonymous usage analytics send.
It is generated from the app's analytics code, not from a design plan, so it
describes what the app actually does.

## Summary

Cloudfull sends one small analytics record per session. A session runs from
the moment the app comes to the foreground until it goes to the background,
and the record is sent at that point. The record goes to a CloudKit public
database container that belongs to the app's developer, Marshall Ross. Each
record carries a random ID that the app generates once when it is first
installed. This ID does not identify a person: it is not linked to a name, an
email address, or an Apple Account. The app does not send a record when it
runs in the iOS Simulator, and it does not send one during an automated UI
test run. A copy of the app built with a different bundle ID (a fork) never sends
one. A record also never reaches the developer if the phone is not
signed into iCloud, because it has nowhere to go.

## What is sent

Every value below comes straight from a counter or a stored fact in the
app's analytics code. A counter is a running total for the session. A fact is
a single value, written once or updated as it changes. Numbers are exact —
the code does not round or bucket them, except where a value is noted as
rounded for display (such as free space in GB).

Some key names include a placeholder in angle brackets, such as `<mode>`.
The placeholder stands for one of a small, fixed set of values, listed next
to the key.

### Device & app

| Key | Description | Type / format |
|---|---|---|
| `installId` | Random ID for this install of the app. | Random UUID string. |
| `id` | Random ID for this one session record. | Random UUID string. |
| `schema` | Version number of the record's own format. | Exact integer. |
| `app` | App version and build number. | String, e.g. `1.2 (34)`. |
| `ios` | iOS version. | String, e.g. `26.0`. |
| `device` | Hardware model identifier. | String, e.g. `iPhone15,2`. |
| `coldStart` | Whether the session began with a fresh app launch. | Boolean, `0` or `1`. |
| `daysSinceInstall` | Days since the app was first opened on this phone. | Exact integer. |
| `sessionsBefore` | Number of sessions started on this phone before this one. | Exact integer. |
| `appIconSetting` | Which app icon the user has chosen. | One of a fixed set of icon names. |
| `defaultTabSetting` | Which feed (Videos or Photos) opens by default. | One of a fixed set of names. |
| `openMutedSetting` | Whether videos open muted by default. | Boolean, `0` or `1`. |
| `liveDefaultSetting` | Whether Live Photos autoplay by default. | Boolean, `0` or `1`. |
| `dailyReminderSetting` | Whether the daily reminder notification is on. | Boolean, `0` or `1`. |
| `dailyReminderHourSetting` | The hour set for the daily reminder, if it is on. | Exact integer, 0–23. |
| `keepsAlbumSetting` | Whether Keep also adds the item to a "Cloudfull keeps" album. | Boolean, `0` or `1`. |
| `albumSort` | The album picker's sort order (Recent or Alphabetical). | One of a fixed set of names. |
| `endReason` | Why the session record was closed. | One of `background`, `crashOrKill`, `reopen`. |
| `startedAt` / `endedAt` | When the session began and ended. | Exact timestamps. |
| `openedFromNotification` | Whether this session was opened by tapping a notification. | Boolean, `0` or `1`. |
| `notificationKind` | Which notification type opened the session. | Fixed value, `daily`. |

### Library

| Key | Description | Type / format |
|---|---|---|
| `libraryCount` | Number of items in the user's Photos library, read once at the end of the session. | Exact integer, or `-1` if photo access was not granted. |

### Storage

| Key | Description | Type / format |
|---|---|---|
| `freeSpaceGBAtStart` / `freeSpaceGBAtEnd` | Free storage space on the phone, at the start and end of the session. | Exact value in GB, shown to one decimal place. |
| `binItemsAtEnd` | Items sitting in the Bin when the app goes to the background. | Exact integer. |
| `binBytesAtEnd` | Total bytes those bin items would free. | Exact integer, bytes. |
| `bytesFreed.byDelete` / `bytesFreed.byShrink` / `bytesFreed.total` | Bytes freed this session by deleting, by shrinking, and by either. | Exact integer, bytes, running total for the session. |
| `bin.emptied.<mode>.itemCount` | Items cleared by "Empty Bin", by feed (`videos` or `photos`). | Exact integer, running total. |
| `bin.emptied.<mode>.sizedItemCount` | Of those, how many had a known size. | Exact integer, running total. |
| `bin.emptied.<mode>.bytesSum` | Total bytes of the sized items cleared. | Exact integer, bytes, running total. |
| `bin.emptiedOldestDaysMax` | The longest any item sat in the Bin before an empty, in days. | Exact integer, the highest value seen this session. |
| `deleted.videos.durationMsSum` / `deleted.videos.durationCount` | Total length and count of deleted videos. | Exact integer milliseconds / count, running total. |

### Session

| Key | Description | Type / format |
|---|---|---|
| `sessionSeconds` | Length of the session. | Exact integer, seconds. |
| `secondsToFirstAction` | Time from open to the user's first keep, delete, share, album, or shrink. | Exact integer, seconds. |
| `lastEventSeconds` | Time from open to the last counted event. | Exact integer, seconds. |
| `notificationToFirstAction` | Time from a notification tap to the first action, when the app was opened that way. | Exact integer, seconds. |
| `startHour` / `startWeekday` | The hour and weekday the session began, in the phone's local time. | Exact integer. |
| `utcOffsetMinutes` | The phone's time zone offset from UTC. | Exact integer, minutes. |
| `secondsIn.<mode>` | Seconds spent in the Videos feed vs. the Photos feed (`mode` = `videos` or `photos`). | Exact integer, seconds, running total. |
| `firstLoadMs.<mode>` | Time to the first post shown on screen, per feed. | Exact integer, milliseconds. |
| `firstLoadSpannedSessions.<mode>` | Counted instead of `firstLoadMs` when the load began in an earlier session. | Exact integer, running total. |
| `daysToFirst.<what>` | Days from install to the first-ever delete, keep, or bin-empty (`what` = `delete`, `keep`, or `binEmpty`). Written once per phone. | Exact integer. |
| `gateScreen.<gate>.seconds` | Seconds spent on a permission gate screen (`gate` = `welcome`, `limited`, or `denied`). | Exact integer, seconds, running total. |
| `photoPermission.seconds` | Seconds taken to answer the system photo-permission prompt. | Exact integer, seconds. |

### Locale

| Key | Description | Type / format |
|---|---|---|
| `country` | Region code from the phone's locale. | Fixed code, e.g. `US`. |
| `language` | Two-letter language code from the phone's preferred language. | Fixed code, e.g. `en`. |
| `timeZone` | The phone's time zone name. | String, e.g. `America/Chicago`. |

### Network

| Key | Description | Type / format |
|---|---|---|
| `networkAtStart` / `networkAtEnd` | Kind of network connection. | One of `wifi`, `5G`, `LTE`, `3G`, `2G`, `cell`, `wired`, `other`, `none`. |
| `networkChanges` | Number of times the network kind changed during the session. | Exact integer, running total. |
| `networkExpensive` | Whether iOS marks the connection "expensive" (for example, a cellular hotspot). | Boolean, `0` or `1`. |
| `lowDataMode` | Whether Low Data Mode is on. | Boolean, `0` or `1`. |

### Display & accessibility

| Key | Description | Type / format |
|---|---|---|
| `darkModeSetting` | Whether the app is displayed in dark mode. | Boolean, `0` or `1`. |
| `reduceMotion` | Whether Reduce Motion is on. | Boolean, `0` or `1`. |
| `textSize` | The user's preferred text size category. | One of a fixed set, e.g. `L`, `XL`. |
| `lowPowerAtStart` | Whether Low Power Mode was on at the start of the session. | Boolean, `0` or `1`. |

### Audio

| Key | Description | Type / format |
|---|---|---|
| `volumeAtStart` | The phone's output volume at the start of the session. | Exact value, `0.00`–`1.00`. |
| `audioRouteAtStart` / `audioRouteAtEnd` | Where sound plays. | One of `speaker`, `wired`, `bluetooth`, `airplay`, `car`, or another system-reported name. |
| `audioRouteChanges` | Number of times the audio route changed during the session. | Exact integer, running total. |
| `muteButton.muted` / `muteButton.unmuted` | Taps on the mute button, by the state it left the video in. | Exact integer, running total. |
| `liveSwitch.turnedOn` / `liveSwitch.turnedOff` | Taps on the Live Photo on/off switch. | Exact integer, running total. |
| `livePlay.tap` / `livePlay.auto` | Live Photo plays, by whether the user tapped or it auto-played. | Exact integer, running total. |

### Feature counters

| Key | Description | Type / format |
|---|---|---|
| `action.<mode>.<kind>` | An action taken on an item, by feed and kind (`kind` = `keep`, `unkeep`, `delete`, `share`, `album`, `shrink`). | Exact integer, running total. |
| `keepSource.<mode>.<source>` | A Keep, by how it was done (`source` = `rail` or `doubleTap`). | Exact integer, running total. |
| `afterPhotoKeep.<result>` | What the user did right after a photo Keep (`result` = `swipe`, `stay`, `back`). | Exact integer, running total. |
| `modeSwitch.<via>` | A switch between the Videos and Photos feeds, by how it was triggered (`via` = `chin`, `quickAction`, `notification`, `endPage`). | Exact integer, running total. |
| `modeSwitchTo.<mode>` | Which feed a mode switch landed on. | Exact integer, running total. |
| `modeSwitcherOpened` | The feed switcher was opened. | Exact integer, running total. |
| `quickAction.<mode>` | The app was opened using a Home Screen quick action, by feed. | Exact integer, running total. |
| `filterOn.<mode>.<name>` / `filterOff.<mode>.<name>` | A filter was turned on or off, by feed and filter name. | Exact integer, running total. |
| `sortChanged.<mode>.<name>` | The sort order was changed, by feed and the new sort's name. | Exact integer, running total. |
| `filterChange.<mode>` | A filter set was changed, by feed. | Exact integer, running total. |
| `filterReset.<mode>` | The filters were reset to default, by feed. | Exact integer, running total. |
| `postsSeenBeforeFilterReset.<mode>` | Posts seen since the last filter change, at the point of a reset. | Exact integer, running total. |
| `sort.<mode>` | The exact sort order in force when the app opened (only for a feed that has a sort). | One of a fixed set of names. |
| `filters.<mode>` | The exact filters in force when the app opened, as a joined list of names. | String, comma-separated fixed names. |
| `types.<mode>` | The exact media type filters in force when the app opened. | String, comma-separated fixed names. |
| `onThisDateEndPage.<mode>.reached` | The "On This Date" end-of-feed page was reached. | Exact integer, running total. |
| `onThisDateEndPage.<mode>.<tap>` | A button tapped on that end page (`tap` = `keepScrolling`, `toPhotos`, `toVideos`). | Exact integer, running total. |
| `dailyReminderAsk.<at>.<answer>` | The daily reminder opt-in prompt was answered (`at` = `firstDelete` or `endPage`; `answer` = `yes` or `notNow`). | Exact integer, running total. |
| `notificationPermission.allowed` / `notificationPermission.denied` | The system notification-permission prompt was answered. | Exact integer, running total. |
| `notificationTap.<kind>` | A notification was tapped, by kind (`kind` = `daily`). | Exact integer, running total. |
| `openedNearDailyReminder` | The app was opened within an hour of the set daily reminder time. | Exact integer, running total. |
| `pullRefresh.<mode>` | The feed was pulled to refresh. | Exact integer, running total. |
| `photoPinchZoom` | A pinch-to-zoom gesture on a photo. | Exact integer, running total. |
| `video.fastForwardHold` | A fast-forward hold gesture on a video. | Exact integer, running total. |
| `video.scrub` | A scrub gesture on a video's timeline. | Exact integer, running total. |
| `video.rotatedToFullscreen` | A video was rotated into fullscreen. | Exact integer, running total. |
| `video.served.<W>x<H>` | The pixel size of a video actually played, exact width and height. | Exact integer counter keyed by resolution, e.g. `video.served.1920x1080`. |
| `video.clipsLogged` / `video.secondsLogged` | Clips finished on screen, and total seconds watched. | Exact integer, running total. |
| `video.logStalls` / `video.droppedFrames` / `video.clipsWithTrouble` | Playback stalls and dropped frames reported by the player, and clips that had either. | Exact integer, running total. |
| `video.clipsNoLog` | A clip that played with no playback log at all. | Exact integer, running total. |
| `video.stalledMidPlay` | A clip ran out of buffered data while playing. | Exact integer, running total. |
| `video.loops` | A feed video reached its end and looped while still on screen. | Exact integer, running total. |
| `deleted.<mode>.sizeUnknown` | An item was deleted before its size could be read. | Exact integer, running total. |
| `deleted.<mode>.res.<W>x<H>` | The exact pixel size of a deleted item, by feed. | Exact integer counter keyed by resolution, e.g. `deleted.videos.res.1920x1080`. |
| `postsSeen.<mode>` | Posts seen in the feed. | Exact integer, running total. |
| `swipes.<mode>` / `swipesBack.<mode>` | Swipes in the feed, and swipes that went backward. | Exact integer, running total. |
| `afterDelete.<mode>.back` / `.swipe` / `.stay` | What happened in the 5 seconds after a delete: swiped back, swiped on, or stayed. | Exact integer, running total. |
| `bin.open` / `bin.preview` | The Bin was opened, or a bin item was previewed. | Exact integer, running total. |
| `bin.emptyTapped` | "Empty Bin" was tapped (before the system confirms). | Exact integer, running total. |
| `bin.emptiedCount` | An empty of the Bin was confirmed. | Exact integer, running total. |
| `bin.restore` | An item was restored from the Bin. | Exact integer, running total. |
| `keepPulledFromBin.<mode>` | A Keep pulled an item back out of the Bin queue. | Exact integer, running total. |
| `unqueuedInFeed.<mode>` | A second trash tap took an item back out, without opening the Bin. | Exact integer, running total. |
| `shrink.sheet` / `shrink.cancel` | The Shrink sheet was opened, or cancelled. | Exact integer, running total. |
| `shrink.<outcome>` | How a started shrink ended (`outcome` = `done`, `failed`, `originalKept.liked`, `originalKept.cancelled`, `originalKept.queueRefused`). | Exact integer, running total. |
| `shareSheetOpened.<mode>` | The share sheet was opened, by feed. | Exact integer, running total. |
| `shareTarget.<target>` | Where a share finished, from a fixed list of apps and system actions (for example `messages`, `mail`, `airDrop`, `instagram`, `whatsapp`, `cancelled`, `other`). | Exact integer, running total. |
| `shareTargetRaw.<id>` | The exact system identifier of the share target app, up to 64 characters, alongside the mapped name above. | String key, a system activity or app identifier, not user-typed text. |
| `shareFailed` | A share attempt failed. | Exact integer, running total. |
| `shareKind.<kind>` | What kind of file was shared (`kind` = `movie`, `still`, `live`, `liveMovie`). | Exact integer, running total. |
| `album.new` / `album.existing` | An item was added to a new album, or an existing one. | Exact integer, running total. |
| `album.cancel` | The album picker was cancelled. | Exact integer, running total. |
| `album.sortChanged` | The album picker's sort order was changed. | Exact integer, running total. |
| `appIcon.<name>` | An app icon was chosen, by name. | Exact integer, running total. |
| `appIcon.failed` | Setting the app icon failed. | Exact integer, running total. |
| `keepAlbum.added` / `.alreadyThere` / `.removed` / `.failed` | The "Cloudfull keeps" album was updated, or the update failed. | Exact integer, running total. |
| `gateScreen.<gate>.shown` | A permission gate screen was shown (`gate` = `welcome`, `limited`, `denied`). | Exact integer, running total. |
| `gateScreen.<gate>.<via>` | How the user left a gate screen (`via` = `continue` or `openSettings`). | Exact integer, running total. |
| `photoPermission.<name>` | The photo-permission prompt was answered this session, by the choice made. | Exact integer, running total. |
| `photoPermissionAtStart` / `photoPermissionAfterSettings` | The app's photo access level at session start, and after a return from the Settings app. | One of `full`, `limited`, `denied`, `restricted`, `notAsked`, `other`. |
| `onboarding.<step>` | An onboarding step was reached (`step` = `shown` or `completed`). | Exact integer, running total. |
| `loadingTaps.<mode>` | A tap on the loading state, by feed. | Exact integer, running total. |
| `photoLoadFailedCount` / `videoLoadFailedCount` | A photo or video failed to load. | Exact integer, running total. |
| `slowDownloadCount` | An iCloud download was slow to arrive. | Exact integer, running total. |
| `settingsOpened` | The Settings screen was opened. | Exact integer, running total. |
| `setting.<name>` | A setting was changed, by name (`name` = `keepsAlbum`, `defaultTab`, `openMuted`, `dailyReminder`, `dailyReminderHour`). | Exact integer, running total. |
| `settingsLink.<name>` | A link row was tapped in Settings, by which link (`name` = `website`, `contact`, `privacy`, `sourceCode`, `feelsMusic`, `guestBets`, `carlyAndTheUniverse`, `tabzTech`, `barkBarkBark`). Caught by one handler for every link on the screen; never the raw URL. | Exact integer, running total. |
| `showWelcomeTapped` | "Show welcome screen" was tapped in Settings. | Exact integer, running total. |
| `showOnboardingAgainTapped` | "Show onboarding again" was tapped in Settings. | Exact integer, running total. |
| `settingsOpenIOSSettingsTapped` | "Turn on notifications in iOS Settings" was tapped in Settings (shown only after the daily reminder's notification permission is denied). | Exact integer, running total. |
| `tip.tapped.<tier>` | A tip jar button was tapped, by price tier (`tier` = `1`, `10`, `100`). Never the product's actual price or currency. | Exact integer, running total. |
| `tip.outcome.<tier>.<outcome>` | How a tapped tip purchase ended (`outcome` = `success`, `cancelled`, `pending`). | Exact integer, running total. |
| `tip.unavailable.<reason>` | The tip jar had no products to show (`reason` = `loadFailed` when StoreKit's load threw, `empty` when it returned zero products). | Exact integer, running total. |
| `mainThreadStallsOver250ms` | Main-thread stalls longer than 250ms this session. Written only in DEBUG builds, never in the App Store build. | Exact integer. |

## Never sent

The analytics code does not read or send any of the following. This is
verified against the code, not assumed:

- Photos or videos themselves.
- Filenames.
- Asset IDs.
- A photo's or video's date.
- A photo's or video's location.
- Album names.
- Anything the user types.
- A tip jar product's price or currency. Only its fixed tier (`1`, `10`, or `100`) is sent.
- The destination URL of a tapped link. Only the fixed name of the link row is sent.

The only identifiers Cloudfull sends about media are exact pixel dimensions
(such as `1920x1080`) and, for a deleted video, its duration in
milliseconds — never which item, never its name, date, or place.

## Place-name captions are separate, and are not analytics

When a photo carries a location, Cloudfull looks up a short place name (for
example, "Encino, CA") to show under it. This is a separate, on-demand call
to Apple's Maps service, made only for the photo the user is currently
looking at. It sends that photo's own embedded coordinate to Apple. It is
not part of the usage analytics described above, it is not sent to
Cloudfull's own database, and it does not use the phone's current location.

## For maintainers

### The CloudKit schema

- Container: `iCloud.com.cloudfull.app`, public database.
- Record type: `UsageSession`, one record for each session.
- Fields: `installId`, `startedAt`, `endedAt`, `coldStart`, `schema`, `app`, `ios`, `device`, `libraryCount`, `sessionSeconds`, `daysSinceInstall`, `country`, `photoPermissionAtStart`, `endReason`, `counts`, `facts`.
- `counts` and `facts` are JSON text. Do not index them. An index on a large text field wastes the container's index limit.
- Security roles, in both environments:
  - `GRANT CREATE TO "_icloud"`: a signed-in iCloud user can create a record.
  - `GRANT WRITE TO "_creator"`: only the creator can change it.
  - No grant to `_world`. No grant on `Users`.

### Deploy the schema to Production before a release

The environment follows the build configuration. `Cloudfull.entitlements` sets `com.apple.developer.icloud-container-environment` to `$(CLOUDKIT_ENVIRONMENT)`: Debug uses Development, Release uses Production.

Development creates new fields automatically on the first save. Production does not. An App Store or TestFlight build cannot save a record with a field that Production does not have.

When you add a field:

1. Run a Debug build once, so that Development gets the new field.
2. Deploy the schema to Production **before** you ship the release. In the CloudKit Console, select the container, then **Deploy Schema Changes**.
3. Check the result. Export both schemas and compare them:

   ```
   xcrun cktool export-schema --team-id <TEAM_ID> --container-id iCloud.com.cloudfull.app --environment development --output-file dev.ckdb
   xcrun cktool export-schema --team-id <TEAM_ID> --container-id iCloud.com.cloudfull.app --environment production --output-file prod.ckdb
   diff dev.ckdb prod.ckdb
   ```

   `cktool` schema commands need a management token (`xcrun cktool save-token`, type `m`). Record queries need a user token (type `u`).

### Rules for new fields

- Do not add anything more identifying. The install ID, country, device, language, and hour together can already narrow a record to a small group of people.
- Add new names. Do not rename or reuse old names. After a Production deploy, a renamed field leaves the old records under the old name, and `scripts/usage_report.py` reads fields by name.
- Update this document and the privacy page when you add a field.

### Look at the raw records

1. Open [the CloudKit Console](https://icloud.developer.apple.com/dashboard).
2. Select the container `iCloud.com.cloudfull.app`, then **Data**.
3. Select database **Public** and environment **Development** or **Production**.
4. Select record type **UsageSession**, then **Query Records**.

For totals, use `scripts/usage_report.py`. It needs `CLOUDFULL_TEAM_ID` set to your Apple Developer Team ID.

After you run the report, update the [usage dashboard](https://claude.ai/artifact/TME9cPtKC82fhePavDVhTJ) with the new numbers. The dashboard is a private page; only the maintainer can open it. The script prints this reminder at the end of each report. Set `CLOUDFULL_DASHBOARD_URL` to use a different page.

## More information

For the full privacy statement, see
[cloudfull.app/privacy](https://cloudfull.app/privacy/).
