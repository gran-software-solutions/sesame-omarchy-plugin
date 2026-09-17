.pragma library

// Issuer -> vendored brand mark.
//
// The popup gets an issuer string from whatever the user (or the QR code) put
// in the otpauth `issuer` parameter, so the input is messy by nature: real
// examples include "Slack (Acme Inc)", "auth.mongodb.com" and a bare device
// model number. Matching therefore normalises first and falls back to the
// initial badge rather than guessing.
//
// Adding a brand is two steps: drop the svg in brands/, add a row to ICONS.

// Exact brand file stems vendored under brands/. Kept as a list so `has()`
// can reject a table entry whose file was never fetched.
var ICONS = [
  "amazon", "bitwarden", "github", "google", "hetzner", "jetbrains",
  "linkedin", "mongodb", "openai", "opera", "paypal", "reddit", "slack",
  "stripe", "twitter", "vivaldi", "xing", "zoho"
]

// Normalised issuer -> file stem, for names that do not reduce to the stem by
// themselves. The right-hand side must appear in ICONS.
var ALIASES = {
  // The real store's awkward ones.
  "auth.mongodb.com": "mongodb",
  "auth.opera.com": "opera",
  "jetbrains account": "jetbrains",

  // Neighbours nobody wants to hand-map later.
  "amazon web services": "amazon",
  "aws": "amazon",
  "bitwarden web vault": "bitwarden",
  "github.com": "github",
  "gitlab": null,          // not vendored: falls back on purpose
  "google workspace": "google",
  "gmail": "google",
  "googlemail": "google",
  "youtube": "google",
  "hetzner online": "hetzner",
  "hetzner online gmbh": "hetzner",
  "linkedin.com": "linkedin",
  "microsoft": null,
  "open ai": "openai",
  "chatgpt": "openai",
  "paypal.com": "paypal",
  "reddit.com": "reddit",
  "slack.com": "slack",
  "stripe.com": "stripe",
  "x": "twitter",
  "twitter.com": "twitter",
  "x.com": "twitter",
  "zoho corporation": "zoho"
}

function has(stem) {
  return ICONS.indexOf(stem) !== -1
}

// Lower-case, drop anything in brackets, drop a leading host label
// ("auth.mongodb.com"), drop a trailing TLD, and collapse the rest. Applied to
// both sides of the alias table so "Slack (Acme Inc)" and an ALIASES key of
// "slack" meet in the middle.
function normalise(raw) {
  var s = String(raw || "").toLowerCase().trim()
  if (s === "") return ""

  s = s.replace(/\([^)]*\)/g, " ")          // "slack (acme inc)" -> "slack"
  s = s.replace(/\b(inc|llc|ltd|gmbh|corp|corporation|company|account)\b\.?/g, " ")
  s = s.replace(/[^a-z0-9.]+/g, " ")        // punctuation to spaces, keep dots
  s = s.replace(/\s+/g, " ").trim()

  // Strip the host prefix from a domain: auth.mongodb.com -> mongodb.com
  var host = s.match(/^(?:[a-z0-9-]+\.)+([a-z0-9-]+)\.[a-z]{2,}$/)
  if (host) s = host[1]

  // Strip a bare TLD: mongodb.com -> mongodb, github.io -> github
  s = s.replace(/\.(com|org|net|io|co|dev|app|sh|de|eu|me)$/, "")
  // And any remaining dotted run: mongodb.co.uk -> mongodb
  s = s.replace(/\..*$/, "")

  return s.trim()
}

// The brand file stem for an issuer, or "" when there is no vendored mark.
function forIssuer(raw) {
  var s = String(raw || "").toLowerCase().trim()
  if (s === "") return ""

  // Exact alias first, on the raw string: the aliases exist precisely because
  // normalisation would lose the distinction.
  if (ALIASES.hasOwnProperty(s)) {
    var mapped = ALIASES[s]
    return mapped && has(mapped) ? mapped : ""
  }

  var n = normalise(raw)
  if (n === "") return ""

  if (ALIASES.hasOwnProperty(n)) {
    var mapped2 = ALIASES[n]
    return mapped2 && has(mapped2) ? mapped2 : ""
  }

  // The stem itself: google, github, reddit.
  if (has(n)) return n

  // A single leading or trailing word match, which catches "zoho mail" and
  // "paypal europe" without matching mid-word noise like "xing" in "boxing".
  var words = n.split(" ")
  for (var i = 0; i < words.length; i++) {
    if (has(words[i])) return words[i]
  }

  return ""
}

// A stable per-issuer colour index, for tinting a mark (and for the fallback
// initial) so the same service always gets the same colour.
function hueIndex(raw, count) {
  var text = normalise(raw)
  if (text === "") text = String(raw || "")
  var hash = 0
  for (var i = 0; i < text.length; i++) hash = (hash * 31 + text.charCodeAt(i)) >>> 0
  return hash % Math.max(1, count)
}

// Each brand's own colour, so the mark is recognised by hue as well as shape.
//
// This deliberately does not use the theme palette. Hash-assigning a theme hue
// gave Mongo orange and Bitwarden orange and Opera magenta — the shapes were
// right but the colours were wrong, which is the opposite of recognition: the
// eye knows GitHub is near-black and Reddit is orange, and a magenta GitHub
// mark reads as neither. Brand colour is the one place in this popup that
// should not follow the theme.
//
// Values are the official brand hexes (Simple Icons' data file), with a few
// lightened where the real colour is too dark to read as a tint on a light
// surface — GitHub's #181717 and JetBrains' #000000 would both draw as black.
var BRAND_COLORS = {
  amazon:    "#FF9900",
  bitwarden: "#175DDC",
  github:    "#3A3A3C",   // lightened from #181717
  google:    "#4285F4",
  hetzner:   "#D50C2D",
  jetbrains: "#5A5A5F",   // lightened from #000000
  linkedin:  "#0A66C2",
  mongodb:   "#47A248",
  openai:    "#4A4A4F",   // OpenAI publishes no single brand colour
  opera:     "#FF1B2D",
  paypal:    "#002991",
  reddit:    "#FF4500",
  slack:     "#611F69",
  stripe:    "#635BFF",
  twitter:   "#1DA1F2",
  vivaldi:   "#EF3939",
  xing:      "#006567",
  zoho:      "#E42527"
}

// The mark colour for an issuer: its brand colour when known, else "" so the
// caller can fall back to the theme hue.
function brandColor(raw) {
  var stem = forIssuer(raw)
  if (stem === "") return ""
  return BRAND_COLORS.hasOwnProperty(stem) ? BRAND_COLORS[stem] : ""
}
