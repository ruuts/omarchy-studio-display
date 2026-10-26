// Pure logic for ruuts.studio-display, shared by Service.qml and test.cjs.

// Omarchy's night light: on below 6000 K (NightlightModel.js), off is 6500 K, on is 4000 K
// (bin/omarchy-toggle-nightlight).
var NIGHT_THRESHOLD = 6000
var NIGHT_OFF = 6500
var NIGHT_ON = 4000

// Room light (lux) to display brightness (%), interpolated on a log scale.
var CURVE_LUX = [0, 10, 50, 100, 200, 400, 800, 1500, 3000, 5000]
var CURVE_PCT = [10, 20, 35, 45, 55, 65, 75, 85, 95, 100]
var PROFILE_OFFSET = { dim: -12, balanced: 0, bright: 12 }

// How far True Tone follows the room's colour, and how warm it may go.
// The warmest True Tone goes (the strong floor below).
var TRUE_TONE_FLOOR = 4800

var STRENGTH = {
  subtle: { follow: 0.35, floor: 6000 },
  normal: { follow: 0.5, floor: 5400 },
  strong: { follow: 0.65, floor: TRUE_TONE_FLOOR }
}

function clamp(value, lo, hi) {
  return Math.min(hi, Math.max(lo, value))
}

function ema(previous, value, alpha) {
  return previous === null || previous === undefined ? value : previous + alpha * (value - previous)
}

function brightnessForLux(lux, profile) {
  var x = Math.log(Math.max(0, lux) + 1)
  var pct = CURVE_PCT[CURVE_PCT.length - 1]
  if (lux <= CURVE_LUX[0]) {
    pct = CURVE_PCT[0]
  } else {
    for (var i = 1; i < CURVE_LUX.length; i++) {
      if (lux <= CURVE_LUX[i]) {
        var xa = Math.log(CURVE_LUX[i - 1] + 1)
        var xb = Math.log(CURVE_LUX[i] + 1)
        pct = CURVE_PCT[i - 1] + (x - xa) / (xb - xa) * (CURVE_PCT[i] - CURVE_PCT[i - 1])
        break
      }
    }
  }
  var offset = PROFILE_OFFSET[profile] !== undefined ? PROFILE_OFFSET[profile] : 0
  return Math.round(clamp(pct + offset, 1, 100))
}

// One step toward the target: brighten quickly, dim gently, ignore small differences.
function brightnessStep(current, target) {
  if (current === null || current === undefined) return target
  var diff = target - current
  if (Math.abs(diff) < 3) return current
  return diff > 0 ? current + Math.min(diff, 8) : current + Math.max(diff, -3)
}

// The room light's colour temperature to a screen white point, rounded to 50 K.
function trueToneTarget(ambientK, strength) {
  var s = STRENGTH[strength] || STRENGTH.normal
  var ambient = clamp(ambientK, 2700, 9000)
  var target = ambient <= NIGHT_OFF
    ? NIGHT_OFF - s.follow * (NIGHT_OFF - ambient)
    : NIGHT_OFF + s.follow * 0.5 * (ambient - NIGHT_OFF)
  return Math.round(clamp(target, s.floor, 7000) / 50) * 50
}

// Decides whether Omarchy's night light is on, from what hyprsunset reports.
// state: { nightLight, lastSeenTemp, lastProfileTime, ownTemp }
// observation: { temp, profileTime, profileIdentity, profileTemp }
// Returns the next state plus `claimNightLight` when the plugin must apply night light
// itself: Omarchy's toggle command only turns night light on from exactly 6500 K, so
// while True Tone holds another temperature it "turns night light off" to 6500 K instead.
function observeHyprsunset(state, observation) {
  var next = {
    nightLight: state.nightLight,
    lastSeenTemp: observation.temp,
    lastProfileTime: observation.profileTime,
    ownTemp: state.ownTemp,
    claimNightLight: false
  }

  // On a fresh start we don't know who set the current temperature. True Tone never
  // goes below TRUE_TONE_FLOOR, so anything under it is night light. After an identity
  // schedule entry hyprsunset still reports the old night light temperature; leaving
  // True Tone paused then is better than switching off a night light you turned on.
  var firstLook = state.lastSeenTemp === null || state.lastSeenTemp === undefined
  if (firstLook) {
    next.nightLight = observation.temp !== state.ownTemp && observation.temp < TRUE_TONE_FLOOR
    return next
  }

  // A schedule entry in hyprsunset.conf took effect. Identity leaves the reported
  // temperature unchanged, so this is the only sign that a scheduled night light ended.
  if (observation.profileTime !== state.lastProfileTime) {
    next.nightLight = !observation.profileIdentity && observation.profileTemp < NIGHT_THRESHOLD
    return next
  }

  if (observation.temp === state.lastSeenTemp || observation.temp === state.ownTemp) return next

  if (observation.temp < NIGHT_THRESHOLD) {
    next.nightLight = true
  } else if (state.nightLight) {
    next.nightLight = false
  } else if (observation.temp === NIGHT_OFF && state.ownTemp !== null && state.ownTemp !== NIGHT_OFF) {
    next.nightLight = true
    next.claimNightLight = true
  }
  return next
}

