import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import QtQuick.Shapes
import qs.Ui
import "BrandIcons.js" as BrandIcons

// Sesame — bar icon + popup.
//
// Modes:
//   list     accounts with live codes; type to filter, Enter copies
//   scan     webcam viewfinder (ScanPane); frames are decoded by bin/totp
//   confirm  a QR was recognised; Enter stores it, Esc discards it
//
// All secrets stay inside bin/totp's encrypted store. The QML side only ever
// sees ids, labels and the current codes; a scanned frame is decoded and
// deleted by the backend, never parsed here.
Panel {
  id: root
  moduleName: "de.gransoftware.sesame"
  // A plugin may own exactly one IPC target, so the standard open/close set
  // and the extra `scan` method live in one handler (see below).
  manageIpc: false

  property string mode: "list"
  property var accounts: []
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property string errorText: ""
  property string actionStatus: ""
  property int tickEpoch: Math.floor(Date.now() / 1000)
  property bool deleteConfirmOpen: false
  property var deleteTarget: null
  property var scanFound: []
  property string scanFramePath: ""
  property string scanHint: ""
  // manual-entry form
  property string manualIssuer: ""
  property string manualAccount: ""
  property string manualSecret: ""
  property int manualDigits: 6
  property int manualPeriod: 30
  property string manualAlgorithm: "SHA1"
  readonly property bool manualSecretIsUrl: /^otpauth(-migration)?:\/\//i.test(manualSecret.trim())
  readonly property bool manualSecretValid: manualSecretIsUrl
    || /^[A-Za-z2-7]+=*$/.test(manualSecret.replace(/[\s-]/g, ""))
  readonly property bool manualReady: manualSecret.trim() !== "" && manualSecretValid
    && (manualSecretIsUrl || manualIssuer.trim() !== "" || manualAccount.trim() !== "")

  readonly property url helperUrl: Qt.resolvedUrl("bin/totp")
  readonly property string helperPath: decodeURIComponent(String(helperUrl).replace(/^file:\/\//, ""))
  // A captured frame is a picture of the secret, so it only ever goes in a
  // directory private to the user — never the shared /tmp.
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || (Quickshell.env("HOME") + "/.cache")
  readonly property string framePath: runtimeDir + "/sesame-frame.jpg"
  readonly property string defaultGlyph: "󰦝"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Visual language shared with Yank: one flat surface split by hairlines, a
  // search field beside a segmented control, two-line rows with a leading
  // tile and an accent marker on the focused row, and a footer of key hints.
  //
  // Every value below is a theme token rather than a number chosen here. The
  // plugin used to pick its own alphas and sizes, which meant it kept its
  // original look while the rest of the desktop moved — the shell's own popups
  // read Style.spacing and the [controls] state tokens, and this now does the
  // same, so the TOTP card, a bar flyout and the Omarchy menu all restyle
  // together when the theme changes.
  readonly property color cardBorder: Color.popups.border

  // Persistent chosen row, straight from the theme's selected state. The
  // accent-marker bar and the label tint that go with it stay local, because
  // they are this plugin's own way of saying "this is the row Enter will act
  // on" and no other surface has that job.
  readonly property color selectedBackground: Style.selectedFillFor(foreground, Color.accent, Color.urgent)
  // Mouse hover, which is also the keyboard cursor here: `cursorActive` tracks
  // the pointer as well as the arrow keys, so both use the theme's hover token
  // and the two input methods cannot drift apart.
  readonly property color rowHover: Style.hoverFillFor(foreground, Color.accent, Color.urgent)

  readonly property color secondary: theme.secondaryText
  readonly property color tertiary: theme.tertiaryText

  // Windows use decoration:rounding, and the shell reads that same value into
  // Style.cornerRadius for every panel, menu and button. A popup card that
  // rounded differently from the window behind it was the single most visible
  // tell that this was a plugin rather than part of the desktop, so the card
  // takes the theme radius outright.
  //
  // The pieces *inside* the card take a proportional share of it rather than
  // the full value. At 13px a key cap and a 26px badge are more than half
  // rounded and read as pills, which loses the card/cap/row hierarchy; two
  // thirds keeps the family resemblance at every radius while leaving the card
  // the roundest thing on screen.
  readonly property int cardRadius: Style.cornerRadius
  readonly property int componentRadius: Math.max(3, Math.round(Style.cornerRadius * 2 / 3))
  // Inner padding follows the popup scale, so the card breathes in step with
  // the shell's own flyouts instead of holding its own rhythm.
  readonly property int cardPadding: Style.spacing.popupPadding

  // Row height is pinned above the kit's default: an account row carries a
  // badge, two lines of label and a 20px countdown ring, which the stock
  // popup row height is too short for. Taking the larger of the two keeps the
  // rows legible while still growing if the theme scales spacing up.
  readonly property int rowHeight: Math.max(Style.spacing.popupRowHeight + Style.space(6), Style.space(48))
  readonly property int headerHeight: Style.space(34)
  readonly property color hairline: Util.alpha(foreground, 0.08)
  readonly property color hintLabel: Util.alpha(foreground, 0.68)
  // A white keycap reads as a physical key on a light popup but is a pale,
  // unreadable block on a dark one, so dark themes get a faint tint instead.
  readonly property bool lightTheme: Color.popups.background.hslLightness > 0.5
  readonly property color keycapFill: lightTheme ? Util.alpha("#ffffff", 0.55) : Util.alpha(foreground, 0.07)

  readonly property int labelFont: Math.max(9, Math.round(Style.font.caption * 0.82))
  readonly property int capHeight: labelFont + Style.space(7)
  readonly property int keyColumnWidth: Style.space(80)
  // The full shortcut list, toggled from the footer's keyboard button.
  property bool shortcutsOpen: false

  // Footer hints: the few things you most likely want next.
  readonly property var primaryHints: {
    if (mode === "scan") return [{ keys: "Ctrl+N", label: "Type it" }, { keys: "Esc", label: "Back" }]
    if (mode === "confirm") return [{ keys: "Enter", label: "Add", primary: true }, { keys: "Esc", label: "Discard" }]
    if (mode === "manual") return [{ keys: "Enter", label: "Save", primary: true }, { keys: "Tab", label: "Next" }, { keys: "Esc", label: "Back" }]
    return [{ keys: "Enter", label: "Copy", primary: true }, { keys: "Ctrl+S", label: "Scan" }, { keys: "Ctrl+N", label: "Add" }]
  }

  // Every binding of the current mode, grouped.
  readonly property var shortcutGroups: {
    if (mode === "scan") return [
      { title: "SCANNER", rows: [
        { keys: ["Esc"], label: "back to codes" },
        { keys: ["Ctrl+N"], label: "type it instead" } ] } ]
    if (mode === "confirm") return [
      { title: "FOUND", rows: [
        { keys: ["⏎"], label: "add to store" },
        { keys: ["Esc"], label: "discard" } ] } ]
    if (mode === "manual") return [
      { title: "FORM", rows: [
        { keys: ["Tab", "⇧Tab"], label: "next / previous" },
        { keys: ["⏎"], label: "save" },
        { keys: ["Esc"], label: "back to codes" } ] } ]
    return [
      { title: "NAVIGATE", rows: [
        { keys: ["↑", "↓"], label: "move" },
        { keys: ["Ctrl+J", "Ctrl+K"], label: "move" },
        { keys: ["Esc"], label: filterText !== "" ? "clear search" : "close" } ] },
      { title: "ACCOUNT", rows: [
        { keys: ["⏎"], label: "copy code" },
        { keys: ["Del"], label: "remove" },
        { keys: ["⇧Del"], label: "remove (search)" } ] },
      { title: "ADD", rows: [
        { keys: ["Ctrl+S"], label: "scan a QR code" },
        { keys: ["Ctrl+N"], label: "type it in" },
        { keys: ["Ctrl+R"], label: "refresh codes" } ] } ]
  }
  readonly property var filteredAccounts: {
    var query = filterText.trim().toLowerCase()
    var result = []
    for (var i = 0; i < accounts.length; i++) {
      var account = accounts[i]
      var haystack = (String(account.issuer || "") + " " + String(account.name || "")).toLowerCase()
      if (query === "" || haystack.indexOf(query) !== -1) result.push(account)
    }
    return result
  }

  function glyphFor(value) {
    var text = String(value === undefined || value === null ? "" : value).trim()
    if (text === "") return root.defaultGlyph
    if (/^[0-9a-fA-F]{4,6}$/.test(text)) {
      var code = parseInt(text, 16)
      if (isFinite(code) && code > 0) return String.fromCodePoint(code)
    }
    return text
  }

  // ---- lifecycle ----------------------------------------------------------

  function close() {
    leaveScan()
    controller.hide()
    if (listProcess.running) listProcess.running = false
    accounts = []
    errorText = ""
    actionStatus = ""
    filterText = ""
    cursorActive = false
    deleteConfirmOpen = false
    deleteTarget = null
    resetManual()
    shortcutsOpen = false
    mode = "list"
  }

  onOpenedChanged: {
    if (opened) {
      mode = "list"
      selectedIndex = 0
      cursorActive = false
      tickEpoch = Math.floor(Date.now() / 1000)
      theme.reload()
      refresh()
      Qt.callLater(root.focusForMode)
    }
  }

  function refresh() {
    if (!listProcess.running) listProcess.running = true
  }

  function parseAccounts(raw) {
    if (!opened) return
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      accounts = Array.isArray(parsed.accounts) ? parsed.accounts : []
      selectedIndex = Math.max(0, Math.min(selectedIndex, filteredAccounts.length - 1))
      errorText = ""
    } catch (error) {
      errorText = "Could not read the account list."
    }
  }

  function focusForMode() {
    if (mode === "list") searchInput.forceActiveFocus()
    else if (mode === "manual") issuerField.input.forceActiveFocus()
    else keyCatcher.forceActiveFocus()
  }

  onModeChanged: Qt.callLater(root.focusForMode)

  function remainingFor(account) {
    var period = Math.max(1, Number(account.period) || 30)
    return period - (tickEpoch % period)
  }

  function codesNeedRefresh() {
    for (var i = 0; i < accounts.length; i++) {
      var period = Math.max(1, Number(accounts[i].period) || 30)
      if (Math.floor(tickEpoch / period) !== Number(accounts[i].counter)) return true
    }
    return false
  }

  function flash(text) {
    actionStatus = text
    actionTimer.restart()
  }

  // ---- list actions -------------------------------------------------------

  function moveSelection(delta) {
    if (filteredAccounts.length === 0) return
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta > 0 ? 0 : filteredAccounts.length - 1
      return
    }
    selectedIndex = Math.max(0, Math.min(filteredAccounts.length - 1, selectedIndex + delta))
  }

  function copyAt(index) {
    if (index < 0 || index >= filteredAccounts.length || copyProcess.running) return
    var account = filteredAccounts[index]
    cursorActive = true
    selectedIndex = index
    errorText = ""
    copyProcess.command = [helperPath, "copy", String(account.id),
      "--clear-after", String(Math.max(0, Number(setting("clipboardClearSeconds", 30)) || 0))]
    copyProcess.running = true
  }

  function copySelected() {
    if (!cursorActive && filteredAccounts.length > 0) {
      cursorActive = true
      selectedIndex = 0
    }
    copyAt(selectedIndex)
  }

  function requestDeleteSelected() {
    if (!cursorActive || selectedIndex < 0 || selectedIndex >= filteredAccounts.length
        || removeProcess.running) return
    var account = filteredAccounts[selectedIndex]
    deleteTarget = { id: String(account.id), name: labelFor(account) }
    deleteConfirm.selectedIndex = 0   // Cancel is the default; Delete needs → or a click
    deleteConfirmOpen = true
  }

  function cancelDelete() {
    deleteConfirmOpen = false
    deleteTarget = null
    deleteConfirm.selectedIndex = 0
    Qt.callLater(root.focusForMode)
  }

  function confirmDelete() {
    var target = deleteTarget
    deleteConfirmOpen = false
    deleteTarget = null
    if (!target || removeProcess.running) return
    removeProcess.command = [helperPath, "remove", String(target.id), "--yes"]
    removeProcess.running = true
  }

  function labelFor(account) {
    var issuer = String(account.issuer || "")
    var name = String(account.name || "")
    if (issuer !== "" && name !== "" && issuer.toLowerCase() !== name.toLowerCase())
      return issuer + " · " + name
    return issuer !== "" ? issuer : name
  }

  // ---- manual entry ------------------------------------------------------

  function openManualAdd() {
    if (mode === "scan" || mode === "confirm") leaveScan()
    errorText = ""
    mode = "manual"
  }

  function resetManual() {
    manualIssuer = ""
    manualAccount = ""
    manualSecret = ""
    manualDigits = 6
    manualPeriod = 30
    manualAlgorithm = "SHA1"
  }

  function backToList() {
    errorText = ""
    mode = "list"
  }

  // Everything goes through the backend's otpauth parser so the QML side
  // never has to know the store format. The URL travels over stdin.
  function manualUri() {
    var secret = manualSecret.trim()
    if (manualSecretIsUrl) return secret
    var issuer = manualIssuer.trim()
    var account = manualAccount.trim() || issuer
    var label = issuer !== "" ? issuer + ":" + account : account
    var query = "secret=" + encodeURIComponent(secret.replace(/[\s-]/g, "").toUpperCase())
      + (issuer !== "" ? "&issuer=" + encodeURIComponent(issuer) : "")
      + "&digits=" + manualDigits + "&period=" + manualPeriod + "&algorithm=" + manualAlgorithm
    return "otpauth://totp/" + encodeURIComponent(label) + "?" + query
  }

  function submitManual() {
    if (mode !== "manual" || manualProcess.running) return
    if (!manualReady) {
      errorText = manualSecret.trim() === "" ? "Enter the secret (Base32) or paste an otpauth:// URL."
        : (!manualSecretValid ? "The secret is not valid Base32." : "Give the account an issuer or a name.")
      return
    }
    errorText = ""
    manualProcess.stdinEnabled = true
    manualProcess.running = true
    manualProcess.write(manualUri() + "\n")
    manualProcess.stdinEnabled = false
  }

  function onManualAdded(raw, exitCode, stderrText) {
    if (exitCode !== 0) {
      errorText = stderrText || "Could not store the account."
      Qt.callLater(root.focusForMode)
      return
    }
    var added = 0, skipped = 0
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      added = Array.isArray(parsed.added) ? parsed.added.length : 0
      skipped = Array.isArray(parsed.skipped) ? parsed.skipped.length : 0
    } catch (error) {}
    resetManual()
    mode = "list"
    filterText = ""
    flash(added > 0 ? (added === 1 ? "Added" : "Added " + added)
                    : (skipped > 0 ? "Already present" : ""))
    refresh()
  }

  // ---- scanning -----------------------------------------------------------

  function enterScan() {
    if (mode === "scan") return
    errorText = ""
    scanFound = []
    scanHint = "Hold the QR code from your phone up to the camera."
    scanFramePath = ""
    mode = "scan"
  }

  function leaveScan() {
    if (decodeProcess.running) decodeProcess.running = false
    discardFrame()
    scanFound = []
    if (mode !== "list") mode = "list"
  }

  function discardFrame() {
    if (scanFramePath !== "") {
      cleanupProcess.command = ["rm", "-f", scanFramePath]
      cleanupProcess.running = true
      scanFramePath = ""
    }
  }

  function onFrameCaptured(path) {
    if (mode !== "scan" || decodeProcess.running) return
    scanFramePath = path
    decodeProcess.command = [helperPath, "decode", path]
    decodeProcess.running = true
  }

  function onDecoded(raw) {
    if (mode !== "scan") return
    var parsed
    try {
      parsed = JSON.parse(String(raw || "{}"))
    } catch (error) {
      discardFrame()
      return
    }
    var found = Array.isArray(parsed.found) ? parsed.found : []
    var invalid = Array.isArray(parsed.invalid) ? parsed.invalid : []
    if (found.length > 0) {
      scanFound = found
      mode = "confirm"   // keep the frame: confirmAdd re-decodes it with --add
      return
    }
    if (invalid.length > 0) scanHint = "That QR code is not a TOTP secret: " + invalid[0]
    discardFrame()
  }

  function confirmAdd() {
    if (mode !== "confirm" || addProcess.running || scanFramePath === "") return
    addProcess.command = [helperPath, "decode", scanFramePath, "--add"]
    addProcess.running = true
  }

  function onAdded(raw, exitCode, stderrText) {
    discardFrame()
    if (exitCode !== 0) {
      errorText = stderrText || "Could not store the account."
      mode = "scan"
      return
    }
    var added = 0, skipped = 0
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      added = Array.isArray(parsed.added) ? parsed.added.length : 0
      skipped = Array.isArray(parsed.skipped) ? parsed.skipped.length : 0
    } catch (error) {}
    scanFound = []
    mode = "list"
    filterText = ""
    flash(added > 0 ? (added === 1 ? "Added" : "Added " + added)
                    : (skipped > 0 ? "Already present" : ""))
    refresh()
  }

  function rejectScan() {
    discardFrame()
    scanFound = []
    scanHint = "Discarded. Point the camera at another code, or Esc to go back."
    mode = "scan"
  }

  function handleEscape() {
    if (deleteConfirmOpen) { cancelDelete(); return }
    if (mode === "confirm") { rejectScan(); return }
    if (mode === "scan") { leaveScan(); return }
    if (mode === "manual") { backToList(); return }
    if (filterText !== "") { filterText = ""; return }
    close()
  }

  // ---- theme palette ------------------------------------------------------

  ThemePalette { id: theme }

  // ---- processes ----------------------------------------------------------

  Process {
    id: listProcess
    command: [root.helperPath, "list"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseAccounts(text) }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") root.errorText = String(text).trim()
    }
  }

  Process {
    id: copyProcess
    stderr: StdioCollector { id: copyStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.flash("Copied")
        if (root.setting("closeOnCopy", true)) closeTimer.restart()
      } else {
        root.errorText = String(copyStderr.text || "").trim() || "Could not copy the code."
      }
    }
  }

  Process {
    id: removeProcess
    stderr: StdioCollector { id: removeStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) { root.flash("Deleted"); root.refresh() }
      else root.errorText = String(removeStderr.text || "").trim() || "Could not delete the account."
      Qt.callLater(root.focusForMode)
    }
  }

  Process {
    id: decodeProcess
    stdout: StdioCollector { id: decodeStdout; waitForEnd: true }
    stderr: StdioCollector { id: decodeStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.onDecoded(decodeStdout.text)
      else {
        root.scanHint = String(decodeStderr.text || "").trim() || "Could not decode the frame."
        root.discardFrame()
      }
    }
  }

  Process {
    id: addProcess
    stdout: StdioCollector { id: addStdout; waitForEnd: true }
    stderr: StdioCollector { id: addStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.onAdded(addStdout.text, exitCode, String(addStderr.text || "").trim())
    }
  }

  Process {
    id: manualProcess
    command: [root.helperPath, "add", "--stdin"]
    stdout: StdioCollector { id: manualStdout; waitForEnd: true }
    stderr: StdioCollector { id: manualStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.onManualAdded(manualStdout.text, exitCode, String(manualStderr.text || "").trim())
    }
  }

  // Started once at load: removes a frame a crashed shell may have left behind.
  Process {
    id: cleanupProcess
    command: ["rm", "-f", root.framePath]
    running: true
  }

  // omarchy-shell de.gransoftware.sesame toggle | open | close | scan
  IpcHandler {
    target: "de.gransoftware.sesame"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function scan(): void { if (!root.opened) root.open(); root.enterScan() }
  }

  Timer {
    interval: 1000
    running: root.opened && root.mode === "list"
    repeat: true
    onTriggered: {
      root.tickEpoch = Math.floor(Date.now() / 1000)
      if (root.codesNeedRefresh()) root.refresh()
    }
  }

  Timer { id: actionTimer; interval: 1400; onTriggered: root.actionStatus = "" }
  Timer { id: closeTimer; interval: 350; onTriggered: root.close() }

  // ---- bar button ---------------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyphFor(root.setting("icon", ""))
    slotSize: Style.bar.statusSlot
    tooltipText: "TOTP codes · right-click to scan a QR code"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) { if (!root.opened) root.open(); root.enterScan() }
      else if (mouseButton === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // ---- reusable pieces ----------------------------------------------------
  //
  // Same visual language as Yank: one flat surface split by hairlines, a
  // search field with a segmented control beside it, two-line rows with a
  // leading tile, and a footer of key hints. Everything is derived from the
  // theme's foreground/accent so it restyles with the desktop.

  component Divider: Rectangle {
    width: parent ? parent.width : 0
    height: 1
    color: root.hairline
  }

  component SectionLabel: Text {
    textFormat: Text.PlainText
    color: root.foreground
    opacity: 0.45
    font.family: root.fontFamily
    font.pixelSize: root.labelFont
    font.letterSpacing: 1.4
  }

  component KeyCap: Rectangle {
    id: keyCap
    property string label
    property bool primary: false
    width: keyCapLabel.implicitWidth + Style.space(9)
    height: root.capHeight
    radius: 5
    color: primary ? Util.alpha(Color.accent, 0.15) : root.keycapFill
    border.color: primary ? Util.alpha(Color.accent, 0.45) : Util.alpha(root.foreground, 0.20)
    border.width: 1
    Text {
      id: keyCapLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: keyCap.label
      color: Util.alpha(root.foreground, 0.9)
      font.family: root.fontFamily
      font.pixelSize: root.labelFont
      font.weight: keyCap.primary ? Font.DemiBold : Font.Normal
    }
  }

  component Hint: Row {
    id: hint
    property string keys
    property string label
    property bool primary: false
    spacing: Style.space(6)
    KeyCap { label: hint.keys; primary: hint.primary; anchors.verticalCenter: parent.verticalCenter }
    Text {
      textFormat: Text.PlainText
      text: hint.label
      color: root.hintLabel
      font.family: root.fontFamily
      font.pixelSize: root.labelFont
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // aligned shortcut row: fixed key column + description column
  component ShortcutRow: Row {
    id: shortcutRow
    property var keys: []
    property string label
    spacing: Style.space(10)
    Row {
      width: root.keyColumnWidth
      spacing: Style.space(3)
      Repeater {
        model: shortcutRow.keys
        delegate: KeyCap { required property string modelData; label: modelData }
      }
    }
    Text {
      textFormat: Text.PlainText
      text: shortcutRow.label
      color: root.hintLabel
      font.family: root.fontFamily
      font.pixelSize: root.labelFont
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // named group of shortcut rows
  component ShortcutGroup: Column {
    id: shortcutGroup
    property string title
    property var rows: []
    spacing: Style.space(4)
    Text {
      textFormat: Text.PlainText
      text: shortcutGroup.title
      color: Color.accent
      font.family: root.fontFamily
      font.pixelSize: root.labelFont
      font.letterSpacing: 1.4
      font.weight: Font.DemiBold
      bottomPadding: Style.space(3)
    }
    Repeater {
      model: shortcutGroup.rows
      delegate: ShortcutRow {
        required property var modelData
        keys: modelData.keys
        label: modelData.label
      }
    }
  }

  // One button of the header's segmented control. `active` is the raised,
  // outlined state Yank uses for the current filter; here it marks the
  // action Enter will run.
  component SegmentButton: Rectangle {
    id: seg
    property string glyph
    property string label
    property bool active: false
    signal clicked()
    readonly property bool hovered: segArea.containsMouse
    height: root.headerHeight - Style.space(6)
    width: segRow.implicitWidth + Style.space(20)
    radius: Style.space(6)
    color: active ? Color.popups.background : (hovered ? Util.alpha(root.foreground, 0.06) : "transparent")
    border.width: active ? 1 : 0
    border.color: Util.alpha(root.foreground, 0.12)
    Behavior on color { ColorAnimation { duration: 110 } }
    Row {
      id: segRow
      anchors.centerIn: parent
      spacing: Style.space(6)
      Text {
        visible: seg.glyph !== ""
        text: seg.glyph
        color: seg.active || seg.hovered ? Color.accent : root.foreground
        opacity: seg.active || seg.hovered ? 1 : 0.55
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        textFormat: Text.PlainText
        text: seg.label
        color: root.foreground
        opacity: seg.active ? 1 : (seg.hovered ? 0.8 : 0.55)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.weight: seg.active ? Font.DemiBold : Font.Normal
        anchors.verticalCenter: parent.verticalCenter
      }
    }
    MouseArea {
      id: segArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: seg.clicked()
    }
  }

  // The bordered container the segment buttons sit in.
  component SegmentGroup: Rectangle {
    default property alias buttons: segButtons.children
    height: root.headerHeight
    width: segButtons.implicitWidth + Style.space(6)
    radius: Style.space(8)
    color: Util.alpha(root.foreground, 0.05)
    border.width: 1
    border.color: Util.alpha(root.foreground, 0.10)
    Row {
      id: segButtons
      anchors.centerIn: parent
      spacing: Style.space(2)
    }
  }

  // Issuer badge: the service's brand mark when one is vendored, otherwise its
  // initial. Both forms are the same size, so every title starts on the same x
  // whichever one is showing.
  //
  // When a mark exists the badge takes the brand's own colour — a near-white
  // plate with the mark drawn at full strength — because shape *and* colour is
  // what makes a row scannable. An earlier pass used the hash-assigned theme
  // hue for both, which gave Mongo, Bitwarden and XING all the same orange and
  // drew GitHub and Opera nearly black; the shapes were right and the colours
  // were wrong, which is the opposite of recognition. Brand colour is the one
  // thing in this popup that should not follow the theme.
  //
  // Brands with no vendored mark keep the hashed theme hue for their initial,
  // as before.
  component Badge: Rectangle {
    id: badge
    property string label
    // The raw issuer, which is what identifies the service. `label` may be an
    // account name, so it is not used for the lookup.
    property string issuer: ""
    property bool hot: false

    readonly property string brand: BrandIcons.forIssuer(badge.issuer)
    readonly property bool hasBrand: brand !== ""
    readonly property string brandColor: BrandIcons.brandColor(badge.issuer)
    // A near-black mark (GitHub, Slack) disappears on a dark popup, so there
    // it takes the theme's text colour; every other brand keeps its own.
    readonly property bool brandTooDark: brandColor !== "" && !root.lightTheme
                                         && Qt.color(brandColor).hslLightness < 0.3
    readonly property color hue: brandTooDark ? root.foreground
                               : (brandColor !== "" ? brandColor
                                  : theme.badgeHue(badge.issuer !== "" ? badge.issuer : badge.label))
    // The plate is the mark's own hue at low alpha, so it frames the mark with
    // contrast rather than diluting it.
    readonly property real plateAlpha: hasBrand ? (hot ? 0.20 : 0.10)
                                                : (hot ? 0.28 : 0.14)

    width: root.rowHeight - Style.space(14)
    height: width
    radius: Style.space(6)
    color: Util.alpha(hue, plateAlpha)
    border.color: Util.alpha(hue, hasBrand ? (hot ? 0.55 : 0.28) : (hot ? 0.6 : 0.3))
    border.width: 1
    Behavior on color { ColorAnimation { duration: 90 } }

    // The mark is smaller than the badge so the tinted plate still frames it,
    // and it is inset by the same amount on every side to keep the optical
    // centre — brand SVGs are drawn to their own bounding boxes, not to ours.
    Image {
      id: brandMark
      anchors.centerIn: parent
      visible: badge.hasBrand
      source: badge.hasBrand ? Qt.resolvedUrl("brands/" + badge.brand + ".svg") : ""
      // Draw at device resolution rather than the logical 14px, or the mark
      // softens on this 2x display.
      sourceSize.width: Math.round(Style.space(17) * 2)
      sourceSize.height: Math.round(Style.space(17) * 2)
      width: Style.space(17)
      height: width
      fillMode: Image.PreserveAspectFit
      smooth: true
      layer.enabled: true
      // The vendored marks are black. Colorization keeps their lightness, so
      // on a dark popup they are lifted to white first and then tinted —
      // otherwise every mark is a dark shape on a dark tile.
      layer.effect: MultiEffect {
        brightness: root.lightTheme ? 0 : 1.0
        colorization: 1.0
        colorizationColor: badge.hue
      }
    }

    Text {
      anchors.centerIn: parent
      visible: !badge.hasBrand
      textFormat: Text.PlainText
      text: {
        var t = String(badge.label || "").trim()
        return t === "" ? "?" : t.charAt(0).toUpperCase()
      }
      color: badge.hue
      opacity: 1
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.weight: Font.DemiBold
    }
  }

  // Countdown ring: drains clockwise over the period.
  component CountdownRing: Item {
    id: ring
    property int remaining: 30
    property int period: 30
    property bool urgent: remaining <= 5
    property bool warning: remaining <= 10
    readonly property color hue: urgent ? theme.red : (warning ? theme.yellow : theme.green)
    width: Style.space(26)
    height: width
    Shape {
      anchors.fill: parent
      antialiasing: true
      layer.enabled: true
      layer.samples: 4
      ShapePath {
        strokeColor: Util.alpha(root.secondary, 0.18)
        strokeWidth: 2
        fillColor: "transparent"
        PathAngleArc { centerX: ring.width / 2; centerY: ring.height / 2; radiusX: ring.width / 2 - 1.5; radiusY: radiusX; startAngle: 0; sweepAngle: 360 }
      }
      ShapePath {
        strokeColor: ring.hue
        strokeWidth: 2
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathAngleArc {
          centerX: ring.width / 2; centerY: ring.height / 2
          radiusX: ring.width / 2 - 1.5; radiusY: radiusX
          startAngle: -90
          sweepAngle: 360 * ring.remaining / Math.max(1, ring.period)
          Behavior on sweepAngle { NumberAnimation { duration: 900; easing.type: Easing.Linear } }
        }
      }
    }
    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: ring.remaining
      color: ring.urgent ? theme.red : root.secondary
      opacity: 1
      font.family: root.fontFamily
      font.pixelSize: Math.max(8, root.labelFont - 1)
    }
  }

  // Labelled text field for the manual-entry form.
  component FormField: Column {
    id: field
    property string label
    property string placeholder
    property alias text: input.text
    property alias input: input
    property bool invalid: false
    property Item nextItem: null
    width: parent.width
    spacing: Style.space(4)

    SectionLabel { text: field.label; anchors.left: parent.left; anchors.leftMargin: Style.space(2) }

    Rectangle {
      width: parent.width
      height: root.headerHeight
      radius: Style.space(8)
      color: Util.alpha(root.foreground, 0.05)
      border.width: 1
      // idle → focus rings come from the theme's control-state tokens, so the
      // field lights up in exactly the accent the rest of the desktop uses for
      // focus. The error state is the theme's own red, at full strength: it is
      // the one state that must not look like a tint.
      border.color: field.invalid ? theme.red
                  : (input.activeFocus ? Util.alpha(Color.accent, 0.55) : Util.alpha(root.foreground, 0.10))
      Behavior on border.color { ColorAnimation { duration: 120 } }

      TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: Style.space(11)
        anchors.rightMargin: Style.space(11)
        verticalAlignment: TextInput.AlignVCenter
        color: root.foreground
        selectionColor: theme.selection
        selectedTextColor: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        clip: true
        KeyNavigation.tab: field.nextItem
        KeyNavigation.backtab: field.nextItem   // overridden per field below
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.submitManual(); event.accepted = true }
          else if (event.key === Qt.Key_Escape) { root.handleEscape(); event.accepted = true }
          else event.accepted = false
        }
        Text {
          anchors.fill: parent
          visible: input.text === ""
          text: field.placeholder
          color: root.foreground
          opacity: 0.38
          font: input.font
          verticalAlignment: Text.AlignVCenter
          elide: Text.ElideRight
        }
      }
    }
  }

  // One option of a small selector row (digits / period / algorithm).
  component OptionChip: Rectangle {
    id: option
    property string label
    property bool active: false
    signal clicked()
    width: optionLabel.implicitWidth + Style.space(14)
    height: root.capHeight + Style.space(6)
    radius: Style.space(6)
    // A selector row is exactly what the theme's selected/normal states are
    // for, so the chips agree with every Toggle, tab strip and dropdown in the
    // shell rather than inventing a second accent tint.
    color: active ? Color.popups.background : Util.alpha(root.foreground, 0.05)
    border.width: 1
    border.color: active ? Util.alpha(Color.accent, 0.55) : Util.alpha(root.foreground, 0.10)
    Behavior on color { ColorAnimation { duration: 90 } }
    Text {
      id: optionLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: option.label
      color: option.active ? Color.accent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.labelFont
      font.weight: option.active ? Font.DemiBold : Font.Normal
    }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: option.clicked() }
  }

  // ---- popup --------------------------------------------------------------

  KeyboardPanel {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.mode === "list" ? searchInput : (root.mode === "manual" ? issuerField.input : keyCatcher)
    contentWidth: popup.fittedContentWidth(Style.space(460))
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight, Style.space(820))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchInput.activeFocus || root.deleteConfirmOpen || root.mode === "manual"
      onMoveRequested: function(dx, dy) { if (root.mode === "list" && dy !== 0) root.moveSelection(dy) }
      onActivateRequested: {
        if (root.mode === "confirm") root.confirmAdd()
        else if (root.mode === "manual") root.submitManual()
        else if (root.mode === "list") root.copySelected()
      }
      onDeleteRequested: if (root.mode === "list") root.requestDeleteSelected()
      onCloseRequested: root.handleEscape()
      onTabRequested: function(direction) { if (root.mode === "list") root.switchPanel(direction) }
      onTextKey: function(text) {
        if (root.mode === "list" && text === "/") searchInput.forceActiveFocus()
        else if (text === "r" || text === "R") root.refresh()
      }

      Column {
        id: contentColumn
        width: parent.width
        spacing: 0

        // ---- header: search + actions, or the current step's title ----
        Item {
          id: header
          width: parent.width
          height: root.headerHeight + Style.space(12)

          // list: search field
          Rectangle {
            id: searchField
            visible: root.mode === "list"
            anchors.left: parent.left
            anchors.right: headerActions.left
            anchors.rightMargin: Style.space(8)
            anchors.top: parent.top
            height: root.headerHeight
            radius: Style.space(8)
            color: Util.alpha(root.foreground, 0.05)
            border.width: 1
            border.color: root.filterText.length > 0 ? Util.alpha(Color.accent, 0.55) : Util.alpha(root.foreground, 0.10)
            Behavior on border.color { ColorAnimation { duration: 120 } }

            Text {
              id: searchIcon
              anchors.left: parent.left
              anchors.leftMargin: Style.space(11)
              anchors.verticalCenter: parent.verticalCenter
              text: "󰍉"
              color: root.filterText.length > 0 ? Color.accent : root.foreground
              opacity: root.filterText.length > 0 ? 1 : 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }

            TextInput {
              id: searchInput
              anchors.left: searchIcon.right
              anchors.leftMargin: Style.space(9)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              color: root.foreground
              selectionColor: theme.selection
              selectedTextColor: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              clip: true
              text: root.filterText
              onTextChanged: {
                if (root.filterText === text) return
                root.filterText = text
                root.selectedIndex = 0
                root.cursorActive = root.filteredAccounts.length > 0
              }
              Text {
                anchors.fill: parent
                visible: searchInput.text === ""
                text: "Search accounts"
                color: root.foreground
                opacity: 0.38
                font: searchInput.font
                verticalAlignment: Text.AlignVCenter
              }
              Keys.onPressed: function(event) {
                if (root.deleteConfirmOpen) {
                  deleteConfirm.handleKey(event); event.accepted = true; return
                }
                var ctrl = event.modifiers & Qt.ControlModifier
                if (ctrl && event.key === Qt.Key_S) { root.enterScan(); event.accepted = true }
                else if (ctrl && event.key === Qt.Key_N) { root.openManualAdd(); event.accepted = true }
                else if (ctrl && event.key === Qt.Key_R) { root.refresh(); event.accepted = true }
                else if (ctrl && event.key === Qt.Key_J) { root.moveSelection(1); event.accepted = true }
                else if (ctrl && event.key === Qt.Key_K) { root.moveSelection(-1); event.accepted = true }
                // Delete removes an account only when it cannot mean "delete a
                // character": with an empty search box, or with Shift held.
                else if (event.key === Qt.Key_Delete
                         && ((event.modifiers & Qt.ShiftModifier) || text === "")) {
                  root.requestDeleteSelected(); event.accepted = true
                }
                else if (event.key === Qt.Key_Down) { root.moveSelection(1); event.accepted = true }
                else if (event.key === Qt.Key_Up) { root.moveSelection(-1); event.accepted = true }
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.copySelected(); event.accepted = true }
                else if (event.key === Qt.Key_Escape) { root.handleEscape(); event.accepted = true }
                else event.accepted = false
              }
            }
          }

          // other modes: back + the step's title
          Row {
            visible: root.mode !== "list"
            anchors.left: parent.left
            anchors.right: headerActions.left
            anchors.rightMargin: Style.space(8)
            anchors.top: parent.top
            height: root.headerHeight
            spacing: Style.space(10)

            SegmentGroup {
              anchors.verticalCenter: parent.verticalCenter
              SegmentButton {
                glyph: "󰁍"; label: "Codes"
                onClicked: root.mode === "manual" ? root.backToList() : root.leaveScan()
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: {
                if (root.mode === "scan") return "Scan a QR code"
                if (root.mode === "confirm") return root.scanFound.length === 1 ? "Found an account" : "Found " + root.scanFound.length + " accounts"
                return "New account"
              }
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.weight: Font.DemiBold
            }
          }

          SegmentGroup {
            id: headerActions
            anchors.right: parent.right
            anchors.top: parent.top
            SegmentButton {
              visible: root.mode === "list" || root.mode === "scan"
              glyph: "󰄀"; label: "Scan"
              active: root.mode === "scan"
              onClicked: root.enterScan()
            }
            SegmentButton {
              visible: root.mode === "list" || root.mode === "scan" || root.mode === "manual"
              glyph: root.mode === "manual" ? "󰄬" : "󰐕"
              label: root.mode === "manual" ? "Save" : "Add"
              active: root.mode === "manual" && root.manualReady
              onClicked: root.mode === "manual" ? root.submitManual() : root.openManualAdd()
            }
            SegmentButton {
              visible: root.mode === "confirm"
              glyph: "󰄬"; label: "Add"
              active: true
              onClicked: root.confirmAdd()
            }
          }
        }

        Divider {}

        // ---- body ----
        Column {
          id: body
          width: parent.width
          topPadding: Style.space(6)
          bottomPadding: Style.space(6)
          spacing: Style.space(6)

          // error banner
          Text {
            visible: root.errorText !== ""
            width: parent.width
            leftPadding: Style.space(12)
            rightPadding: Style.space(12)
            topPadding: Style.space(4)
            text: root.errorText
            textFormat: Text.PlainText
            color: theme.red
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---- list ----
          ListView {
            id: accountList
            visible: root.mode === "list" && root.filteredAccounts.length > 0
            width: parent.width
            height: visible ? Math.min(contentHeight, (root.rowHeight + spacing) * 7.5) : 0
            spacing: Style.space(2)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            model: root.filteredAccounts
            currentIndex: root.cursorActive ? root.selectedIndex : -1
            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
            ScrollBar.vertical: ScrollBar { policy: accountList.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }

            delegate: Rectangle {
              id: row
              required property var modelData
              required property int index
              readonly property int remaining: root.remainingFor(modelData)
              readonly property int period: Math.max(1, Number(modelData.period) || 30)
              readonly property bool urgent: remaining <= 5
              readonly property bool hasCursor: root.cursorActive && root.selectedIndex === index
              readonly property bool hovered: rowArea.containsMouse
              readonly property string issuer: String(modelData.issuer || "")
              readonly property string name: String(modelData.name || "")
              readonly property string title: issuer !== "" ? issuer : name
              readonly property string caption: issuer !== "" && name.toLowerCase() !== issuer.toLowerCase() ? name : ""

              width: ListView.view.width
              height: root.rowHeight
              radius: Style.space(7)
              color: hasCursor ? root.selectedBackground : (hovered ? root.rowHover : "transparent")
              Behavior on color { ColorAnimation { duration: 90 } }

              Rectangle {
                visible: row.hasCursor
                width: 3
                height: parent.height * 0.46
                radius: 1.5
                color: Color.accent
                anchors.left: parent.left
                anchors.leftMargin: Style.space(3)
                anchors.verticalCenter: parent.verticalCenter
              }

              MouseArea {
                id: rowArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: { root.cursorActive = true; root.selectedIndex = row.index }
                onClicked: root.copyAt(row.index)
              }

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(11)

                Badge { label: row.title; issuer: row.issuer; hot: row.hasCursor }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(2)
                  Text {
                    Layout.fillWidth: true
                    text: row.title
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    Layout.fillWidth: true
                    text: row.caption !== "" ? row.caption : "TOTP  ·  " + row.period + "s"
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.45
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Text {
                  text: row.modelData.displayCode
                  textFormat: Text.PlainText
                  color: row.urgent ? theme.red : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.weight: Font.DemiBold
                  font.letterSpacing: 2
                  Layout.alignment: Qt.AlignVCenter
                }

                CountdownRing {
                  remaining: row.remaining
                  period: row.period
                  Layout.alignment: Qt.AlignVCenter
                }
              }
            }
          }

          // ---- empty / no-match ----
          Item {
            visible: root.mode === "list" && root.filteredAccounts.length === 0 && root.errorText === ""
            width: parent.width
            height: visible ? Style.space(120) : 0
            Column {
              anchors.centerIn: parent
              spacing: Style.space(8)
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.accounts.length === 0 ? root.defaultGlyph : "󰍉"
                color: Color.accent
                opacity: 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.accounts.length === 0
                  ? "No accounts yet — scan a QR code from your phone"
                  : "No matches for “" + root.filterText + "”"
                textFormat: Text.PlainText
                color: root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          // ---- manual entry form ----
          Column {
            visible: root.mode === "manual"
            width: parent.width - Style.space(24)
            anchors.horizontalCenter: parent.horizontalCenter
            topPadding: Style.space(4)
            spacing: Style.space(12)

            FormField {
              id: issuerField
              label: "ISSUER"
              placeholder: "GitHub"
              text: root.manualIssuer
              onTextChanged: root.manualIssuer = text
              nextItem: accountField.input
              Component.onCompleted: input.KeyNavigation.backtab = secretField.input
            }
            FormField {
              id: accountField
              label: "ACCOUNT"
              placeholder: "you@example.com"
              text: root.manualAccount
              onTextChanged: root.manualAccount = text
              nextItem: secretField.input
              Component.onCompleted: input.KeyNavigation.backtab = issuerField.input
            }
            FormField {
              id: secretField
              label: "SECRET  ·  BASE32, OR PASTE AN OTPAUTH:// URL"
              placeholder: "JBSW Y3DP EHPK 3PXP"
              text: root.manualSecret
              onTextChanged: root.manualSecret = text
              invalid: root.manualSecret.trim() !== "" && !root.manualSecretValid
              nextItem: issuerField.input
              Component.onCompleted: input.KeyNavigation.backtab = accountField.input
            }

            // options only matter for a raw secret; a URL carries its own
            Row {
              visible: !root.manualSecretIsUrl
              width: parent.width
              spacing: Style.space(16)
              Column {
                spacing: Style.space(5)
                SectionLabel { text: "DIGITS" }
                Row {
                  spacing: Style.space(4)
                  Repeater {
                    model: [6, 7, 8]
                    delegate: OptionChip {
                      required property int modelData
                      label: String(modelData)
                      active: root.manualDigits === modelData
                      onClicked: root.manualDigits = modelData
                    }
                  }
                }
              }
              Column {
                spacing: Style.space(5)
                SectionLabel { text: "PERIOD" }
                Row {
                  spacing: Style.space(4)
                  Repeater {
                    model: [30, 60]
                    delegate: OptionChip {
                      required property int modelData
                      label: modelData + "s"
                      active: root.manualPeriod === modelData
                      onClicked: root.manualPeriod = modelData
                    }
                  }
                }
              }
              Column {
                spacing: Style.space(5)
                SectionLabel { text: "ALGORITHM" }
                Row {
                  spacing: Style.space(4)
                  Repeater {
                    model: ["SHA1", "SHA256", "SHA512"]
                    delegate: OptionChip {
                      required property string modelData
                      label: modelData
                      active: root.manualAlgorithm === modelData
                      onClicked: root.manualAlgorithm = modelData
                    }
                  }
                }
              }
            }
            Item { width: 1; height: Style.space(2) }
          }

          // ---- viewfinder ----
          Loader {
            id: scanLoader
            width: parent.width - Style.space(12)
            anchors.horizontalCenter: parent.horizontalCenter
            height: active ? Math.round(width * 3 / 4) : 0
            visible: active
            active: root.opened && (root.mode === "scan" || root.mode === "confirm")
            sourceComponent: ScanPane {
              active: root.mode === "scan"
              busy: decodeProcess.running
              mirror: root.setting("mirrorPreview", true)
              framePath: root.framePath
              foreground: root.foreground
              frameColor: Util.alpha(theme.surfaceLight, 0.85)
              busyColor: theme.green
              fontFamily: root.fontFamily
              onFrameCaptured: function(path) { root.onFrameCaptured(path) }
              onFailed: function(message) { root.scanHint = message }
            }
          }

          Text {
            visible: root.mode === "scan"
            width: parent.width
            leftPadding: Style.space(12)
            rightPadding: Style.space(12)
            text: root.scanHint
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          // ---- found accounts ----
          Repeater {
            model: root.mode === "confirm" ? root.scanFound : []
            delegate: Rectangle {
              id: found
              required property var modelData
              required property int index
              width: parent.width
              height: root.rowHeight
              radius: Style.space(7)
              color: index === 0 ? root.selectedBackground : "transparent"

              Rectangle {
                visible: found.index === 0
                width: 3
                height: parent.height * 0.46
                radius: 1.5
                color: Color.accent
                anchors.left: parent.left
                anchors.leftMargin: Style.space(3)
                anchors.verticalCenter: parent.verticalCenter
              }

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(11)
                Badge {
                  label: found.modelData.issuer || found.modelData.name
                  issuer: found.modelData.issuer || ""
                  hot: found.index === 0
                }
                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(2)
                  Text {
                    Layout.fillWidth: true
                    text: found.modelData.issuer || found.modelData.name
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    Layout.fillWidth: true
                    text: (found.modelData.name || "") + "  ·  " + found.modelData.algorithm
                          + "  ·  " + found.modelData.digits + " digits  ·  " + found.modelData.period + "s"
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.45
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
                Rectangle {
                  Layout.alignment: Qt.AlignVCenter
                  Layout.preferredHeight: Style.space(20)
                  Layout.preferredWidth: newLabel.implicitWidth + Style.space(16)
                  radius: height / 2
                  color: Util.alpha(theme.green, 0.14)
                  Text {
                    id: newLabel
                    anchors.centerIn: parent
                    text: addProcess.running ? "Saving…" : "New"
                    color: theme.green
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.weight: Font.DemiBold
                  }
                }
              }
            }
          }
        }

        // ---- full shortcut reference, opened from the footer ----
        Column {
          width: parent.width
          visible: root.shortcutsOpen
          spacing: 0

          Divider {}

          Grid {
            x: Style.space(12)
            topPadding: Style.space(12)
            bottomPadding: Style.space(12)
            width: parent.width - Style.space(24)
            columns: 2
            columnSpacing: Style.space(20)
            rowSpacing: Style.space(12)
            Repeater {
              model: root.shortcutGroups
              delegate: ShortcutGroup {
                required property var modelData
                title: modelData.title
                rows: modelData.rows
              }
            }
          }
        }

        Divider {}

        // ---- footer: status + key hints ----
        Item {
          id: footer
          width: parent.width
          height: Style.space(34)

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: {
              if (root.actionStatus !== "") return root.actionStatus
              if (root.mode === "scan") return decodeProcess.running ? "Decoding…" : "Looking for a QR code"
              if (root.mode === "confirm") return addProcess.running ? "Saving…" : "Review before adding"
              if (root.mode === "manual") return manualProcess.running ? "Saving…" : (root.manualSecretIsUrl ? "otpauth URL" : "Base32 secret")
              if (root.filterText === "")
                return root.accounts.length === 1 ? "1 account" : root.accounts.length + " accounts"
              return root.filteredAccounts.length + " of " + root.accounts.length
            }
            color: root.actionStatus !== "" ? Color.accent : root.foreground
            opacity: root.actionStatus !== "" ? 1 : 0.45
            font.family: root.fontFamily
            font.pixelSize: root.labelFont
            font.weight: root.actionStatus !== "" ? Font.DemiBold : Font.Normal
          }

          Row {
            anchors.right: shortcutsToggle.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(12)
            Repeater {
              model: root.primaryHints
              delegate: Hint {
                required property var modelData
                keys: modelData.keys
                label: modelData.label
                primary: !!modelData.primary
              }
            }
          }

          // keyboard glyph: opens the full shortcut list above the footer
          Item {
            id: shortcutsToggle
            width: Style.space(22)
            height: width
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Rectangle {
              anchors.fill: parent
              radius: width / 2
              color: shortcutsArea.containsMouse || root.shortcutsOpen ? Util.alpha(root.foreground, 0.08) : "transparent"
              Behavior on color { ColorAnimation { duration: 110 } }
            }
            Text {
              anchors.centerIn: parent
              text: "󰌌"
              color: root.shortcutsOpen ? Color.accent : root.foreground
              opacity: root.shortcutsOpen ? 1 : 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            MouseArea {
              id: shortcutsArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.shortcutsOpen = !root.shortcutsOpen
            }
          }
        }
      }

      ConfirmDialog {
        id: deleteConfirm
        anchors.fill: parent
        z: 20
        opened: root.deleteConfirmOpen
        message: "Delete " + ((root.deleteTarget && root.deleteTarget.name) || "this account") + "? This cannot be undone."
        cancelText: "Cancel"
        confirmText: "Delete"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.cancelDelete()
        onConfirmed: root.confirmDelete()
      }
    }
  }
}
