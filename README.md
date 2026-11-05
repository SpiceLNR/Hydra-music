# Hydra Music

**English** · [Русский](README.ru.md)

A personal audio player for Android and Windows that syncs your music between your own devices
directly, with no cloud and no accounts. Metro-style interface (Windows Phone): flat tiles, large
light headings, a green accent, only buttons and lists, no rounded corners, no panoramas or swipes.

The source code is open (PolyForm Noncommercial license: you may read, change and make your own
versions, but not sell them). The core is written in Rust, the interface in Flutter.

Interface languages: English, Russian, Ukrainian. By default the system language is used (English
if it is none of the three); it can be changed in Settings → Language.

## Contents

1. [The idea in brief](#the-idea-in-brief)
2. [Library: folders and playlists](#library-folders-and-playlists)
3. [Working with tracks](#working-with-tracks)
4. [Player and playback modes](#player-and-playback-modes)
5. [Protection against accidental mass deletion](#protection-against-accidental-mass-deletion)
6. [Trash](#trash)
7. [Device sync](#device-sync)
8. [Android](#android)
9. [Windows](#windows)
10. [Updates](#updates)
11. [Settings](#settings)
12. [Security and privacy](#security-and-privacy)
13. [Building and installing](#building-and-installing)
14. [Repository layout](#repository-layout)
15. [Not done yet](#not-done-yet)
16. [Changelog](#changelog)
17. [License](#license)

## The idea in brief

- **A playlist is an ordinary folder.** Music lives in `Music/Hydra/<Playlist>` and is visible in
  any file manager and player. The app does not hide files inside its database.
- **No cloud.** Devices exchange music with each other directly.
- **Nothing gets lost.** Deleting sends a track to the trash for 30 days. Conflicting edits are
  resolved by time, the same way on every device.

## Library: folders and playlists

- Library root folder:
  - Android: `Music/Hydra`;
  - Windows: `Music\Hydra` (`%USERPROFILE%\Music\Hydra`).
  The folder can be moved elsewhere (Settings → Library → Folder): music, trash and all service
  data move together, and the app remembers the new location even after reinstalling.
- Every subfolder is a playlist. Music folders contain nothing but music: all service data lives
  in one hidden folder `.hydra/` in the library root — track order (`.hydra/playlists/`),
  playlist order, trash (`.hydra/trash/`), covers, edits for tagless files. Track order refers to
  tracks by a permanent identifier (UUID), not by file name.
- Images found in a playlist folder (`folder.jpg`, `cover.png`, etc.) are moved to
  `.hydra/images/<playlist>/`: nothing is deleted, but only tracks remain among the music.
- Every track gets a UUID when first added. Renaming a file in a file manager does not make it a
  “new” track.
- On start the app scans the folder and picks up everything you added by hand.
- Folder and file names are cleaned of forbidden characters and reserved Windows names so the
  same files open the same way on both systems.
- Formats: mp3, flac, wav, ogg, oga, opus, m4a, aac, mka, m4b. Video containers mp4, mkv, webm,
  mov, m4v are picked up too and play as audio. The format is detected by file content, so, for
  example, WebM with an `.m4a` extension plays as well.
- Only formats that play on both systems are picked up. **WMA, APE, WavPack (wv), AIFF and AVI are
  not supported:** Android cannot play them. New files of these formats are not picked up (they
  stay in the folder as is); tracks of these formats added before 0.33.0 stay in the library.
  To listen to them, convert the files, for example, to FLAC or Opus.
- Tags (title, artist, cover) are written into the file itself for mp3, flac, m4a/mp4, ogg/opus,
  wav and aac. Matroska/WebM (mka, mkv, webm) cannot hold written tags: edits are kept in the app
  (`.hydra/meta.json`) and survive reinstalling. Images no longer needed (an old cover after
  replacement, the cover of a track deleted forever) are removed from `.hydra/covers` automatically.

**Playlist actions:** create, rename, delete, reorder playlists.

**Playlist sort rule** (chosen per playlist):

| Rule | What it does |
|---|---|
| By artist | tracks are ordered by artist right away; new ones take their place automatically |
| By track title | the same by title |
| Any order | you set the order by dragging |

Manual reordering switches the rule to “Any order”. On Windows the rule is chosen by right-clicking
the green bar of the current playlist (the selected rule is checked).

## Working with tracks

- **Adding:** put a file into a playlist folder; it appears at the next scan. Title, artist and
  cover are read from the file's tags.
- **Title, artist, cover:** the player screen has a gear button. The “Track settings” dialog has
  “Change cover”, a title field and an artist field. Changes are written into the file's tags. If
  the format has no tags, the edit is saved in the app only, and the app says so. An empty artist
  clears the field. On Windows, title and cover are changed from the track's menu in the list.
- **Moving** a track between playlists moves the physical file.
- **Reordering** tracks within a playlist by dragging.
- **Deleting:** the track goes to the trash (with confirmation).
- **Marquee:** long titles in lists and in the player scroll smoothly.

## Player and playback modes

Player elements: cover, title and artist, position bar, “previous”, “pause/play”, “next”, volume
(on Windows a vertical bar at the window edge).

- **“Previous”:** the first press returns to the start of the track, a second press within 1.5 s
  goes to the previous track.
- **The queue loops:** after the last track the first one plays; “next” on the last track also
  goes to the first.

**Playback modes** — a wide slider switch with icons, from left to right:

| Icon | Mode | What it does |
|---|---|---|
| repeat one | **Repeat** | the current track loops |
| list | **Standard** | the playlist in order, looping |
| shuffle | **Shuffle** | random order of the current playlist, new on every switch-on |
| flame | **Anarchy** | random order of all playlists together (trash excluded) |

- A mode is chosen by tapping its icon; the square slider glides to it.
- Switching modes does not interrupt the track: it continues from the same place (a short hiccup
  is possible).
- When leaving Shuffle or Anarchy, playback continues with the playlist the current track belongs to.
- In Anarchy mode all green player elements (pause button, switch, position and volume bars) turn
  red. The rest of the app does not change.
- The app always starts in Standard mode.

## Protection against accidental mass deletion

If a playlist folder or most of its files (5 or more) disappear outside the app (for example, in a
file manager), the app **deletes nothing and sends nothing to other devices**. Instead a question
with two answers appears at the top:

- **Get back from other devices** — the tracks stay, and the missing files are downloaded at the
  next sync;
- **Delete everywhere** — after confirmation the tracks go to the trash on all devices.

Single file deletions (fewer than 5) apply immediately.

## Trash

- Tracks deleted in the app stay in the trash for 30 days, then are erased automatically.
- From the trash you can restore a track or delete it forever, or empty the whole trash.
- A later edit or move of the track on another device brings it back from the trash.
- Deletions received by sync also go to the trash, without asking again.
- The trash shows only tracks whose file is on this device. Deletions the device learned from the
  journal for files it never had do not appear in the trash.
- After reinstalling or a database reset the app picks up from `.hydra/trash` only what was deleted
  no more than 30 days ago: older items would have been erased anyway.

## Device sync

Sync works **over the local network (Wi-Fi)** and **over the internet** (the iroh library): devices
find each other by key and connect directly or, if that fails, through a relay server. Music and
the journal are encrypted on the devices; the server only sees an encrypted stream. Devices that
are already paired sync over the internet; for the first pairing they must see each other on the
same network or have internet access. Internet sync can be turned off in Settings, and on Android
limited to unmetered networks (Wi-Fi). By default the public n0 relay servers (from the iroh
authors) are used; you can set your own (`iroh-relay` on your server): Settings → Relay server.

**How it works**
- Devices exchange journal operations (add, move, edit, delete, reorder), then the missing files.
  Every file is verified by SHA-256.
- The journal uses hybrid logical clocks: the result does not depend on delivery order, and clock
  drift between devices does not break event order.
- Simultaneous work on two devices converges to one result.
- Only one sync session runs at a time.
- The journal is compacted: once a day (when it has more than 1000 entries) operations fully
  overridden by later ones are dropped, for example old track reorders. The state does not change.
- Ports: TCP 47475 (exchange), UDP 47476 (device discovery on the network).

**Pairing (once)**
1. On one device open “Devices” and show the pairing QR code. It is single-use and valid for
   3 minutes.
2. On the other device open the QR scanner and point it at the code. Fallbacks: open the
   `hydra://pair?…` link with the regular phone camera or paste it manually (“Enter the link
   manually”).
3. The devices remember each other and sync right away.

**Auto sync** (on by default, can be turned off in Settings): devices of your family sync on their
own as soon as they are on the same network, then roughly every 10 minutes, and a few seconds after
your edits (cover, title, deletion, move, playlists). On Android an “Auto sync is on” notification
is shown: the service keeps the app alive and accepts connections without using the CPU. There is
an “Only while charging” option and an “Allow background work” button (battery optimization
exemption). On Windows auto sync works while the app is running.

**Afterwards** the device appears in the list, where you can sync manually, rename it (pencil
button; the name is visible only on this device) or forget it. Forgetting a device during a sync
aborts the running session.

**Removing a device works both ways.** When you remove a device, it is sent a message and removes
you from its list. If the device is unreachable at that moment, the message waits up to 14 days
and is delivered when it shows up (over Wi-Fi or the internet). The music stays.

**Log.** The button in the top-right corner of the Devices screen opens a separate screen with the
network log; every entry has a date and time. It shows how pairing and sync went, how many
operations and files were exchanged, how many tracks went to the trash and why. The last 100
entries are kept.

**Wi-Fi requirements:** both devices on the same network (not needed over the internet). Guest
networks and “client isolation” on the router get in the way. On Windows you may need to allow
Hydra Music in the firewall.

## Android

- Background playback: foreground service, notification with buttons, control from the lock screen
  and headphones.
- Audio is played by the system ExoPlayer: battery-friendly and without stutters.
- During sync a separate service (with a notification) keeps Android from putting the app to sleep
  with the screen off.
- Access to all files is required to work with the `Music/Hydra` folder.
- The QR scanner works without Google services (tested on GrapheneOS).
- Without folder access, or while the library is still opening, the Playlists, Devices and Trash
  tiles on the home screen are unavailable.
- Designed for Android 11 and newer: the `Music/Hydra` folder is accessed via the “All files
  access” permission, which older versions lack.

## Windows

The app window is a “panel” at the screen edge:

- a narrow window the full height of the work area (down to the taskbar), docked to the chosen edge;
- clicking outside collapses it into a green 40×40 button with an arrow at the same edge, centered
  vertically and staying on top of other windows; clicking the button expands the window;
- the app is not on the taskbar and has no Windows frame;
- the window width is changed by dragging the edge (from 320 to 700 pixels);
- a vertical volume bar on the docked side;
- open Devices and Settings screens are kept when the window collapses;
- a notification area (tray) icon: left click expands the window, right click opens the menu
  “Show” and “Exit”; the close button in the header only collapses the program;
- optional start with Windows (Settings → Start with Windows): the program starts collapsed at the
  screen edge.

Music is read from `Music\Hydra` by default. The app is not code-signed, so SmartScreen may warn:
click “More info” → “Run anyway”.

## Updates

The app checks for a new version by itself: on start, every 6 hours, and on Windows also when the
panel is expanded (at most once an hour). The “Check” button in Settings checks right away. New
versions come from Releases (tag `latest`); the file is verified by SHA-256.

- **Windows:** a “Version X is available” banner appears at the bottom of the panel: “Download”
  (with pause and stop), then “Install”. The program closes for a couple of seconds and starts again
  updated; the previous version stays next to it in `app.prev`. The program folder must be writable
  (for example, `%LOCALAPPDATA%\HydraMusic\app`); in `Program Files` the update cannot be installed.
  Install log: `app.update\install.log` next to the program folder.
- **Android:** the same banner on the home screen right below the tiles. “Install” opens the system
  installer. The first time, Android asks to allow Hydra Music to install apps; after installing,
  open the app again. Data and pairing are kept.

## Settings

The screen is split into sections, one line per setting:

- **This device:** the name other devices see (they learn a new name at the next sync); the
  interface language (same as system, Russian, English, Ukrainian).
- **Sync:** automatic on/off; “only while charging” (Android); over the internet on/off and “only
  over Wi-Fi” (Android); relay server (empty means n0 servers; your own `https://...` address applies
  at once, the device address stays the same for others); an “Allow background work” button
  (Android, until allowed).
- **Library:** the folder; tap it to move the library.
- **Window (Windows):** docking side, collapse on outside click, start with Windows.
- **Updates:** version and build (first characters of the commit), time of the last check, “Check”
  button.

Explanations appear only when something is wrong: for example, if internet sync or the core did not
start.

## Security and privacy

- Music and the journal never leave your devices; there is no cloud.
- Connections between devices are encrypted (Noise over TCP). Pairing requires a one-time secret
  from the QR code; only paired devices are accepted.
- The app collects no statistics.

## Building and installing

Builds run in GitHub Actions (`.github/workflows/ci.yml`):

- `core-tests` — Rust core and bridge tests;
- `android-apk` — analysis, tests and the release APK build;
- `windows-build` — the Windows folder build.

Finished builds are published to Releases under the `latest` tag. The Android build is signed with a
permanent key from the repository secret `HYDRA_KEYSTORE_B64` (the key is not in the repository), so
a new version installs over the old one; before publishing, CI checks the APK signature fingerprint
against this key. In your fork create your own key and a secret with the same name; without the
secret a fork build gets a temporary key.

**Android:** download the `.apk` and install it (allow installing from unknown sources).

**Windows:** download `hydra-music-windows.zip`, unpack it into a writable folder (for example,
`%LOCALAPPDATA%\HydraMusic\app`, so auto-update works) and run `hydra_music.exe`. `hydra_ffi.dll`
must be next to it (it is already in the archive).

Local build: Rust, Flutter and (for Android) the Android SDK are needed. Before building for Android
run `python tools/patch_android_manifest.py`: it adds permissions, services and `hydra://pair` links
to the project. For Windows the same script hides the window until the first frame.

## Repository layout

```
core/     Rust: clocks, operation journal, SQLite, names, order, tags, trash, network and sync
ffi/      C interface of the core for Flutter (hydra_call: JSON -> JSON)
app/      Flutter: Android and Windows interface
bridge/   notes on the Flutter <-> Rust bridge
docs/     architecture and protocol (ARCHITECTURE.md)
tools/    scripts (Android and Windows project setup, local build, translations) and icons
```

Details of the journal, track order and protocol: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
Pre-1.0.0 checklist (Russian): [docs/RELEASE-1.0.md](docs/RELEASE-1.0.md).

## Not done yet

- File transfer speed over the internet: large libraries (hundreds of tracks) are slow.
- Core messages (errors, network log) are still in Russian.

## Changelog

All versions and changes from the first skeleton to now: [CHANGELOG.md](CHANGELOG.md).
Current version: **0.34.0**. Numbering `0.N.M`: `N` — new feature, `M` — fix.

## License

Author: SpiceLNR. The project is distributed under the
[PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0) license:

- you may use, change and make your own versions (forks), including closed ones;
- wherever a copy goes, keep the `LICENSE` file and the “Required Notice” line;
- **you may not sell** the program or derived works or use them commercially.

This is not “open source” in the OSI sense: the source is available, but commercial use is
forbidden. The Noto Sans (Medium) font is distributed under the SIL Open Font License 1.1, its text
is in `app/assets/fonts/OFL.txt`. Other dependencies (Flutter, Rust crates) remain under their own
licenses.
