# Soma.fm — Requirements

Status: **implemented** (v0.1.0, live-verified on Omarchy 4 / Quattro)
Target: Omarchy 4 / Quattro shell (Quickshell plugin API)
Plugin ID: `io.github.joshuaswarren.somafm`
Kind: `panel` + `bar-widget`

## 1. Problem

Listening to internet radio while working means either a browser tab (heavy, gets lost among real tabs) or a full music app (built for libraries, not streams). Nothing on the desktop treats "put a station on and forget about it" as the primary job.

## 2. Goals

- G1: Bar chip opens a small panel listing every Soma.fm station with genre subtitles.
- G2: Live filter over station name and genre; fully keyboard-drivable (arrows move selection, `Enter` plays, `Space` pauses, `Esc` clears/hides) — mouse optional.
- G3: Station list fetched from somafm.com's public channels.json; mp3 stream preferred per channel; `.pls` resolved to a direct icecast mirror at play time so no hostnames are hardcoded.
- G4: Now-playing strip with an animated equalizer, explicit loading/empty/error states, and a retry affordance when the catalog fetch fails.
- G5: Audio keeps streaming when the panel is hidden or the session locks (it is a radio); the panel itself never maps over the lock screen. Stop is an explicit button.
- G6: Volume belongs to the system: the stream runs at unity gain as a normal PipeWire stream, so volume keys and the bar's audio widget behave exactly as for any other app. The panel offers only a mute toggle.

## 3. Non-goals

- No playback queue, favourites, or listening history — Soma.fm is lean-back radio.
- No plugin-side volume slider or persistence (see G6); no system-audio mutation.
- No codec handling of our own: QtMultimedia plays what the icecast mirror serves.

## 4. Security notes

- All fetches run `curl --fail --proto =https` — error pages can't be parsed as data, and redirects cannot downgrade to plaintext.
- Every transfer is bounded by `curl --max-filesize` (2 MiB catalog, 128 KiB playlist, 16 KiB redirect probe) and parsing re-bounds item count (256) and field lengths — a hostile endpoint cannot inflate the keep-loaded shell through either buffering or structure.
- The stream's redirect chain is resolved by the plugin before playback: the final `url_effective` must still pass the somafm.com gate, or playback is refused. The allowlist is never checked only on the initial URL.
- Both the playlist URL from channels.json and the `File1=` value inside a `.pls` are remote-controlled; both are gated through `isSomaUrl()` (https + somafm.com host) before reaching curl or the player. The gate lives in Model.js and is unit-tested.
- Remote strings render with `textFormat: Text.PlainText` — a hostile title cannot inject rich text or image beacons.

## 5. Testing

`node --test tests/model.test.mjs` — 8 tests over parseChannels (playability filter, mp3 preference, sorting), extractStreamUrl (CRLF tolerance, junk rejection), isSomaUrl (host/scheme gating incl. `file://` and lookalike domains), and filterStations.
