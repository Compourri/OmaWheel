function stripJsonc(raw) {
  return String(raw || "")
    .replace(/^\s*\/\/[^\n]*(\n|$)/gm, "")
    .replace(/,(\s*[}\]])/g, "$1")
}

function normalizeAliases(value) {
  if (Array.isArray(value)) return value.filter(function(v) { return v })
  if (typeof value === "string" && value) return [value]
  return []
}

function normalizeItem(id, raw) {
  var value = raw || {}
  var aliases = normalizeAliases(value.aliases)
  var parent = value.parent
  if (parent === undefined)
    parent = id.indexOf(".") >= 0 ? id.split(".").slice(0, -1).join(".") : "root"
  if (id === "root") parent = ""

  var kind = value.action ? "action" : (value.target ? "link" : "menu")

  return {
    id: id,
    parent: parent,
    kind: kind,
    icon: value.icon || "",
    iconFont: value.iconFont || "",
    label: value.label || id,
    title: value.title || "",
    target: value.target || "",
    description: value.description || "",
    action: value.action || "",
    provider: value.provider || "",
    aliases: aliases,
    when: value.when || "",
    checked: value.checked || ""
  }
}

function parseMenuJsonc(raw) {
  var stripped = stripJsonc(raw)
  if (!stripped.trim()) return []

  var parsed
  try {
    parsed = JSON.parse(stripped)
  } catch (e) {
    return []
  }
  if (typeof parsed !== "object" || parsed === null) return []

  var source = (parsed.items && typeof parsed.items === "object" && !Array.isArray(parsed.items))
    ? parsed.items
    : parsed
  var out = []
  for (var id in source) {
    var entry = source[id]
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue
    out.push(normalizeItem(id, entry))
  }
  return out
}

function mergeMenuSources(defaultItems, userItems) {
  var nextItems = ({})
  var nextOrder = []
  var sources = [defaultItems || [], userItems || []]

  for (var s = 0; s < sources.length; s++) {
    var src = sources[s]
    for (var i = 0; i < src.length; i++) {
      var entry = src[i]
      if (!entry || !entry.id) continue
      if (!nextItems[entry.id]) nextOrder.push(entry.id)
      var prior = nextItems[entry.id] || {}
      var merged = {}
      for (var k in prior) merged[k] = prior[k]
      for (var k2 in entry) merged[k2] = entry[k2]
      merged.id = entry.id
      nextItems[entry.id] = merged
    }
  }

  if (!nextItems.root) {
    nextItems.root = { id: "root", parent: "", kind: "menu", icon: "", iconFont: "", label: "Go", title: "", target: "", description: "", aliases: [], when: "", checked: "", action: "", provider: "" }
    nextOrder.unshift("root")
  }
  for (var k3 = 0; k3 < nextOrder.length; k3++) nextItems[nextOrder[k3]].order = k3

  return {
    items: nextItems,
    itemOrder: nextOrder
  }
}

// Both merges below return fresh items/itemOrder objects for the caller to
// assign in one go. They must never write into the maps they are handed: those
// live in QML `var` properties, and an in-place write into such an object is
// occasionally dropped by the engine — the key lands with an undefined value.
// A lost write used to leave an id in itemOrder with no item behind it, and
// the next merge then kept that orphan and appended a second row for the same
// app, so the launcher listed it twice (and again on every later rescan).

// Swaps every app row for the current set. Rows keep the order they arrive in;
// ids already claimed (including duplicate desktop ids) are listed once.
function mergeAppRows(items, itemOrder, appRows) {
  var source = items || ({})
  var order = Array.isArray(itemOrder) ? itemOrder : []
  var rows = Array.isArray(appRows) ? appRows : []
  var nextItems = ({})
  var nextOrder = []

  for (var i = 0; i < order.length; i++) {
    var id = order[i]
    var existing = source[id]
    // Orphans (an id with no item) are dropped rather than carried forward,
    // so a single lost write cannot compound into a duplicate row.
    if (!existing || existing.kind === "app") continue
    nextItems[id] = existing
    nextOrder.push(id)
  }

  for (var j = 0; j < rows.length; j++) {
    var row = rows[j]
    if (!row || !row.id || nextItems[row.id]) continue
    row.order = nextOrder.length
    nextItems[row.id] = row
    nextOrder.push(row.id)
  }

  return { items: nextItems, itemOrder: nextOrder }
}

