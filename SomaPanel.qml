import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtMultimedia
import qs.Commons

// Soma.fm panel entry point.
// Hosted by omarchy-shell; summoned with:
//   omarchy-shell shell toggle io.github.joshuaswarren.somafm
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

  // ---- state ----
  property bool opened: false
  property bool loadingStations: false
  property string playState: "idle" // idle | playing | error
  property string statusText: ""
  property var stations: []
  property string filterText: ""
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
      volume: 0.9
    }
    onMediaStatusChanged: function(status) {
      if (status === MediaPlayer.InvalidMedia) {
        root.playState = "error"
        root.statusText = "Stream error — try another station"
        root.currentTitle = ""
      }
    }
    onErrorOccurred: function(error) {
      root.playState = "error"
      root.statusText = "Playback error: " + (player.errorString || error)
      root.currentTitle = ""
    }
  }

  function open() {
    root.opened = true
    if (root.stations.length === 0 && !root.loadingStations) loadStations()
  }

  function close() {
    root.opened = false
  }

  // Audio keeps playing when hidden (same contract as YT Mini).
  function stop() {
    player.stop()
    player.source = ""
    root.playState = "idle"
    root.statusText = ""
  }

  // ---- station list ----
  function loadStations() {
    root.loadingStations = true
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
              genre: String(c.genre || ""),
              plsUrl: String(pl.url)
            })
          }
          out.sort(function(a, b) { return a.title.localeCompare(b.title) })
          root.stations = out
          if (root.stations.length === 0) root.statusText = "Soma.fm returned no stations"
        } catch (e) {
          root.statusText = "Could not load station list"
        }
      }
    }
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
    root.statusText = "Connecting…"
  }

  Process {
    id: plsFetch
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // End-anchored capture: the value must be a bare https/http URL with
        // no whitespace, and it must resolve to a somafm.com host after the
        // TLS upgrade. Anything else (file://, ftp://, foreign host) is dropped.
        var m = String(text || "").match(/^File\d+=(\S+)$/m)
        var url = m ? m[1].replace(/^http:\/\//, "https://") : ""
        if (url !== "" && root.somaHost.test(url)) {
          player.stop()
          player.source = url
          root.playState = "playing"
          root.statusText = ""
          player.play()
        } else {
          root.playState = "error"
          root.statusText = "Could not resolve a Soma.fm stream"
        }
      }
    }
  }

  property string currentTitle: ""

  // ---- window ----
  PanelWindow {
    id: window
    visible: root.opened && !root.sessionLocked
    anchors { top: false; left: false; right: true; bottom: true }
    margins { right: 14; bottom: 14 }
    width: 340
    height: 460
    color: root.background
    WlrLayershell.namespace: "somafm"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore

    Keys.onEscapePressed: root.close()

    Column {
      anchors.fill: parent
      anchors.margins: 1
      spacing: 0

      // header
      Rectangle {
        width: parent.width
        height: 34
        color: root.background

        MouseArea {
          id: headerDrag
          property int sx: 0
          property int sy: 0
          property int sr: 14
          property int sb: 14
          anchors.fill: parent
          cursorShape: Qt.SizeAllCursor
          onPressed: function(mouse) { sx = mouse.x; sy = mouse.y; sr = window.margins.right; sb = window.margins.bottom }
          onPositionChanged: function(mouse) {
            if (!pressed) return
            window.margins.right = Math.max(0, Math.min(sr - (mouse.x - sx), window.screen.width - window.width))
            window.margins.bottom = Math.max(0, Math.min(sb - (mouse.y - sy), window.screen.height - window.height))
          }
        }

        Text {
          anchors.left: parent.left
          anchors.leftMargin: 10
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - 120
          elide: Text.ElideRight
          textFormat: Text.PlainText
          color: root.playState === "error" ? root.urgent : root.foreground
          text: {
            if (root.playState === "error") return root.statusText
            if (root.playState === "playing") return root.currentTitle
            return root.statusText !== "" ? root.statusText : "Soma.fm"
          }
          font.pixelSize: 13
          font.family: Style.fontFamily
        }

        Row {
          anchors.right: parent.right
          anchors.rightMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          spacing: 18

          Text {
            color: root.foreground
            opacity: root.playState === "playing" ? 1 : 0.4
            text: root.playState === "playing" ? "󰐎" : "󰐊"
            font.pixelSize: 15
            font.family: Style.fontFamily
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (!player.source) return
                if (player.playbackState === MediaPlayer.PlayingState) player.pause()
                else player.play()
              }
            }
          }

          Text {
            color: root.foreground
            text: "󰅖"
            font.pixelSize: 16
            font.family: Style.fontFamily
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.close()
            }
          }
        }
      }

      Rectangle { width: parent.width; height: 1; color: root.accent; opacity: 0.35 }

      // filter box
      Rectangle {
        width: parent.width - 20
        x: 10
        height: 30
        radius: Style.cornerRadius
        color: root.background
        border.color: filterInput.activeFocus ? root.accent : root.muted
        border.width: 1
        opacity: 0.9

        TextInput {
          id: filterInput
          anchors.fill: parent
          anchors.margins: 7
          color: root.foreground
          selectionColor: root.accent
          font.pixelSize: 12
          font.family: Style.fontFamily
          clip: true
          verticalAlignment: TextInput.AlignVCenter
          onTextChanged: root.filterText = text

          Text {
            visible: filterInput.text === "" && !filterInput.activeFocus
            anchors.fill: parent
            anchors.margins: 7
            verticalAlignment: Text.AlignVCenter
            color: root.muted
            opacity: 0.6
            font.pixelSize: 12
            font.family: Style.fontFamily
            text: "Filter stations…"
          }
        }
      }

      // station list
      ListView {
        width: parent.width
        height: parent.height - 34 - 1 - 30 - 40
        clip: true
        model: root.visibleStations()
        delegate: Rectangle {
          width: ListView.view.width
          height: 30
          color: rowMouse.containsPress
            ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.32)
            : (modelData.title === root.currentTitle
              ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
              : (rowMouse.containsMouse ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.08) : "transparent"))

          Behavior on color { ColorAnimation { duration: 100 } }

          Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.right: parent.right
            anchors.rightMargin: 12
            spacing: 8
            Text {
              width: parent.width - parent.spacing - genreLabel.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              color: modelData.title === root.currentTitle ? root.accent : root.foreground
              font.pixelSize: 13
              font.family: Style.fontFamily
              text: modelData.title
            }
            Text {
              id: genreLabel
              textFormat: Text.PlainText
              color: root.muted
              opacity: 0.55
              font.pixelSize: 11
              font.family: Style.fontFamily
              text: modelData.genre
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

      // volume bar
      Item {
        width: parent.width
        height: 40

        Rectangle {
          id: volBar
          anchors.left: parent.left
          anchors.right: volPct.left
          anchors.top: parent.top
          anchors.topMargin: 16
          anchors.leftMargin: 14
          anchors.rightMargin: 8
          height: 6
          radius: 3
          color: root.muted
          opacity: 0.25

          Rectangle {
            width: parent.width * audio.volume
            height: parent.height
            radius: 3
            color: root.accent
          }

          MouseArea {
            anchors.fill: parent
            anchors.margins: -4
            cursorShape: Qt.PointingHandCursor
            function setVol(x) { audio.volume = Math.max(0, Math.min(1, x / width)) }
            onPressed: function(mouse) { setVol(mouse.x) }
            onPositionChanged: function(mouse) { if (pressed) setVol(mouse.x) }
          }
        }

        Text {
          id: volPct
          anchors.right: parent.right
          anchors.rightMargin: 14
          anchors.verticalCenter: volBar.verticalCenter
          color: root.muted
          font.pixelSize: 11
          font.family: Style.fontFamily
          text: Math.round(audio.volume * 100) + "%"
        }
      }
    }
  }
}
