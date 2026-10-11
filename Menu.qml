import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "WheelModel.js" as WheelModel

// OmaWheel — weapon-wheel style menu for the Omarchy shell.
//
// RDR-style drill-in wheel that auto-populates from the same sources as
// the built-in omarchy.menu: default omarchy-menu.jsonc + user extension,
// same when:/checked: guards, same providers (apps native + fonts +
// power-profiles). One ring per level; hub goes back, wedge click
// descends or runs. Point + click, arrows + Enter fallback, type-to-filter
// search, destructive confirm, launch pulse, recents, custom image icons,
// and a graphical editor for the user file.
//
// Summon: omarchy-shell shell summon oma.wheel '{"menu":"root"}'
// Routes accept ids (system, setup.power) or aliases (power, settings).
// Editor: omarchy-shell shell summon oma.wheel '{"edit":true}'

Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // ---- lifecycle (standard menu plugin surface) ----
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.edit === true) { root.openEditor(); return }
    root.openRoute(payload.initialMenu || payload.menu || "root")
  }
  function close() { root.cancel() }
  function refresh() {
    defaultMenuFile.reload()
    userMenuFile.reload()
    return "ok"
  }
  function ping() { return "ok" }

  // No-UI diagnostic for the apps provider chain. Callable via:
  // omarchy-shell shell call oma.wheel debugApps x
  function debugApps() {
    var preLoaded = !!(root.providersLoaded && root.providersLoaded["apps"])
    var preRunning = providerProc.running
    root.loadProviderForMenu("apps")
    var libCount = -1
    var libError = ""
    try {
      libCount = root.appLibrary ? root.appLibrary.sortedEntries("").length : -2
    } catch (e) { libError = String(e && e.message ? e.message : e) }
    var appsRows = 0
    var appsCats = 0
    for (var i = 0; i < root.itemOrder.length; i++) {
      var e = root.item(root.itemOrder[i])
      if (!e) continue
      var underApps = e.parent === "apps" || WheelModel.isDescendantOf(root.items, e.id, "apps")
      if (!underApps) continue
      if (e.kind === "app") appsRows++
      else if (e.kind === "menu" && e.parent === "apps") appsCats++
    }
    return JSON.stringify({
      rowsLoaded: root.rowsLoaded,
      activeMenu: root.activeMenu,
      pendingRoute: root.pendingRoute,
      itemOrder: root.itemOrder.length,
      shellNull: !root.shell,
      shellInRoot: ("shell" in root),
      manifestNull: !root.manifest,
      omarchyPath: String(root.omarchyPath || ""),
      shellPluginId: root.shell ? String(root.shell.pluginId || "?") : "",
      appLibraryNull: !root.appLibrary,
      appLibraryUndefined: root.shell ? (typeof root.shell.appLibrary === "undefined") : "n/a",
      libEntries: libCount,
      libError: libError,
      appsRows: appsRows,
      appsCats: appsCats,
      appsEntryProvider: String((root.item("apps") || {}).provider || ""),
      recentCount: root.recentEntries.length,
      recentEntries: root.recentEntries,
      recentMenuPresent: !!root.items["recent"],
      iconIndexSize: Object.keys(root.iconIndex || {}).length,
      iconIndexScanned: root.iconIndexScanned,
      hiddenConfigured: Object.keys(root.configuredHiddenEntryIds || {}).length,
      hiddenDesktop: Object.keys(root.desktopHiddenEntryIds || {}).length,
      procRunning: providerProc.running,
      appsProviderLoaded: !!(root.providersLoaded && root.providersLoaded["apps"]),
      appsPreLoaded: preLoaded,
      appsPreRunning: preRunning,
      appsPostRunning: providerProc.running,
      appsScanner: root.appsScannerPath(),
      userRawKeys: Object.keys(root.userRawItems || {}),
      userCount: (root.userMenuItems || []).length,
      hasTestItem: !!root.items["test-item"],
      learnWhen: String((root.items["learn"] || {}).when || ""),
      defaultCount: (root.defaultMenuItems || []).length,
      ringIds: root.currentRows.map(function(r) { return r && r.id }),
      appsWhen: String((root.items["apps"] || {}).when || ""),
      whenFalse: Object.keys(root.whenResults || {}).filter(function(k) { return root.whenResults[k] === false }),
      eventLog: root.eventLog
    })
  }

  // ---- menu data (mirrors omarchy.menu sources) ----
  property string defaultMenuPath: omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
  property string userMenuPath: Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"
  property var defaultMenuItems: []
  property var userMenuItems: []
  property bool defaultReported: false
  property bool userReported: false
  property bool opened: false
  property bool rowsLoaded: false
  property string activeMenu: "root"
  property var items: ({})
  property var itemOrder: []
  property var navStack: []
  property var providersLoaded: ({})
  property var providerQueue: []
  property int providerRevision: 0
  property var whenResults: ({})
  property var checkedResults: ({})
  property bool guardsPending: false

  // ---- wheel state ----
  property int hoveredIndex: -1
  property int wheelSerial: 0
  property var currentRows: []
  // Type-to-filter: dim non-matches, snap hover to the best ring match,
  // show the global (deep) best match in the hub for Enter-to-launch.
  property string filterText: ""
  property var ringMatchMap: ({})
  property var bestGlobal: null
  property int matchCount: 0
  property bool confirmOpen: false
  property var confirmTarget: null
  property bool launchFlashing: false
  property string launchLabel: ""
  // Press + launch animation state. pressedIndex flashes the wedge sector
  // and pops its icon; shockT drives the expanding launch shockwave.
  property int pressedIndex: -1
  property real shockT: 0
  // ---- wheel editor (edits the USER extension file only, never defaults) ----
  property bool editorOpen: false
  property bool editorPending: false
  property string editorMenu: "root"
  property var userRawItems: ({})
  property var defaultIds: ({})
  property bool editorFormOpen: false
  property string editorEditingId: ""
  property bool editorLockKind: false
  property bool editorIsActionForm: true
  property string editorError: ""
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

  // Theme-conscious surfaces: every color comes from the central
  // [menu] section via Color.qml, geometry from Style tokens.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color selectedBorder: Color.menu.selectedBorder
  property color accent: Color.accent
  // Hover fill: the theme's selected-background hue at wheel opacity.
  // (The stock-selected roles compose to near-transparent on some
  // themes, which made hover look like it vanished.) Stays theme-driven:
  // switching themes re-tints the wheel with no code change.
  property color selectionFill: Util.alpha(Color.flatColor(Color.pick("menu.selected-background", "#003e50"), "#003e50"), 0.85)

  // Content color on top of a fill. No theme token exists for "text on
  // fill", so pick whichever of background/foreground contrasts more
  // (WCAG-style ratio). A fixed light/dark assumption breaks on light
  // themes, where foreground itself is dark. Adapts to any theme.
  function luminance(c) {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
  }
  function contentOn(fill) {
    var lf = root.luminance(fill)
    var lb = root.luminance(root.background)
    var lt = root.luminance(root.foreground)
    var cb = (Math.max(lf, lb) + 0.05) / (Math.min(lf, lb) + 0.05)
    var ct = (Math.max(lf, lt) + 0.05) / (Math.min(lf, lt) + 0.05)
    return cb > ct ? root.background : root.foreground
  }
  property int cornerRadius: Style.cornerRadius

  // Ring geometry (logical px via Style.space so themes scale it).
  readonly property int hubRadius: Style.space(128)
  // Gap between wedges and between wedges and hub, in logical px. The
  // angular wedge gap is derived from this so both read the same size.
  readonly property int wedgeGap: Style.space(10)
  readonly property int wheelRadius: Style.space(250)
  // Icons ride mid-ring, centered between hub and rim, in a box that
  // leaves breathing room on both sides of the wedge band. Dense rings
  // (>12 wedges, e.g. Graphics) step the box down so icons stop touching.
  // Boxes are sized to fill the band: inner edge stays clear of the hub
  // (128) and the outer edge clear of the rim (250) at mid-ring R 189.
  readonly property int ringCount: root.currentRows.length
  readonly property int iconBox: root.ringCount > 12 ? Style.space(56) : (root.ringCount > 8 ? Style.space(68) : Style.space(88))
  readonly property int iconRingR: (hubRadius + wheelRadius) / 2
  readonly property int wheelSize: (wheelRadius + Style.space(48)) * 2

  function item(id) { return root.items[id] || null }

  // Wedge path only (no style): shared by the base + highlight canvases.
  // Split-canvas idea from signaldirective/radial-menu (WTFPL) — hover
  // repaints one segment instead of the whole pie. Visuals unchanged.
  function traceWedge(ctx, cx, cy, i, n) {
    var step = Math.PI * 2 / n
    // Angular gap sized to read the same as the radial hub gap at mid-ring;
    // capped to a slice fraction so dense rings keep viable wedges.
    var gap = Math.min(step * 0.12, root.wedgeGap / root.iconRingR)
    var inner = root.hubRadius + root.wedgeGap
    var a0 = -Math.PI / 2 - step / 2 + i * step + gap / 2
    var a1 = -Math.PI / 2 - step / 2 + (i + 1) * step - gap / 2
    ctx.beginPath()
    ctx.arc(cx, cy, root.wheelRadius, a0, a1, false)
    ctx.arc(cx, cy, inner, a1, a0, true)
    ctx.closePath()
  }

  function resolveRoute(input) {
    return WheelModel.resolveRoute(root.items, root.itemOrder, input)
  }

  // Non-kept instances are born empty: FileViews populate async AFTER
  // the host delivers open(). A route requested before rowsLoaded would
  // fall back to root, so stash it and open once the merge lands.
  property string pendingRoute: ""
  // Deep links into provider-generated submenus (apps categories, fonts)
  // can't resolve until that provider's enumeration lands. Retry them on
  // every provider merge; each merge is finite so this always terminates.
  property string pendingProviderRoute: ""
  property var eventLog: []

  function traceEvent(msg) {
    var log = root.eventLog.concat([Date.now() + " " + msg])
    if (log.length > 12) log = log.slice(log.length - 12)
    root.eventLog = log
  }

  function openRoute(initialMenu) {
    root.traceEvent("openRoute in=" + String(initialMenu) + " rowsLoaded=" + root.rowsLoaded)
    if (!root.rowsLoaded) {
      root.pendingRoute = String(initialMenu || "root")
      root.opened = true
      return "ok"
    }
    root.pendingRoute = ""
    root.pendingProviderRoute = ""
    var id = root.resolveRoute(initialMenu)
    var entry = root.items[id]
    if (entry && entry.kind === "action" && entry.action) {
      root.recordEntryLaunch(entry)
      root.cancel()
      root.runAction(entry.action)
      return "ok"
    }
    if (entry && entry.kind === "link" && entry.target) id = entry.target
    if (!root.item(id)) {
      if (id !== "root") {
        root.pendingProviderRoute = String(initialMenu || "")
        root.loadAncestorProviders(root.pendingProviderRoute)
      }
      id = "root"
    }
    root.traceEvent("openRoute resolved=" + id)
    root.openExistingMenu(id)
    return "ok"
  }

  // Kick off enumeration for static provider menus on the path to an
  // unresolved deep link (e.g. "apps" for "apps.graphics"), so the merge
  // that creates the target actually happens.
  function loadAncestorProviders(route) {
    var parts = String(route || "").split(".")
    var prefix = ""
    for (var i = 0; i < parts.length - 1; i++) {
      prefix = prefix ? prefix + "." + parts[i] : parts[i]
      var entry = root.item(prefix)
      if (entry && entry.provider && !root.providersLoaded[prefix]) root.loadProviderForMenu(prefix)
    }
  }

  function retryPendingProviderRoute() {
    if (!root.opened || !root.pendingProviderRoute) return
    var pr = root.pendingProviderRoute
    root.pendingProviderRoute = ""
    root.traceEvent("retry provider route " + pr)
    root.openRoute(pr)
  }

  function openExistingMenu(id) {
    root.traceEvent("openExistingMenu id=" + id)
    var chain = []
    var cursor = root.item(id)
    var guard = 0
    while (cursor && cursor.parent && cursor.parent !== "" && guard < 32) {
      if (cursor.parent !== "root") {
        var parentEntry = root.item(cursor.parent)
        if (!parentEntry) break
        chain.unshift(cursor.parent)
        cursor = parentEntry
      } else break
      guard++
    }
    root.navStack = chain
    root.activeMenu = id
    root.hoveredIndex = -1
    root.pressedIndex = -1
    root.evaluateGuards()
    root.opened = true
    root.rebuildWheel()
    root.invalidateVolatileProvider(id)
    root.loadProviderForMenu(id)
    if (root.appLibrary) root.appLibrary.refreshIcons()
    root.wheelSerial++
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function cancel() {
    root.opened = false
    exitAnim.stop()
    pressTimer.stop()
    wheelHolder.scale = 1
    wheelHolder.opacity = 1
    root.shockT = 0
    root.pressedIndex = -1
    root.confirmOpen = false
    root.confirmTarget = null
    root.editorOpen = false
    root.editorPending = false
    root.pendingProviderRoute = ""
    root.editorFormOpen = false
    root.editorEditingId = ""
    root.editorError = ""
    root.pendingRoute = ""
    root.filterText = ""
    root.ringMatchMap = ({})
    root.bestGlobal = null
    root.matchCount = 0
    root.hoveredIndex = -1
    root.navStack = []
  }

  function setActiveMenu(id, pushHistory) {
    if (!root.item(id)) id = "root"
    if (pushHistory && id !== root.activeMenu) root.navStack = root.navStack.concat([root.activeMenu])
    root.activeMenu = id
    root.hoveredIndex = -1
    root.pressedIndex = -1
    root.filterText = ""
    root.rebuildWheel()
    root.invalidateVolatileProvider(id)
    root.loadProviderForMenu(id)
    root.wheelSerial++
  }

  function goBack() {
    if (root.navStack.length > 0) {
      var stack = root.navStack
      var previous = stack[stack.length - 1]
      root.navStack = stack.slice(0, -1)
      root.setActiveMenu(previous, false)
      return
    }
    var active = root.item(root.activeMenu)
    if (active && active.parent && active.parent !== "") {
      root.setActiveMenu(active.parent === "root" ? "root" : active.parent, false)
      return
    }
    root.cancel()
  }

  function triggerLaunch(entry) {
    if (!entry || root.launchFlashing) return
    root.launchLabel = root.labelFor(entry)
    root.launchFlashing = true
    exitAnim.restart()
  }

  function pressWedge(index) {
    if (index < 0 || index >= root.currentRows.length) return
    root.pressedIndex = index
    glowRing.requestPaint()
    pressTimer.restart()
  }

  Timer {
    id: pressTimer
    interval: 140
    repeat: false
    onTriggered: {
      root.pressedIndex = -1
      glowRing.requestPaint()
    }
  }

  function activateEntry(entry) {
    if (!entry || root.launchFlashing) return
    if (entry.kind === "menu" || entry.kind === "link") {
      var target = entry.kind === "link" ? entry.target : entry.id
      root.setActiveMenu(target || entry.id, true)
    } else if (entry.kind === "app") {
      var appId = entry.appId
      var label = entry.label
      root.triggerLaunch(entry)
      root.launchApp(appId, label)
    } else {
      var msg = root.destructiveMessage(entry)
      if (msg) {
        root.confirmTarget = entry
        confirmDialog.selectedIndex = 0
        root.confirmOpen = true
        return
      }
      root.triggerLaunch(entry)
      root.recordEntryLaunch(entry)
      root.runAction(entry.action)
    }
  }

  // Power actions that must never fire on a misclick. Matched on the
  // command's first token so trailing args can't sneak past.
  function destructiveMessage(entry) {
    if (!entry || entry.kind !== "action") return ""
    var cmd = String(entry.action || "").split(/\s+/)[0]
    if (cmd === "omarchy-system-shutdown") return "Shut down now?"
    if (cmd === "omarchy-system-reboot") return "Reboot now?"
    if (cmd === "omarchy-system-logout") return "Log out now?"
    return ""
  }

  function cancelConfirm() {
    root.confirmOpen = false
    root.confirmTarget = null
    confirmDialog.selectedIndex = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmDestructive() {
    var target = root.confirmTarget
    root.confirmOpen = false
    root.confirmTarget = null
    if (!target || !target.action) return
    root.recordEntryLaunch(target)
    root.cancel()
    root.runAction(target.action)
  }

  function activateIndex(index) {
    if (index < 0 || index >= root.currentRows.length) return
    var entry = root.currentRows[index]
    // Flash launches (menus navigate away instantly, clearing the press).
    if (entry && entry.kind !== "menu" && entry.kind !== "link") root.pressWedge(index)
    root.activateEntry(entry)
  }

  function runAction(action) {
    var command = String(action || "")
    if (!command) return
    Util.execDetached(command)
  }

  // ---- rows for the current ring ----
  function isVisible(entry) {
    return WheelModel.isVisible(root.items, root.itemOrder, root.whenResults, entry)
  }
  function labelFor(entry) {
    return WheelModel.labelFor(entry, root.checkedResults)
  }

  function rebuildWheel() {
    var rows = []
    if (root.rowsLoaded) {
      for (var i = 0; i < root.itemOrder.length; i++) {
        var child = root.item(root.itemOrder[i])
        if (!child || child.parent !== root.activeMenu) continue
        if (!root.isVisible(child)) continue
        rows.push(child)
      }
      if (root.activeMenu === "apps" || WheelModel.isDescendantOf(root.items, root.activeMenu, "apps")) {
        rows.sort(function(a, b) {
          var al = String(a.label || "").toLowerCase()
          var bl = String(b.label || "").toLowerCase()
          if (al < bl) return -1
          if (al > bl) return 1
          return String(a.id) < String(b.id) ? -1 : 1
        })
      }
    }
    root.currentRows = rows
    if (root.hoveredIndex >= rows.length) root.hoveredIndex = -1
    root.rebuildSearch()
  }

  function matchesQuery(entry, query) {
    return WheelModel.matchesQuery(entry, query, root.isVisible(entry))
  }
  function searchScore(entry, query) {
    return WheelModel.searchScore(root.items, entry, query)
  }
  function isRingMatch(entry) {
    if (!root.filterText.trim() || !entry) return true
    return root.ringMatchMap[entry.id] === true
  }

  function setFilter(next) {
    root.filterText = String(next || "")
    root.rebuildSearch()
  }

  // Recompute filter matches: ring-local map for dimming + global best
  // (deep under the active ring) for the hub readout and Enter-to-launch.
  // Hover snaps to the best ring match; -1 when the ring has none.
  function rebuildSearch() {
    var q = root.filterText.trim()
    var map = ({})
    var best = null
    var bestRingScore = 0
    var bestRingIndex = -1
    var count = 0
    if (q) {
      var scored = []
      for (var i = 0; i < root.itemOrder.length; i++) {
        var entry = root.item(root.itemOrder[i])
        if (!entry || entry.id === "root") continue
        if (!WheelModel.isDescendantOf(root.items, entry.id, root.activeMenu)) continue
        if (!root.matchesQuery(entry, q)) continue
        var s = root.searchScore(entry, q)
        scored.push({ entry: entry, score: s })
        if (entry.parent === root.activeMenu) {
          map[entry.id] = true
          if (bestRingIndex < 0 || s < bestRingScore) {
            bestRingScore = s
            bestRingIndex = root.ringIndexOf(entry.id)
          }
        }
      }
      scored.sort(function(a, b) {
        if (a.score !== b.score) return a.score - b.score
        var ap = WheelModel.pathFor(root.items, a.entry.id)
        var bp = WheelModel.pathFor(root.items, b.entry.id)
        return ap < bp ? -1 : (ap > bp ? 1 : 0)
      })
      count = scored.length
      best = scored.length > 0 ? scored[0].entry : null
    }
    root.ringMatchMap = map
    root.bestGlobal = best
    root.matchCount = count
    root.hoveredIndex = q ? bestRingIndex : (root.hoveredIndex >= root.currentRows.length ? -1 : root.hoveredIndex)
    root.wheelSerial++
  }

  function ringIndexOf(id) {
    for (var i = 0; i < root.currentRows.length; i++)
      if (root.currentRows[i] && root.currentRows[i].id === id) return i
    return -1
  }

  // Arrow-step hover; while filtering, cycle matching wedges only.
  function stepHover(delta) {
    var n = root.currentRows.length
    if (n === 0) return
    if (!root.filterText.trim()) {
      root.hoveredIndex = root.hoveredIndex < 0
        ? (delta < 0 ? n - 1 : 0)
        : (root.hoveredIndex + delta + n) % n
      return
    }
    var idxs = []
    for (var i = 0; i < n; i++) {
      var entry = root.currentRows[i]
      if (entry && root.ringMatchMap[entry.id] === true) idxs.push(i)
    }
    if (idxs.length === 0) { root.hoveredIndex = -1; return }
    var pos = idxs.indexOf(root.hoveredIndex)
    if (pos < 0) pos = delta < 0 ? idxs.length - 1 : 0
    else pos = (pos + delta + idxs.length) % idxs.length
    root.hoveredIndex = idxs[pos]
  }

  function activeTitle() {
    var entry = root.item(root.activeMenu)
    if (!entry || root.activeMenu === "root") return "Go"
    return entry.title || entry.label
  }
  function activePath() {
    if (root.activeMenu === "root") return ""
    return WheelModel.pathFor(root.items, root.activeMenu)
  }

  // Hub readout: wedges carry icons only, the focused wedge's text lives
  // in the center circle (classic weapon-wheel behavior).
  function hoveredEntry() {
    if (root.hoveredIndex < 0 || root.hoveredIndex >= root.currentRows.length) return null
    return root.currentRows[root.hoveredIndex]
  }
  // The entry the hub readout follows: deep best match while filtering,
  // hovered wedge otherwise. Null when the hub shows only the menu itself.
  function hubEntry() {
    if (root.filterText.trim()) return root.bestGlobal
    return root.hoveredEntry()
  }
  function hubEntryIsImage() {
    var e = root.hubEntry()
    return !!e && (e.kind === "app" || root.isImageIcon(e.icon))
  }
  function hubEntryIconSource() {
    var e = root.hubEntry()
    if (!e) return ""
    if (e.kind === "app") return root.iconSourceFor(e.appIcon)
    return root.iconSourceFor(e.icon)
  }
  function hubTitle() {
    if (root.launchFlashing) return root.launchLabel
    if (root.filterText.trim()) {
      if (root.bestGlobal) return root.labelFor(root.bestGlobal)
      return "No matches"
    }
    var e = root.hoveredEntry()
    return e ? root.labelFor(e) : root.activeTitle()
  }
  function hubSub() {
    if (root.launchFlashing) return "launching…"
    if (root.filterText.trim()) {
      if (root.bestGlobal) return WheelModel.pathFor(root.items, root.bestGlobal.id)
      return "for “" + root.filterText.trim() + "”"
    }
    var e = root.hoveredEntry()
    if (!e) return root.activeMenu === "root" ? root.currentRows.length + " items" : "hub: back"
    if (e.kind === "menu" || e.kind === "link") {
      var target = e.kind === "link" ? e.target : e.id
      // Provider-backed submenus (Apps, fonts) have no countable children
      // until their enumeration lands — never claim "0 items" meanwhile.
      if (e.provider && !(root.providersLoaded && root.providersLoaded[target])) return "…"
      var n = WheelModel.childCount(root.items, root.itemOrder, target)
      return n + (n === 1 ? " item ›" : " items ›")
    }
    if (e.kind === "app") return e.description || "launch app"
    return e.description || "run command"
  }

  // ---- wedge geometry: N dynamic sectors, first centered on top ----
  function stepDeg() {
    return root.currentRows.length > 0 ? 360 / root.currentRows.length : 360
  }
  function centerDeg(index) {
    return -90 + index * root.stepDeg()
  }
  function wedgeIndexAt(x, y, cx, cy) {
    var n = root.currentRows.length
    if (n === 0) return -1
    var dx = x - cx
    var dy = y - cy
    var r = Math.sqrt(dx * dx + dy * dy)
    if (r < root.hubRadius + root.wedgeGap || r > root.wheelRadius + Style.space(40)) return -1
    var deg = Math.atan2(dy, dx) * 180 / Math.PI
    var step = 360 / n
    var rel = ((deg + 90 + step / 2) % 360 + 360) % 360
    return Math.floor(rel / step) % n
  }

  // ---- JSONC sources ----
  function parseMenuJsonc(raw) { return WheelModel.parseMenuJsonc(raw) }

  function rebuildItemsFromSources() {
    // Both JSONC sources report independently (and in either order). A
    // merge with only one side would miss ids (e.g. "apps" lives in the
    // defaults) and mis-resolve a stashed pendingRoute to root.
    if (!root.defaultReported || !root.userReported) return
    var dids = ({})
    for (var d = 0; d < root.defaultMenuItems.length; d++) dids[root.defaultMenuItems[d].id] = true
    root.defaultIds = dids
    var merged = WheelModel.mergeMenuSources(root.defaultMenuItems, root.userMenuItems)
    root.providerRevision += 1
    root.providersLoaded = ({})
    root.providerQueue = []
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    root.rowsLoaded = true
    root.ensureRecentMenu()
    root.rebuildRecentRows()
    root.evaluateGuards()
    root.traceEvent("rebuild pending=" + root.pendingRoute + " opened=" + root.opened + " active=" + root.activeMenu)
    if (root.editorPending) {
      root.editorPending = false
      root.openEditor()
      return
    }
    if (root.pendingRoute) {
      var route = root.pendingRoute
      root.pendingRoute = ""
      root.openRoute(route)
      return
    }
    if (root.opened) {
      root.rebuildWheel()
      root.loadProviderForMenu(root.activeMenu)
      root.wheelSerial++
    } else {
      root.rebuildWheel()
    }
  }

  // ---- providers (same contract as omarchy.menu) ----
  // The scoped shell.appLibrary facade is null on this host (verified via
  // debugApps: null both for kept startup-loaded and fresh summoned
  // instances), so "apps" falls back to a self-sufficient .desktop scan
  // (appscan.py) with client-side icon resolution. When the facade exists
  // the native path is preferred (hidden-entry filtering, launch feedback).
  function appsScannerPath() {
    try {
      return decodeURIComponent(String(Qt.resolvedUrl("appscan.py")).replace(/^file:\/\//, ""))
    } catch (e) { return "" }
  }

  readonly property var providers: ({
    "apps": {
      script: "",
      volatile: true
    },
    "fonts": {
      script: "current=$(omarchy-font-current 2>/dev/null); omarchy-font-list 2>/dev/null | while read -r f; do [[ -z $f ]] && continue; printf '%s\\t%s\\t%s\\n' \"$f\" \"$f\" \"$current\"; done",
      icon: "\ue699",
      volatile: true,
      actionFor: function(value) { return "omarchy-font-set " + Util.shellQuote(value) }
    },
    "power-profiles": {
      script: "current=$(powerprofilesctl get 2>/dev/null); omarchy-powerprofiles-list 2>/dev/null | while read -r p; do [[ -z $p ]] && continue; printf '%s\\t%s\\t%s\\n' \"$p\" \"$p\" \"$current\"; done",
      icon: "\udb81\udc0b",
      actionFor: function(value) { return "omarchy-powerprofiles-set autodetect " + Util.shellQuote(value) }
    }
  })

  function slugify(value) { return WheelModel.slugify(value) }

  // Apps are grouped into XDG-category sub-wheels so the Apps ring holds
  // ~10 wedges instead of one per installed app. Order doubles as
  // priority: an app matching several mains lands in the first listed.
  readonly property var appCategories: [
    { key: "Game",        label: "Games",       icon: "\uf11b" },
    { key: "Network",     label: "Internet",    icon: "\uf0ac" },
    { key: "AudioVideo",  label: "Media",       icon: "\uf001" },
    { key: "Graphics",    label: "Graphics",    icon: "\uf03e" },
    { key: "Office",      label: "Office",      icon: "\uf15c" },
    { key: "Development", label: "Development", icon: "\uf121" },
    { key: "Education",   label: "Education",   icon: "\uf19d" },
    { key: "Science",     label: "Science",     icon: "\uf0c3" },
    { key: "System",      label: "System",      icon: "\uf0ad" },
    { key: "Settings",    label: "Settings",    icon: "\uf013" },
    { key: "Utility",     label: "Utilities",   icon: "\uf1de" },
    { key: "Other",       label: "Other",       icon: "\uf1b2" }
  ]
  // Top-level Recent menu icon (matches the old apps.recent wedge).
  readonly property string recentMenuIcon: "\uf1da"

  // Apps are bucketed into their XDG main category only. The global
  // top-level Recent menu duplicates rows separately (see rebuildRecentRows),
  // so nothing here diverts into Recent.
  function appCategoryFor(appId, cats) {
    var list = Array.isArray(cats) ? cats : String(cats || "").split(/[;,\s]+/)
    for (var i = 0; i < root.appCategories.length - 1; i++) {
      var key = root.appCategories[i].key
      for (var j = 0; j < list.length; j++)
        if (list[j] === key) return root.appCategories[i]
    }
    return root.appCategories[root.appCategories.length - 1]
  }

  // ---- hidden desktop entries (stock parity) ----
  // The stock menu hides apps from two lists; ids in either never get rows
  // here (categories, Recent duplicates, or search). Verbatim port of the
  // stock AppLibrary hide loading, ids normalized the same way.
  property var configuredHiddenEntryIds: ({})
  property var desktopHiddenEntryIds: ({})
  property bool hiddenEntriesScanned: false

  function normalizeDesktopId(id) {
    var value = String(id || "").trim()
    if (value.slice(-8) === ".desktop") value = value.slice(0, -8)
    return value
  }

  function isHiddenApp(appId) {
    var id = root.normalizeDesktopId(appId)
    if (!id) return false
    return root.configuredHiddenEntryIds[id] === true || root.desktopHiddenEntryIds[id] === true
  }

  function loadConfiguredHides(rawText) {
    var next = ({})
    var lines = String(rawText || "").split(/\n/)
    for (var i = 0; i < lines.length; i++) {
      var id = root.normalizeDesktopId(lines[i])
      if (id.length > 0) next[id] = true
    }
    root.configuredHiddenEntryIds = next
    root.refreshAppsForHides()
  }

  function loadDesktopHiddenEntries(rawText) {
    var next = ({})
    var lines = String(rawText || "").split(/\n/)
    for (var i = 0; i < lines.length; i++) {
      var id = root.normalizeDesktopId(lines[i])
      if (id.length > 0) next[id] = true
    }
    root.desktopHiddenEntryIds = next
    root.refreshAppsForHides()
  }

  function hiddenEntryScanCommand() {
    var desktop = [Quickshell.env("XDG_CURRENT_DESKTOP"), Quickshell.env("XDG_SESSION_DESKTOP"), Quickshell.env("DESKTOP_SESSION")].filter(function(v) { return String(v || "").length > 0 }).join(":")
    var script = root.omarchyPath + "/shell/services/hidden-entries.sh"
    return Util.shellQuote(script) + " " + Util.shellQuote(desktop)
  }

  // One DE-hides scan per summon is enough: the instance is short-lived
  // (keepLoaded: false) and enumeration always precedes any app row.
  function refreshHiddenEntries() {
    if (!root.hiddenEntriesScanned && !hiddenEntryScan.running) hiddenEntryScan.running = true
  }

  // Re-enumerate Apps once hide lists land after it; a no-op before the
  // first enumeration, when Apps was never opened, or mid-scan.
  function refreshAppsForHides() {
    if (!root.rowsLoaded || !root.providersLoaded["apps"]) return
    if (providerProc.running) return
    root.providersLoaded["apps"] = false
    root.startProviderForMenu("apps")
  }

  // Shared organizer: flat app infos -> category submenus + app rows.
  // infos: [{appId, label, description, icon, aliases, cats}]
  // Also refreshes the appInfoById cache the global Recent menu resolves
  // app duplicates from.
  function organizeAppRows(infos, menuId) {
    root.cacheAppInfos(infos)
    var sorted = (infos || []).slice().sort(function(a, b) {
      var al = String(a.label || "").toLowerCase()
      var bl = String(b.label || "").toLowerCase()
      if (al < bl) return -1
      if (al > bl) return 1
      return String(a.appId) < String(b.appId) ? -1 : 1
    })
    var buckets = ({})
    for (var i = 0; i < sorted.length; i++) {
      var info = sorted[i]
      var cat = root.appCategoryFor(info.appId, info.cats).key
      if (!buckets[cat]) buckets[cat] = []
      buckets[cat].push(info)
    }
    var rows = []
    var takenIds = ({})
    for (var c = 0; c < root.appCategories.length; c++) {
      var meta = root.appCategories[c]
      var apps = buckets[meta.key]
      if (!apps || apps.length === 0) continue
      var subId = menuId + "." + meta.key.toLowerCase()
      rows.push({
        id: subId, parent: menuId, kind: "menu",
        icon: meta.icon, iconFont: Style.fontFamily, appIcon: "", appId: "",
        label: meta.label, title: "",
        target: "", description: "", action: "",
        provider: "", aliases: [], when: "", checked: "", order: 0,
        generated: true
      })
      for (var k = 0; k < apps.length; k++) {
        var info = apps[k]
        var rowId = subId + "." + info.appId
        while (takenIds[rowId]) rowId += "-"
        takenIds[rowId] = true
        rows.push({
          id: rowId, parent: subId, kind: "app",
          icon: "", appIcon: info.icon, appId: info.appId,
          label: info.label, title: "",
          target: "", description: info.description, action: "",
          provider: "", aliases: info.aliases, when: "", checked: "", order: 0,
          generated: true
        })
      }
    }
    return rows
  }

  function mergeAppRows() {
    if (!root.appLibrary) return
    var rows = root.appLibrary.sortedEntries("")
    var infos = []
    for (var j = 0; j < rows.length; j++) {
      var entry = rows[j].entry
      var appId = String(entry.id || "")
      if (!appId) continue
      if (root.isHiddenApp(appId)) continue
      var subtext = root.appLibrary.entrySubtext(entry)
      var aliases = subtext ? [subtext] : []
      try {
        if (entry.keywords && typeof entry.keywords.join === "function") aliases = aliases.concat(entry.keywords)
      } catch (e) {}
      var cats = []
      try {
        if (Array.isArray(entry.categories)) cats = entry.categories
        else if (typeof entry.categories === "string") cats = entry.categories.split(/[;,\s]+/)
      } catch (e2) {}
      infos.push({
        appId: appId, label: root.appLibrary.entryName(entry),
        description: subtext, icon: String(entry.icon || ""),
        aliases: aliases, cats: cats
      })
    }
    var merged = WheelModel.swapProviderRows(root.items, root.itemOrder, "apps", root.organizeAppRows(infos, "apps"))
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    root.refreshIconIndex()
    root.refreshHiddenEntries()
    root.rebuildRecentRows()
  }

  // Native enumeration via Quickshell DesktopEntries (no subprocess, no
  // shell facade needed). Looted idea from signaldirective/radial-menu
  // (WTFPL): they read DesktopEntries.applications.values directly instead
  // of shelling out. We keep our own grouping/search model — only the
  // enumeration source is shared. Returns true when it produced rows.
  function mergeDesktopEntries(menuId) {
    var values = null
    try {
      values = DesktopEntries.applications.values
    } catch (e) { return false }
    if (!values || !values.length) return false
    var infos = []
    var seenIds = ({})
    for (var i = 0; i < values.length; i++) {
      var en = values[i]
      if (!en) continue
      var appId = String((en.id || "").replace(/\.desktop$/, ""))
      var label = String(en.name || "")
      if (!appId || !label || seenIds[appId]) continue
      if (root.isHiddenApp(appId)) continue
      seenIds[appId] = true
      var generic = String(en.genericName || "")
      var comment = String(en.comment || "")
      var aliases = []
      try {
        var kw = en.keywords
        for (var k = 0; kw && k < kw.length; k++) if (kw[k]) aliases.push(String(kw[k]))
      } catch (e2) {}
      if (generic) aliases.push(generic)
      if (comment && comment !== generic) aliases.push(comment)
      var cats = []
      try {
        var c = en.categories
        if (c && typeof c.length === "number") {
          for (var j = 0; j < c.length; j++) if (c[j]) cats.push(String(c[j]))
        }
      } catch (e3) {}
      infos.push({
        appId: appId, label: label, description: generic || comment,
        icon: String(en.icon || ""), aliases: aliases, cats: cats
      })
    }
    if (infos.length === 0) return false
    var merged = WheelModel.swapProviderRows(root.items, root.itemOrder, menuId, root.organizeAppRows(infos, menuId))
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    root.refreshIconIndex()
    root.refreshHiddenEntries()
    root.rebuildRecentRows()
    return true
  }

  function startProviderForMenu(id) {
    var entry = root.item(id)
    if (!entry || !entry.provider || root.providersLoaded[id]) return
    if (entry.provider === "apps" && root.appLibrary) {
      root.providersLoaded[id] = true
      root.mergeAppRows()
      return
    }
    if (entry.provider === "apps") {
      // Fast path first: synchronous, no python/bash spawn. Falls through
      // to appscan.py only when DesktopEntries is empty/unavailable.
      root.providersLoaded[id] = true
      try {
        if (root.mergeDesktopEntries(id)) return
      } catch (e) {}
      root.providersLoaded[id] = false
    }
    var spec = root.providers[entry.provider]
    if (!spec) return
    var script = spec.script
    if (entry.provider === "apps") {
      var scanner = root.appsScannerPath()
      if (!scanner) return
      script = "python3 " + Util.shellQuote(scanner)
    }
    if (!script) return
    root.providersLoaded[id] = true
    providerProc.menuId = id
    providerProc.providerKey = entry.provider
    providerProc.revision = root.providerRevision
    providerProc.collected = ""
    providerProc.command = ["bash", "-lc", script]
    providerProc.running = true
  }

  // Bash fallback rows for the apps provider: `<id>\t<Name>\t<Generic>\t<Icon>\t<Keywords>\t<Categories>`.
  function mergeAppsBash(collected, menuId) {
    var lines = String(collected || "").split("\n")
    var infos = []
    var seenIds = ({})
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var parts = line.split("\t")
      var appId = parts[0] || ""
      var label = parts[1] || ""
      if (!appId || !label || seenIds[appId]) continue
      if (root.isHiddenApp(appId)) continue
      seenIds[appId] = true
      var generic = parts[2] || ""
      var keywords = parts[4] || ""
      var aliases = []
      if (generic) aliases.push(generic)
      var kw = keywords.split(/[;\s]+/)
      for (var k = 0; k < kw.length; k++) if (kw[k]) aliases.push(kw[k])
      infos.push({
        appId: appId, label: label, description: generic,
        icon: parts[3] || "", aliases: aliases,
        cats: String(parts[5] || "").split(/[;,\s]+/)
      })
    }
    var merged = WheelModel.swapProviderRows(root.items, root.itemOrder, menuId, root.organizeAppRows(infos, menuId))
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    root.refreshIconIndex()
    root.refreshHiddenEntries()
    root.rebuildRecentRows()
  }

  readonly property string homeDir: Quickshell.env("HOME")

  // Display-time icon fallback: a partial user override (e.g. an
  // aliases-only entry) normalizes to icon:"" and would wipe the stock
  // glyph at merge. The merge itself stays a verbatim port of omarchy.menu
  // semantics — only the wheel's glyph lookup falls back to the stock icon
  // so a wedge never collapses to the "•" dot. Labels, visibility, and
  // search behavior are untouched.
  function defaultIconFor(id) {
    for (var i = 0; i < root.defaultMenuItems.length; i++) {
      var e = root.defaultMenuItems[i]
      if (e && e.id === id) return e.icon || ""
    }
    return ""
  }
  function glyphFor(entry) {
    if (!entry) return "•"
    if (entry.icon) return entry.icon
    return root.defaultIconFor(entry.id) || "•"
  }

  // Custom image icons: any icon that looks like a path (absolute, ~,
  // file://, image://) renders as an image instead of a glyph. Works for
  // menu entries from omarchy-menu.jsonc as well as app icons.
  function isImageIcon(icon) {
    var value = String(icon || "")
    return value.charAt(0) === "/" || value.charAt(0) === "~"
      || value.indexOf("file://") === 0 || value.indexOf("image://") === 0
  }

  // Icon resolution with facade-first, index, then Quickshell-themed
  // fallback. The index is a verbatim port of the stock AppLibrary service:
  // Qt's themed lookup caches at process start and misses icons installed
  // later, so bare names resolve against a bash-scanned name -> file map
  // first (index hits also win over themed lookup, which can resolve an app
  // name to a wrong-context icon instead).
  property var iconIndex: ({})
  property var pendingIconIndex: ({})
  property bool iconIndexScanned: false

  function iconIndexScanCommand() {
    // List app/device icons across the XDG icon dirs and /usr/share/pixmaps
    // as "<path>" lines. SVGs are emitted before PNGs so the parser, which
    // keeps the first hit per name, prefers scalable icons.
    return [
      'dirs="$HOME/.icons $HOME/.local/share/icons";',
      'IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS;',
      'for ext in svg png; do',
      '  for base in $dirs; do',
      '    [[ -d $base ]] && find "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) -name "*.$ext" 2>/dev/null;',
      '  done;',
      '  find /usr/share/pixmaps -maxdepth 1 -name "*.$ext" 2>/dev/null;',
      'done'
    ].join(' ')
  }

  function indexIconLine(path) {
    var value = String(path || "").trim()
    if (value.length === 0) return
    var slash = value.lastIndexOf("/")
    var file = slash >= 0 ? value.slice(slash + 1) : value
    var dot = file.lastIndexOf(".")
    var name = dot > 0 ? file.slice(0, dot) : file
    if (name.length > 0 && root.pendingIconIndex[name] === undefined)
      root.pendingIconIndex[name] = value
  }

  // One scan per summon is enough: the instance is short-lived
  // (keepLoaded: false) and enumeration always precedes any icon lookup.
  function refreshIconIndex() {
    if (!root.iconIndexScanned && !iconIndexScan.running) iconIndexScan.running = true
  }

  function iconSourceFor(icon) {
    var value = String(icon || "")
    if (root.appLibrary) return root.appLibrary.iconSource(value)
    if (!value) return Quickshell.iconPath("application-x-executable", true)
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "~") return Util.fileUrl(root.homeDir + value.slice(1))
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    var indexed = root.iconIndex[value]
    if (indexed) return Util.fileUrl(indexed)
    var themed = Quickshell.iconPath(value, true)
    if (themed && themed.length > 0) return themed
    return Quickshell.iconPath("application-x-executable", true)
  }

  // ---- global Recent (persisted in ~/.local/state/omarchy/omawheel-recents.json) ----
  // A top-level "Recent" wedge duplicating the latest launches of any kind:
  // apps (by desktop id) and menu actions (by item id). Duplicates only -
  // originals keep their normal spots. Files written by older versions
  // (a bare array of app ids) migrate to app entries on load.
  readonly property int recentMax: 8
  property string recentsPath: Quickshell.env("HOME") + "/.local/state/omarchy/omawheel-recents.json"
  property var recentEntries: []
  // Last full app infos by desktop id, refreshed by organizeAppRows on every
  // apps enumeration. Recent app duplicates resolve through this cache.
  property var appInfoById: ({})

  FileView {
    id: recentsFile
    path: root.recentsPath
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        root.recentEntries = root.normalizeRecents(parsed)
      } catch (e) { root.recentEntries = [] }
      if (root.rowsLoaded) { root.ensureRecentMenu(); root.rebuildRecentRows() }
    }
    onLoadFailed: { root.recentEntries = [] }
  }

  function normalizeRecents(parsed) {
    var out = []
    if (!Array.isArray(parsed)) return out
    for (var i = 0; i < parsed.length && out.length < root.recentMax; i++) {
      var e = parsed[i]
      if (typeof e === "string") {
        if (e) out.push({ k: "app", id: e })
      } else if (e && typeof e === "object") {
        var k = e.k === "action" ? "action" : "app"
        var id = String(e.id || "")
        if (id) out.push({ k: k, id: id })
      }
    }
    return out
  }

  function cacheAppInfos(infos) {
    var next = ({})
    var list = infos || []
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].appId) next[list[i].appId] = list[i]
    }
    root.appInfoById = next
  }

  function recordRecent(kind, id) {
    var key = String(id || "")
    if (!kind || !key) return
    var list = [{ k: kind, id: key }]
    for (var i = 0; i < root.recentEntries.length && list.length < root.recentMax; i++) {
      var e = root.recentEntries[i]
      if (!e || !e.id || (e.k === kind && e.id === key)) continue
      list.push({ k: e.k === "action" ? "action" : "app", id: String(e.id) })
    }
    root.recentEntries = list
    try {
      recentsFile.setText(JSON.stringify(list))
    } catch (e2) {}
    if (root.rowsLoaded) root.rebuildRecentRows()
  }

  // Empty the global Recent list (editor "Clear recent"). The Recent wedge
  // hides itself once its rows rebuild to nothing.
  function clearRecent() {
    root.recentEntries = []
    try {
      recentsFile.setText("[]")
    } catch (e) {}
    if (root.rowsLoaded) root.rebuildRecentRows()
  }

  // Recent duplicates launch their origin: map a recent row back to the
  // entry that should be recorded (and moved to the front).
  function recordEntryLaunch(entry) {
    if (!entry) return
    if (entry.kind === "app") {
      if (entry.appId) root.recordRecent("app", entry.appId)
    } else if (entry.kind === "action" && entry.action) {
      var id = (entry.generated && entry.parent === "recent" && entry.origin) ? entry.origin : entry.id
      if (id) root.recordRecent("action", id)
    }
  }

  // The Recent submenu itself, injected under root right after Apps so it
  // reads as a sibling wedge. An empty Recent hides on its own: a menu
  // without a provider and with no visible children is invisible.
  function ensureRecentMenu() {
    if (!root.rowsLoaded || root.items["recent"]) return
    var menu = {
      id: "recent", parent: "root", kind: "menu",
      icon: root.recentMenuIcon, iconFont: Style.fontFamily, appIcon: "", appId: "",
      label: "Recent", title: "",
      target: "", description: "", action: "",
      provider: "", aliases: [], when: "", checked: "", order: 0,
      generated: true
    }
    var items = ({})
    for (var k in root.items) items[k] = root.items[k]
    items["recent"] = menu
    var order = root.itemOrder.slice()
    var at = order.indexOf("apps")
    if (at >= 0) order.splice(at + 1, 0, "recent")
    else order.push("recent")
    menu.order = order.length
    root.items = items
    root.itemOrder = order
  }

  // Rebuild the children of the global Recent menu from recentEntries, most
  // recent first. Unresolvable entries (uninstalled apps, removed or hidden
  // menu items) are skipped; launching a duplicate re-records its origin.
  function rebuildRecentRows() {
    if (!root.rowsLoaded) return
    root.ensureRecentMenu()
    var rows = []
    var taken = ({})
    for (var i = 0; i < root.recentEntries.length; i++) {
      var e = root.recentEntries[i]
      if (!e || !e.id) continue
      if (e.k === "app") {
        var info = root.appInfoById[e.id]
        if (!info) continue
        var appRowId = "recent.app." + e.id
        if (taken[appRowId]) continue
        taken[appRowId] = true
        rows.push({
          id: appRowId, parent: "recent", kind: "app",
          icon: "", appIcon: info.icon, appId: e.id,
          label: info.label, title: "",
          target: "", description: info.description, action: "",
          provider: "", aliases: info.aliases || [], when: "", checked: "", order: 0,
          generated: true
        })
      } else {
        var src = root.items[e.id]
        if (!src || src.kind !== "action" || !src.action) continue
        if (src.generated && src.parent === "recent") continue
        var actRowId = "recent." + e.id
        if (taken[actRowId]) continue
        taken[actRowId] = true
        rows.push({
          id: actRowId, parent: "recent", kind: "action",
          icon: src.icon, iconFont: src.iconFont || "", appIcon: "", appId: "",
          label: src.label, title: "",
          target: "", description: src.description || "", action: src.action,
          provider: "", aliases: src.aliases || [], when: src.when || "", checked: src.checked || "", order: 0,
          generated: true, origin: e.id
        })
      }
    }
    var merged = WheelModel.swapProviderRows(root.items, root.itemOrder, "recent", rows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    if (root.opened) { root.rebuildWheel(); root.retryPendingProviderRoute(); root.wheelSerial++ }
  }

  function launchApp(appId, label) {
    root.recordRecent("app", appId)
    if (root.appLibrary) { root.appLibrary.launch(appId, label); return }
    Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(String(appId || "") + ".desktop"))
  }

  // ---- wheel editor ----
  // Raw (un-normalized) user dict, mirrored from the extension file so the
  // editor round-trips unknown keys (target, provider, aliases, when...).
  function parseRawMenuJsonc(raw) {
    var stripped = WheelModel.stripJsonc(raw)
    if (!stripped.trim()) return {}
    var parsed
    try { parsed = JSON.parse(stripped) } catch (e) { return {} }
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return {}
    var source = (parsed.items && typeof parsed.items === "object" && !Array.isArray(parsed.items))
      ? parsed.items : parsed
    var out = ({})
    for (var id in source) {
      var entry = source[id]
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue
      out[id] = entry
    }
    return out
  }

  function openEditor() {
    if (!root.rowsLoaded) { root.editorPending = true; root.opened = true; return }
    root.editorPending = false
    root.editorOpen = true
    root.editorFormOpen = false
    root.editorEditingId = ""
    root.editorError = ""
    root.editorMenu = "root"
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  function closeEditor() {
    root.editorOpen = false
    root.editorFormOpen = false
    root.editorEditingId = ""
    root.editorError = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  function editorRows() {
    var rows = []
    if (!root.rowsLoaded) return rows
    for (var i = 0; i < root.itemOrder.length; i++) {
      var child = root.item(root.itemOrder[i])
      if (!child || child.parent !== root.editorMenu) continue
      rows.push(child)
    }
    return rows
  }
  function editorBadge(entry) {
    if (!entry) return ""
    if (entry.generated) return "auto"
    if (!root.defaultIds[entry.id]) return "custom"
    var raw = root.userRawItems[entry.id]
    if (raw && String(raw.when).toLowerCase() === "false") return "hidden"
    if (raw) return "custom"
    return "stock"
  }
  function editorDelLabel(entry) {
    var badge = root.editorBadge(entry)
    if (badge === "hidden") return "Unhide"
    if (badge === "custom") return "Delete"
    return "Hide"
  }
  function editorBack() {
    if (root.editorFormOpen) { root.editorFormOpen = false; root.editorError = ""; return }
    if (root.editorMenu !== "root") {
      var cur = root.item(root.editorMenu)
      root.editorMenu = (cur && cur.parent) ? cur.parent : "root"
      return
    }
    root.closeEditor()
  }
  function beginEditorAdd() {
    root.editorEditingId = ""
    root.editorLockKind = false
    root.editorIsActionForm = true
    root.editorError = ""
    editorLabelField.text = ""
    editorIconField.text = ""
    editorCommandField.text = ""
    root.editorFormOpen = true
    Qt.callLater(function() { editorLabelField.forceActiveFocus() })
  }
  function beginEditorEdit(id) {
    var entry = root.item(id)
    if (!entry || entry.generated) return
    root.editorEditingId = id
    root.editorLockKind = !!root.defaultIds[id]
    root.editorIsActionForm = (entry.kind === "action")
    root.editorError = ""
    editorLabelField.text = entry.label === id ? "" : (entry.label || "")
    editorIconField.text = entry.icon || ""
    editorCommandField.text = entry.action || ""
    root.editorFormOpen = true
    Qt.callLater(function() { editorLabelField.forceActiveFocus() })
  }
  // Normalized user entries overwrite stock per-key, with absent keys
  // reading as "" — so an override that only changes the icon would wipe
  // provider/target/aliases/iconFont (killing e.g. the fonts provider or
  // alias routes). The form manages icon/label/action/when; every other
  // stock key passes through verbatim into the override.
  function stockPassthrough(id, upd) {
    var src = root.item(id)
    if (!src) return upd
    // "when" rides along too: an explicit "false" (hide) is already set by
    // the caller and wins; otherwise the stock guard is preserved.
    var keys = ["target", "provider", "title", "description", "aliases", "checked", "iconFont", "when"]
    for (var i = 0; i < keys.length; i++) {
      var k = keys[i]
      if (upd[k] === undefined) {
        var v = src[k]
        if (v === undefined || v === "") continue
        if (Array.isArray(v) && v.length === 0) continue
        upd[k] = v
      }
    }
    return upd
  }

  function saveEditorForm() {
    var label = editorLabelField.text.trim()
    var icon = editorIconField.text.trim()
    var command = editorCommandField.text.trim()
    var isAction = root.editorIsActionForm
    if (!label) { root.editorError = "Label is required."; return }
    if (isAction && !command) { root.editorError = "Command is required for actions."; return }
    if (!root.editorEditingId) {
      var base = WheelModel.slugify(label)
      var prefix = root.editorMenu === "root" ? "" : root.editorMenu + "."
      var nid = prefix + base
      var n = 2
      while (root.items[nid] || root.userRawItems[nid]) { nid = prefix + base + "-" + n; n++ }
      var fresh = { icon: icon, label: label }
      if (isAction) fresh.action = command
      var next = {}
      for (var k in root.userRawItems) next[k] = root.userRawItems[k]
      next[nid] = fresh
      root.userRawItems = next
      root.refreshModelFromRaw()
      root.applyUserFileOps([{ t: "set", id: nid, value: fresh }])
    } else {
      var id = root.editorEditingId
      var prev = root.userRawItems[id] || {}
      var upd = {}
      for (var k2 in prev) upd[k2] = prev[k2]
      upd.icon = icon
      upd.label = label
      if (isAction) {
        if (!root.editorLockKind || (root.item(id) && root.item(id).kind === "action")) upd.action = command
        delete upd.target
      } else if (!root.editorLockKind) {
        delete upd.action
      }
      if (root.editorLockKind) upd = root.stockPassthrough(id, upd)
      var next2 = {}
      for (var k3 in root.userRawItems) next2[k3] = root.userRawItems[k3]
      next2[id] = upd
      root.userRawItems = next2
      root.refreshModelFromRaw()
      root.applyUserFileOps([{ t: "set", id: id, value: upd }])
    }
    if (!root.editorError) {
      root.editorFormOpen = false
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }
  function deleteEditorItem(id) {
    var entry = root.item(id)
    if (!entry || entry.generated) return
    var isStock = !!root.defaultIds[id]
    var ops = []
    var next = {}
    for (var k in root.userRawItems) {
      // Custom subtrees go with their root; stock hides keep descendants.
      if (k === id || (!isStock && k.indexOf(id + ".") === 0)) {
        ops.push({ t: "remove", id: k })
        continue
      }
      next[k] = root.userRawItems[k]
    }
    if (isStock) {
      var kept = {}
      var prev = root.userRawItems[id] || {}
      for (var k2 in prev) kept[k2] = prev[k2]
      kept.when = "false"
      next[id] = root.stockPassthrough(id, kept)
      ops.push({ t: "set", id: id, value: next[id] })
    }
    root.userRawItems = next
    root.refreshModelFromRaw()
    root.applyUserFileOps(ops)
  }
  function unhideEditorItem(id) {
    var prev = root.userRawItems[id] || {}
    var upd = {}
    var hasOther = false
    for (var k in prev) {
      if (k === "when") continue
      upd[k] = prev[k]
      hasOther = true
    }
    var next = {}
    for (var k2 in root.userRawItems) next[k2] = root.userRawItems[k2]
    if (hasOther) {
      next[id] = upd
      root.userRawItems = next
      root.refreshModelFromRaw()
      root.applyUserFileOps([{ t: "set", id: id, value: upd }])
    } else {
      delete next[id]
      root.userRawItems = next
      root.refreshModelFromRaw()
      root.applyUserFileOps([{ t: "remove", id: id }])
    }
  }
  // ---- surgical user-file edits ----
  // The extension file is shared with other tools (and hand-written
  // comments), so the editor never rewrites it wholesale. Instead each
  // save resolves minimal text spans (one entry value, or an insert
  // point) against the last loaded text and patches those bytes only.
  // Unknown shapes (e.g. an {"items":{}} wrapper) abort safely rather
  // than risk destroying content.
  function scanJsoncSpans(text) {
    // Returns { rootStart, rootEnd, entries: [{id, keyStart, valStart,
    // valEnd}] } for a flat top-level object, or null. Strings, escapes
    // and // plus /* */ comments are skipped while scanning.
    var n = text.length
    var i = 0
    function skipSpace() {
      while (i < n) {
        var c = text.charAt(i)
        if (c === " " || c === "\t" || c === "\n" || c === "\r") { i++; continue }
        if (c === "/" && i + 1 < n && text.charAt(i + 1) === "/") {
          while (i < n && text.charAt(i) !== "\n") i++
          continue
        }
        if (c === "/" && i + 1 < n && text.charAt(i + 1) === "*") {
          i += 2
          while (i + 1 < n && !(text.charAt(i) === "*" && text.charAt(i + 1) === "/")) i++
          i += 2
          continue
        }
        break
      }
    }
    function parseStr() {
      var out = ""
      i++ // opening quote
      while (i < n) {
        var c = text.charAt(i)
        if (c === "\\" && i + 1 < n) { out += c + text.charAt(i + 1); i += 2; continue }
        if (c === '"') { i++; return out }
        if (c === "\n") return null
        out += c
        i++
      }
      return null
    }
    function skipVal() {
      // Value starts at i. Returns exclusive end offset.
      skipSpace()
      if (i >= n) return i
      var c = text.charAt(i)
      if (c === "{" || c === "[") {
        var open = c
        var close = c === "{" ? "}" : "]"
        var depth = 0
        while (i < n) {
          var d = text.charAt(i)
          if (d === '"') { if (parseStr() === null) return i }
          else if (d === "/" && i + 1 < n && text.charAt(i + 1) === "/") {
            while (i < n && text.charAt(i) !== "\n") i++
          } else if (d === "/" && i + 1 < n && text.charAt(i + 1) === "*") {
            i += 2
            while (i + 1 < n && !(text.charAt(i) === "*" && text.charAt(i + 1) === "/")) i++
            i += 2
          } else if (d === open) { depth++; i++ }
          else if (d === close) { depth--; i++; if (depth === 0) return i }
          else i++
        }
        return i
      }
      if (c === '"') { parseStr(); return i }
      while (i < n && ",}]".indexOf(text.charAt(i)) < 0) i++
      return i
    }
    skipSpace()
    if (i >= n || text.charAt(i) !== "{") return null
    var rootStart = i
    var depth = 0
    var entries = []
    var seenKey = false
    i++ // consume root {
    depth = 1
    while (i < n) {
      skipSpace()
      if (i >= n) break
      var ch = text.charAt(i)
      if (ch === '"') {
        var keyStart = i
        var key = parseStr()
        if (key === null) return null
        var afterKey = i
        skipSpace()
        if (i >= n || text.charAt(i) !== ":") {
          // Not a key (string inside an unexpected spot): give up.
          return null
        }
        i++ // colon
        var valStart = i
        var valEnd = skipVal()
        // Only depth-1 keys count; nested strings never surface here
        // because skipVal consumes whole values.
        entries.push({ id: key, keyStart: keyStart, valStart: valStart, valEnd: valEnd })
        seenKey = true
        skipSpace()
        if (i < n && text.charAt(i) === ",") { i++; continue }
        if (i < n && text.charAt(i) === "}") { i++; return { rootStart: rootStart, rootEnd: i, entries: entries } }
        return null
      } else if (ch === "}") {
        i++
        return { rootStart: rootStart, rootEnd: i, entries: entries }
      } else if (ch === ",") {
        i++
        continue
      } else {
        return null
      }
    }
    return null
  }

  function stringifyEntryValue(value) {
    var lines = JSON.stringify(value, null, 2).split("\n")
    for (var i = 1; i < lines.length; i++) lines[i] = "  " + lines[i]
    return lines.join("\n")
  }

  function planUserFileOps(text, ops) {
    // Resolve every op to concrete ranges against the ORIGINAL text, then
    // apply back-to-front so offsets stay valid. Returns the new text, or
    // null when the shape is unexpected (caller aborts, never rewrites).
    var scan = root.scanJsoncSpans(text)
    if (!scan) return null
    var byId = ({})
    for (var e = 0; e < scan.entries.length; e++) byId[scan.entries[e].id] = scan.entries[e]
    // Refuse the {"items":{}} wrapper and friends: only flat objects here.
    if (scan.entries.length === 1 && scan.entries[0].id === "items") return null
    var edits = []
    for (var o = 0; o < ops.length; o++) {
      var op = ops[o]
      if (op.t === "set") {
        var span = byId[op.id]
        var rendered = root.stringifyEntryValue(op.value)
        if (span) {
          edits.push({ start: span.valStart, end: span.valEnd, text: rendered })
        } else {
          var insertAt = scan.rootEnd - 1
          var head = scan.entries.length === 0 ? "{\n  " : ",\n  "
          // Empty object: replace the void between braces.
          if (scan.entries.length === 0) {
            edits.push({ start: scan.rootStart + 1, end: scan.rootEnd - 1, text: "\n  " + JSON.stringify(op.id) + ": " + rendered + "\n" })
          } else {
            edits.push({ start: insertAt, end: insertAt, text: head + JSON.stringify(op.id) + ": " + rendered + "\n" })
          }
        }
      } else if (op.t === "remove") {
        var gone = byId[op.id]
        if (!gone) continue
        var rs = gone.keyStart
        var re = gone.valEnd
        // Swallow one adjacent comma so no dangling "," remains.
        var b = rs - 1
        while (b >= 0 && " \t\n\r".indexOf(text.charAt(b)) >= 0) b--
        if (b >= 0 && text.charAt(b) === ",") {
          rs = b
        } else {
          var f = re
          while (f < text.length && " \t\n\r".indexOf(text.charAt(f)) >= 0) f++
          if (f < text.length && text.charAt(f) === ",") re = f + 1
        }
        // Collapse the vacated line(s): extend to line boundaries when the
        // remainder of those lines is whitespace only, so no blank gap
        // stays behind in the file.
        var ls = rs
        while (ls > 0 && text.charAt(ls - 1) !== "\n") ls--
        var preWs = true
        for (var w = ls; w < rs; w++) {
          if (" \t".indexOf(text.charAt(w)) < 0) { preWs = false; break }
        }
        var g = re
        while (g < text.length && (text.charAt(g) === " " || text.charAt(g) === "\t")) g++
        if (preWs) rs = ls
        if (g < text.length && text.charAt(g) === "\n") re = g + 1
        edits.push({ start: rs, end: re, text: "" })
      }
    }
    edits.sort(function(a, b) { return b.start - a.start })
    var out = text
    for (var k = 0; k < edits.length; k++) {
      out = out.slice(0, edits[k].start) + edits[k].text + out.slice(edits[k].end)
    }
    return out
  }

  function applyUserFileOps(ops) {
    var text = ""
    try { text = String(userMenuFile.text() || "") } catch (e) { text = "" }
    if (!text.trim()) {
      // No file yet: build a fresh flat object from set-ops.
      var fresh = {}
      for (var i = 0; i < ops.length; i++) {
        if (ops[i].t === "set") fresh[ops[i].id] = ops[i].value
      }
      try {
        userMenuFile.setText(JSON.stringify(fresh, null, 2) + "\n")
      } catch (e2) { root.editorError = "Could not write menu file." }
      return
    }
    var planned = root.planUserFileOps(text, ops)
    if (planned === null || planned === undefined) {
      root.editorError = "Could not safely edit menu file (unexpected layout)."
      return
    }
    try {
      userMenuFile.setText(planned)
      // NOTE: no immediate reload() here on purpose. A re-read racing the
      // async write can load pre-write content and clobber the optimistic
      // model below; the watcher round-trip (or the next summon) confirms.
    } catch (e3) { root.editorError = "Could not write menu file." }
  }

  // Rebuild the derived model straight from the edited raw dict instead of
  // waiting for the file round-trip: editor saves become visible instantly
  // and can never be clobbered by a stale read.
  function refreshModelFromRaw() {
    var arr = []
    for (var id in root.userRawItems) {
      var raw = root.userRawItems[id]
      if (!raw || typeof raw !== "object" || Array.isArray(raw)) continue
      arr.push(WheelModel.normalizeItem(id, raw))
    }
    root.userMenuItems = arr
    root.rebuildItemsFromSources()
  }


  function mergeProviderRows(rows, menuId, providerKey) {
    var spec = root.providers[providerKey]
    if (!spec) return
    var lines = String(rows || "").split("\n")
    var providerRows = []
    var takenIds = ({})
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var parts = line.split("\t")
      var label = parts[0] || ""
      var value = parts[1] || parts[0] || ""
      var current = parts[2] || ""
      if (!label) continue
      var rowId = menuId + "." + root.slugify(value)
      while (takenIds[rowId]) rowId += "-"
      takenIds[rowId] = true
      providerRows.push({
        id: rowId, parent: menuId, kind: "action",
        icon: (value === current) ? "✓" : (spec.icon || ""),
        label: label, title: "", target: "", description: "",
        action: spec.actionFor(value),
        provider: "", aliases: [], when: "", checked: "", order: 0,
        generated: true
      })
    }
    var merged = WheelModel.swapProviderRows(root.items, root.itemOrder, menuId, providerRows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    root.rebuildRecentRows()
  }

  function startNextProvider() {
    if (providerProc.running) return
    while (root.providerQueue.length > 0) {
      var id = root.providerQueue.shift()
      var entry = root.item(id)
      if (!entry || !entry.provider || root.providersLoaded[id]) continue
      root.startProviderForMenu(id)
      return
    }
  }

  function invalidateVolatileProvider(id) {
    var entry = root.item(id)
    var spec = entry && entry.provider ? root.providers[entry.provider] : null
    if (spec && spec.volatile) root.providersLoaded[id] = false
  }

  function loadProviderForMenu(id) {
    var entry = root.item(id)
    if (!entry || !entry.provider || root.providersLoaded[id]) return
    if (entry.provider === "apps") { root.startProviderForMenu(id); return }
    if (providerProc.running) {
      if (root.providerQueue.indexOf(id) < 0) root.providerQueue = root.providerQueue.concat([id])
      return
    }
    root.startProviderForMenu(id)
  }

  // ---- guards (batched bash, same as omarchy.menu) ----
  function evaluateGuards() {
    if (guardProc.running) { root.guardsPending = true; return }
    root.guardsPending = false
    var script = WheelModel.guardScript(root.items)
    if (!script) { root.whenResults = ({}); root.checkedResults = ({}); root.rebuildWheel(); return }
    guardProc.collected = ""
    guardProc.command = ["bash", "-lc", script]
    guardProc.running = true
  }

  Process {
    id: providerProc
    property string menuId: ""
    property string providerKey: ""
    property string collected: ""
    property int revision: 0
    stdout: SplitParser {
      onRead: function(data) { providerProc.collected += data + "\n" }
    }
    onExited: {
      if (providerProc.revision === root.providerRevision) {
        if (providerProc.providerKey === "apps" && !root.appLibrary)
          root.mergeAppsBash(providerProc.collected, providerProc.menuId)
        else
          root.mergeProviderRows(providerProc.collected, providerProc.menuId, providerProc.providerKey)
      }
      root.startNextProvider()
    }
  }

  Process {
    id: iconIndexScan
    command: ["bash", "-c", root.iconIndexScanCommand()]
    stdout: SplitParser { onRead: function(line) { root.indexIconLine(line) } }
    onStarted: root.pendingIconIndex = ({})
    // Swapping the property re-evaluates every iconSourceFor() binding, so
    // newly found icons pop in without rebuilding the rows.
    onExited: {
      root.iconIndex = root.pendingIconIndex
      root.iconIndexScanned = true
    }
  }

  Process {
    id: hiddenEntryScan
    property string collected: ""
    command: ["bash", "-c", root.hiddenEntryScanCommand()]
    stdout: SplitParser { onRead: function(line) { hiddenEntryScan.collected += line + "\n" } }
    onStarted: hiddenEntryScan.collected = ""
    onExited: {
      root.loadDesktopHiddenEntries(hiddenEntryScan.collected)
      root.hiddenEntriesScanned = true
    }
  }

  FileView {
    path: root.omarchyPath + "/default/omarchy/launcher.hides"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadConfiguredHides(text())
    onFileChanged: root.loadConfiguredHides(text())
    onLoadFailed: root.loadConfiguredHides("")
  }

  Process {
    id: guardProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { guardProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 || exitStatus !== 0) {
        if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
        return
      }
      var nextWhen = ({})
      var nextChecked = ({})
      var lines = guardProc.collected.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        if (!line) continue
        var colon = line.lastIndexOf(":")
        if (colon < 0) continue
        var value = line.substring(colon + 1) === "1"
        var rest = line.substring(0, colon)
        var tagAt = rest.lastIndexOf(":")
        if (tagAt < 0) continue
        var gid = rest.substring(0, tagAt)
        var tag = rest.substring(tagAt + 1)
        if (tag === "w") nextWhen[gid] = value
        else if (tag === "c") nextChecked[gid] = value
      }
      root.whenResults = nextWhen
      root.checkedResults = nextChecked
      if (root.opened) { root.rebuildWheel(); root.wheelSerial++ }
      if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
    }
  }

  Connections {
    target: root.appLibrary
    function onAppsChanged() {
      if (root.providersLoaded["apps"]) root.mergeAppRows()
    }
  }

  FileView {
    id: defaultMenuFile
    path: root.defaultMenuPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.defaultMenuItems = root.parseMenuJsonc(text()); root.defaultReported = true; root.rebuildItemsFromSources() }
    onLoadFailed: { root.defaultMenuItems = []; root.defaultReported = true; root.rebuildItemsFromSources() }
    onFileChanged: reload()
  }
  FileView {
    id: userMenuFile
    path: root.userMenuPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.userMenuItems = root.parseMenuJsonc(text()); root.userRawItems = root.parseRawMenuJsonc(text()); root.userReported = true; root.rebuildItemsFromSources() }
    onLoadFailed: { root.userMenuItems = []; root.userRawItems = ({}); root.userReported = true; root.rebuildItemsFromSources() }
    onFileChanged: reload()
  }

  // ---- wheel surface ----
  PanelWindow {
    id: panel
    visible: root.opened && root.rowsLoaded
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "oma-wheel"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }
    MouseArea {
      anchors.fill: parent
      onClicked: root.cancel()
    }

    // Breadcrumb above the wheel.
    Column {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.gapsOut + Style.space(24)
      spacing: Style.space(4)
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: root.activePath() || "Omarchy"
        color: root.foreground
        opacity: 0.6
        font.family: Style.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: root.filterText.trim() ? ("⌕ " + root.filterText) : (root.activeTitle() + "…")
        color: root.foreground
        font.family: Style.fontFamily
        font.pixelSize: Style.font.title
        font.weight: Font.Medium
      }
    }

    Item {
      id: wheelHolder
      width: root.wheelSize
      height: root.wheelSize
      anchors.centerIn: parent
      transformOrigin: Item.Center

      // Launch exit: wheel shrinks + fades while the shockwave expands,
      // then the panel closes. Dismissals (Esc/scrim) stay instant.
      ParallelAnimation {
        id: exitAnim
        NumberAnimation { target: wheelHolder; property: "scale"; to: 0.9; duration: 190; easing.type: Easing.InQuad }
        NumberAnimation { target: wheelHolder; property: "opacity"; to: 0; duration: 190; easing.type: Easing.InQuad }
        NumberAnimation { target: root; property: "shockT"; from: 0; to: 1; duration: 170; easing.type: Easing.OutCubic }
        onFinished: {
          root.launchFlashing = false
          root.cancel()
        }
      }

      // Static pie: data, filter, or theme only — never hover/press.
      Canvas {
        id: baseRing
        anchors.fill: parent
        property int serial: root.wheelSerial
        property color bg: root.background
        property color bd: root.border
        onSerialChanged: requestPaint()
        onBgChanged: requestPaint()
        onBdChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.clearRect(0, 0, width, height)
          var cx = width / 2, cy = height / 2
          var n = root.currentRows.length
          if (n === 0) {
            ctx.beginPath()
            ctx.arc(cx, cy, root.wheelRadius, 0, Math.PI * 2)
            // Semi-transparent so the compositor blurs the wallpaper
            // through the wheel (frosted-glass ring + hub).
            ctx.fillStyle = Util.alpha(root.background, 0.68)
            ctx.fill()
            return
          }
          for (var i = 0; i < n; i++) {
            root.traceWedge(ctx, cx, cy, i, n)
            // Unselected style always; the highlight layer overdraws the
            // hovered/pressed wedge. Filtered-out wedges fade.
            var dimmed = root.filterText.trim() && root.currentRows[i] && root.ringMatchMap[root.currentRows[i].id] !== true
            ctx.fillStyle = Util.alpha(root.background, dimmed ? 0.35 : 0.68)
            ctx.fill()
            ctx.lineWidth = Math.max(1, Style.space(1))
            ctx.strokeStyle = root.border
            ctx.stroke()
          }
          // Hub disc (slightly more solid than the ring for text legibility).
          ctx.beginPath()
          ctx.arc(cx, cy, root.hubRadius, 0, Math.PI * 2)
          ctx.fillStyle = Util.alpha(root.background, 0.8)
          ctx.fill()
          ctx.lineWidth = Math.max(1, Style.space(1))
          ctx.strokeStyle = root.border
          ctx.stroke()
        }
      }

      // Highlight: hovered/pressed wedge only. Cheap to repaint on
      // every hover — the base pie above never repaints for it.
      Canvas {
        id: glowRing
        anchors.fill: parent
        property int serial: root.wheelSerial
        property int hover: root.hoveredIndex
        property int press: root.pressedIndex
        property color sel: root.selectionFill
        property color acc: root.accent
        property color bd: root.border
        onSerialChanged: requestPaint()
        onHoverChanged: requestPaint()
        onPressChanged: requestPaint()
        onSelChanged: requestPaint()
        onAccChanged: requestPaint()
        onBdChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.clearRect(0, 0, width, height)
          var cx = width / 2, cy = height / 2
          var n = root.currentRows.length
          if (n === 0) return
          // Pressed wedge: solid accent (the committed choice). Drawn
          // first so a differing hover ring still reads on top.
          var p = root.pressedIndex
          if (p >= 0 && p < n) {
            root.traceWedge(ctx, cx, cy, p, n)
            ctx.fillStyle = root.accent
            ctx.fill()
            ctx.lineWidth = Math.max(1, Style.space(3))
            ctx.strokeStyle = root.border
            ctx.stroke()
          }
          var h = root.hoveredIndex
          if (h >= 0 && h < n && h !== p) {
            root.traceWedge(ctx, cx, cy, h, n)
            ctx.fillStyle = root.selectionFill
            ctx.fill()
            ctx.lineWidth = Math.max(1, Style.space(2))
            ctx.strokeStyle = root.border
            ctx.stroke()
          }
        }
      }

      // Expanding launch shockwave (visual only; plain rects never
      // swallow mouse events, so the wheel stays clickable beneath it).
      Rectangle {
        anchors.centerIn: parent
        width: root.hubRadius * 2 + root.shockT * (root.wheelRadius * 2 - root.hubRadius * 2)
        height: width
        radius: width / 2
        color: "transparent"
        border.color: Util.alpha(root.accent, (1 - root.shockT) * 0.8)
        border.width: Math.max(1, Style.space(3))
        visible: root.launchFlashing && root.shockT < 1
      }

      // Hover + click handling across the whole wheel.
      MouseArea {
        id: wheelMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPositionChanged: function(mouse) {
          var idx = root.wedgeIndexAt(mouse.x, mouse.y, width / 2, height / 2)
          if (idx !== root.hoveredIndex) root.hoveredIndex = idx
        }
        onPressed: function(mouse) {
          if (mouse.button !== Qt.LeftButton) return
          var pressed = root.wedgeIndexAt(mouse.x, mouse.y, width / 2, height / 2)
          if (pressed >= 0) root.pressWedge(pressed)
        }
        onClicked: function(mouse) {
          // Right-click anywhere on the wheel opens the editor.
          if (mouse.button === Qt.RightButton) { root.openEditor(); return }
          var idx = root.wedgeIndexAt(mouse.x, mouse.y, width / 2, height / 2)
          if (idx >= 0) {
            root.hoveredIndex = idx
            root.activateIndex(idx)
            return
          }
          var dx = mouse.x - width / 2
          var dy = mouse.y - height / 2
          // Clicks in the hub gap count as hub (back), never as dismiss.
          if (Math.sqrt(dx * dx + dy * dy) < root.hubRadius + root.wedgeGap) root.goBack()
          else root.cancel()
        }
      }

      // Wedge icons positioned at each sector's mid-angle. Icon only —
      // the focused wedge's text is shown in the hub instead.
      Repeater {
        id: wedges
        model: root.currentRows
        Item {
          id: wedgeItem
          required property var modelData
          required property int index
          readonly property bool hovered: index === root.hoveredIndex
          readonly property bool pressed: index === root.pressedIndex
          readonly property bool dimmed: root.filterText.trim() && wedgeItem.modelData && root.ringMatchMap[wedgeItem.modelData.id] !== true
          readonly property bool imageIcon: wedgeItem.modelData
            && (wedgeItem.modelData.kind === "app" || root.isImageIcon(wedgeItem.modelData.icon))
          // centerDeg already includes the -90 top offset; convert to rad directly.
          readonly property real rad: root.centerDeg(index) * Math.PI / 180
          x: wheelHolder.width / 2 + Math.cos(rad) * root.iconRingR - width / 2
          y: wheelHolder.height / 2 + Math.sin(rad) * root.iconRingR - height / 2
          width: root.iconBox
          height: root.iconBox
          transformOrigin: Item.Center
          scale: wedgeItem.pressed ? 0.82 : 1
          Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutQuad } }

          // Image icon (app icons + custom image paths) or glyph icon.
          Image {
            visible: wedgeItem.imageIcon
            anchors.centerIn: parent
            width: Math.round(root.iconBox * 0.62)
            height: Math.round(root.iconBox * 0.62)
            opacity: wedgeItem.dimmed ? 0.25 : 1
            fillMode: Image.PreserveAspectFit
            sourceSize.width: width * Screen.devicePixelRatio
            sourceSize.height: height * Screen.devicePixelRatio
            source: {
              if (!wedgeItem.modelData) return ""
              if (wedgeItem.modelData.kind === "app") return root.iconSourceFor(wedgeItem.modelData.appIcon)
              return root.iconSourceFor(wedgeItem.modelData.icon)
            }
            asynchronous: true
          }
          Text {
            visible: !wedgeItem.imageIcon
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: root.glyphFor(wedgeItem.modelData)
            color: wedgeItem.pressed ? root.contentOn(root.accent) : (wedgeItem.hovered ? root.contentOn(root.selectionFill) : root.foreground)
            opacity: wedgeItem.dimmed && !wedgeItem.hovered ? 0.25 : 1
            font.family: (wedgeItem.modelData && wedgeItem.modelData.iconFont) || Style.fontFamily
            font.pixelSize: root.iconBox > 72 ? Style.font.displayLarge : (root.iconBox > 60 ? Style.font.display : Style.font.iconLarge)
          }
        }
      }

      // Hub: back affordance + keyboard focus.
      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        z: root.confirmOpen ? 20 : 0

        ConfirmDialog {
          id: confirmDialog
          anchors.fill: parent
          opened: root.confirmOpen
          z: 10
          message: root.confirmTarget ? ("Do you want to " + (root.confirmTarget.label || "confirm") + "?") : "Confirm?"
          confirmText: "Confirm"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: Style.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelConfirm()
          onConfirmed: root.confirmDestructive()
        }
        Keys.onPressed: function(event) {
          if (root.confirmOpen) {
            if (confirmDialog.handleKey(event)) event.accepted = true
            return
          }
          // Editor mode: fields own the keyboard; Esc alone backs out.
          if (root.editorOpen) {
            if (event.key === Qt.Key_Escape) { root.editorBack(); event.accepted = true }
            return
          }

          var n = root.currentRows.length
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else if (root.activeMenu === "root") root.cancel()
            else root.goBack()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Backspace) {
            root.goBack()
            event.accepted = true
          } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
            root.stepHover(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
            root.stepHover(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            if (root.filterText.trim()) {
              var hov = root.hoveredEntry()
              if (hov && root.isRingMatch(hov)) root.activateEntry(hov)
              else if (root.bestGlobal) root.activateEntry(root.bestGlobal)
            } else if (root.hoveredIndex >= 0) root.activateIndex(root.hoveredIndex)
            else if (n > 0) { root.hoveredIndex = 0 }
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.centerIn: parent
        width: root.hubRadius * 2 - Style.space(12)
        spacing: Style.space(2)
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: root.filterText.trim() ? (root.matchCount + (root.matchCount === 1 ? " match" : " matches")) : (root.hoveredEntry() ? root.activeTitle() : (root.activeMenu === "root" ? "Omarchy" : "‹ back"))
          color: root.foreground
          opacity: 0.55
          font.family: Style.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        // Focused wedge's icon above its name; hidden when the hub shows
        // only the menu itself.
        Item {
          anchors.horizontalCenter: parent.horizontalCenter
          width: Style.space(52)
          height: Style.space(52)
          visible: root.hubEntry() !== null
          Image {
            anchors.centerIn: parent
            width: Math.round(parent.width * 0.85)
            height: Math.round(parent.height * 0.85)
            visible: root.hubEntryIsImage()
            fillMode: Image.PreserveAspectFit
            sourceSize.width: width * Screen.devicePixelRatio
            sourceSize.height: height * Screen.devicePixelRatio
            source: root.hubEntryIconSource()
            asynchronous: true
          }
          Text {
            anchors.centerIn: parent
            visible: !root.hubEntryIsImage()
            textFormat: Text.PlainText
            text: root.hubEntry() ? root.glyphFor(root.hubEntry()) : ""
            color: (((root.filterText.trim() && root.bestGlobal) || root.hoveredEntry()) ? root.selectedText : root.foreground)
            font.family: (root.hubEntry() && root.hubEntry().iconFont) || Style.fontFamily
            font.pixelSize: Style.space(40)
          }
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: root.hubTitle()
          color: root.launchFlashing ? root.accent : (((root.filterText.trim() && root.bestGlobal) || root.hoveredEntry()) ? root.selectedText : root.foreground)
          font.family: Style.fontFamily
          font.pixelSize: Style.font.heading
          font.weight: Font.Medium
          elide: Text.ElideRight
          maximumLineCount: 2
          wrapMode: Text.Wrap
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: root.hubSub()
          color: root.foreground
          opacity: 0.65
          font.family: Style.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }

    // Hint bar.
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.gapsOut + Style.space(20)
      textFormat: Text.PlainText
      text: root.filterText.trim() ? "Enter launches best match • Esc clears filter" : "Click a wedge to open / run • hub to go back • type to filter • right-click for editor • Esc to close"
      color: root.foreground
      opacity: 0.5
      font.family: Style.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    // Empty state.
    Text {
      visible: root.currentRows.length === 0
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: "Nothing here yet"
      color: root.foreground
      opacity: 0.7
      font.family: Style.fontFamily
      font.pixelSize: Style.font.title
    }

    // ---- wheel editor overlay (edits the user extension file only) ----
    Item {
      id: editorLayer
      anchors.fill: parent
      visible: root.editorOpen
      // Swallow every click so the scrim-cancel underneath never fires.
      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onClicked: {}
      }
      Rectangle {
        anchors.fill: parent
        color: Util.alpha(root.background, 0.55)
      }

      Rectangle {
        id: editorCard
        width: Math.min(Style.space(560), parent.width - Style.gapsOut * 2)
        height: Math.min(Style.space(620), parent.height - Style.gapsOut * 2 - Style.space(40))
        anchors.centerIn: parent
        color: root.background
        border.color: root.border
        border.width: Math.max(1, Style.space(1))
        radius: root.cornerRadius

        Column {
          id: editorCol
          anchors.fill: parent
          anchors.margins: Style.spacing.panelPadding
          spacing: Style.space(8)

          Item {
            id: editorHeader
            width: parent.width
            height: Math.max(editorTitle.height, editorClose.height)
            Text {
              id: editorTitle
              anchors.left: parent.left
              anchors.right: editorClose.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "Wheel editor"
              color: root.foreground
              font.family: Style.fontFamily
              font.pixelSize: Style.font.title
              font.weight: Font.Medium
              elide: Text.ElideRight
            }
            Button {
              id: editorClose
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Close"
              onClicked: root.closeEditor()
            }
          }

          Text {
            id: editorPathText
            width: parent.width
            textFormat: Text.PlainText
            text: root.editorMenu === "root" ? "Top level" : WheelModel.pathFor(root.items, root.editorMenu)
            color: root.foreground
            opacity: 0.6
            font.family: Style.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          // List mode: browse entries, drill, add.
          Item {
            id: editorListSlot
            width: parent.width
            height: root.editorFormOpen ? 0 : (parent.height - editorHeader.height - editorPathText.height - editorFooter.height - editorCol.spacing * 4)
            visible: !root.editorFormOpen
            clip: true
            Flickable {
              anchors.fill: parent
              clip: true
              contentHeight: editorListCol.height
              Column {
                id: editorListCol
                width: parent.width
                spacing: Style.space(4)
                Text {
                  width: parent.width
                  visible: root.editorRows().length === 0
                  textFormat: Text.PlainText
                  text: "No items here — add one."
                  color: root.foreground
                  opacity: 0.6
                  font.family: Style.fontFamily
                  font.pixelSize: Style.font.body
                }
                Repeater {
                  model: root.editorRows()
                  Item {
                    required property var modelData
                    width: editorListCol.width
                    height: Style.space(40)
                    // Tap a submenu row to drill in; buttons above consume
                    // their own clicks first.
                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: (modelData.kind === "menu" || modelData.kind === "link") ? Qt.PointingHandCursor : Qt.ArrowCursor
                      onClicked: {
                        var t = modelData.kind === "link" ? modelData.target : modelData.id
                        if ((modelData.kind === "menu" || modelData.kind === "link") && t) root.editorMenu = t
                      }
                    }
                    Row {
                      anchors.fill: parent
                      spacing: Style.space(8)
                    Text {
                      width: Style.space(28)
                      height: parent.height
                      verticalAlignment: Text.AlignVCenter
                      horizontalAlignment: Text.AlignHCenter
                      textFormat: Text.PlainText
                      text: root.isImageIcon(modelData.icon) ? "▦" : (modelData.icon || "•")
                      color: root.foreground
                      font.family: modelData.iconFont || Style.fontFamily
                      font.pixelSize: Style.font.title
                    }
                    Column {
                      width: parent.width - Style.space(28) - Style.space(64) - Style.space(72) - parent.spacing * 3
                      anchors.verticalCenter: parent.verticalCenter
                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: root.labelFor(modelData) + ((modelData.kind === "menu" || modelData.kind === "link") ? " ›" : "")
                        color: root.foreground
                        font.family: Style.fontFamily
                        font.pixelSize: Style.font.body
                        elide: Text.ElideRight
                      }
                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: {
                          var badge = root.editorBadge(modelData)
                          return modelData.id + (badge ? " • " + badge : "")
                        }
                        color: root.foreground
                        opacity: 0.55
                        font.family: Style.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                      }
                    }
                    Button {
                      width: Style.space(64)
                      anchors.verticalCenter: parent.verticalCenter
                      visible: modelData.id !== "recent" && root.editorBadge(modelData) !== "auto"
                      text: "Edit"
                      onClicked: root.beginEditorEdit(modelData.id)
                    }
                    Button {
                      width: Style.space(72)
                      anchors.verticalCenter: parent.verticalCenter
                      visible: modelData.id === "recent" ? root.recentEntries.length > 0 : root.editorBadge(modelData) !== "auto"
                      text: modelData.id === "recent" ? "Clear" : root.editorDelLabel(modelData)
                      onClicked: {
                        if (modelData.id === "recent") { root.clearRecent(); return }
                        var badge = root.editorBadge(modelData)
                        if (badge === "hidden") root.unhideEditorItem(modelData.id)
                        else root.deleteEditorItem(modelData.id)
                      }
                    }
                    }
                  }
                }
              }
            }
          }

          // Form mode: add / edit a single entry.
          Column {
            id: editorFormSlot
            width: parent.width
            visible: root.editorFormOpen
            height: root.editorFormOpen ? implicitHeight : 0
            spacing: Style.space(6)
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.editorEditingId ? "Edit item" : "New item"
              color: root.foreground
              font.family: Style.fontFamily
              font.pixelSize: Style.font.subtitle
              font.weight: Font.Medium
            }
            TextField {
              id: editorLabelField
              width: parent.width
              placeholderText: "Label (required)"
              onAccepted: root.saveEditorForm()
              Keys.onEscapePressed: { root.editorBack(); event.accepted = true }
            }
            Row {
              width: parent.width
              spacing: Style.space(8)
              TextField {
                id: editorIconField
                width: parent.width - previewBox.width - parent.spacing
                placeholderText: "Icon glyph or image path"
                onAccepted: root.saveEditorForm()
                Keys.onEscapePressed: { root.editorBack(); event.accepted = true }
              }
              Item {
                id: previewBox
                width: Style.space(40)
                height: Style.space(40)
                Text {
                  visible: !root.isImageIcon(editorIconField.text)
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: editorIconField.text || "•"
                  color: root.foreground
                  font.family: Style.fontFamily
                  font.pixelSize: Style.font.display
                }
                Image {
                  visible: root.isImageIcon(editorIconField.text)
                  anchors.centerIn: parent
                  width: Style.space(32)
                  height: Style.space(32)
                  fillMode: Image.PreserveAspectFit
                  source: root.iconSourceFor(editorIconField.text)
                  asynchronous: true
                }
              }
            }
            Toggle {
              id: editorKindToggle
              width: parent.width
              visible: !root.editorLockKind
              label: "Run a command"
              description: "Off = submenu that holds more items"
              checked: root.editorIsActionForm
              onClicked: root.editorIsActionForm = !root.editorIsActionForm
            }
            TextField {
              id: editorCommandField
              width: parent.width
              visible: root.editorIsActionForm
              placeholderText: "Command (required for actions)"
              onAccepted: root.saveEditorForm()
              Keys.onEscapePressed: { root.editorBack(); event.accepted = true }
            }
            Text {
              width: parent.width
              visible: root.editorError !== ""
              textFormat: Text.PlainText
              text: root.editorError
              color: Color.urgent
              font.family: Style.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }
            Row {
              width: parent.width
              spacing: Style.space(8)
              Button {
                text: "Save"
                onClicked: root.saveEditorForm()
              }
              Button {
                text: "Cancel"
                onClicked: {
                  root.editorFormOpen = false
                  root.editorError = ""
                  keyCatcher.forceActiveFocus()
                }
              }
            }
          }

          Item {
            id: editorFooter
            width: parent.width
            height: visible ? Style.space(36) : 0
            visible: !root.editorFormOpen
            Button {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              visible: root.editorMenu !== "root"
              text: "‹ Back"
              onClicked: root.editorBack()
            }
            Button {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "+ Add item"
              onClicked: root.beginEditorAdd()
            }
          }
        }
      }
    }
  }
}