// Swaps the rows one provider contributed, leaving every other item untouched.
// Rows carry the id of the submenu that produced them, so a provider that runs
// again drops its previous batch — a plugin that was just enabled disappears
// from the Enable list — without disturbing static children declared in JSONC.
function swapProviderRows(items, itemOrder, menuId, rows) {
  var source = items || ({})
  var order = Array.isArray(itemOrder) ? itemOrder : []
  var incoming = Array.isArray(rows) ? rows : []
  var nextItems = ({})
  var nextOrder = []

  for (var i = 0; i < order.length; i++) {
    var id = order[i]
    var existing = source[id]
    if (!existing || existing.providerMenu === menuId) continue
    nextItems[id] = existing
    nextOrder.push(id)
  }

  for (var j = 0; j < incoming.length; j++) {
    var row = incoming[j]
    if (!row || !row.id || nextItems[row.id]) continue
    row.providerMenu = menuId
    row.order = nextOrder.length
    nextItems[row.id] = row
    nextOrder.push(row.id)
  }

  return { items: nextItems, itemOrder: nextOrder }
}

function item(items, id) {
  return items && items[id] ? items[id] : null
}

// Routes may name a real id (`system`, `setup.power`) or an alias declared in
// JSONC (`power-menu`, `settings`). An exact id beats any alias, and app rows
// are never routable: their aliases carry .desktop Keywords and GenericName
// for search, so an installed application could otherwise shadow a menu route
// (htop ships `Keywords=system;...`). Unknown strings fall through as the
// literal input so misspellings still attempt to open that id.
function resolveRoute(items, itemOrder, input) {
  var raw = String(input || "").toLowerCase().replace(/_/g, "-")
  if (!raw || raw === "go" || raw === "menu") return "root"
  if (item(items, raw)) return raw
  var order = Array.isArray(itemOrder) ? itemOrder : []
  for (var i = 0; i < order.length; i++) {
    var entry = item(items, order[i])
    if (!entry || entry.kind === "app" || !entry.aliases) continue
    for (var j = 0; j < entry.aliases.length; j++) {
      var alias = String(entry.aliases[j] || "").toLowerCase().replace(/_/g, "-")
      if (alias === raw) return entry.id
    }
  }
  return raw
}

