# Recharge Island · NotchIsland

**Turns the MacBook notch into something you can actually use.** Hover over the notch and it expands into a small panel with media controls and lyrics, calendar, volume/brightness HUDs, a pomodoro timer, a file shelf, and a page full of system shortcuts.

[中文](README.md) · English

![macOS 15+](https://img.shields.io/badge/macOS-15.0%2B-black)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-black)
![License GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue)

<p align="center"><img src="boringNotch/Assets.xcassets/ShuIcon-captain.imageset/icon.png" width="150" alt="Captain Shu"></p>

<p align="center"><img src="docs/screenshots/island.png" width="820" alt="The expanded island: media controls, lyrics and calendar"></p>
<p align="center"><i>Hover the notch and it expands: media controls, synced lyrics and the calendar at a glance</i></p>

**👉 New here? Jump straight to [Download & install](#1-download--install).**

---

## Contents

- [What it is](#what-it-is)
- [1. Download & install](#1-download--install)
- [2. Five-minute tour](#2-five-minute-tour)
- [3. Features in detail](#3-features-in-detail)
- [4. Settings at a glance](#4-settings-at-a-glance)
- [5. FAQ](#5-faq)
- [6. Building it yourself](#6-building-it-yourself)
- [7. Known limitations](#7-known-limitations)
- [8. Privacy](#8-privacy)
- [9. License & credits](#9-license--credits)

---

## What it is

A native macOS app (SwiftUI + AppKit) that lives in the notch at the top of your screen:

- **Out of the way when idle** — collapsed it is just the black notch, showing a sliver of information only while music plays, a timer runs, or power is plugged in.
- **Hover to expand** — it becomes an interactive panel with four pages.
- **Never steals keyboard focus** — the island is never the active window, so it cannot interrupt your typing.

It is built on the open-source [boring.notch](https://github.com/TheBoredTeam/boring.notch) (GPL-3.0), with a sweet-potato mascot ("Captain Shu"), a pomodoro game built around it, and a full page of system shortcuts added on top.

**Requirements**

| Item | Requirement |
|---|---|
| OS | macOS 15.0 or later |
| Machine | Apple Silicon (M-series). Intel is untested |
| Display | Best on a MacBook with a physical notch; other displays get a simulated pill at the top center |
| Price | Free and open source — no account, no purchases, no ads |

---

## 1. Download & install

### Step 1: Download the installer

**[Go to the latest release](../../releases/latest)**

Scroll down to the **Assets** section and click the file named like `NotchIsland-1.0.0.dmg`.

> ⚠️ `Source code (zip)` / `Source code (tar.gz)` in the same list are the **source code**, not the app.

### Step 2: Drag it into Applications

1. Double-click the downloaded `.dmg`.
2. Drag the **工位充电岛** (Recharge Island) icon onto the **Applications** folder next to it.
3. Eject the mounted disk image from the Finder sidebar; the `.dmg` can then be deleted.

### Step 3: Allow it the first time (this always happens, do not worry)

The app is **not notarized by Apple**, because notarization requires a paid Apple Developer account that the author does not have. macOS will therefore block the first launch with a warning about an unverified developer or possible malware. **This is what every un-notarized open-source app looks like on macOS.**

To allow it:

1. Double-click the app once (it gets blocked) → dismiss the dialog;
2. Open **System Settings → Privacy & Security**, scroll near the bottom, find the line saying the app was blocked, and click **"Open Anyway"**;
3. Confirm once more (you may need your login password).

After that it launches normally.

<details>
<summary>Command-line alternative (click to expand)</summary>

```sh
xattr -dr com.apple.quarantine /Applications/工位充电岛.app
```

This means you take on the risk of skipping the Gatekeeper check yourself — please make sure the `.dmg` came from this repository's Releases page.

</details>

### Step 4: Grant permissions (all optional, feature by feature)

The first launch shows a short onboarding page; you can also grant everything later in **System Settings → Privacy & Security**.

| Permission | What it enables | Without it |
|---|---|---|
| **Accessibility** | Volume/brightness/mute HUDs in the notch; mirroring other apps' notification banners to the island; the lock-screen tool; ⌘C/⌘X/⌘V in the file shelf | Those features stay silently unavailable; everything else works |
| **Screen Recording** | Screenshot and screen-recording tools | Capture tools unavailable |
| **Calendar / Reminders** | Events and reminders on the island's home page | That area stays empty |
| **Camera** | The "mirror" on the home page | Mirror unavailable |
| **Notifications** | Alerts from the built-in stopwatch / timer / alarm | No alerts |
| **Automation (System Events)** | The Dark Mode toggle in the quick tools | That tile reports a failure |

> After changing the Accessibility permission, quit and relaunch the app for the cleanest state.

### Step 5 (optional): Launch at login

Menu bar potato icon → **Settings…** → **General** → enable "Launch at login".

---

## 2. Five-minute tour

### Opening and closing

| Goal | How |
|---|---|
| Expand | Hover the notch for ~0.15 s; it collapses ~0.1 s after you leave |
| Keyboard | **⇧⌘I** by default (configurable in Settings → Shortcuts) |
| From the menu bar | Potato icon → "Open island" |
| Hide it temporarily (e.g. before screen sharing) | Potato icon → "Hide island"; click again to restore |
| Settings | Potato icon → "Settings…", or **⌘,** while the app is frontmost |
| Quit | Potato icon → "Quit" |

> **Only the real physical notch rectangle triggers the expansion.** The media wings, the lyrics row and the widened HUD bar are drawn outside it and deliberately do *not* trigger anything — otherwise the island would pop up whenever you reach for the menu bar.

### Four pages

The row of small icons at the top switches pages (hovering an icon switches by default; you can turn that off in Settings → Appearance):

| Page | Contents |
|---|---|
| 🍠 **Island** | Captain Shu's little farm plus the Sweet Potato Timer (pomodoro). Harvested potatoes pile up on the ground |
| 🏠 **Home** (default landing page) | Now playing (artwork, progress, previous/play/next), calendar and reminders, mirror, shelf entry |
| 📥 **Shelf** | A temporary tray for files — drag in, drag out |
| ⊞ **Quick tools** | A page of system shortcuts and small utilities; pick which ones show and in what order |

### What the collapsed notch shows

- While music plays: artwork and a spectrum on either side of the notch (can be turned off in Settings → Media);
- With lyrics enabled: a synced lyrics line **below** the notch;
- While the timer runs: a potato icon and the remaining time;
- When you change volume/brightness/mute: the HUD is drawn on the notch instead of the system's big square;
- When you plug or unplug power: a brief charging notice.

### Two floating buttons

While expanded, two small round buttons float just outside the notch on the upper right: the top one **collapses the island**, the bottom one **clears the file shelf** (greyed out when the shelf is empty).

---

## 3. Features in detail

### 1. Media & lyrics

- **Controls**: artwork, title, artist and progress for whatever is playing, with previous / play-pause / next. The button layout is rearrangeable in Settings → Media → Media controls.
- **Lyrics**: **they do not come from the player.** macOS only exposes title, artist, album, duration and progress to third-party apps — there is no lyrics field. So the app looks up LRC lyrics online (the NetEase public endpoint and LRCLIB) and advances the timeline locally from the playback progress.
  - Placement: off / inside the player / below the notch (Settings → Media → Lyrics location).
  - Color: white / follow album artwork / custom.
  - Long lines scroll; the row hides itself while paused, during instrumental gaps, or when nothing matched.
  - **Matching is strict**: title, album, duration (within 1 s) and the primary artist all have to line up. It would rather show nothing than show you a wrong timeline, so live versions, covers and obscure tracks often have no lyrics.
  - NetEase playback prefers NetEase lyrics; other players (QQ Music, Kugou, Spotify, Apple Music) prefer LRCLIB. **The author has not personally tested non-NetEase players** — issues welcome.

### 2. System HUDs

Replaces the translucent system square for the **built-in keyboard's** volume, brightness and mute keys with a slim indicator on the notch.

- Two styles: **default** (a 28-point row under the notch) and **inline** (drawn beside the camera).
- Requires **Accessibility**. Without it, the system HUD is left in place — you never get both at once.
- Settings → HUDs contains a read-only diagnostics block (process path, signature, authorization state, recent media-key events) that you can copy into an issue.

### 3. Sweet Potato Timer (pomodoro)

<p align="center"><img src="docs/screenshots/timer.png" width="820" alt="Sweet Potato Timer: Captain Shu's farm and the potato stock"></p>

On the 🍠 page. Focus and rest are mutually exclusive.

- **Focus**: 25 minutes by default, 1–120 configurable. A ring shows the remaining time while Captain Shu eats a baked potato in six bites. Completing one consumes a potato from your stock; with zero stock you can still run a round ("tasting") and never go into debt.
- **Rest**: 1 minute by default, 1–120 configurable. Tilling, watering and pulling in the first half, roasting in the second — **every completed minute earns one potato**.
- Pause / resume and early stop are supported (completed whole minutes are kept, partial minutes are not).
- **Closing the lid, locking the screen or quitting the app does not change the end time**: the next launch settles the harvest from the real elapsed time.
- The farm draws up to 12 potatoes (3×4); anything beyond that shows as `+N`, while the number always reflects the full stock.
- When a focus round ends the island expands once and stays readable for at least 10 seconds. **No sound, no focus stealing** — the next round is started by you.
- Settings → Sweet Potato Timer can turn off "show the countdown on the collapsed notch"; the timer itself keeps running and settling either way.

### 4. File shelf

A temporary tray for handing files from one place to another: drag in from Finder, drag out into a chat, an email or a web page later.

- **Ways in**: drag onto the island; screenshots and recordings taken from the app; **⇧⌘3 / ⇧⌘4** system screenshots get copied in automatically (**the original file stays where it was**); or the "stage clipboard file" button.
- **Ways out**: drag out to the target app. Hold the chord (**⌥⌘** by default, configurable) while dragging to *remove on drop*.
- **Mistakes are recoverable**: an "Removed · Undo" strip appears for 10 seconds after a removal, and the same applies to clearing the shelf.
- Multi-select (⌘-click), ⌘C/⌘X/⌘V (needs Accessibility) and a right-click menu (open / copy / cut / remove / paste).
- **Automatic cleanup**: each file is timed from the moment it enters — never / 12 hours / 1 day / 3 days / 1 week (1 day by default). On expiry only files the app itself created in the temporary directory (screenshots, recordings, clipboard images…) are actually deleted; items dragged in from Finder merely disappear from the list, **their originals on disk are untouched**.

### 5. Quick tools page

<p align="center"><img src="docs/screenshots/tools.png" width="820" alt="Quick tools page: capture, stopwatch, timer, volume slider and more"></p>

A grid of tiles — **73 in total**. Choose which ones appear and drag the handles to reorder them in Settings → Quick tools.

Note that the tiles are not all the same kind of thing (each tile's subtitle says which):

| Kind | Count | Notes |
|---|---:|---|
| Opens a System Settings pane | 35 | Jumps to the corresponding settings pane rather than toggling anything (Focus, VPN, Stage Manager, the accessibility options…) |
| Opens a built-in app | 13 | Clock, Calculator, Notes, Voice Memos, Shortcuts, Weather, Home, Reminders, Magnifier, Spotlight, Siri, Screen Saver, Accessibility Shortcuts |
| Capture flows | 7 | Full-screen / region / window / custom screenshot, full-screen / region / custom recording. Output lands in the shelf. **Video only — no system audio or microphone** |
| In-app utilities | 3 | Stopwatch, timer, alarm (separate small windows; they keep running when closed and post a notification) |
| Sliders | 3 | Volume, display brightness, keyboard backlight — real hardware |
| Direct toggles / pickers | 9 | Mute, Wi-Fi power, Dark Mode, Time Machine backup, lock screen, input source, audio output device, display resolution/refresh rate, jump back to the player page |
| Marked "experimental" | 3 | **Bluetooth, Night Shift, True Tone.** These go through private system interfaces, so on some machines the state cannot be read or the switch fails; failures are reported honestly with a link to the matching settings pane instead of being faked as success |

How thoroughly each of these has been verified varies: Night Shift, Increase Contrast, Reduce Transparency, audio-output switching, input sources, display-mode switching, Bluetooth power, region recording and drag reordering **were each exercised by hand on a real machine**; VPN connect/disconnect and real Time Machine start/stop **could not be verified** (the author's machine has neither configured); for the 13 "open a built-in app" tiles only path resolution was checked.

### 6. App notification mirroring

Mirrors **any app's desktop notification banner** onto the island, with a click to jump to that app.

- Requires **Accessibility**.
- Once an app has posted its first notification it shows up in Settings → App notifications, where you can enable it **per app** and separately decide whether to **show the content preview** (with previews off you only learn that the app has a new message).
- Verified against real WeChat and corporate IM banners.
- ⚠️ **The system's own banner is not hidden**, so for now both appear. Hiding the original banner, and following the island's display, are not implemented yet.

### 7. Calendar, reminders and mirror

The home page's right side shows calendar events and reminders (permissions are requested separately; pick which calendars in Settings → Calendar). There is also a "mirror" — the front camera, **started only while you have it open** (turn it off in Settings → Appearance if you do not want it).

### 8. Battery & power notices

Plugging or unplugging power shows a notice shaped like the volume HUD (following your default/inline choice). Can be turned off in Settings → Battery.

### 9. Appearance, icon and language

- **Language**: Settings → General → Language, Chinese/English, applied immediately.
- **App icon**: three variants under Settings → Advanced.
- With the system's "Reduce motion" enabled, Captain Shu's animation degrades to static frames.

---

## 4. Settings at a glance

Menu bar potato icon → "Settings…". The sidebar has (there is a search field at the top right):

| Pane | What it covers |
|---|---|
| **General** | Language, launch at login, menu bar icon, which display hosts the island |
| **Sweet Potato Timer** | Focus/rest durations, countdown on the collapsed notch |
| **Quick tools** | Which of the 73 tools show, and their order |
| **Appearance** | Notch behavior: open-on-hover switch, collapse mode and delay, hover tab switching and delay, haptics, remember last tab, mirror toggle |
| **Media** | Notch media wings, lyrics location and color, media control layout, artwork glow |
| **App notifications** | Which apps get mirrored, content previews |
| **Calendar** | Which calendars, reminders toggle |
| **HUDs** | Whether to take over volume/brightness HUDs, default vs inline style, read-only diagnostics |
| **Battery** | Power notices |
| **Shelf** | Enable, default landing on the shelf when non-empty, remove-on-drop chord, retention |
| **Shortcuts** | Global shortcuts for toggling the island and the quick media peek |
| **Advanced** | App icon and more |
| **About** | Version, upstream credits |

---

## 5. FAQ

<details open>
<summary><b>It will not open — "unverified developer" / "may contain malware"</b></summary>

Expected, because the app is not notarized. Follow [Step 3](#step-3-allow-it-the-first-time-this-always-happens-do-not-worry): System Settings → Privacy & Security → "Open Anyway", once. The old trick (Control-click → Open) no longer works on macOS 15+.
</details>

<details>
<summary><b>Nothing shows on the notch / hovering does nothing</b></summary>

1. Is the app running? There should be a potato icon in the menu bar. If not, launch it from Applications (if you disabled the menu bar icon, relaunching opens the settings window instead).
2. Did you press "Hide island"? Use the menu bar icon → "Show island".
3. Hover the **notch itself**, not the menu bar beside it and not the wings the app draws.
4. Is "Open notch on hover" turned off in Settings → Appearance → Notch behavior? (With it off, only the shortcut and the menu bar can open the island.)
5. Does your Mac have a physical notch? Other displays get a simulated pill at the top center.
6. Multiple displays: pick the host display in Settings → General (there is also a "show on all displays" switch).

If the opposite happens and it **collapses too eagerly**, raise the "Collapse delay" in Settings → Appearance → Notch behavior.
</details>

<details>
<summary><b>Volume/brightness still shows the system's big square</b></summary>

This needs **Accessibility**: System Settings → Privacy & Security → Accessibility → enable the app, then quit and relaunch it. Settings → HUDs reports the current state (running / not authorized / failed to start). Note that it takes over the **built-in keyboard's** keys.
</details>

<details>
<summary><b>No lyrics / lyrics out of sync</b></summary>

- Check that Settings → Media → Lyrics location is not "off".
- Lyrics are fetched online, so a network connection is required.
- Title, album, duration and primary artist must all match, so live versions, covers and obscure tracks often have none — a deliberate "nothing rather than wrong" trade-off.
- NetEase playback is the best-tested path; other players go through LRCLIB, where a transcription can be a few seconds off.
</details>

<details>
<summary><b>Other apps' notifications are not mirrored</b></summary>

1. **Accessibility** is required.
2. The app has to post one real notification first; only then does it appear in Settings → App notifications, where you enable it.
3. That app's notifications must actually be banners (not set to "None" in System Settings → Notifications).
4. Note that the system's own banner is **not hidden** in this version, so both appear.
</details>

<details>
<summary><b>Screenshots / recordings do nothing</b></summary>

**Screen Recording** is required: System Settings → Privacy & Security → Screen Recording → enable the app, then **quit and relaunch** (this permission only takes effect on restart). Recording captures video only — no system audio, no microphone.
</details>

<details>
<summary><b>How do I update?</b></summary>

**There is no auto-update** (that also needs a paid developer account for signing). Download the newer `.dmg` from [Releases](../../releases/latest) and replace the app; your potato stock, settings and shelf are preserved. Quit the running app first.

To hear about new versions, use **Watch → Custom → Releases** at the top of the repository.
</details>

<details>
<summary><b>How do I uninstall it completely?</b></summary>

1. Menu bar potato icon → Quit.
2. Move **工位充电岛** from Applications to the Trash.
3. Optionally remove the local data:
   ```sh
   rm -rf ~/Library/Application\ Support/boringNotch
   defaults delete com.dongfengrui.NotchIsland
   ```
4. Optionally remove the leftover entries in System Settings → Privacy & Security → Accessibility / Screen Recording with the "−" button.
</details>

<details>
<summary><b>Can it coexist with the original boring.notch?</b></summary>

They can both be installed (separate apps, neither overwrites the other), but **do not run them at the same time** — two windows would fight over the same notch. Quit one while using the other.
</details>

---

## 6. Building it yourself

```sh
git clone https://github.com/eDouFuRu/notch-island.git
cd notch-island
open boringNotch.xcodeproj
```

Pick the **NotchIslandNext** scheme in Xcode, switch signing to your own account (or "Sign to Run Locally"), then Build & Run. Xcode 16+ and the macOS 15 SDK are required.

Checks that need no Xcode:

```sh
swift test                              # pure-logic unit tests (timer, state machines, lyrics matching…)
./scripts/test-services.sh              # service-layer checks (fakes only, no real hardware)
python3 scripts/audit-localization.py   # zh/en string catalog consistency
```

Layering convention: `boringNotch/Interaction/Core/` and `boringNotch/components/Island/Core/` are pure-Swift cores with no AppKit/SwiftUI dependency (unit-testable); the outer layers call system APIs and draw the UI. Please follow the same split when adding features.

> Released binaries are signed with the author's local self-signed certificate; those scripts touch the local keychain and are not part of this repository.

<details>
<summary><b>About that corporate IM bundle id in the code</b></summary>

The code contains notification-parsing support for a corporate IM app (bundle id `com.electron.redcity`) because the author's company uses it. For everyone else it is just one redundant parsing rule — it changes no behavior and sends nothing anywhere.
</details>

---

## 7. Known limitations

- **Not notarized by Apple** — the first launch has to be allowed manually.
- **No auto-update** — new versions are downloaded manually from Releases.
- Built and verified on **Apple Silicon** only; Intel is unknown.
- The trigger area is fixed to the physical notch rectangle; other machines get a simulated pill, which feels different.
- When mirroring notifications, **the system banner is not hidden**.
- Bluetooth / Night Shift / True Tone use private interfaces and are marked experimental; they may not work on every machine.
- 35 of the quick tools only open the matching System Settings pane — they are not switches.
- Lyrics on non-NetEase players are untested by the author.
- Not on the App Store (uses private frameworks such as MediaRemote and is not sandboxed).

---

## 8. Privacy

- The app **collects and uploads nothing**: timer history, staged files, notification text and settings stay on your own machine (`~/Library/Application Support/boringNotch/` plus the app's preferences).
- **The only network access is lyrics matching**: the current track's title/artist/album/duration are sent to the NetEase public endpoint and LRCLIB to look up an LRC file. Set Settings → Media → Lyrics location to "off" and the app goes fully offline.
- Notification mirroring reads banner text locally for display only; nothing is uploaded or persisted.
- The mirror starts the camera only while you have it open.

---

## 9. License & credits

This project is licensed under **GPL-3.0**, same as upstream: use, modify and redistribute freely, but derivative works must stay open source under the same license.

- Upstream: [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch), commit `16b0f11f51c79d42e27c10d77fd9e53c11410fdb` (v2.7.3). Thanks to its authors.
- Full license in [LICENSE](LICENSE), third-party notices in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES), the upstream readme in [docs/upstream/README-boring-notch.md](docs/upstream/README-boring-notch.md).
- Version history in [CHANGELOG.md](CHANGELOG.md).

**About the mascot**: the "Captain Shu" illustrations and 2.5D sprites were generated for this project. This is a personal side project, unaffiliated with and unendorsed by any company. If you believe an asset infringes your rights, please open an issue and it will be removed or replaced.

Questions, ideas and bug reports are welcome in [issues](../../issues).
