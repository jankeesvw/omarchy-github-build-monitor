import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.Commons
import qs.Ui

// Builds: whether the branch you deploy from is green right now.
//
// The bar carries one mark. It spins while a build is running, goes solid
// green for a minute after one passes, and turns red and stays red when one
// fails. That asymmetry is the whole point: a build that went green is news
// for about as long as it takes to notice it, and then it is just the normal
// state of things, so it steps back out of the way. A build that broke is not
// news, it is a job, and it keeps saying so until a later build replaces it.
//
// A build here is a commit, not a workflow run. One push starts several
// workflows and they finish minutes apart, so following any single one of
// them means saying green while the deploy is still going. `bin/omarchy-github-build-monitor`
// groups every push-triggered run by its head sha and rolls them up; the
// duration is the wall clock from the first run starting to the last one
// ending, which is the wait an actual person sits through.
//
// Commit messages, author names and workflow names all come back from the
// API, so every Text here carries `textFormat: Text.PlainText`. Left on the
// default AutoText, Qt decides for itself that a string looks like markup and
// renders it as rich text, and rich text really does load `<img src="http://">`
// - a request out of the shell process to a server someone else picked.
//
// The URL a click opens is built here from a sha and a repository name that
// have both been through a regex, never from the html_url the API handed us.
Panel {
  id: root

  moduleName: "jankeesvw.github-build-monitor"
  ipcTarget: "jankeesvw.github-build-monitor"

  // The script sits next to this file, so the plugin runs from wherever it
  // was installed without putting anything on $PATH.
  readonly property string script:
    Qt.resolvedUrl("bin/omarchy-github-build-monitor").toString().replace(/^file:\/\//, "")

  // ------------------------------------------------------------- settings

  // What you have in your hand when you want to watch a project is the page
  // you were just looking at, so the setting takes that: the browser URL, the
  // clone URL, or owner/name if you happen to know it by heart.
  readonly property string repo: normalizeRepo(root.setting("repo", ""))
  readonly property string branchSetting: String(root.setting("branch", "") || "").trim()
  readonly property bool showLabel: root.setting("showLabel", false) === true
  readonly property int holdSec: Math.min(3600, Math.max(0, Math.round(Number(root.setting("successHoldSec", 60)) || 0)))
  readonly property string flagPattern: String(root.setting("flagPattern", "migrate,migration") || "").trim()
  readonly property int historyCount: Math.min(40, Math.max(1, Math.round(Number(root.setting("historyCount", 5)) || 5)))

  // Whatever the settings say, or the repository name without its owner. A
  // bar is a row of small things and "application" is the half you recognise.
  readonly property string label: {
    var given = String(root.setting("label", "") || "").trim()
    if (given !== "") return given
    var parts = root.repo.split("/")
    return parts.length === 2 ? parts[1] : root.repo
  }

  // ---------------------------------------------------------------- state

  property var builds: []
  property bool reachable: true
  property string errorText: ""
  property bool loading: false
  // The branch the script resolved for us. Held so the second poll onwards
  // costs one API call instead of two: without it every refresh asks GitHub
  // what the default branch is, and that answer changes about once never.
  property string resolvedBranch: ""
  // The payload as it was last applied. Assigning a new array to the model
  // throws every delegate away and builds them again, and a poll that found
  // nothing new has nothing to rebuild for: the list would flicker, the
  // scroll position would jump, and it would all be for the same five rows.
  property string appliedBuilds: ""
  // The project the payload says it is about, which is the setting in normal
  // use and the invented one while the demo is on. Everything on screen reads
  // this rather than the setting, so a demo never has half the panel showing
  // somebody's real repository name.
  property string reportedRepo: ""
  property bool demoMode: false
  property int cursor: 0
  property bool cursorPlaced: false
  // Where the cursor is across a row: 0 is the build itself, 1 is the pull
  // request it came in through. Kept as a number rather than a per-row object
  // so walking up and down holds its place: if you were on the pull requests,
  // you stay on them.
  property int column: 0

  // The settings screen. It opens by itself the first time the panel is used
  // without a project, because a widget that shows an empty list and expects
  // you to go looking through the bar's own settings for the one field it
  // needs has not really been set up at all.
  property bool settingsOpen: false
  property var branchOptions: []
  property bool branchesLoading: false
  property string settingsError: ""
  property string draftBranch: ""
  // What the project field is worth right now. Checked while you type rather
  // than on save, because "no such project, or gh cannot see it" is the
  // answer you want next to the field you are still holding, not after the
  // screen has closed and the bar has gone grey.
  property string checkState: "idle"    // idle | checking | ok | error
  // The card turns over to show its other side. The angle is driven by the
  // animation below and read by the transform on the content.
  property real flipAngle: 0
  property bool pendingSettings: false
  // The card pulls back as it turns. Without it the rotated content swings
  // outside the card's own border, which does not move: the panel background
  // is the shell's, and only what is inside it is ours to turn.
  readonly property real flipScale:
    1 - 0.16 * Math.abs(Math.sin(flipAngle * Math.PI / 180))
  property string checkedRepo: ""
  property string checkedDefault: ""
  property int checkedBranchCount: 0

  // Seconds since the epoch, moved on by the ticker below rather than read
  // per binding: a running build's duration counts up in the panel, and the
  // green in the bar has to expire on its own without a poll landing first.
  property double nowSec: Date.now() / 1000

  readonly property var latest: builds.length > 0 ? builds[0] : null
  readonly property string branchLabel: resolvedBranch !== "" ? resolvedBranch
                                                              : (branchSetting !== "" ? branchSetting : "")

  readonly property bool configured: validRepo(repo)
  readonly property string displayRepo: reportedRepo !== "" ? reportedRepo : repo

  // A success is only worth a colour for as long as it is news.
  readonly property bool holding:
    latest !== null && latest.state === "success"
    && (nowSec - Number(latest.finishedAt)) < holdSec

  readonly property string barState: {
    if (!configured) return "unset"
    if (!reachable) return "unreachable"
    if (!latest) return "idle"
    if (latest.state === "running") return "running"
    if (latest.state === "failure") return "failure"
    if (holding) return "success"
    return "idle"
  }

  // Omarchy themes carry a foreground, an accent and an urgent, and no green.
  // Green is what a passing build is everywhere there is a build, and taking
  // the accent for it would leave "finished" looking exactly like "working"
  // on a theme whose accent happens to be warm. So this one is picked rather
  // than themed. Red comes from the theme, because urgent is what urgent is
  // for and every theme has thought about it.
  // nf-fa-database, U+F1C0. Written as an escape rather than as the character
  // itself: a private-use codepoint does not always survive the path from an
  // editor to disk, and what arrives is an empty string and an invisible icon.
  readonly property string iconMigration: "\uF1C0"
  // nf-fa-cog, U+F013.
  readonly property string iconSettings: "\uF013"

  readonly property color green: "#5FA46B"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color muted: Qt.darker(foreground, 1.6)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function stateColor(state) {
    if (state === "running") return root.green
    if (state === "success") return root.green
    if (state === "failure") return root.urgent
    return root.muted
  }

  // The last build's own colour, whatever the bar is doing about it. Grey for
  // a cancelled one, nothing at all when there is no build to report on.
  readonly property color badgeColor: {
    if (!configured || !reachable || !latest) return Qt.rgba(0, 0, 0, 0)
    if (latest.state === "success") return root.green
    if (latest.state === "failure") return root.urgent
    if (latest.state === "cancelled" || latest.state === "skipped") return root.muted
    return Qt.rgba(0, 0, 0, 0)
  }

  // The mark is loud only while something is worth being loud about. Once
  // the minute is up it goes back to being an ordinary bar icon and lets the
  // badge carry the news.
  readonly property color markColor: {
    if (barState === "unset") return root.muted
    if (barState === "unreachable" || barState === "failure") return root.urgent
    if (barState === "success" || barState === "running") return root.green
    return root.foreground
  }

  // ------------------------------------------------------------------ bar

  readonly property int labelWidth: showLabel && label !== "" ? labelMetrics.implicitWidth : 0
  // The mark, plus the couple of pixels the badge hangs off its corner by.
  // Without them the dot spills onto whatever widget sits next in the bar.
  readonly property int barContentWidth:
    Style.bar.iconFont + Style.space(4) + (labelWidth > 0 ? labelWidth + Style.space(5) : 0)
  // Panel is a bare Item with no size of its own, so the bar would hand this
  // widget zero width. Set it from the computed content width, never from a
  // child that fills this item: that is a loop where nothing decides the
  // size, the content still paints, and the button quietly stops being
  // clickable.
  readonly property int barSlot: barContentWidth + Style.space(10)

  // The bar draws a coloured mark under a module whose panel is open, and a
  // module may say how long that mark should be. A hint of zero is read as
  // "no hint given" and falls back to a fraction of the slot, so the way to
  // decline it is the smallest number that still passes that test and rounds
  // to nothing. The panel opening under the mark is its own announcement;
  // a second one underneath is a line of colour saying what you can already
  // see.
  readonly property real openPanelIndicatorWidth: 0.4
  readonly property real openPanelIndicatorHeight: 0.4

  implicitWidth: bar && bar.vertical ? (bar ? bar.barSize : Style.bar.sizeHorizontal) : barSlot
  implicitHeight: bar && bar.vertical ? barSlot : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  // Measured off-screen so the bar slot can be sized before anything is drawn.
  Text {
    id: labelMetrics
    visible: false
    text: root.label
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // -------------------------------------------------------------- helpers

  // Both of these travel back out: the repository into the script's argument
  // list, the sha into a URL. The script checks the repository too; this is
  // the near end of the same fence.
  function validRepo(name) {
    return /^[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._-]*$/.test(String(name))
  }
  function validSha(sha) { return /^[0-9a-f]{7,40}$/.test(String(sha)) }

  // Everything that identifies a GitHub repository, reduced to owner/name:
  // the address bar (with or without a /tree/main tail), the clone URL, the
  // ssh remote, or owner/name typed by hand. A URL on some other host is
  // refused rather than trimmed into a shape that looks right, because
  // gitlab.com/group/project would otherwise silently become a GitHub query
  // for a repository that is not the one you pasted.
  function normalizeRepo(value) {
    var s = String(value || "").trim().replace(/\s+/g, "")
    if (s === "") return ""

    var m = s.match(/^git@github\.com:(.+)$/i)
    if (m) {
      s = m[1]
    } else {
      m = s.match(/^(?:[a-z][a-z0-9+.-]*:\/\/)?(?:www\.)?github\.com\/(.+)$/i)
      if (m) s = m[1]
      else if (/:\/\/|@/.test(s)) return ""
    }

    s = s.replace(/\.git$/i, "")
    var parts = s.split("/").filter(function (p) { return p !== "" })
    if (parts.length < 2) return ""
    return parts[0] + "/" + parts[1]
  }
  function validBranch(name) { return /^[A-Za-z0-9][A-Za-z0-9._\/-]*$/.test(String(name)) }

  // Markup stripped rather than escaped: the bar tooltip is the shell's own
  // component, so `textFormat` there is not ours to set.
  function plain(s) { return String(s || "").replace(/[<>]/g, "") }

  function formatDuration(seconds) {
    var s = Math.max(0, Math.round(Number(seconds) || 0))
    if (s < 60) return s + "s"
    var m = Math.floor(s / 60)
    if (m < 60) return m + "m " + (s % 60) + "s"
    var h = Math.floor(m / 60)
    return h + "h " + (m % 60) + "m"
  }

  function formatAgo(epoch) {
    var s = Math.max(0, Math.round(root.nowSec - Number(epoch)))
    if (s < 60) return "just now"
    var m = Math.floor(s / 60)
    if (m < 60) return m + "m ago"
    var h = Math.floor(m / 60)
    if (h < 24) return h + "h ago"
    return Math.floor(h / 24) + "d ago"
  }

  function stateWord(state) {
    if (state === "running") return "running"
    if (state === "success") return "passed"
    if (state === "failure") return "failed"
    if (state === "cancelled") return "cancelled"
    if (state === "skipped") return "skipped"
    return state
  }

  function buildDuration(build) {
    if (!build) return 0
    if (build.state === "running") return Math.max(0, root.nowSec - Number(build.startedAt))
    return Number(build.durationSec) || 0
  }

  // The workflows worth naming under a row: the ones that went wrong. Naming
  // all of them turns every row into a paragraph, and on a green build the
  // list says nothing you did not already read from the colour.
  function troubleRuns(build) {
    if (!build || !build.runs) return []
    var out = []
    for (var i = 0; i < build.runs.length; i++) {
      var r = build.runs[i]
      if (r.state === "failure" || r.state === "cancelled") out.push(r.name)
    }
    return out
  }

  // The jobs of a running build that are worth a line: the ones actually
  // working, and any that already failed while the rest carries on. A
  // finished build gets none of this, because then the duration and the
  // colour say everything there is to say.
  function runningJobs(build) {
    if (!build || build.state !== "running" || !build.runs) return []
    var out = []
    for (var i = 0; i < build.runs.length; i++) {
      var run = build.runs[i]
      if (!run.jobs) continue
      for (var j = 0; j < run.jobs.length; j++) {
        var job = run.jobs[j]
        if (job.state !== "running" && job.state !== "failure") continue
        out.push({ workflow: String(run.name || ""), name: String(job.name || ""),
                   state: String(job.state), step: String(job.currentStep || ""),
                   done: Number(job.stepsDone) || 0, total: Number(job.stepCount) || 0 })
      }
    }
    return out
  }

  // The pull request a commit came in through, if it says so. Merge commits
  // start with "Merge pull request #1977 from ..." and a squashed one ends in
  // "(#1977)", so both shapes are looked at, and only a run of digits counts.
  function prNumber(build) {
    if (!build) return ""
    var sources = [String(build.message || ""), String(build.detail || "")]
    for (var i = 0; i < sources.length; i++) {
      var found = sources[i].match(/#(\d{1,7})(?!\d)/)
      if (found) return found[1]
    }
    return ""
  }

  function openPr(number) {
    if (!root.validRepo(root.repo) || !/^[0-9]{1,7}$/.test(String(number))) return
    openProc.command = ["xdg-open", "https://github.com/" + root.repo + "/pull/" + String(number)]
    openProc.running = true
    root.close()
  }

  function tooltipText() {
    if (!root.configured) return "GitHub Build Monitor: no project set"
    var head = root.displayRepo + (root.branchLabel !== "" ? " · " + root.branchLabel : "")
    if (!root.reachable) return head + "\n" + (root.errorText !== "" ? root.errorText : "unreachable")
    if (!root.latest) return head + "\nNo builds on this branch yet"
    var b = root.latest
    var line = root.stateWord(b.state) + " · " + root.formatDuration(root.buildDuration(b))
    if (b.state !== "running") line += " · " + root.formatAgo(b.finishedAt)
    return head + "\n" + line + "\n" + String(b.message || "")
  }

  function titleText() {
    if (!root.configured) return "GitHub Build Monitor"
    return root.displayRepo + (root.branchLabel !== "" ? "  ·  " + root.branchLabel : "")
  }

  // ------------------------------------------------------------- settings

  // Written back into this widget's own entry in shell.json, which is where
  // the bar's settings screen reads from too, so the two never disagree and
  // nothing here needs a config file of its own. Applied locally first so the
  // panel redraws on the click rather than on the write coming back.
  function persistSettings(values) {
    // Every write is a no-op while the demo is on, so a click during a
    // screenshot session cannot quietly repoint the widget at the invented
    // project it is showing.
    if (root.demoMode) return

    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Nothing about a settings screen has to be a flip. But a bar widget is a
  // small object you look at rather than a page you navigate, and turning it
  // over to find its controls on the back is how a small object works. The
  // swap happens at the halfway point, edge on, where there is nothing to see
  // anyway, so the two sides never overlap.
  function flipTo(open) {
    if (flipAnim.running) return
    if (open === root.settingsOpen) return
    root.pendingSettings = open
    flipAnim.start()
  }

  SequentialAnimation {
    id: flipAnim

    NumberAnimation {
      target: root; property: "flipAngle"
      to: 90; duration: 190; easing.type: Easing.InCubic
    }

    ScriptAction {
      script: {
        // Round the far side of the turn rather than continuing to 180, which
        // would leave everything mirrored.
        root.flipAngle = -90
        if (root.pendingSettings) root.openSettings()
        else root.closeSettings()
      }
    }

    NumberAnimation {
      target: root; property: "flipAngle"
      to: 0; duration: 260; easing.type: Easing.OutCubic
    }
  }

  function openSettings() {
    root.settingsError = ""
    root.checkState = "idle"
    root.checkedRepo = ""
    root.draftBranch = root.branchSetting
    root.settingsOpen = true
    repoField.text = root.displayRepo !== "" ? "https://github.com/" + root.displayRepo
                                             : String(root.setting("repo", "") || "")
    root.loadBranches(repoField.text)
    // Focus is not handed over by anything when a view is swapped in, and an
    // unfocused form reads as a dead one.
    Qt.callLater(function() { repoField.forceActiveFocus(); repoField.selectAll() })
  }

  function closeSettings() {
    root.settingsOpen = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function saveSettings() {
    var normalized = root.normalizeRepo(repoField.text)
    if (normalized === "") {
      root.checkState = "error"
      root.settingsError = "That is not a GitHub project. Paste the URL of one."
      return
    }
    // Saving something gh cannot reach would leave a grey bar and no reason
    // for it, so the check has to have said yes first. It is kept pressable
    // rather than disabled: a button that vanishes from the focus ring until
    // some other field is right is a button you find by tabbing past where it
    // should be.
    if (root.checkState !== "ok") {
      root.loadBranches(repoField.text)
      return
    }
    var branch = String(root.draftBranch || "")
    if (branch !== "" && !root.validBranch(branch)) branch = ""

    root.persistSettings({ repo: normalized, branch: branch })
    root.resolvedBranch = ""
    root.builds = []
    root.reachable = true
    root.errorText = ""
    root.refresh()
    // Turned back rather than swapped out, so saving ends the way it began.
    if (root.settingsOpen) root.flipTo(false)
  }

  function loadBranches(value) {
    var normalized = root.normalizeRepo(value)
    root.branchOptions = []
    root.checkedRepo = ""
    root.settingsError = ""

    if (String(value || "").trim() === "") { root.checkState = "idle"; return }
    if (normalized === "") {
      root.checkState = "error"
      root.settingsError = "That is not a GitHub project URL."
      return
    }
    if (branchProc.running) return

    root.checkState = "checking"
    root.branchesLoading = true
    branchProc.command = [root.script, "branches", normalized]
    branchProc.running = true
  }

  // One request after you stop typing, not one per keystroke.
  Timer {
    id: checkTimer
    interval: 650
    onTriggered: root.loadBranches(repoField.text)
  }

  function applyBranches(text) {
    root.branchesLoading = false

    var payload
    try { payload = JSON.parse(text) } catch (e) { payload = null }

    if (!payload || payload.ok !== true) {
      root.branchOptions = []
      root.checkState = "error"
      root.checkedRepo = ""
      // The one place where not having access has to be said out loud: this
      // is the screen where somebody just typed the project in.
      root.settingsError = payload && payload.error ? String(payload.error)
                                                    : "Could not read that project."
      return
    }

    root.settingsError = ""
    root.checkState = "ok"
    root.checkedRepo = String(payload.repo || "")
    root.checkedDefault = String(payload.default || "")
    root.checkedBranchCount = (payload.branches || []).length
    var options = [{ value: "", label: "Default branch" + (payload.default ? " (" + String(payload.default) + ")" : "") }]
    var list = payload.branches || []
    for (var i = 0; i < list.length; i++) options.push({ value: String(list[i]), label: String(list[i]) })
    root.branchOptions = options
  }

  Process {
    id: branchProc
    stdout: StdioCollector { onStreamFinished: root.applyBranches(text) }
    onExited: function(exitCode) { root.branchesLoading = false }
  }

  // ------------------------------------------------------------- fetching

  function refresh() {
    if (!root.configured) {
      root.builds = []
      root.reachable = true
      root.errorText = ""
      return
    }
    if (listProc.running) return
    var branch = root.resolvedBranch !== "" ? root.resolvedBranch : root.branchSetting
    if (branch !== "" && !root.validBranch(branch)) branch = ""
    root.loading = true
    listProc.command = [root.script, "status", root.repo, branch,
                        String(root.historyCount), root.flagPattern]
    listProc.running = true
  }

  function applyPayload(text) {
    root.loading = false
    root.nowSec = Date.now() / 1000

    var payload
    try { payload = JSON.parse(text) } catch (e) { payload = null }

    if (!payload || payload.ok !== true) {
      root.reachable = false
      root.errorText = payload && payload.error ? String(payload.error) : "Could not read the builds."
      return
    }

    root.reachable = true
    root.errorText = ""
    root.demoMode = payload.demo === true
    if (payload.repo) root.reportedRepo = String(payload.repo)
    if (payload.branch) root.resolvedBranch = String(payload.branch)

    var incoming = JSON.stringify(payload.builds || [])
    if (incoming !== root.appliedBuilds) {
      root.appliedBuilds = incoming
      root.builds = payload.builds || []
      if (root.cursor >= root.builds.length) root.cursor = Math.max(0, root.builds.length - 1)
    }
  }

  // Polled at three speeds. A running build is the only time the mark can
  // change on its own without anybody pushing anything, and it is also the
  // only time somebody is watching it, so that is where the requests go. Idle
  // costs one call a minute, which is a little over a percent of an hour's
  // API budget.
  Timer {
    interval: {
      if (!root.configured) return 60000
      if (root.barState === "running") return 10000
      if (root.opened) return 15000
      return 60000
    }
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // The clock behind the counting duration and the expiring green. It runs
  // only while something depends on it: a build in flight, a success still
  // inside its minute, or an open panel showing relative times.
  Timer {
    interval: 1000
    repeat: true
    running: root.opened || root.barState === "running" || root.holding
    onTriggered: root.nowSec = Date.now() / 1000
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      onStreamFinished: root.applyPayload(text)
    }
    onExited: function(exitCode) { root.loading = false }
  }

  Process { id: openProc }

  function openBuild(build) {
    if (!build || !root.validRepo(root.repo) || !root.validSha(build.sha)) return
    // Built from a sha we matched against a hex pattern and a repository name
    // that matched owner/name, behind a literal prefix. The html_url the API
    // sent is not used: it is a string from the network heading for something
    // that opens it.
    var url = "https://github.com/" + root.repo + "/commit/" + String(build.sha) + "/checks"
    openProc.command = ["xdg-open", url]
    openProc.running = true
    root.close()
  }

  function buildAt(index) {
    return index >= 0 && index < root.builds.length ? root.builds[index] : null
  }

  // Whether the row under the cursor has a second thing to walk to.
  function rowHasPr(index) {
    return root.prNumber(root.buildAt(index)) !== ""
  }

  function activateCursor() {
    var build = root.buildAt(root.cursor)
    if (!build) return
    if (root.column === 1 && root.rowHasPr(root.cursor)) root.openPr(root.prNumber(build))
    else root.openBuild(build)
  }

  function moveCursor(step, wrap) {
    if (root.builds.length === 0) return
    var next = root.cursor + step
    if (next < 0) next = wrap ? root.builds.length - 1 : 0
    else if (next >= root.builds.length) next = wrap ? 0 : root.builds.length - 1
    root.cursor = next
    // A row without a pull request has nothing in the second column, so the
    // cursor falls back rather than sitting on something that is not there.
    if (root.column === 1 && !root.rowHasPr(next)) root.column = 0
    list.positionViewAtIndex(next, ListView.Contain)
  }

  function moveColumn(step) {
    if (!root.rowHasPr(root.cursor)) { root.column = 0; return }
    root.column = Math.min(1, Math.max(0, root.column + step))
  }

  onOpenedChanged: {
    if (opened) {
      if (!cursorPlaced) { cursor = 0; column = 0; cursorPlaced = true }
      if (!configured) openSettings()
      refresh()
    } else {
      cursorPlaced = false
      settingsOpen = false
      // A panel closed halfway through the turn opens flat again next time.
      flipAngle = 0
    }
  }

  // ------------------------------------------------------------- the mark
  //
  // One circle in four treatments, so the shape is the widget and the colour
  // is the news. At bar size that is about as much as sixteen pixels holds:
  // a ring, a fill, and a gap in the ring that turns.
  component StatusMark: Item {
    id: mark
    property color markColor: "white"
    property bool spinning: false
    property bool filled: false
    property real thickness: Math.max(1.4, width * 0.16)

    Shape {
      anchors.fill: parent
      antialiasing: true
      layer.enabled: true
      layer.samples: 4
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeColor: mark.markColor
        strokeWidth: mark.thickness
        capStyle: ShapePath.RoundCap
        fillColor: mark.filled ? mark.markColor : "transparent"

        PathAngleArc {
          centerX: mark.width / 2
          centerY: mark.height / 2
          radiusX: (mark.width - mark.thickness) / 2
          radiusY: (mark.height - mark.thickness) / 2
          startAngle: -90
          sweepAngle: mark.spinning ? 280 : 360
        }
      }
    }

    RotationAnimator on rotation {
      from: 0
      to: 360
      duration: 1100
      loops: Animation.Infinite
      running: mark.spinning
    }
  }

  // The GitHub mark, from Simple Icons (CC0), as one path on a 24x24 grid.
  // A brand mark says which service this is in a way a generic circle cannot,
  // and at bar size a shape with a silhouette survives where an outline does
  // not. It carries the build's colour, which is the one place in this widget
  // where colour is information rather than decoration.
  component GithubMark: Item {
    id: gh
    property color markColor: "white"

    Item {
      anchors.centerIn: parent
      width: 24
      height: 24
      scale: Math.min(gh.width, gh.height) / 24

      Shape {
        anchors.fill: parent
        antialiasing: true
        // A mark this size aliases badly without it: the octocat's tail is
        // under a pixel wide at thirteen.
        layer.enabled: true
        layer.samples: 4
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
          fillColor: gh.markColor
          strokeWidth: 0
          fillRule: ShapePath.WindingFill
          PathSvg {
            path: "M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"
          }
        }
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: root.barSlot
    opticalSize: root.barContentWidth
    opacity: root.configured ? 1 : 0.55
    tooltipText: root.plain(root.tooltipText())

    iconComponent: Component {
      Item {
        Row {
          anchors.centerIn: parent
          spacing: Style.space(5)

          // The mark steps aside for the spinner while a build runs, rather
          // than trying to hold both in thirteen pixels. A logo that spins
          // reads as a loading screen, and a ring drawn around a logo at this
          // size is two shapes fighting over the same four pixels. Swapping
          // them also means the moment a build starts is visible from the
          // corner of your eye, which is the only moment this widget has to
          // announce anything.
          Item {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.round(Style.bar.iconFont * 0.88)
            height: width

            // The mark steps aside for the spinner while a build runs, rather
            // than trying to hold both in thirteen pixels. A logo that spins
            // reads as a loading screen, and a ring drawn around a logo at
            // this size is two shapes fighting over the same four pixels.
            // Swapping them also means the moment a build starts is visible
            // from the corner of your eye, which is the only moment this
            // widget has to announce anything.
            GithubMark {
              id: barMark
              anchors.fill: parent
              visible: root.barState !== "running"
              markColor: root.markColor
            }

            // And when nothing is running, the badge is what is left. The
            // mark going green is loud and lasts a minute; after that the
            // dot keeps saying where the branch stands without shouting
            // about it, which is the difference between news and a fact.
            Rectangle {
              visible: root.barState !== "running" && root.badgeColor.a > 0
              anchors.right: barMark.right
              anchors.top: barMark.top
              // Sitting off the corner rather than inside it. A dot tucked
              // within the silhouette is a few pixels of colour surrounded by
              // logo, and at bar size that reads as an artefact; hanging over
              // the edge it reads as a badge. Top right, where an unread count
              // rides an app icon, because that is the corner an eye already
              // checks.
              anchors.rightMargin: -Math.round(parent.width * 0.34)
              anchors.topMargin: -Math.round(parent.width * 0.18)
              width: Math.max(Style.space(8), Math.round(parent.width * 0.66))
              height: width
              radius: width / 2
              color: root.badgeColor
              // A rim in the bar's own background separates the dot from the
              // mark it sits on, so the corner it covers still reads as a
              // corner and not as two shapes fused together.
              border.width: Math.max(1, Math.round(parent.width * 0.10))
              border.color: Color.bar.background
            }

            StatusMark {
              anchors.centerIn: parent
              width: Math.round(parent.width * 0.86)
              height: width
              visible: root.barState === "running"
              markColor: root.green
              spinning: root.barState === "running"
              filled: false
            }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.showLabel && root.label !== ""
            text: root.label
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
            color: root.opened ? Color.accent : root.foreground
          }
        }
      }
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // ---------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // KeyboardPanel focuses this on open through a Qt.callLater of its own,
    // and it wins the race against anything the panel does in the same tick.
    // So the form says so here rather than reaching for the focus itself.
    focusTarget: root.settingsOpen ? repoField : keyCatcher
    // One width for both sides. The card turns over rather than being
    // replaced, and a card that changes size halfway through the turn is two
    // cards. Read as a plain property rather than through fittedContentWidth,
    // which settles on open and does not look again afterwards.
    readonly property int desiredWidth: Style.space(400)
    contentWidth: Math.min(desiredWidth,
                           panel.availableCardWidth > 0 ? panel.availableCardWidth : desiredWidth)
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the form is up this forwards every key to the controls in it
      // without firing a signal of its own. Declaring Keys.onPressed on the
      // instance would replace the component's handler rather than run before
      // it, and the panel would lose its arrows for good.
      blocked: root.settingsOpen
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy, false)
        else if (dx !== 0) root.moveColumn(dx)
      }
      // Tab wraps where the arrows clamp, so a list you are walking with one
      // hand comes back around instead of stopping dead at the last build.
      onTabRequested: function(direction) { root.moveCursor(direction, true) }
      // Only activateRequested, never returnRequested as well: Enter fires
      // both, and a handler on each opens the browser twice.
      onActivateRequested: root.activateCursor()
      onTextKey: function(t) {
        if (t === "r") root.refresh()
        else if (t === "o") root.activateCursor()
        // Tab belongs to the key catcher while the list is up, so the gear
        // cannot be reached by walking to it. This is how you get there.
        else if (t === "s") root.flipTo(true)
      }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(6)

        // Centre, rotate about the vertical axis, project, put back. The
        // projection is the difference between a card turning over and a card
        // being squashed sideways: without that third matrix the far edge
        // never comes closer than the near one.
        transform: [
          Translate { x: -content.width / 2; y: -content.height / 2 },
          Scale { xScale: root.flipScale; yScale: root.flipScale },
          Rotation {
            axis.x: 0
            axis.y: 1
            axis.z: 0
            angle: root.flipAngle
          },
          Matrix4x4 {
            matrix: Qt.matrix4x4(1, 0, 0,       0,
                                 0, 1, 0,       0,
                                 0, 0, 1,       0,
                                 0, 0, -0.0009, 1)
          },
          Translate { x: content.width / 2; y: content.height / 2 }
        ]

        Item {
          width: parent.width
          height: Math.max(headerText.implicitHeight, gear.height)

          PanelSectionHeader {
            id: headerText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - gear.width - Style.space(6)
            text: root.settingsOpen ? "Settings" : root.titleText()
            textFormat: Text.PlainText
            elide: Text.ElideRight
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          PanelActionButton {
            id: gear
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.iconSettings
            tooltipText: root.settingsOpen ? "Back to the builds" : "Settings"
            foreground: root.settingsOpen ? Color.accent : root.foreground
            fontFamily: root.fontFamily
            focusable: true
            onClicked: root.flipTo(!root.settingsOpen)
          }
        }

        PanelSeparator { width: parent.width }

        // The form. A plain Item rather than a second PanelKeyCatcher: the
        // catcher reads keys before its descendants and turns Tab and Enter
        // into signals, so every control in here would be reachable and none
        // of them pressable. An ordinary ancestor sees only what the focused
        // control did not want, which leaves Qt's own focus chain intact.
        Item {
          id: settingsKeys
          width: parent.width
          height: root.settingsOpen ? settingsForm.implicitHeight : 0
          visible: root.settingsOpen

          // Fades and rises a few pixels on the way in. Only on the way in:
          // `visible` drops the moment the form closes, so the list underneath
          // is never drawing through a form that is still fading out.
          opacity: root.settingsOpen ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }

          transform: Translate {
            y: root.settingsOpen ? 0 : Style.space(10)
            Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
          }

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              // With nothing configured there is nothing to go back to, so
              // Escape leaves the panel rather than stranding you on a screen
              // with no way out.
              if (root.configured) root.flipTo(false)
              else root.close()
              event.accepted = true
            }
          }

          Column {
            id: settingsForm
            width: parent.width
            spacing: Style.space(14)

            // A hero rather than a row of fields straight away. This screen
            // opens by itself on a bar that may carry twenty widgets, so the
            // first thing it owes you is which one is asking, and the mark
            // says that faster than a line of text does.
            Column {
              width: parent.width
              spacing: Style.space(5)
              topPadding: Style.space(6)

              // The mark answers the question the field asks. It breathes
              // while the check is out, then turns green when gh can see the
              // project and red when it cannot. Colour only: a logo that
              // grows and springs back draws the eye to the movement rather
              // than to what the movement means, and the mark is the same
              // shape the bar will be carrying a second from now.
              GithubMark {
                id: heroMark
                anchors.horizontalCenter: parent.horizontalCenter
                width: Style.space(34)
                height: width

                // While the check is out the mark swings between the two
                // answers it could come back with, red and green, and then
                // settles on the one it got. Driven through a property of its
                // own rather than animating markColor directly: an animation
                // declared "on" a property replaces whatever binding was
                // there, and the binding is what tells the mark the answer
                // when the swinging stops.
                property color pulseColor: root.urgent

                SequentialAnimation on pulseColor {
                  running: root.checkState === "checking"
                  loops: Animation.Infinite
                  alwaysRunToEnd: false
                  ColorAnimation { to: root.green; duration: 650; easing.type: Easing.InOutSine }
                  ColorAnimation { to: root.urgent; duration: 650; easing.type: Easing.InOutSine }
                }

                markColor: root.checkState === "checking" ? heroMark.pulseColor
                         : root.checkState === "ok" ? root.green
                         : root.checkState === "error" ? root.urgent
                         : root.foreground

                // Off while it is swinging, or every step of the swing would
                // be smoothed again on top of itself and the whole thing would
                // drag behind.
                Behavior on markColor {
                  enabled: root.checkState !== "checking"
                  ColorAnimation { duration: 260 }
                }
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "GitHub Build Monitor"
                textFormat: Text.PlainText
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                color: root.foreground
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "Paste the project you want the bar to watch."
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.muted
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(4)

              PanelSectionHeader {
                width: parent.width
                text: "Project"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              TextField {
                id: repoField
                width: parent.width
                placeholderText: "https://github.com/owner/name"
                foreground: root.foreground
                // A shared TextField defaults this to false, which takes it
                // off the focus ring entirely: you can tab out of the field
                // the form opened on and never tab back into it.
                activeFocusOnTab: true
                onTextChanged: checkTimer.restart()
                onAccepted: root.loadBranches(text)
              }

              // The answer to "do I have access", under the field you are
              // typing in. A bar that has gone grey with no explanation is
              // what this line exists to prevent, and the place to say it is
              // here rather than three screens later.
              Item {
                width: parent.width
                height: root.checkState === "idle" ? 0 : checkLine.implicitHeight + Style.space(4)
                visible: root.checkState !== "idle"
                clip: true

                Row {
                  id: checkLine
                  anchors.left: parent.left
                  anchors.bottom: parent.bottom
                  width: parent.width
                  spacing: Style.space(6)

                  StatusMark {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(8)
                    height: width
                    markColor: root.checkState === "ok" ? root.green
                             : root.checkState === "error" ? root.urgent : root.muted
                    spinning: root.checkState === "checking"
                    filled: root.checkState !== "checking"
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(14)
                    text: {
                      if (root.checkState === "checking") return "Checking access..."
                      if (root.checkState === "ok") {
                        return root.checkedRepo + "  ·  " + root.checkedBranchCount
                               + (root.checkedBranchCount === 1 ? " branch" : " branches")
                      }
                      return root.settingsError !== "" ? root.settingsError
                                                       : "Could not read that project."
                    }
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.checkState === "error" ? root.urgent
                         : root.checkState === "ok" ? root.green : root.muted
                  }
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(4)

              PanelSectionHeader {
                width: parent.width
                text: "Branch"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Dropdown {
                id: branchDrop
                width: parent.width
                showLabel: false
                enabled: root.branchOptions.length > 0
                options: root.branchOptions.length > 0
                         ? root.branchOptions
                         : [{ value: "", label: root.checkState === "ok" ? "Default branch"
                                                                         : "Pick a project first" }]
                value: root.draftBranch
                foreground: root.foreground
                fontFamily: root.fontFamily
                onChanged: function(value) { root.draftBranch = String(value) }
              }
            }

            PanelSeparator { width: parent.width }

            Item {
              width: parent.width
              height: Math.max(footNote.implicitHeight, actions.implicitHeight)

              Text {
                id: footNote
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - actions.width - Style.space(10)
                text: "Access comes from gh."
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: Qt.darker(root.foreground, 2.0)
              }

              Row {
                id: actions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                // Declared in the order they are walked, which is why Cancel
                // is written first: Tab follows the order children appear in
                // the file, not where they land on screen.
                Button {
                  text: "Cancel"
                  focusable: true
                  enabled: root.configured
                  foreground: root.muted
                  fontFamily: root.fontFamily
                  onClicked: root.flipTo(false)
                }

                // Kept pressable even when the check has not passed. A submit
                // button that drops out of the focus ring until some other
                // field is right is a button you find by tabbing past where
                // it should be; pressing it early just runs the check.
                Button {
                  text: "Save"
                  bordered: true
                  focusable: true
                  foreground: root.checkState === "ok" ? Color.accent
                                                       : Qt.darker(root.foreground, 2.0)
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  onClicked: root.saveSettings()
                }
              }
            }
          }
        }

        // A widget with no repository set is not broken, it is unfinished, so
        // it says what to do rather than what went wrong.
        Text {
          width: parent.width
          visible: !root.configured && !root.settingsOpen
          text: "No project yet. Open the bar settings for this widget and paste "
                + "the GitHub URL, for example https://github.com/basecamp/omarchy."
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.muted
        }

        Text {
          width: parent.width
          visible: root.configured && !root.reachable && !root.settingsOpen
          text: root.errorText !== "" ? root.errorText : "Could not read the builds."
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.urgent
        }

        Text {
          width: parent.width
          visible: root.configured && root.reachable && root.builds.length === 0 && !root.settingsOpen
          bottomPadding: Style.space(4)
          text: root.loading ? "Looking..."
                             : "No pushes to this branch have built yet."
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.muted
        }

        ListView {
          id: list
          width: parent.width
          visible: root.builds.length > 0 && !root.settingsOpen
          clip: true
          model: root.builds
          // Air between the builds. Five rows stacked flush read as one block
          // of text you have to parse; the same five with room around them
          // read as five things, which is what they are.
          spacing: Style.space(6)
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          // Grows with what it holds and stops at whatever the card has left
          // once the header and the caption have had their share.
          readonly property int cap: {
            var chrome = Style.space(74)
            if (!root.reachable) chrome += Style.space(24)
            return Math.max(Style.space(140),
                            panel.availableCardHeight - panel.verticalContentInset - chrome)
          }
          height: Math.min(contentHeight, cap)

          delegate: Rectangle {
            id: row
            required property var modelData
            required property int index

            readonly property bool active: root.cursor === row.index || rowMouse.containsMouse
            readonly property var trouble: root.troubleRuns(row.modelData)

            width: list.width - (list.interactive ? Style.space(10) : 0)
            height: rowContent.implicitHeight + Style.space(14)
            radius: Style.cornerRadius
            // Every build sits on its own faint card, so a row is a thing with
            // edges rather than a paragraph among paragraphs. The cursor only
            // has to lift it a little from there.
            color: active
              ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.11)
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.045)

            Behavior on color { ColorAnimation { duration: 80 } }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onContainsMouseChanged: if (containsMouse) { root.cursor = row.index; root.column = 0 }
              onClicked: root.openBuild(row.modelData)
            }

            Row {
              id: rowContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(9)
              anchors.rightMargin: Style.space(9)
              spacing: Style.space(8)

              // The dot lines up with the middle of the title rather than
              // with the top of the block. The block grows downwards when a
              // running build lists its jobs, and a marker pinned to the top
              // of that stops pointing at the thing it marks.
              Item {
                width: Style.space(13)
                height: titleLine.height

                StatusMark {
                  anchors.centerIn: parent
                  width: Style.space(10)
                  height: width
                  markColor: root.stateColor(row.modelData.state)
                  spinning: row.modelData.state === "running"
                  filled: row.modelData.state !== "running"
                }
              }

              // Everything else hangs off one left edge and one right edge.
              Column {
                id: rowText
                width: parent.width - Style.space(13) - parent.spacing
                spacing: Style.space(3)

                // Line one carries the duration on its right, rather than
                // giving it a column of its own outside this one. That is
                // what puts the step counts of a running build under it on
                // exactly the same edge.
                Row {
                  id: titleLine
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - durationText.width - parent.spacing
                           - (migrationMark.visible ? migrationMark.width + parent.spacing : 0)
                    text: String(row.modelData.detail || "") !== ""
                          ? String(row.modelData.detail)
                          : String(row.modelData.message || "(no commit message)")
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    color: root.foreground
                  }

                  // A build that carries a schema change is worth knowing
                  // about before you deploy over it or roll it back, and that
                  // is not something the status colour can say.
                  Item {
                    id: migrationMark
                    anchors.verticalCenter: parent.verticalCenter
                    visible: row.modelData.flagged !== undefined && row.modelData.flagged.length > 0
                    width: visible ? migrationGlyph.implicitWidth : 0
                    height: migrationGlyph.implicitHeight

                    Text {
                      id: migrationGlyph
                      anchors.centerIn: parent
                      text: root.iconMigration
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      renderType: Text.NativeRendering
                      color: Color.accent
                    }

                    // A glyph this small says "something about the database"
                    // and nothing else. Which files, on hover, is the rest.
                    MouseArea {
                      id: migrationHover
                      anchors.fill: parent
                      anchors.margins: -Style.space(3)
                      hoverEnabled: true
                      acceptedButtons: Qt.NoButton
                    }

                    PanelToolTip {
                      visible: migrationHover.containsMouse
                      text: {
                        var paths = row.modelData.flagged || []
                        var head = paths.length === 1 ? "1 migration in this build:"
                                                      : paths.length + " migrations in this build:"
                        return head + "\n" + paths.join("\n")
                      }
                      fontFamily: root.fontFamily
                    }
                  }

                  Text {
                    id: durationText
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.formatDuration(root.buildDuration(row.modelData))
                    textFormat: Text.PlainText
                    horizontalAlignment: Text.AlignRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    color: row.modelData.state === "running" ? root.green : root.muted
                  }
                }

                // Line two: the merge commit's own subject, in grey, only
                // when line one took the pull request title off it.
                Text {
                  width: parent.width
                  visible: String(row.modelData.detail || "") !== ""
                  text: String(row.modelData.message || "")
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  color: root.muted
                }

                Row {
                  id: metaLine
                  width: parent.width
                  spacing: Style.space(5)

                  // Who pushed it. A local file the fetch script downloaded
                  // into its own cache: nothing in this panel ever loads a
                  // picture over the network, because an Image with a remote
                  // source is the shell process opening a connection to a
                  // host named in data it was handed.
                  ClippingRectangle {
                    id: avatarSlot
                    anchors.verticalCenter: parent.verticalCenter
                    visible: String(row.modelData.avatar || "") !== ""
                    width: visible ? Style.space(15) : 0
                    height: Style.space(15)
                    radius: width / 2
                    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)

                    Image {
                      anchors.fill: parent
                      source: "file://" + String(row.modelData.avatar || "")
                      sourceSize.width: Style.space(30)
                      sourceSize.height: Style.space(30)
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      smooth: true
                    }
                  }

                  // Its own item rather than a piece of the sentence next to
                  // it, because a link inside a Text means rich text, and
                  // rich text on a string that came out of a commit message
                  // is how a shell process ends up fetching somebody's image.
                  Text {
                    id: prLink
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.prNumber(row.modelData) !== ""
                    text: "#" + root.prNumber(row.modelData)
                    textFormat: Text.PlainText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption

                    readonly property bool onCursor: root.cursor === row.index && root.column === 1
                    font.underline: prMouse.containsMouse || onCursor
                    font.bold: onCursor
                    color: Color.accent

                    MouseArea {
                      id: prMouse
                      anchors.fill: parent
                      anchors.margins: -Style.space(2)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onContainsMouseChanged: if (containsMouse) { root.cursor = row.index; root.column = 1 }
                      onClicked: root.openPr(root.prNumber(row.modelData))
                    }
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                           - (avatarSlot.visible ? avatarSlot.width + parent.spacing : 0)
                           - (prLink.visible ? prLink.width + parent.spacing : 0)
                    text: {
                      var parts = [String(row.modelData.sha || "").substring(0, 7)]
                      if (row.modelData.state !== "running") parts.push(root.formatAgo(row.modelData.finishedAt))
                      else parts.push("running")
                      // The name only when there is no face for it. Both is
                      // the same fact twice, and the row is not wide enough
                      // to spend on that.
                      if (row.modelData.actor && !avatarSlot.visible) parts.push(String(row.modelData.actor))
                      if (row.trouble.length > 0) parts.push(row.trouble.join(", ") + " "
                        + (row.modelData.state === "cancelled" ? "cancelled" : "failed"))
                      // The link is its own item, so the separator that
                      // would have followed it has to be put back by hand.
                      return (prLink.visible ? "·  " : "") + parts.join("  ·  ")
                    }
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: row.modelData.state === "failure" ? root.urgent : root.muted
                  }
                }

                // What a running build is doing right now, one line per job
                // that is working or has already gone wrong. Same width as
                // the title line, so the step count lands under the duration.
                Repeater {
                  model: root.runningJobs(row.modelData)

                  delegate: Row {
                    required property var modelData
                    width: rowText.width
                    spacing: Style.space(6)
                    topPadding: Style.space(1)

                    StatusMark {
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(7)
                      height: width
                      markColor: modelData.state === "failure" ? root.urgent : root.green
                      spinning: modelData.state === "running"
                      filled: modelData.state !== "running"
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      width: parent.width - Style.space(7) - stepCount.width - parent.spacing * 2
                      text: modelData.step !== ""
                            ? modelData.name + "  ·  " + modelData.step
                            : modelData.name
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: modelData.state === "failure" ? root.urgent : root.foreground
                    }

                    Text {
                      id: stepCount
                      anchors.verticalCenter: parent.verticalCenter
                      visible: modelData.total > 0
                      text: modelData.done + "/" + modelData.total
                      textFormat: Text.PlainText
                      horizontalAlignment: Text.AlignRight
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: root.muted
                    }
                  }
                }
              }
            }
          }
        }

        // An icon button hands its tooltip to a mouse only, so a keyboard has
        // nothing to read. One dim line covers what the keys do.
        Text {
          width: parent.width
          visible: root.builds.length > 0 && !root.settingsOpen
          text: root.rowHasPr(root.cursor)
                ? "enter opens the " + (root.column === 1 ? "pull request" : "build")
                  + "  ·  \u2190 \u2192 switches  ·  esc closes"
                : "enter opens  ·  s settings  ·  r refreshes  ·  esc closes"
          textFormat: Text.PlainText
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: Qt.darker(root.foreground, 2.0)
        }
      }
    }
  }
}