function slugify(value) {
  return String(value || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "item"
}

function depthFor(items, id) {
  var depth = 0
  var current = item(items, id)
  var guard = 0

  while (current && current.parent && current.parent !== "root" && guard < 32) {
    depth += 1
    current = item(items, current.parent)
    guard += 1
  }

  return depth
}

function pathFor(items, id) {
  var labels = []
  var current = item(items, id)
  var guard = 0

  while (current && current.id !== "root" && guard < 32) {
    labels.unshift(current.label)
    current = item(items, current.parent)
    guard += 1
  }

  return labels.join(" › ")
}

function parentPathFor(items, id) {
  var entry = item(items, id)
  if (!entry || !entry.parent || entry.parent === "root") return ""
  return pathFor(items, entry.parent)
}

function isDescendantOf(items, id, ancestorId) {
  if (ancestorId === "root") return id !== "root"

  var current = item(items, id)
  var guard = 0
  while (current && current.parent && guard < 32) {
    if (current.parent === ancestorId) return true
    current = item(items, current.parent)
    guard += 1
  }

  return false
}

function childCount(items, itemOrder, id) {
  var count = 0
  var order = Array.isArray(itemOrder) ? itemOrder : []
  for (var i = 0; i < order.length; i++) {
    var entry = item(items, order[i])
    if (entry && entry.parent === id) count += 1
  }
  return count
}

function isVisible(items, itemOrder, whenResults, entry, depth) {
  if (!entry) return false
  if (entry.when && whenResults && whenResults[entry.id] === false) return false
  if (entry.kind !== "menu" && entry.kind !== "link") return true
  if (entry.provider) return true

  var guard = depth || 0
  if (guard >= 32) return false

  var target = entry.kind === "link" ? entry.target : entry.id
  var order = Array.isArray(itemOrder) ? itemOrder : []
  for (var i = 0; i < order.length; i++) {
    var child = item(items, order[i])
    if (child && child.parent === target && isVisible(items, itemOrder, whenResults, child, guard + 1)) return true
  }

  return false
}

function labelFor(entry, checkedResults) {
  if (!entry) return ""
  if (entry.checked && checkedResults && checkedResults[entry.id]) return entry.label + " ✓"
  return entry.label
}

function searchableToken(value) {
  return String(value || "").replace(/[._-]+/g, " ")
}

function leafIdFor(id) {
  var parts = String(id || "").split(".")
  return parts.length > 0 ? parts[parts.length - 1] : id
}

function nameSearchText(entry) {
  if (!entry) return ""
  var aliases = []
  var values = Array.isArray(entry.aliases) ? entry.aliases : []
  for (var i = 0; i < values.length; i++) aliases.push(searchableToken(values[i]))
  return [entry.label, searchableToken(leafIdFor(entry.id)), aliases.join(" ")].join(" ").toLowerCase()
}

function termInSearchWords(term, text) {
  var words = String(text || "").toLowerCase().split(/\s+/)
  for (var i = 0; i < words.length; i++) {
    if (words[i] === term) return true
  }
  return false
}

function descriptionTextMatches(query, text) {
  var terms = String(query || "").toLowerCase().trim().split(/\s+/)
  for (var i = 0; i < terms.length; i++) {
    if (terms[i] && !termInSearchWords(terms[i], text)) return false
  }
  return true
}

function matchesQuery(entry, query, visible) {
  if (!entry || entry.id === "root") return false
  if (!visible) return false

  var nameText = nameSearchText(entry)
  var descriptionText = String(entry.description || "").toLowerCase()
  var terms = String(query || "").toLowerCase().trim().split(/\s+/)

  for (var i = 0; i < terms.length; i++) {
    if (!terms[i]) continue
    if (nameText.indexOf(terms[i]) >= 0) continue
    if (termInSearchWords(terms[i], descriptionText)) continue
    return false
  }

  return true
}

function searchScore(items, entry, query) {
  var needle = String(query || "").toLowerCase().trim()
  var label = entry.label.toLowerCase()
  var nameText = nameSearchText(entry)
  var descriptionText = String(entry.description || "").toLowerCase()
  var score = 80

  if (label === needle) score = entry.parent === "root" ? 2 : 0
  // An installed app whose name contains the query as a whole word ("zen"
  // for Zen Browser) beats exact-labeled menu entries like Install > Zen.
  else if (entry.kind === "app" && label.split(/\s+/).indexOf(needle) >= 0) score = 0
  else if (label.indexOf(needle) === 0) score = 10
  else if (label.indexOf(needle) >= 0) score = 30
  else if (nameText.indexOf(needle) >= 0) score = 40
  else if (descriptionTextMatches(needle, descriptionText)) score = 60

  if (entry.kind === "menu" || entry.kind === "link") score -= 2
  // App rows sort after all menu items, so they lose the tiebreak below to an
  // equal match. Outrank those, but stay inside the tier so better ones win.
  if (entry.kind === "app") score -= 5

  return score * 1000 + depthFor(items, entry.id) * 25 + entry.order
}

function displayRow(items, itemOrder, checkedResults, entry, detail, score, section) {
  var target = entry.kind === "link" ? entry.target : entry.id
  return {
    itemId: entry.id,
    kind: entry.kind,
    icon: entry.icon,
    iconFont: entry.iconFont || "",
    appIcon: entry.appIcon || "",
    appId: entry.appId || "",
    label: labelFor(entry, checkedResults),
    target: target,
    detail: detail || "",
    path: pathFor(items, entry.id),
    childCount: (entry.kind === "menu" || entry.kind === "link") ? childCount(items, itemOrder, target) : 0,
    action: entry.action || "",
    provider: entry.provider || "",
    score: score || 0,
    section: section || ""
  }
}

// Commands a `checked:` expression reads a value out of. Every sibling row
// asks the same one -- Defaults > Browser has seven rows all comparing
// against `omarchy-default-browser` -- so the batch runs it once and the rows
// read the captured answer.
//
// The capture has to be eager. These are read inside `$(...)`, and a value
// cached while one expression runs lives in that subshell only, so a lazy
// memo never survives to the expression after it.
var GUARD_READERS = [
  "omarchy-channel-current",
  "omarchy-default-agent",
  "omarchy-default-browser",
  "omarchy-default-editor",
  "omarchy-default-terminal",
  "omarchy-dns"
]

// Package and command presence account for most of what the guards ask, and
// asked one at a time they are almost all fork: the shipped menu spends over
// a second on them. Answer them inside the guard process instead. These
// shadow the real commands for the batch only, so they have to agree with
// them everywhere, including for no arguments at all (present is true of
// nothing, missing is not).
//
// `pacman -Q` resolves a name through what installed packages provide, not
// just what they are called -- with gvim installed it reports `vim` as
// present -- so the set has to carry provides too, or `install.editor.vim`
// comes back and offers to install what is already there. A version
// constraint (`bash>=1`) is not a name any set can answer, so it goes to
// pacman itself; no shipped guard writes one.
//
// `pacman -Qi` wraps a long list across continuation lines whenever COLUMNS
// is set in the environment, which a login shell may well have done, so the
// parser follows the indented lines rather than reading the first one and
// dropping half of what is installed.
function guardHelpers() {
  return 'declare -A __omarchy_pkgs=()\n'
    + 'mapfile -t __omarchy_pkg_names < <({ pacman -Qq; LC_ALL=C pacman -Qi'
    + " | awk '/^[A-Za-z]/ { provides = ($0 ~ /^Provides/); sub(/^[^:]*: /, \"\") }"
    + ' provides && $0 != "None" { n = split($0, p, " ");'
    + ' for (i = 1; i <= n; i++) { sub(/[<>=].*/, "", p[i]); print p[i] } }\'; } 2>/dev/null)\n'
    + 'for __omarchy_pkg in "${__omarchy_pkg_names[@]}"; do __omarchy_pkgs[$__omarchy_pkg]=1; done\n'
    + '__omarchy_pkg_has() { [[ -n ${__omarchy_pkgs[$1]-} ]] && return 0; '
    + '[[ $1 == *[\\<\\>=]* ]] && { pacman -Q "$1" &>/dev/null; return; }; return 1; }\n'
    + 'omarchy-pkg-present() { local p; for p in "$@"; do __omarchy_pkg_has "$p" || return 1; done; return 0; }\n'
    + 'omarchy-pkg-missing() { local p; for p in "$@"; do __omarchy_pkg_has "$p" || return 0; done; return 1; }\n'
    + 'omarchy-cmd-present() { local c; for c in "$@"; do command -v "$c" &>/dev/null || return 1; done; return 0; }\n'
    + 'omarchy-cmd-missing() { local c; for c in "$@"; do command -v "$c" &>/dev/null || return 0; done; return 1; }\n'
}

// Substitute the captured answer into the expression rather than shadowing
// the reader with a function. `$(reader)` and the variable holding what it
// printed are interchangeable -- both strip trailing newlines, both split the
// same way unquoted -- while a function would also catch `command -v reader`,
// `VAR=x reader`, and every other form, and answer those wrong. Anything but
// the plain substitution is left alone to run the real command.
function guardPrelude(guards) {
  var prelude = guardHelpers()

  for (var i = 0; i < GUARD_READERS.length; i++) {
    // The guards arrive already substituted, so what marks a reader as wanted
    // is the slot standing in for it, not the call it replaced.
    if (guards.indexOf(guardReaderSlot(i)) < 0) continue
    // `|| :` so a reader that exits nonzero cannot take the batch down with
    // it under a login shell that turned on errexit.
    prelude += "__omarchy_read_" + i + "=$(" + GUARD_READERS[i] + " 2>/dev/null) || :\n"
  }

  return prelude
}

function guardReaderSlot(index) {
  return "${__omarchy_read_" + index + "}"
}

function substituteGuardReaders(expression) {
  for (var i = 0; i < GUARD_READERS.length; i++)
    expression = expression.split("$(" + GUARD_READERS[i] + ")").join(guardReaderSlot(i))

  return expression
}

function guardLine(id, tag, expression) {
  return "if { " + substituteGuardReaders(expression) + "; } >/dev/null 2>&1; then echo "
    + id + ":" + tag + ":1; else echo " + id + ":" + tag + ":0; fi\n"
}

// One bash script for every `when:` and `checked:` in the menu, reporting
// `<id>:<w|c>:<0|1>` per line. Speed is the whole point: the menu opens on
// the last evaluation's answers, so however long this takes is how long a row
// can contradict the state it describes.
function guardScript(items) {
  var guards = ""
  var ids = Object.keys(items || {})

  for (var i = 0; i < ids.length; i++) {
    var entry = items[ids[i]]
    if (!entry) continue
    if (entry.when) guards += guardLine(ids[i], "w", entry.when)
    if (entry.checked) guards += guardLine(ids[i], "c", entry.checked)
  }

  return guards ? guardPrelude(guards) + guards : ""
}

// Island (https://github.com/Guilhermerisu/island) points the shared user
// menu file's stock entries at itself on setup (companion/install.sh):
//   "apps": {"action":"omarchy-shell guilhermerisu.island apps"}, ...
// for style.theme, style.background, apps, system, trigger.emoji,
// learn.keybindings. Merged verbatim that flips "apps" from a provider
// submenu into an action, so the wheel's Apps wedge launches the island
// instead of drilling into app categories (and System loses its subtree
// the same way). The wheel ignores those overrides in memory — the file
// itself is left alone so the stock menu keeps whatever island intended.
// A custom user entry that merely opens the island under its own id is
// intentional and is kept; only the six stock ids are scrubbed.
var ISLAND_HIJACK_IDS = [
  "style.theme",
  "style.background",
  "apps",
  "system",
  "trigger.emoji",
  "learn.keybindings"
]

function isIslandHijack(entry) {
  if (!entry || !entry.id) return false
  if (ISLAND_HIJACK_IDS.indexOf(entry.id) < 0) return false
  return String(entry.action || "").indexOf("guilhermerisu.island") >= 0
}

function scrubIslandHijacks(defaultItems, userItems) {
  var list = Array.isArray(userItems) ? userItems : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (isIslandHijack(list[i])) continue
    out.push(list[i])
  }
  return out
}

