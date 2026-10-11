#!/usr/bin/env python3
"""OmaWheel fallback apps enumerator.

The scoped `shell.appLibrary` facade is documented for menu plugins but
arrives null on this host (both at startup for keepLoaded plugins and at
summon time), so the wheel enumerates XDG .desktop files itself and emits
one tab-delimited row per app:

    <desktop-id>\\t<Name>\\t<GenericName>\\t<Icon>\\t<Keywords>\\t<Categories>

NoDisplay/Hidden entries are skipped. First directory wins for duplicate
ids (user-local overrides system), mirroring XDG precedence. Icons are
resolved to absolute paths here (current theme plus its inheritance
chain, then the GTK implicit fallbacks, hicolor last — the same lookup
the stock icon index performs); anything unresolved keeps its bare name
for client-side Quickshell.iconPath. Categories feed the Apps →
category sub-wheels in the wheel UI.
"""

import os
import re
import subprocess
import sys

APP_DIRS = [
    os.path.expanduser("~/.local/share/applications"),
    "/usr/share/applications",
    os.path.expanduser("~/.local/share/flatpak/exports/share/applications"),
    "/var/lib/flatpak/exports/share/applications",
]

FALSE_VALUES = ("false", "0", "no", "off")

ICON_EXTS = (".png", ".svg", ".svgz", ".xpm")
ICON_CONTEXT_RANK = {"apps": 0, "devices": 1, "actions": 2, "mimetypes": 3,
                     "categories": 4, "emblems": 5, "status": 6}
SIZE_RE = re.compile(r"(\d+)[xX](\d+)")


def theme_inherits(theme):
    """Parent themes from index.theme (freedesktop inheritance)."""
    parents = []
    for base in (os.path.expanduser("~/.local/share/icons"),
                 os.path.expanduser("~/.icons"),
                 "/usr/share/icons"):
        index_theme = os.path.join(base, theme, "index.theme")
        try:
            with open(index_theme, "r", encoding="utf-8",
                      errors="replace") as handle:
                for raw in handle:
                    line = raw.strip()
                    if line.lower().startswith("inherits="):
                        parents.extend(
                            p for p in
                            (x.strip() for x in
                             line.split("=", 1)[1].split(","))
                            if p)
                        break
        except OSError:
            continue
    return parents


def detect_icon_themes():
    """Current icon theme first with its inheritance chain, then the GTK
    implicit fallbacks, hicolor always last (freedesktop fallback)."""
    themes = []
    try:
        out = subprocess.run(
            ["gsettings", "get", "org.gnome.desktop.interface", "icon-theme"],
            capture_output=True, text=True, timeout=5)
        name = (out.stdout or "").strip().strip("'\"")
        if name:
            themes.append(name)
    except Exception:
        pass
    queue = list(themes)
    while queue:
        for parent in theme_inherits(queue.pop(0)):
            if parent not in themes:
                themes.append(parent)
                queue.append(parent)
    for fallback in ("Adwaita", "AdwaitaLegacy", "hicolor"):
        if fallback not in themes:
            themes.append(fallback)
    return themes


def icon_candidate_score(theme_rank, path):
    """Lower is better: themed over fallback, apps context over the rest,
    scalable svg over raster, larger raster over smaller."""
    parts = path.split(os.sep)
    context = parts[-2] if len(parts) >= 2 else ""
    context_rank = ICON_CONTEXT_RANK.get(context, 9)
    size_dir = parts[-3] if len(parts) >= 3 else ""
    size_rank = 0
    if size_dir == "scalable":
        size_rank = -1000000
    else:
        m = SIZE_RE.search(size_dir)
        if m:
            size_rank = -max(int(m.group(1)), int(m.group(2)))
    ext = os.path.splitext(path)[1].lower()
    ext_rank = 0 if ext == ".svg" else (1 if ext == ".svgz" else 2)
    return (theme_rank, context_rank, size_rank, ext_rank)


