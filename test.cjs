// Run with: node test.cjs
const assert = require("node:assert/strict")
const M = require("./Model.js")

// Brightness curve: monotonic, profile offsets, clamped.
assert.equal(M.brightnessForLux(0, "balanced"), 10)
assert.equal(M.brightnessForLux(100, "balanced"), 45)
assert.equal(M.brightnessForLux(100, "dim"), 33)
assert.equal(M.brightnessForLux(100, "bright"), 57)
assert.equal(M.brightnessForLux(100000, "bright"), 100)
assert.equal(M.brightnessForLux(0, "dim"), 1)
let previous = 0
for (const lux of [0, 3, 10, 30, 75, 135, 300, 900, 2000, 4000, 9000]) {
  const pct = M.brightnessForLux(lux, "balanced")
  assert.ok(pct >= previous, `curve is monotonic at ${lux} lux`)
  previous = pct
}

// Steps: brighten fast, dim slowly, hold small differences.
assert.equal(M.brightnessStep(null, 50), 50)
assert.equal(M.brightnessStep(50, 52), 50)
assert.equal(M.brightnessStep(40, 70), 48)
assert.equal(M.brightnessStep(70, 40), 67)

// True Tone: warmer under lamps, floor per strength, never warmer than night light territory
// for the subtle setting.
assert.equal(M.trueToneTarget(6500, "normal"), 6500)
assert.equal(M.trueToneTarget(3845, "normal"), 5400)
assert.equal(M.trueToneTarget(3845, "subtle"), 6000)
assert.equal(M.trueToneTarget(5500, "normal"), 6000)
assert.equal(M.trueToneTarget(2000, "strong"), 4800)
assert.equal(M.trueToneTarget(9000, "normal"), 7000)
for (const k of [2700, 3500, 4500, 5500, 6500]) {
  assert.ok(M.trueToneTarget(k, "subtle") >= M.NIGHT_THRESHOLD)
}

// Parsing hyprctl output.
assert.equal(M.parseTemperature("5400\n"), 5400)
assert.equal(M.parseTemperature("Couldn't connect to socket (3)"), null)
assert.deepEqual(M.parseProfile("Time: 21:00\nTemperature: 4000\nGamma: 1\nIdentity: false\n"),
  { time: "21:00", temperature: 4000, identity: false })

// Night light state.
const day = { profileTime: "07:00", profileIdentity: true, profileTemp: 6000 }
const evening = { profileTime: "21:00", profileIdentity: false, profileTemp: 4000 }
const fresh = { nightLight: false, lastSeenTemp: null, lastProfileTime: null, ownTemp: null }

let s = M.observeHyprsunset(fresh, { ...day, temp: 6000 })
assert.equal(s.nightLight, false, "freshly started hyprsunset in the day")

s = M.observeHyprsunset(fresh, { ...day, temp: 4000 })
assert.equal(s.nightLight, true, "4000 K at startup is night light, even under an identity profile")

s = M.observeHyprsunset(fresh, { ...day, temp: 5400 })
assert.equal(s.nightLight, false, "a True Tone temperature left from before a restart is not night light")

s = M.observeHyprsunset(fresh, { ...evening, temp: 4000 })
assert.equal(s.nightLight, true, "evening profile at startup")

// True Tone holds 5400 K; the bar indicator turns night light on (4000 K) and off (6500 K).
let t = { nightLight: false, lastSeenTemp: 5400, lastProfileTime: "07:00", ownTemp: 5400 }
t = M.observeHyprsunset(t, { ...day, temp: 4000 })
assert.equal(t.nightLight, true)
t = M.observeHyprsunset(t, { ...day, temp: 6500 })
assert.equal(t.nightLight, false)
assert.equal(t.claimNightLight, false)

// The toggle command misfires to 6500 K while True Tone holds 5400 K: the plugin claims it.
t = { nightLight: false, lastSeenTemp: 5400, lastProfileTime: "07:00", ownTemp: 5400 }
t = M.observeHyprsunset(t, { ...day, temp: 6500 })
assert.equal(t.nightLight, true)
assert.equal(t.claimNightLight, true)
// The plugin then applies 4000 K itself (ownTemp 4000); toggling again goes to 6500 K = off.
t = M.observeHyprsunset({ ...t, ownTemp: 4000 }, { ...day, temp: 4000 })
assert.equal(t.nightLight, true)
t = M.observeHyprsunset(t, { ...day, temp: 6500 })
assert.equal(t.nightLight, false)

// Our own changes are not mistaken for night light.
t = { nightLight: false, lastSeenTemp: 5600, lastProfileTime: "07:00", ownTemp: 5400 }
t = M.observeHyprsunset(t, { ...day, temp: 5400 })
assert.equal(t.nightLight, false)

// Schedule: 21:00 turns night light on, 07:00 identity turns it off despite the stale reading.
t = { nightLight: false, lastSeenTemp: 5400, lastProfileTime: "07:00", ownTemp: 5400 }
t = M.observeHyprsunset(t, { ...evening, temp: 4000 })
assert.equal(t.nightLight, true)
t = M.observeHyprsunset(t, { ...day, temp: 4000 })
assert.equal(t.nightLight, false)

// Schedule: Omarchy's default file, round trips, and switching it off keeps the time.
const omarchyDefault = `# Makes hyprsunset do nothing to the screen by default
# Without this, the default applies some tint to the monitor
profile {
    time = 07:00
    identity = true
}

profile {
    time = 21:00
    temperature = 4000
}
`
assert.deepEqual(M.parseSchedule(omarchyDefault), { enabled: true, start: "21:00", end: "07:00", temperature: 4000 })
const later = { enabled: true, start: "22:30", end: "06:30", temperature: 4000 }
assert.deepEqual(M.parseSchedule(M.scheduleConf(later)), later)
const off = { ...later, enabled: false }
assert.deepEqual(M.parseSchedule(M.scheduleConf(off)), off)
assert.match(M.scheduleConf(off), /^# profile \{$/m)
assert.equal(M.shiftTime("23:30", 30), "00:00")
assert.equal(M.shiftTime("00:00", -30), "23:30")
assert.equal(M.shiftTime("7:00", 30), "07:30")

console.log("ok - model")