function parseTemperature(output) {
  var match = String(output || "").match(/^\s*([0-9]+)\s*$/m)
  return match ? Number(match[1]) : null
}

function parseProfile(output) {
  var text = String(output || "")
  var time = text.match(/Time:\s*(\S+)/)
  var temp = text.match(/Temperature:\s*([0-9]+)/)
  var identity = text.match(/Identity:\s*(\S+)/)
  return {
    time: time ? time[1] : "",
    temperature: temp ? Number(temp[1]) : NIGHT_OFF,
    identity: identity ? identity[1] === "true" : true
  }
}

// ---- night light schedule (~/.config/hypr/hyprsunset.conf) -------------------

function parseTime(value) {
  var match = String(value || "").match(/^(\d{1,2}):(\d{2})$/)
  return match ? (Number(match[1]) * 60 + Number(match[2])) % (24 * 60) : null
}

function formatTime(minutes) {
  var m = ((minutes % 1440) + 1440) % 1440
  var hh = Math.floor(m / 60)
  var mm = m % 60
  return (hh < 10 ? "0" : "") + hh + ":" + (mm < 10 ? "0" : "") + mm
}

function shiftTime(value, delta) {
  var minutes = parseTime(value)
  return formatTime((minutes === null ? 0 : minutes) + delta)
}

// Reads the schedule from hyprsunset.conf: the identity profile ends night light, the
// warm profile starts it. A commented-out warm profile means the schedule is off.
function parseSchedule(text) {
  var schedule = { enabled: false, start: "21:00", end: "07:00", temperature: NIGHT_ON }
  var blocks = String(text || "").match(/^[ \t]*#?[ \t]*profile[ \t]*\{[^}]*\}/gm) || []
  for (var i = 0; i < blocks.length; i++) {
    var commented = /^[ \t]*#/.test(blocks[i])
    var body = blocks[i].replace(/^[ \t]*#[ \t]?/gm, "")
    var time = body.match(/time\s*=\s*(\d{1,2}:\d{2})/)
    var identity = /identity\s*=\s*true/.test(body)
    var temp = body.match(/temperature\s*=\s*(\d+)/)
    if (!time) continue
    if (identity && !commented) {
      schedule.end = formatTime(parseTime(time[1]))
    } else if (temp && Number(temp[1]) < NIGHT_THRESHOLD) {
      schedule.start = formatTime(parseTime(time[1]))
      schedule.temperature = Number(temp[1])
      schedule.enabled = !commented
    }
  }
  return schedule
}

function scheduleConf(schedule) {
  var warm = [
    "profile {",
    "    time = " + schedule.start,
    "    temperature = " + schedule.temperature,
    "}"
  ]
  if (!schedule.enabled) warm = warm.map(function(line) { return "# " + line })
  return [
    "# Night light schedule, edited from the Studio Display panel (ruuts.studio-display).",
    "# Hand edits work too; apply them with: omarchy restart hyprsunset",
    "",
    "# Neutral screen from this time",
    "profile {",
    "    time = " + schedule.end,
    "    identity = true",
    "}",
    "",
    "# Night light from this time" + (schedule.enabled ? "" : " (schedule off)")
  ].concat(warm).join("\n") + "\n"
}

if (typeof module !== "undefined") {
  module.exports = {
    NIGHT_THRESHOLD: NIGHT_THRESHOLD,
    NIGHT_OFF: NIGHT_OFF,
    NIGHT_ON: NIGHT_ON,
    clamp: clamp,
    ema: ema,
    brightnessForLux: brightnessForLux,
    brightnessStep: brightnessStep,
    trueToneTarget: trueToneTarget,
    observeHyprsunset: observeHyprsunset,
    parseTemperature: parseTemperature,
    parseProfile: parseProfile,
    shiftTime: shiftTime,
    parseSchedule: parseSchedule,
    scheduleConf: scheduleConf
  }
}