def build_icon_index(needed):
    """Map bare icon names to best absolute file. `needed` holds names as
    written in desktop files (with or without extension)."""
    wanted = set()
    for icon in needed:
        wanted.add(icon)
        root, ext = os.path.splitext(icon)
        if ext.lower() in ICON_EXTS and root:
            wanted.add(root)
    index = {}
    if not wanted:
        return index
    theme_bases = [os.path.expanduser("~/.local/share/icons"),
                   os.path.expanduser("~/.icons"),
                   "/usr/share/icons"]
    pixmaps_dirs = [os.path.expanduser("~/.local/share/pixmaps"),
                    "/usr/share/pixmaps"]
    themes = detect_icon_themes()
    for theme_rank, theme in enumerate(themes):
        for base in theme_bases:
            theme_dir = os.path.join(base, theme)
            if not os.path.isdir(theme_dir):
                continue
            for dirpath, _dirnames, filenames in os.walk(theme_dir):
                for filename in filenames:
                    stem, ext = os.path.splitext(filename)
                    if ext.lower() not in ICON_EXTS or stem not in wanted:
                        continue
                    full = os.path.join(dirpath, filename)
                    score = icon_candidate_score(theme_rank, full)
                    prev = index.get(stem)
                    if prev is None or score < prev[0]:
                        index[stem] = (score, full)
    for pixmaps in pixmaps_dirs:
        try:
            files = os.listdir(pixmaps)
        except OSError:
            continue
        for filename in files:
            stem, ext = os.path.splitext(filename)
            if ext.lower() not in ICON_EXTS or stem not in wanted:
                continue
            full = os.path.join(pixmaps, filename)
            score = (len(themes), 9, 0, 0)
            prev = index.get(stem)
            if prev is None or score < prev[0]:
                index[stem] = (score, full)
    return {name: path for name, (_score, path) in index.items()}


def resolve_icon(icon, index):
    """Absolute existing path (or ~) passes through; otherwise the index,
    else the bare name for client-side themed lookup."""
    value = (icon or "").strip()
    if not value:
        return ""
    if value.startswith("~") or os.path.isabs(value):
        expanded = os.path.expanduser(value)
        if os.path.isfile(expanded):
            return expanded
        stem = os.path.splitext(os.path.basename(expanded))[0]
        if stem in index:
            return index[stem]
        return value
    if value in index:
        return index[value]
    stem = os.path.splitext(value)[0]
    if stem in index:
        return index[stem]
    return value


def parse_desktop(path):
    """Return (name, generic, icon, keywords, categories) or None when skipped."""
    name = ""
    name_fb = ""
    generic = ""
    icon = ""
    keywords = ""
    categories = ""
    in_entry = False
    try:
        handle = open(path, "r", encoding="utf-8", errors="replace")
    except OSError:
        return None
    with handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("["):
                in_entry = line == "[Desktop Entry]"
                continue
            if not in_entry or "=" not in line:
                continue
            key, value = line.split("=", 1)
            value = value.strip().replace("\t", " ")
            if key == "Name" and not name:
                name = value
            elif key.startswith("Name[") and not name_fb:
                name_fb = value
            elif key == "GenericName" and not generic:
                generic = value
            elif key == "Icon" and not icon:
                icon = value
            elif key == "Keywords" and not keywords:
                keywords = value
            elif key == "Categories" and not categories:
                categories = value
            elif key in ("NoDisplay", "Hidden"):
                if value.strip().lower() not in FALSE_VALUES:
                    return None
    label = name or name_fb
    if not label:
        return None
    return (label, generic, icon, keywords, categories)


def main():
    seen = set()
    found = []
    needed_icons = set()
    for directory in APP_DIRS:
        try:
            files = sorted(os.listdir(directory))
        except OSError:
            continue
        for filename in files:
            if not filename.endswith(".desktop"):
                continue
            app_id = filename[: -len(".desktop")]
            if not app_id or app_id in seen:
                continue
            parsed = parse_desktop(os.path.join(directory, filename))
            if parsed is None:
                continue
            seen.add(app_id)
            found.append((app_id,) + parsed)
            if parsed[2]:
                needed_icons.add(parsed[2])
    index = build_icon_index(needed_icons)
    rows = []
    for (app_id, label, generic, icon, keywords, categories) in found:
        rows.append("\t".join([app_id, label, generic,
                               resolve_icon(icon, index),
                               keywords, categories]))
    if rows:
        sys.stdout.write("\n".join(rows) + "\n")


if __name__ == "__main__":
    main()
