import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Auto-brightness and True Tone for the Apple Studio Display.
//
// Reads the display's ambient light sensor (an iio device behind its USB HID sensor
// hub), sets brightness through Omarchy's asdcontrol wrapper and the screen's white
// point through hyprsunset. Omarchy's night light shares hyprsunset: while it is on,
// True Tone steps aside.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest?.id || "ruuts.studio-display"
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string manualSignalPath: runtimeDir + "/omarchy-brightness-display.lock"

  // Settings, stored inline on the bar entry in shell.json.
  property bool autoBrightness: true
  property string profile: "balanced"
  property bool trueTone: true
  property string strength: "normal"
  property var entry: ({})

  // Sensor.
  property string sensorDir: ""
  readonly property bool available: sensorDir !== ""
  property var lux: null
  property var ambientK: null

  // Brightness.
  property var applied: null
  property int target: 0
  property bool manualPause: false
  property var manualLux: null

  // True Tone and night light.
  property var nightState: ({ nightLight: false, lastSeenTemp: null, lastProfileTime: null, ownTemp: null })
  readonly property bool nightLight: nightState.nightLight === true
  property int toneTarget: 0
  property string error: ""

  // Night light schedule, kept in hyprsunset.conf.
  readonly property string scheduleConfPath: Quickshell.env("HOME") + "/.config/hypr/hyprsunset.conf"
  property var schedule: ({ enabled: false, start: "21:00", end: "07:00", temperature: 4000 })

  readonly property string summary: {
    if (!available) return "Studio Display not connected"
    var parts = [Math.round(lux || 0) + " lux"]
    if (applied !== null) parts.push(applied + "%")
    if (nightLight) parts.push("night light")
    else if (trueTone && nightState.ownTemp) parts.push(nightState.ownTemp + " K")
    return parts.join(" · ")
  }

  // ---- settings ------------------------------------------------------------

  function findEntry(config) {
    var layout = config?.bar?.layout || {}
    for (var section in layout) {
      var entries = layout[section] || []
      for (var i = 0; i < entries.length; i++)
        if (entries[i]?.id === pluginId) return entries[i]
    }
    return ({})
  }

  function syncSettings() {
    var config = {}
    try { config = JSON.parse(settingsFile.text()) } catch (e) { return }
    var next = findEntry(config)
    entry = next
    var wasAuto = autoBrightness
    var previousProfile = profile
    autoBrightness = next.autoBrightness !== false
    profile = ["dim", "balanced", "bright"].indexOf(next.profile) >= 0 ? next.profile : "balanced"
    // Changing the auto-brightness settings is an explicit request to follow the room again.
    if (manualPause && ((!wasAuto && autoBrightness) || previousProfile !== profile)) resume()
    var wasTrueTone = trueTone
    trueTone = next.trueTone !== false
    strength = ["subtle", "normal", "strong"].indexOf(next.strength) >= 0 ? next.strength : "normal"
    if (wasTrueTone && !trueTone) stopTrueTone()
  }

  function setSetting(key, value) {
    if (!shell) return
    var next = {}
    for (var k in entry) if (k !== "id") next[k] = entry[k]
    next[key] = value
    shell.updateEntryInline(pluginId, next)
  }

  // ---- brightness ----------------------------------------------------------

  function resume() {
    manualPause = false
    manualLux = null
    applied = null
    if (!readBrightness.running) readBrightness.running = true
  }

  function updateBrightness() {
    if (!autoBrightness || lux === null) return
    target = Model.brightnessForLux(lux, profile)

    if (manualPause) {
      // Resume once the room is clearly brighter or darker than when you set it by hand.
      var ratio = (lux + 5) / (manualLux + 5)
      if (ratio >= 2.5 || ratio <= 0.4) resume()
      return
    }
    if (applied === null || setBrightness.running) return

    var next = Model.brightnessStep(applied, target)
    if (next === applied) return
    setBrightness.pending = next
    setBrightness.command = ["omarchy-brightness-display-apple", "--no-osd", next + "%"]
    setBrightness.running = true
  }

  // ---- True Tone -----------------------------------------------------------

  function setTemperature(kelvin) {
    if (setTone.running) {
      setTone.queued = kelvin
      return
    }
    setTone.pending = kelvin
    setTone.command = ["bash", "-c",
      "pgrep -x hyprsunset >/dev/null || { setsid uwsm-app -- hyprsunset >/dev/null 2>&1 & sleep 1; }; "
      + "hyprctl hyprsunset temperature " + Number(kelvin) + " >/dev/null"]
    setTone.running = true
  }

  function updateTrueTone() {
    if (!trueTone || ambientK === null || sunsetRestarting.running) return
    if (!probeTone.running) probeTone.running = true
  }

  function applyObservation(observation) {
    var next = Model.observeHyprsunset(nightState, observation)
    var claim = next.claimNightLight
    delete next.claimNightLight
    if (next.nightLight !== nightState.nightLight || claim)
      console.info("studio-display: night light " + (next.nightLight ? "on" : "off")
        + " at " + observation.temp + " K" + (claim ? " (from the toggle command)" : ""))
    nightState = next
    if (!trueTone) return

    if (claim) {
      // Omarchy's toggle command turned "night light off" to 6500 K because True Tone
      // held another temperature; what you asked for was night light, so apply it.
      setTemperature(Model.NIGHT_ON)
      Quickshell.execDetached(["bash", "-c", "sleep 2; omarchy-shell -q nightlight refresh"])
      return
    }
    if (nightLight) return

    toneTarget = Model.trueToneTarget(ambientK, strength)
    var own = nightState.ownTemp
    // Someone else set the temperature (night light ended, a schedule entry): resync
    // in one go. Otherwise drift toward the target in small steps.
    if (own === null || own === Model.NIGHT_ON || observation.temp !== own) {
      setTemperature(toneTarget)
    } else if (Math.abs(toneTarget - own) >= 100) {
      setTemperature(own + Math.max(-200, Math.min(200, toneTarget - own)))
    }
  }

  function stopTrueTone() {
    if (!nightLight && nightState.ownTemp !== null) {
      setTone.queued = null
      Quickshell.execDetached(["hyprctl", "hyprsunset", "temperature", String(Model.NIGHT_OFF)])
    }
    // Keep what we know about night light; only forget the temperature True Tone set.
    var next = {}
    for (var k in nightState) next[k] = nightState[k]
    next.ownTemp = null
    nightState = next
  }

  // ---- night light ---------------------------------------------------------

  // Through Omarchy's night light service, so its bar indicator stays in step.
  function setNightLight(on) {
    Quickshell.execDetached(["omarchy-shell", "-q", "nightlight", on ? "enable" : "disable"])
    refreshNightLight.restart()
  }

  function toggleNightLight() {
    setNightLight(!nightLight)
  }

  // A waiting True Tone (night light on) takes over; an active one switches off;
  // switching it on ends night light.
  function toggleTrueTone() {
    if (trueTone && nightLight) {
      setNightLight(false)
    } else if (trueTone) {
      setSetting("trueTone", false)
    } else {
      setSetting("trueTone", true)
      if (nightLight) setNightLight(false)
    }
  }

  // A paused auto-brightness resumes; otherwise switch it on or off.
  function toggleAutoBrightness() {
    if (autoBrightness && manualPause) resume()
    else setSetting("autoBrightness", !autoBrightness)
  }

  function setSchedule(changes) {
    var next = {}
    for (var k in schedule) next[k] = schedule[k]
    for (var c in changes) next[c] = changes[c]
    schedule = next
    writeSchedule.restart()
  }

  // ---- sensor --------------------------------------------------------------

  function tick() {
    luxFile.reload()
    colorFile.reload()
    var luxRaw = parseFloat(luxFile.text())
    var colorRaw = parseFloat(colorFile.text())
    if (isNaN(luxRaw)) {
      sensorLost()
      return
    }
    // The sensor reports milli-lux.
    lux = Model.ema(lux, luxRaw / 1000, 0.3)
    // Below a few lux the colour reading is noise; keep the last one.
    if (!isNaN(colorRaw) && colorRaw > 0 && lux >= 5) ambientK = Model.ema(ambientK, colorRaw, 0.15)

    updateBrightness()
    updateTrueTone()
  }

  function sensorLost() {
    sensorDir = ""
    lux = null
    applied = null
  }

  Process {
    id: discover
    // The display's sensor hub shows up as an iio "als" device on its USB interface.
    command: ["bash", "-c",
      "touch \"$XDG_RUNTIME_DIR/omarchy-brightness-display.lock\"; "
      + "for d in /sys/bus/iio/devices/iio:device*; do "
      + "[[ $(cat \"$d/name\" 2>/dev/null) == als ]] || continue; "
      + "[[ $(readlink -f \"$d\") == *05AC:1114* ]] && { echo \"$d\"; break; }; done"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var dir = String(text).trim()
        if (dir === "") return
        root.sensorDir = dir
        if (!readBrightness.running) readBrightness.running = true
      }
    }
  }

  Timer {
    interval: 10000
    repeat: true
    triggeredOnStart: true
    running: !root.available
    onTriggered: if (!discover.running) discover.running = true
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.available && (root.autoBrightness || root.trueTone)
    onTriggered: root.tick()
  }

  FileView {
    id: luxFile
    path: root.available ? root.sensorDir + "/in_illuminance_raw" : ""
    blockLoading: true
    printErrors: false
  }

  FileView {
    id: colorFile
    path: root.available ? root.sensorDir + "/in_colortemp_raw" : ""
    blockLoading: true
    printErrors: false
  }

  // omarchy-brightness-display opens this lock file for every change it makes: the
  // brightness keys and Omarchy's monitor panel. This plugin calls the Apple script
  // directly, so a change here always means a change by hand.
  FileView {
    path: root.manualSignalPath
    watchChanges: true
    printErrors: false
    onFileChanged: {
      reload()
      if (!root.autoBrightness || root.lux === null) return
      root.manualPause = true
      root.manualLux = root.lux
      // The lock is taken before the change is written; read the result a moment later.
      manualRead.restart()
    }
  }

  Timer {
    id: manualRead
    interval: 1000
    onTriggered: if (!readBrightness.running) readBrightness.running = true
  }

  Process {
    id: readBrightness
    command: ["omarchy-brightness-display-apple"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = parseInt(String(text).trim())
        if (!isNaN(value)) root.applied = value
      }
    }
  }

  Process {
    id: setBrightness
    property var pending: null
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.applied = pending
        root.error = ""
      } else {
        root.error = "Could not set the brightness"
        root.applied = null
        if (!readBrightness.running) readBrightness.running = true
      }
    }
  }

  Process {
    id: probeTone
    command: ["bash", "-c", "hyprctl hyprsunset temperature; echo ---; hyprctl hyprsunset profile"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parts = String(text).split("---")
        var temp = Model.parseTemperature(parts[0])
        if (temp === null) {
          if (!root.trueTone || sunsetRestarting.running) return
          // hyprsunset is not running yet; start it with the current target.
          root.toneTarget = Model.trueToneTarget(root.ambientK, root.strength)
          root.setTemperature(root.toneTarget)
          return
        }
        var profile = Model.parseProfile(parts[1])
        root.applyObservation({
          temp: temp,
          profileTime: profile.time,
          profileIdentity: profile.identity,
          profileTemp: profile.temperature
        })
      }
    }
  }

  Process {
    id: setTone
    property var pending: null
    property var queued: null
    onExited: function(exitCode) {
      if (exitCode === 0 && pending !== null) {
        var next = {}
        for (var k in root.nightState) next[k] = root.nightState[k]
        next.ownTemp = pending
        root.nightState = next
      }
      pending = null
      if (queued !== null) {
        var kelvin = queued
        queued = null
        root.setTemperature(kelvin)
      }
    }
  }

  // Night light state for the panel while True Tone (which polls it) is off.
  Timer {
    id: refreshNightLight
    interval: 1500
    onTriggered: if (!probeTone.running) probeTone.running = true
  }

  function refreshNow() {
    if (!probeTone.running) probeTone.running = true
  }

  // Wait for a pause in edits, then write the file and restart hyprsunset to apply it.
  Timer {
    id: writeSchedule
    interval: 1200
    onTriggered: {
      scheduleFile.setText(Model.scheduleConf(root.schedule))
      sunsetRestarting.restart()
      // Like omarchy-restart-hyprsunset, but wait for the old instance to let go of its
      // socket first; otherwise the new one can exit right away.
      Quickshell.execDetached(["bash", "-c",
        "pkill -x hyprsunset; for i in $(seq 50); do pgrep -x hyprsunset >/dev/null || break; sleep 0.1; done; "
        + "setsid uwsm-app -- hyprsunset >/dev/null 2>&1"])
    }
  }

  // Leave hyprsunset alone while it restarts, so True Tone doesn't start a second one.
  Timer {
    id: sunsetRestarting
    interval: 3000
  }

  FileView {
    id: scheduleFile
    path: root.scheduleConfPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.schedule = Model.parseSchedule(text())
  }

  // omarchy-shell studio-display <method> [args], e.g. for keybindings.
  IpcHandler {
    target: "studio-display"

    function status(): string {
      return JSON.stringify({
        available: root.available, lux: root.lux, ambientK: root.ambientK,
        brightness: root.applied, target: root.target, manualPause: root.manualPause,
        autoBrightness: root.autoBrightness, profile: root.profile,
        trueTone: root.trueTone, strength: root.strength, screenK: root.nightState.ownTemp,
        nightLight: root.nightLight, schedule: root.schedule
      })
    }
    function toggleAutoBrightness(): void { root.toggleAutoBrightness() }
    function toggleTrueTone(): void { root.toggleTrueTone() }
    function toggleNightLight(): void { root.toggleNightLight() }
    function resume(): void { root.resume() }
    function setSchedule(enabled: string, start: string, end: string): string {
      if (!/^\d{2}:\d{2}$/.test(start) || !/^\d{2}:\d{2}$/.test(end)) return "times must be HH:MM"
      root.setSchedule({ enabled: enabled === "true", start: start, end: end })
      return "ok"
    }
  }

  FileView {
    id: settingsFile
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.syncSettings()
  }
}
