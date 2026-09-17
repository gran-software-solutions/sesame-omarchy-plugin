import QtQuick
import Quickshell.Io
import qs.Commons
import "BrandIcons.js" as BrandIcons

// The active theme's full colours.toml, for the tiers the shell's Color
// singleton does not surface (named hues, background/foreground tiers,
// selection). Every property falls back to a shell role so a theme that
// only defines the basics still renders sensibly. Reloaded on every popup
// open, so a theme switch is picked up without restarting the shell.
QtObject {
  id: theme

  property var values: ({})
  readonly property string path: Color.currentThemePath + "/colors.toml"
  readonly property bool dark: String(values["mode"] || "").toLowerCase() !== "light"
                               && Color.background.hslLightness < 0.5

  function pick(key, fallback) {
    var value = values[key]
    return value ? value : fallback
  }
  // Prefer the bright_* row on dark themes: it is tuned for dark grounds.
  function hue(name, fallback) {
    if (dark) return pick("bright_" + name, pick(name, fallback))
    return pick(name, pick("bright_" + name, fallback))
  }

  readonly property color accent: Color.accent
  readonly property color red: hue("red", Color.urgent)
  readonly property color orange: hue("orange", Color.urgent)
  readonly property color yellow: hue("yellow", Color.accent)
  readonly property color green: hue("green", Color.accent)
  readonly property color cyan: hue("cyan", Color.accent)
  readonly property color blue: hue("blue", Color.accent)
  readonly property color magenta: hue("magenta", Color.accent)
  readonly property color brown: hue("brown", Color.muted)
  readonly property color selection: pick("selection", Util.alpha(Color.accent, 0.35))
  readonly property color muted: pick("muted", Color.muted)
  readonly property color foreground: pick("foreground", Color.foreground)
  readonly property color secondaryText: pick("dark_foreground", Util.alpha(Color.foreground, 0.55))
  readonly property color tertiaryText: pick("light_foreground", Util.alpha(Color.foreground, 0.75))
  readonly property color surface: pick("dark_background", Util.alpha(Color.foreground, 0.04))
  readonly property color surfaceStrong: pick("darker_background", Util.alpha(Color.foreground, 0.09))
  readonly property color surfaceLight: pick("lighter_background", Color.background)

  // Hues used for issuer badges, in an order that keeps neighbours distinct.
  // The index comes from BrandIcons so the mark and the fallback initial are
  // tinted by one hash: a service keeps its colour whether or not its brand
  // icon is bundled, and adding an icon never recolours the row.
  readonly property var badgeHues: [blue, green, orange, magenta, cyan, red, yellow, brown]

  function badgeHue(label) {
    return badgeHues[BrandIcons.hueIndex(label, badgeHues.length)]
  }

  function parse(raw) {
    var parsed = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6}|[A-Za-z]+)["']?/)
      if (match) parsed[match[1]] = match[2]
    }
    values = parsed
  }

  function reload() { file.reload() }

  property FileView file: FileView {
    id: file
    path: theme.path
    watchChanges: true
    printErrors: false
    onLoaded: theme.parse(text())
    onFileChanged: file.reload()
  }
}
