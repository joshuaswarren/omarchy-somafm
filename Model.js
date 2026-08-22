// Pure data logic for the Soma.fm radio panel: channels.json parsing,
// mp3-playlist selection, .pls stream extraction, somafm.com URL gating,
// and station filtering. Plain script, no module syntax: the same file
// loads as a QML JavaScript resource for the panel and runs under node:vm
// for unit tests.

// Both the playlist URL from channels.json and the stream URL inside a .pls
// are remote-controlled, so everything that reaches curl or the player must
// be an https URL on a somafm.com host (ice mirrors included).
function isSomaUrl(url) {
  return /^https:\/\/([a-z0-9\-]+\.)?somafm\.com\//.test(String(url || ""))
}

// Pick the mp3 playlist when the channel offers one (broadest player
// compatibility), otherwise fall back to whatever the channel lists first.
function pickPlaylist(playlists) {
  if (!playlists || playlists.length === 0) return null
  var best = null
  for (var i = 0; i < playlists.length; i++) {
    var pl = playlists[i]
    if (!pl || !pl.url) continue
    if (best === null) best = pl
    if (pl.format === "mp3") { best = pl; break }
  }
  return best
}

// Parse the channels.json document into the panel's station shape, sorted
// by title. Throws on invalid JSON so the caller can show its error state.
function parseChannels(jsonText) {
  var doc = JSON.parse(jsonText)
  var out = []
  var channels = doc.channels || []
  for (var i = 0; i < channels.length; i++) {
    var c = channels[i]
    if (!c.playlists || c.playlists.length === 0) continue
    var pl = pickPlaylist(c.playlists)
    if (!pl) continue
    out.push({
      id: String(c.id),
      title: String(c.title),
      genre: String(c.genre || "").replace(/\|/g, " · "),
      listeners: String(c.listeners || ""),
      plsUrl: String(pl.url)
    })
  }
  out.sort(function(a, b) { return a.title.localeCompare(b.title) })
  return out
}

// Extract one direct stream URL from a .pls document. Per-line bare-URL
// capture (tolerating CRLF); any value that is not a bare token cannot
// match. Callers must still gate the result through isSomaUrl — that gate,
// not this regex, is what neutralizes file:// or foreign hosts.
function extractStreamUrl(plsText) {
  var m = String(plsText || "").match(/^File\d+=(\S+)\r?$/m)
  if (!m) return ""
  return m[1].replace(/^http:\/\//, "https://")
}

// Filter stations by substring against title and genre. Empty filter
// returns the full list (same order).
function filterStations(stations, filterText) {
  var f = String(filterText || "").toLowerCase()
  if (f === "") return stations
  var out = []
  for (var i = 0; i < stations.length; i++) {
    var s = stations[i]
    if (s.title.toLowerCase().indexOf(f) >= 0 || s.genre.toLowerCase().indexOf(f) >= 0) out.push(s)
  }
  return out
}