var GLYPH_INK = {
  '\u0001\u2022': 0.24,
  '\u0001\u2713': 0.53,
  '\u0001\ue383': 0.75,
  '\u0001\ue615': 0.88,
  '\u0001\ue627': 0.88,
  '\u0001\ue62a': 0.88,
  '\u0001\ue62b': 0.875,
  '\u0001\ue62d': 0.88,
  '\u0001\ue638': 0.875,
  '\u0001\ue659': 0.875,
  '\u0001\ue6ae': 0.88,
  '\u0001\ue707': 0.74,
  '\u0001\ue737': 0.78,
  '\u0001\ue738': 0.78,
  '\u0001\ue73c': 0.77,
  '\u0001\ue73d': 0.8,
  '\u0001\ue73f': 0.8,
  '\u0001\ue757': 0.78,
  '\u0001\ue768': 0.8,
  '\u0001\ue76f': 0.8,
  '\u0001\ue77f': 0.785,
  '\u0001\ue781': 0.785,
  '\u0001\ue795': 0.705,
  '\u0001\ue7a8': 0.8,
  '\u0001\ue7c0': 0.78,
  '\u0001\ue7f0': 0.8,
  '\u0001\ue84e': 0.8,
  '\u0001\ue860': 0.8,
  '\u0001\ue8da': 0.8,
  '\u0001\ue8ef': 0.8,
  '\u0001\ue999': 0.73,
  '\u0001\uea74': 0.88,
  '\u0001\uea78': 0.94,
  '\u0001\uea7b': 0.88,
  '\u0001\ueb01': 0.88,
  '\u0001\ueb11': 0.88,
  '\u0001\ueba2': 0.94,
  '\u0001\ueba4': 0.88,
  '\u0001\uebcf': 0.88,
  '\u0001\uec12': 0.88,
  '\u0001\uec19': 0.88,
  '\u0001\ued0d': 0.91,
  '\u0001\ued3e': 0.9,
  '\u0001\uef70': 0.93,
  '\u0001\uef94': 0.93,
  '\u0001\uefba': 0.93,
  '\u0001\uf001': 0.93,
  '\u0001\uf005': 0.955,
  '\u0001\uf011': 0.9,
  '\u0001\uf013': 0.93,
  '\u0001\uf021': 0.865,
  '\u0001\uf023': 0.93,
  '\u0001\uf030': 0.925,
  '\u0001\uf03a': 0.895,
  '\u0001\uf03d': 1.04,
  '\u0001\uf03e': 0.925,
  '\u0001\uf040': 0.93,
  '\u0001\uf044': 0.92,
  '\u0001\uf047': 0.93,
  '\u0001\uf07f': 0.93,
  '\u0001\uf0ac': 0.93,
  '\u0001\uf0ad': 0.93,
  '\u0001\uf0c3': 0.93,
  '\u0001\uf0db': 0.925,
  '\u0001\uf114': 0.925,
  '\u0001\uf118': 0.93,
  '\u0001\uf11b': 1.155,
  '\u0001\uf11c': 1.04,
  '\u0001\uf121': 1.155,
  '\u0001\uf15c': 0.93,
  '\u0001\uf19d': 1.155,
  '\u0001\uf1b2': 0.925,
  '\u0001\uf1b6': 0.9,
  '\u0001\uf1da': 0.93,
  '\u0001\uf1de': 0.925,
  '\u0001\uf21f': 1.155,
  '\u0001\uf268': 0.93,
  '\u0001\uf269': 0.9,
  '\u0001\uf2d0': 0.925,
  '\u0001\uf359': 1.0,
  '\u0001\uf405': 1.0,
  '\u0001\uf46a': 0.88,
  '\u0001\uf487': 0.98,
  '\u0001\uf488': 1.0,
  '\u0001\uf489': 1.0,
  '\u0001\uf4b8': 1.0,
  '\u0001\uf50e': 0.94,
  '\u0001\uf835': 0.73,
  '\u0001\u1f534': 0.73,
  '\u0001\u1f7e0': 0.73,
  '\u0001\u1f7e1': 0.73,
  '\u0001\u1f7e2': 0.73,
  '\u0001\uf003b': 0.67,
  '\u0001\uf0045': 0.66,
  '\u0001\uf004d': 0.66,
  '\u0001\uf0054': 0.66,
  '\u0001\uf005d': 0.66,
  '\u0001\uf0079': 0.84,
  '\u0001\uf009b': 0.89,
  '\u0001\uf00af': 0.84,
  '\u0001\uf00b5': 0.8,
  '\u0001\uf00c9': 0.71,
  '\u0001\uf012c': 0.73,
  '\u0001\uf0156': 0.59,
  '\u0001\uf015f': 1.0,
  '\u0001\uf0176': 0.835,
  '\u0001\uf018f': 0.92,
  '\u0001\uf01bd': 0.82,
  '\u0001\uf01c5': 0.84,
  '\u0001\uf01d6': 0.75,
  '\u0001\uf01e9': 0.835,
  '\u0001\uf0237': 0.84,
  '\u0001\uf0249': 0.75,
  '\u0001\uf02ad': 0.84,
  '\u0001\uf02af': 0.84,
  '\u0001\uf02ca': 0.84,
  '\u0001\uf02d1': 0.835,
  '\u0001\uf030c': 0.835,
  '\u0001\uf033e': 0.88,
  '\u0001\uf0343': 0.84,
  '\u0001\uf035c': 0.75,
  '\u0001\uf0372': 0.8,
  '\u0001\uf0373': 0.84,
  '\u0001\uf0379': 0.92,
  '\u0001\uf03d3': 0.75,
  '\u0001\uf03d6': 0.88,
  '\u0001\uf0425': 0.71,
  '\u0001\uf0431': 0.88,
  '\u0001\uf0432': 0.75,
  '\u0001\uf0453': 0.875,
  '\u0001\uf04b2': 0.92,
  '\u0001\uf04c5': 0.835,
  '\u0001\uf04c7': 0.84,
  '\u0001\uf050e': 0.87,
  '\u0001\uf052b': 0.75,
  '\u0001\uf059f': 0.84,
  '\u0001\uf05ba': 0.84,
  '\u0001\uf066f': 0.96,
  '\u0001\uf06a9': 0.92,
  '\u0001\uf06c4': 0.75,
  '\u0001\uf06e4': 1.0,
  '\u0001\uf06e7': 1.0,
  '\u0001\uf06f3': 0.84,
  '\u0001\uf0709': 0.81,
  '\u0001\uf0785': 0.84,
  '\u0001\uf07f5': 0.84,
  '\u0001\uf07f8': 0.835,
  '\u0001\uf0868': 0.835,
  '\u0001\uf0881': 0.92,
  '\u0001\uf088c': 0.92,
  '\u0001\uf08b9': 0.92,
  '\u0001\uf08c0': 0.71,
  '\u0001\uf08c7': 0.84,
  '\u0001\uf0901': 0.75,
  '\u0001\uf0966': 0.84,
  '\u0001\uf09f8': 0.88,
  '\u0001\uf0a5f': 0.75,
  '\u0001\uf0acf': 0.835,
  '\u0001\uf0ae2': 0.92,
  '\u0001\uf0b4c': 0.92,
  '\u0001\uf0b79': 0.835,
  '\u0001\uf0bc9': 0.92,
  '\u0001\uf0d11': 0.75,
  '\u0001\uf0d6e': 0.835,
  '\u0001\uf0e0c': 0.84,
  '\u0001\uf10ac': 0.835,
  '\u0001\uf1104': 0.92,
  '\u0001\uf1183': 0.59,
  '\u0001\uf11f1': 1.0,
  '\u0001\uf14de': 0.845,
  '\u0001\uf14df': 0.845,
  '\u0001\uf16a1': 0.92,
  '\u0001\uf16a4': 0.92,
  '\u0001\uf16be': 0.95,
  '\u0001\uf18f4': 0.835,
  '\u006f\u006d\u0061\u0072\u0063\u0068\u0079\u0001\ue900': 1.0,
  '\u006f\u006d\u0061\u0072\u0063\u0068\u0079\u0001\ue901': 0.88,
  '\u006f\u006d\u0061\u0072\u0063\u0068\u0079\u0001\ue902': 0.88,
  '\u006f\u006d\u0061\u0072\u0063\u0068\u0079\u0001\ue903': 0.88,
  '\u006f\u006d\u0061\u0072\u0063\u0068\u0079\u0001\ue904': 0.88,
  '\u006f\u006d\u0061\u0072\u0063\u0068\u0079\u0001\ue905': 0.88,
  '\u006f\u006d\u0061\u0072\u0063\u0068\u0079\u0001\ue906': 0.88,
  '\u006f\u006d\u0061\u0072\u0063\u0068\u0079\u0001\ue907': 0.88,
  '\u006f\u006d\u0061\u0072\u0063\u0068\u0079\u0001\ue908': 0.88,
  '\u006f\u006d\u0061\u0072\u0063\u0068\u0079\u0001\ue90a': 0.88,
  '\u006f\u006d\u0061\u0072\u0063\u0068\u0079\u0001\ue90b': 0.88,
  '\u006f\u006d\u0061\u0072\u0063\u0068\u0079\u0001\ue90c': 0.835,
  '\u006f\u006d\u0061\u0072\u0063\u0068\u0079\u0001\ue90d': 0.88
}

