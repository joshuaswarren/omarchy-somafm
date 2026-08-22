import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtMultimedia
import qs.Commons

// Soma.fm panel entry point.
// Hosted by omarchy-shell; summoned with:
//   omarchy-shell shell toggle io.github.joshuaswarren.somafm
// Optional payload: {"station":"groovesalad"} plays that station id directly.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.joshuaswarren.somafm"
  readonly property color background: Color.background
  readonly property color foreground: Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color muted: foreground

  function tint(a) { return Qt.rgba(root.accent.r, root.accent.g, root.accent.b, a) }

  // ---- state ----
  property bool opened: false
  property bool loadingStations: false
  property string playState: "idle" // idle | connecting | playing | error
  property string statusText: ""
  property var stations: []
  property string filterText: ""
  property bool audioMuted: false
  property string currentTitle: ""
  property string currentGenre: ""
  property string pendingStationId: ""

  readonly property bool isPlaying: root.playState === "playing"
    && player.playbackState === MediaPlayer.PlayingState

  // First-party lock service: the panel must never map over the lock screen.
  // Audio deliberately keeps playing while locked (it is a radio).
  property var lockService: null
  readonly property bool sessionLocked: lockService !== null && lockService.locked === true

  Timer {
    id: lockServiceResolve
    interval: 1000
    repeat: true
    running: true
    onTriggered: {
      if (root.lockService !== null) { lockServiceResolve.stop(); return }
      if (root.shell && typeof root.shell.serviceFor === "function") {
        var ls = root.shell.serviceFor("omarchy.lock")
        if (ls !== null && ls !== undefined) root.lockService = ls
      }
    }
  }

  MediaPlayer {
    id: player
    audioOutput: AudioOutput {
      id: audio
      // Unity gain, no plugin volume control: PipeWire already owns per-stream
      // volume and WirePlumber persists it per application (module-stream-
      // restore). A second gain stage here just multiplies into whatever the
      // user already set.
      muted: root.audioMuted
    }
    onMediaStatusChanged: function(status) {
      if (status === MediaPlayer.BufferedMedia || status === MediaPlayer.BufferingMedia) {
        if (root.playState === "connecting") root.playState = "playing"
      } else if (status === MediaPlayer.InvalidMedia) {
        root.playState = "error"
        root.statusText = "Stream unavailable — try another station"
      }
    }
    onErrorOccurred: function(error) {
      root.playState = "error"
      root.statusText = "Playback error: " + (player.errorString || error)
    }
  }

  // ---- lifecycle ----
  function open(payloadJson) {
    root.opened = true
    if (root.stations.length === 0 && !root.loadingStations) loadStations()
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.station) {
      root.pendingStationId = String(payload.station)
      playPendingIfPossible()
    }
  }

  function close() { root.opened = false }

  // Audio keeps playing when the window is hidden (it is a radio); the stop
  // button is the way to actually end playback.
  function stop() {
    player.stop()
    player.source = ""
    root.playState = "idle"
    root.statusText = ""
    root.currentTitle = ""
    root.currentGenre = ""
  }

  function togglePause() {
    if (!player.source || String(player.source) === "") return
    if (player.playbackState === MediaPlayer.PlayingState) player.pause()
    else player.play()
  }

  // ---- station list ----
  function loadStations() {
    root.loadingStations = true
    root.statusText = ""
    fetchProcess.running = true
  }

  Process {
    id: fetchProcess
    running: false
    // --fail rejects error pages; --proto pinning means a redirect can never
    // downgrade the station list to plaintext.
    command: ["curl", "-s", "--fail", "--proto", "=https", "--max-time", "10",
      "https://somafm.com/channels.json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loadingStations = false
        try {
          var doc = JSON.parse(String(text || ""))
          var out = []
          for (var i = 0; i < doc.channels.length; i++) {
            var c = doc.channels[i]
            if (!c.playlists || c.playlists.length === 0) continue
            var pl = c.playlists[0]
            for (var j = 0; j < c.playlists.length; j++)
              if (c.playlists[j].format === "mp3") { pl = c.playlists[j]; break }
            out.push({
              id: String(c.id),
              title: String(c.title),
              genre: String(c.genre || "").replace(/\|/g, " · "),
              listeners: String(c.listeners || ""),
              plsUrl: String(pl.url)
            })
          }
          out.sort(function(a, b) { return a.title.localeCompare(b.title) })
          root.stations = out
          if (out.length === 0) {
            root.playState = "error"
            root.statusText = "Soma.fm returned no stations"
          } else {
            root.playPendingIfPossible()
          }
        } catch (e) {
          root.playState = "error"
          root.statusText = "Could not reach somafm.com"
        }
      }
    }
  }

  function playPendingIfPossible() {
    if (root.pendingStationId === "" || root.stations.length === 0) return
    for (var i = 0; i < root.stations.length; i++) {
      if (root.stations[i].id === root.pendingStationId) {
        root.pendingStationId = ""
        playStation(root.stations[i])
        return
      }
    }
    root.pendingStationId = ""
  }

  function visibleStations() {
    if (root.filterText === "") return root.stations
    var f = root.filterText.toLowerCase()
    var out = []
    for (var i = 0; i < root.stations.length; i++) {
      var s = root.stations[i]
      if (s.title.toLowerCase().indexOf(f) >= 0 || s.genre.toLowerCase().indexOf(f) >= 0) out.push(s)
    }
    return out
  }

  // .pls files point at rotating icecast mirrors; resolve one direct stream
  // URL per play instead of hardcoding hostnames. Both the playlist URL and
  // the stream URL inside it are remote-controlled, so both are gated to
  // https://somafm.com hosts before anything is fetched or played.
  readonly property var somaHost: /^https:\/\/([a-z0-9\-]+\.)?somafm\.com\//

  function playStation(s) {
    if (!root.somaHost.test(s.plsUrl)) {
      root.playState = "error"
      root.statusText = "Rejected non-Soma.fm playlist URL"
      return
    }
    plsFetch.command = ["curl", "-s", "--fail", "--proto", "=https", "--max-time", "10", s.plsUrl]
    plsFetch.running = true
    root.currentTitle = s.title
    root.currentGenre = s.genre
    root.playState = "connecting"
    root.statusText = ""
  }

  Process {
    id: plsFetch
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // End-anchored capture: a bare URL with no whitespace, gated to a
        // somafm.com host after the TLS upgrade. Anything else is dropped.
        var m = String(text || "").match(/^File\d+=(\S+)\s*$/m)
        var url = m ? m[1].replace(/^http:\/\//, "https://") : ""
        if (url !== "" && root.somaHost.test(url)) {
          player.stop()
          player.source = url
          player.play()
        } else {
          root.playState = "error"
          root.statusText = "Could not resolve a Soma.fm stream"
        }
      }
    }
  }

  // ---- window position (drag header; persisted) ----
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME")
    || (Quickshell.env("HOME") + "/.local/state")) + "/somafm"
  property int marginRight: 14
  property int marginBottom: 14

  function clampMargins() {
    var w = window && window.screen ? window.screen.width : 0
    var h = window && window.screen ? window.screen.height : 0
    if (w > 0) root.marginRight = Math.max(0, Math.min(root.marginRight, w - window.width))
    if (h > 0) root.marginBottom = Math.max(0, Math.min(root.marginBottom, h - window.height))
  }

  // The state file holds window position only: volume is not ours to own.
  // PipeWire/WirePlumber manage and persist per-stream volume.
  function savePosition() {
    posSave.right = "" + Math.round(root.marginRight)
    posSave.bottom = "" + Math.round(root.marginBottom)
    posSave.running = true
  }

  Process {
    id: posSave
    property string right: "14"
    property string bottom: "14"
    running: false
    command: ["sh", "-c",
      "mkdir -p '" + root.stateDir
      + "' && printf '{\"right\":%s,\"bottom\":%s}' "
      + posSave.right + " " + posSave.bottom
      + " > '" + root.stateDir + "/window.json'"]
  }

  FileView {
    id: positionFile
    path: root.stateDir + "/window.json"
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var doc = JSON.parse(text())
        if (doc.right !== undefined) root.marginRight = Math.max(0, doc.right | 0)
        if (doc.bottom !== undefined) root.marginBottom = Math.max(0, doc.bottom | 0)
      } catch (e) { /* first run */ }
    }
  }

  Component.onCompleted: positionFile.reload()

  // ---- window ----
  PanelWindow {
    id: window
    visible: root.opened && !root.sessionLocked
    anchors { top: false; left: false; right: true; bottom: true }
    margins { right: root.marginRight; bottom: root.marginBottom }
    implicitWidth: 344
    implicitHeight: 438
    color: root.background
    WlrLayershell.namespace: "somafm"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore

    Column {
      anchors.fill: parent
      anchors.margins: 1
      spacing: 0

      // ---- header ----
      Rectangle {
        width: parent.width
        height: 40
        color: root.background

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.SizeAllCursor
          property int sx: 0
          property int sy: 0
          property int sr: 0
          property int sb: 0
          onPressed: function(mouse) { sx = mouse.x; sy = mouse.y; sr = root.marginRight; sb = root.marginBottom }
          onPositionChanged: function(mouse) {
            if (!pressed) return
            root.marginRight = sr - (mouse.x - sx)
            root.marginBottom = sb - (mouse.y - sy)
            root.clampMargins()
          }
          onReleased: root.savePosition()
        }

        Row {
          anchors.left: parent.left
          anchors.leftMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          spacing: 8

          Text {
            anchors.verticalCenter: parent.verticalCenter
            color: root.accent
            text: "󰐋"
            font.pixelSize: 15
            font.family: Style.fontFamily
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            color: root.foreground
            text: "Soma.fm"
            font.pixelSize: 13
            font.family: Style.fontFamily
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            color: root.muted
            opacity: 0.45
            font.pixelSize: 11
            font.family: Style.fontFamily
            text: root.stations.length > 0 ? root.stations.length + " stations" : ""
          }
        }

        Row {
          anchors.right: parent.right
          anchors.rightMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          spacing: 16

          // stop — only meaningful while something is loaded
          Text {
            color: root.urgent
            opacity: root.playState === "playing" || root.playState === "connecting" ? 1 : 0.25
            text: "󰓛"
            font.pixelSize: 15
            font.family: Style.fontFamily
            Behavior on opacity { NumberAnimation { duration: 120 } }
            MouseArea {
              anchors.fill: parent
              anchors.margins: -4
              cursorShape: Qt.PointingHandCursor
              onClicked: root.stop()
            }
          }

          // mute — volume itself belongs to the system (PipeWire), this is
          // just stream silence from the panel
          Text {
            color: root.audioMuted ? root.urgent : root.foreground
            opacity: player.source && String(player.source) !== "" ? 1 : 0.25
            text: root.audioMuted ? "󰖁" : "󰕾"
            font.pixelSize: 15
            font.family: Style.fontFamily
            Behavior on opacity { NumberAnimation { duration: 120 } }
            MouseArea {
              anchors.fill: parent
              anchors.margins: -4
              cursorShape: Qt.PointingHandCursor
              onClicked: root.audioMuted = !root.audioMuted
            }
          }
          Text {
            color: root.foreground
            opacity: player.source && String(player.source) !== "" ? 1 : 0.25
            text: root.isPlaying ? "󰏤" : "󰐊"
            font.pixelSize: 15
            font.family: Style.fontFamily
            Behavior on opacity { NumberAnimation { duration: 120 } }
            MouseArea {
              anchors.fill: parent
              anchors.margins: -4
              cursorShape: Qt.PointingHandCursor
              onClicked: root.togglePause()
            }
          }

          Text {
            color: root.foreground
            text: "󰅖"
            font.pixelSize: 16
            font.family: Style.fontFamily
            MouseArea {
              anchors.fill: parent
              anchors.margins: -4
              cursorShape: Qt.PointingHandCursor
              onClicked: root.close()
            }
          }
        }
      }

      Rectangle { width: parent.width; height: 1; color: root.accent; opacity: 0.35 }

      // ---- now playing / status strip ----
      Rectangle {
        width: parent.width
        height: root.playState === "idle" ? 0 : 52
        visible: height > 0
        color: root.playState === "error" ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.12) : root.tint(0.10)

        Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        // three-bar equalizer: alive while playing, still when paused
        Row {
          id: eq
          anchors.left: parent.left
          anchors.leftMargin: 14
          anchors.verticalCenter: parent.verticalCenter
          spacing: 3
          visible: root.playState !== "error"

          Repeater {
            model: [0, 130, 260]
            delegate: Rectangle {
              required property var modelData
              width: 3
              radius: 1.5
              color: root.accent
              height: 7
              anchors.verticalCenter: parent.verticalCenter

              SequentialAnimation on height {
                running: root.isPlaying
                loops: Animation.Infinite
                PauseAnimation { duration: modelData }
                NumberAnimation { to: 17; duration: 380; easing.type: Easing.InOutSine }
                NumberAnimation { to: 6; duration: 380; easing.type: Easing.InOutSine }
              }
            }
          }
        }

        Column {
          anchors.left: eq.right
          anchors.leftMargin: 12
          anchors.right: parent.right
          anchors.rightMargin: 14
          anchors.verticalCenter: parent.verticalCenter
          spacing: 2

          Text {
            width: parent.width
            elide: Text.ElideRight
            textFormat: Text.PlainText
            color: root.playState === "error" ? root.urgent : root.foreground
            font.pixelSize: 13
            font.family: Style.fontFamily
            text: {
              if (root.playState === "error") return root.statusText
              if (root.playState === "connecting") return "Connecting to " + root.currentTitle + "…"
              return root.currentTitle
            }
          }

          Text {
            width: parent.width
            elide: Text.ElideRight
            visible: text !== ""
            textFormat: Text.PlainText
            color: root.muted
            opacity: 0.55
            font.pixelSize: 11
            font.family: Style.fontFamily
            text: {
              if (root.playState === "error") return "Pick another station below"
              if (root.playState === "playing" && !root.isPlaying) return "Paused · " + root.currentGenre
              return root.currentGenre
            }
          }
        }
      }

      // ---- filter ----
      Item {
        width: parent.width
        height: 40

        Rectangle {
          anchors.centerIn: parent
          width: parent.width - 24
          height: 30
          radius: Style.cornerRadius
          color: root.background
          border.color: filterInput.activeFocus ? root.accent : root.muted
          border.width: 1
          opacity: filterInput.activeFocus ? 1 : 0.55

          Behavior on opacity { NumberAnimation { duration: 120 } }

          Text {
            id: searchGlyph
            anchors.left: parent.left
            anchors.leftMargin: 9
            anchors.verticalCenter: parent.verticalCenter
            color: root.muted
            opacity: 0.6
            text: "󰍉"
            font.pixelSize: 12
            font.family: Style.fontFamily
          }

          TextInput {
            id: filterInput
            anchors.left: searchGlyph.right
            anchors.leftMargin: 8
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            height: parent.height - 8
            color: root.foreground
            selectionColor: root.accent
            font.pixelSize: 12
            font.family: Style.fontFamily
            clip: true
            verticalAlignment: TextInput.AlignVCenter
            onTextChanged: root.filterText = text
            Keys.onEscapePressed: { if (text !== "") text = ""; else root.close() }

            Text {
              visible: filterInput.text === "" && !filterInput.activeFocus
              anchors.fill: parent
              verticalAlignment: Text.AlignVCenter
              color: root.muted
              opacity: 0.5
              font.pixelSize: 12
              font.family: Style.fontFamily
              text: "Filter by name or genre"
            }
          }
        }
      }

      // ---- station list / states ----
      Item {
        width: parent.width
        height: parent.height - 40 - 1 - (root.playState === "idle" ? 0 : 52) - 40 - 14

        // loading
        Text {
          anchors.centerIn: parent
          visible: root.loadingStations
          color: root.muted
          font.pixelSize: 12
          font.family: Style.fontFamily
          text: "Loading stations…"
          SequentialAnimation on opacity {
            running: root.loadingStations
            loops: Animation.Infinite
            NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0.9; duration: 700; easing.type: Easing.InOutSine }
          }
        }

        // empty filter result
        Column {
          anchors.centerIn: parent
          spacing: 6
          visible: !root.loadingStations && root.stations.length > 0 && list.count === 0
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            color: root.muted
            opacity: 0.7
            font.pixelSize: 12
            font.family: Style.fontFamily
            text: "No station matches “" + root.filterText + "”"
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            color: root.accent
            opacity: 0.8
            font.pixelSize: 11
            font.family: Style.fontFamily
            text: "Clear filter"
            MouseArea {
              anchors.fill: parent
              anchors.margins: -6
              cursorShape: Qt.PointingHandCursor
              onClicked: filterInput.text = ""
            }
          }
        }

        // failed station list — offer a retry
        Column {
          anchors.centerIn: parent
          spacing: 6
          visible: !root.loadingStations && root.stations.length === 0 && root.playState === "error"
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            color: root.accent
            opacity: 0.85
            font.pixelSize: 12
            font.family: Style.fontFamily
            text: "Retry"
            MouseArea {
              anchors.fill: parent
              anchors.margins: -8
              cursorShape: Qt.PointingHandCursor
              onClicked: root.loadStations()
            }
          }
        }

        ListView {
          id: list
          anchors.fill: parent
          clip: true
          visible: !root.loadingStations
          model: root.visibleStations()
          currentIndex: -1
          boundsBehavior: Flickable.StopAtBounds

          delegate: Item {
            id: stationRow
            required property var modelData
            width: ListView.view.width
            height: 42

            readonly property bool current: modelData.title === root.currentTitle

            Rectangle {
              anchors.fill: parent
              anchors.leftMargin: 8
              anchors.rightMargin: 8
              anchors.topMargin: 1
              anchors.bottomMargin: 1
              radius: Style.cornerRadius
              color: rowMouse.containsPress ? root.tint(0.30)
                : (stationRow.current ? root.tint(0.16)
                  : (rowMouse.containsMouse ? root.tint(0.07) : "transparent"))

              Behavior on color { ColorAnimation { duration: 110 } }

              // playing marker
              Rectangle {
                anchors.left: parent.left
                anchors.leftMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                width: 2
                height: stationRow.current ? 20 : 0
                radius: 1
                color: root.accent
                Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
              }

              Column {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  color: stationRow.current ? root.accent : root.foreground
                  font.pixelSize: 13
                  font.family: Style.fontFamily
                  text: modelData.title
                }

                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  visible: modelData.genre !== ""
                  textFormat: Text.PlainText
                  color: root.muted
                  opacity: 0.5
                  font.pixelSize: 10
                  font.family: Style.fontFamily
                  text: modelData.genre
                }
              }
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.playStation(modelData)
            }
          }
        }
      }
    }
  }
}
