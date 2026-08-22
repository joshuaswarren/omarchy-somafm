// Soma.fm Model.js unit tests. Loads the QML-style script (plain function
// declarations, no module syntax) into a fresh vm context, exactly the way
// a non-QML host has to consume it.

import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import vm from "node:vm"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const source = readFileSync(join(root, "Model.js"), "utf8")

const ctx = vm.createContext({})
vm.runInNewContext(
  source +
    "\nthis.M = { isSomaUrl: isSomaUrl, pickPlaylist: pickPlaylist," +
    " parseChannels: parseChannels, extractStreamUrl: extractStreamUrl," +
    " filterStations: filterStations }",
  ctx
)
const M = ctx.M

const sampleChannels = JSON.stringify({
  channels: [
    { id: "groovesalad", title: "Groove Salad", genre: "ambient|chill",
      playlists: [
        { url: "https://api.somafm.com/groovesalad130.pls", format: "aac", quality: "high" },
        { url: "https://api.somafm.com/groovesalad.pls", format: "mp3", quality: "highest" }
      ] },
    { id: "bootliquor", title: "Boot Liquor", genre: "americana",
      playlists: [{ url: "https://api.somafm.com/bootliquor.pls", format: "mp3" }] },
    { id: "broken", title: "No Playlists Here" },
    { id: "emptypls", title: "Empty Playlist Entries",
      playlists: [{}] }
  ]
})

test("parseChannels keeps only playable channels and prefers mp3", () => {
  const out = M.parseChannels(sampleChannels)
  assert.equal(out.length, 2)
  const groove = out.find(s => s.id === "groovesalad")
  assert.ok(groove)
  // mp3 playlist preferred over the first-listed aac one
  assert.equal(groove.plsUrl, "https://api.somafm.com/groovesalad.pls")
  // pipe-separated genre becomes middot for display
  assert.equal(groove.genre, "ambient · chill")
})

test("parseChannels sorts by title", () => {
  const out = M.parseChannels(sampleChannels)
  assert.equal(out.map(s => s.title).join("|"), "Boot Liquor|Groove Salad")
})

test("parseChannels throws on invalid JSON so the caller shows its error state", () => {
  assert.throws(() => M.parseChannels("<html>gateway error</html>"))
})

test("extractStreamUrl reads File1 and upgrades to https", () => {
  const pls = "[playlist]\r\nnumberofentries=3\r\nFile1=http://ice6.somafm.com/groovesalad-128-mp3\r\nTitle1=x\r\nLength1=-1\r\n"
  assert.equal(M.extractStreamUrl(pls), "https://ice6.somafm.com/groovesalad-128-mp3")
})

test("extractStreamUrl returns empty for junk instead of guessing", () => {
  assert.equal(M.extractStreamUrl(""), "")
  assert.equal(M.extractStreamUrl("not a playlist"), "")
})

test("the isSomaUrl gate, not the regex, neutralizes hostile values", () => {
  // per-line capture yields the first File line even with junk after it —
  // documented behaviour; the host gate is what rejects hostile payloads
  const pls = "[playlist]\nFile1=https://x\njunk after\n"
  const url = M.extractStreamUrl(pls)
  assert.equal(url, "https://x")
  assert.equal(M.isSomaUrl(url), false) // the caller's gate rejects it
  assert.equal(M.isSomaUrl(M.extractStreamUrl("File1=file:///etc/passwd")), false)
})

test("isSomaUrl gates to somafm.com hosts over https", () => {
  assert.equal(M.isSomaUrl("https://ice6.somafm.com/x-128-mp3"), true)
  assert.equal(M.isSomaUrl("https://api.somafm.com/x.pls"), true)
  assert.equal(M.isSomaUrl("http://ice6.somafm.com/x"), false) // plaintext rejected pre-upgrade
  assert.equal(M.isSomaUrl("https://somafm.com.evil.test/x"), false)
  assert.equal(M.isSomaUrl("file:///etc/passwd"), false)
  assert.equal(M.isSomaUrl(""), false)
})

test("filterStations matches title or genre, empty filter passes through", () => {
  const stations = [
    { title: "Groove Salad", genre: "ambient · chill" },
    { title: "Boot Liquor", genre: "americana" }
  ]
  assert.equal(M.filterStations(stations, "").length, 2)
  assert.equal(M.filterStations(stations, "groove").length, 1)
  assert.equal(M.filterStations(stations, "AMERICANA").length, 1)
  assert.equal(M.filterStations(stations, "zzz").length, 0)
})

test("parseChannels bounds item count and field lengths", () => {
  const many = { channels: Array.from({ length: 300 }, (_, i) => ({
    id: "s" + i, title: "S" + i, genre: "g",
    playlists: [{ url: "https://api.somafm.com/s" + i + ".pls", format: "mp3" }]
  }))}
  assert.equal(M.parseChannels(JSON.stringify(many)).length, 256)

  const long = JSON.stringify({ channels: [{ id: "x", title: "T".repeat(500), genre: "G".repeat(500),
    playlists: [{ url: "https://api.somafm.com/x.pls", format: "mp3" }] }] })
  const st = M.parseChannels(long)[0]
  assert.equal(st.title.length, 96)
  assert.equal(st.genre.length, 96)
})

test("parseChannels drops non-https or oversized playlist URLs", () => {
  const doc = JSON.stringify({ channels: [
    { id: "a", title: "A", playlists: [{ url: "http://api.somafm.com/a.pls", format: "mp3" }] },
    { id: "b", title: "B", playlists: [{ url: "https://" + "x".repeat(600) + ".pls", format: "mp3" }] },
    { id: "c", title: "C", playlists: [{ url: "https://api.somafm.com/c.pls", format: "mp3" }] }
  ]})
  const out = M.parseChannels(doc)
  assert.equal(out.map(s => s.id).join(""), "c")
})

test("extractStreamUrl refuses oversized values", () => {
  assert.equal(M.extractStreamUrl("File1=https://" + "a".repeat(600)), "")
})