// Glyph ink normalization: icon-font glyphs vary wildly in ink coverage
// (measured 0.24–1.16 em across the shipped menu), while app image icons
// are full-bleed tiles filling their box. A single font size can never fit
// both a sprawling outline glyph and a compact mark, so each known glyph
// carries its measured max-dimension ink ratio (ink/em, via PIL over the
// exact font files) and the pixel size derives from the target box:
//   pixelSize = box / inkPerEm  →  every glyph inks the same box.
// Unknown/custom glyphs assume the median 0.88. Sizes clamp to 2.5×box so
// degenerate marks (the "•" missing-icon fallback) stay subdued instead of
// inflating to a full tile.
var GLYPH_FALLBACK_INK = 0.88

function glyphPixelSize(icon, iconFont, box) {
  var key = String(iconFont || "") + "\x01" + String(icon || "")
  var ink = GLYPH_INK[key] || GLYPH_FALLBACK_INK
  if (!(ink > 0)) ink = GLYPH_FALLBACK_INK
  var size = Math.round(box / ink)
  var cap = Math.round(box * 2.5)
  if (size > cap) size = cap
  if (size < 1) size = 1
  return size
}

if (typeof module !== "undefined") {
  module.exports = {
    islandHijackIds: ISLAND_HIJACK_IDS,
    isIslandHijack: isIslandHijack,
    scrubIslandHijacks: scrubIslandHijacks,
    guardReaders: GUARD_READERS,
    guardScript: guardScript,
    stripJsonc: stripJsonc,
    normalizeAliases: normalizeAliases,
    normalizeItem: normalizeItem,
    parseMenuJsonc: parseMenuJsonc,
    mergeMenuSources: mergeMenuSources,
    mergeAppRows: mergeAppRows,
    swapProviderRows: swapProviderRows,
    item: item,
    resolveRoute: resolveRoute,
    slugify: slugify,
    depthFor: depthFor,
    pathFor: pathFor,
    parentPathFor: parentPathFor,
    isDescendantOf: isDescendantOf,
    childCount: childCount,
    isVisible: isVisible,
    labelFor: labelFor,
    searchableToken: searchableToken,
    leafIdFor: leafIdFor,
    nameSearchText: nameSearchText,
    termInSearchWords: termInSearchWords,
    descriptionTextMatches: descriptionTextMatches,
    matchesQuery: matchesQuery,
    searchScore: searchScore,
    displayRow: displayRow,
    glyphPixelSize: glyphPixelSize
  }
}
