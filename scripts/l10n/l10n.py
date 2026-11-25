#!/usr/bin/env python3 -I
"""Regenerates Rolltop's string catalogs from the code and the translation memory.

    scripts/l10n/l10n.py --build      # Release build into .build/dd-strings, then sync (the usual run)
    scripts/l10n/l10n.py              # sync from the last Release build's .stringsdata
    scripts/l10n/l10n.py --check      # change nothing; exit 1 if a catalog is out of date
    scripts/l10n/l10n.py --stubs      # also append missing keys to the memory files, untranslated

How it works:
  1. Collect. The compiler writes one .stringsdata per Swift file (SWIFT_EMIT_LOC_STRINGS) with
     every String(localized:), LocalizedStringResource, SwiftUI literal key and App Intents
     title, description and parameter summary, per table; the App Intents processor adds the
     App Shortcuts phrases (table AppShortcuts). A Release build is used because Release
     compiles no `#if DEBUG` code, so Debug-only UI stays out of the catalogs. Info.plist usage
     descriptions are read from Rolltop/Resources/Info.plist (table InfoPlist).
  2. Merge. `xcstringstool sync` (Xcode's own merge) runs on copies of the catalogs: it adds
     new keys with the right format specifiers, string sets and comments and marks keys the
     code no longer uses as stale. Stale keys are then removed.
  3. Translate. Each table has a memory file, scripts/l10n/tm/<Table>.tm (format below):
     key -> zh-Hans, plus English plural forms where the source needs them. Every key the code
     uses is written with `en` source and `zh-Hans` marked translated.
  4. Report. Keys without a translation, translations whose placeholders differ from the
     source (printf specifiers and ${name} tokens), plural categories that do not match
     (en: one/other, zh-Hans: other), English that breaks the house style (straight
     apostrophes, British spellings, exclamation marks, "please"/"simply"/"just"), memory
     entries the code no longer uses, and near-duplicate English keys that should probably be
     one string. Without --build, a Swift file newer than its .stringsdata (or missing from the
     last build) stops the run, so an old build never passes for the current code.

Memory file format (UTF-8, one entry per line, values are JSON literals):
    # A comment for reviewers; kept in the file only.
    "Hidden items" = "隐藏项"
    "%lld items" = "%lld 项"
      en = {"one": "%lld item", "other": "%lld items"}   # English plural forms of the key
    "Toggle hidden items in ${applicationName}" = ["…", "…"]   # App Shortcuts phrases
Nothing is ever copied from the key: a translation identical to the English (%@, CPU, Rolltop)
is written out like any other, so a forgotten string never passes as translated.
"""
import argparse
import difflib
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
TM_DIR = ROOT / "scripts" / "l10n" / "tm"
DD = ROOT / ".build" / "dd-strings"
STAMP = DD / "l10n-build.stamp"  # touched after each successful --build
OBJECTS = DD / "Build" / "Intermediates.noindex" / "Rolltop.build" / "Release" / "Rolltop.build" / "Objects-normal" / "arm64"
INFO_PLIST = ROOT / "Rolltop" / "Resources" / "Info.plist"
INFO_PLIST_CATALOG = ROOT / "Rolltop" / "Resources" / "InfoPlist.xcstrings"
TARGET = "zh-Hans"
SOURCE = "en"
PLURAL_CATEGORIES = {SOURCE: {"one", "other"}, TARGET: {"other"}}

# Info.plist keys whose values users read: every NS…UsageDescription. The comment is Xcode's
# name for the key where known.
INFO_PLIST_KEY = re.compile(r"^NS\w*UsageDescription$")
INFO_PLIST_COMMENTS = {
    "NSAppleEventsUsageDescription": "Privacy - AppleEvents Sending Usage Description",
    "NSCalendarsFullAccessUsageDescription": "Privacy - Calendars Full Access Usage Description",
    "NSLocationUsageDescription": "Privacy - Location Usage Description",
    "NSLocationWhenInUseUsageDescription": "Privacy - Location When In Use Usage Description",
}

SPECIFIER = re.compile(
    r"%(?:(?P<pos>\d+)\$)?[-+ 0#']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?P<len>hh|h|ll|l|q|z|t|j|L)?(?P<conv>[@dDiuUxXoOfFeEgGcCsSpaA%])")
TOKEN = re.compile(r"\$\{(?P<name>[A-Za-z_]\w*)\}")


# ---------------------------------------------------------------------------- catalog JSON

def serialize(value, indent=0):
    """JSON exactly as Xcode writes .xcstrings (sorted keys, ' : ', empty objects on 3 lines)."""
    pad = "  " * indent
    if isinstance(value, dict):
        if not value:
            return "{\n\n" + pad + "}"
        rows = ["  " * (indent + 1) + json.dumps(k, ensure_ascii=False) + " : " + serialize(value[k], indent + 1)
                for k in sorted(value)]
        return "{\n" + ",\n".join(rows) + "\n" + pad + "}"
    if isinstance(value, list):
        if not value:
            return "[\n\n" + pad + "]"
        rows = ["  " * (indent + 1) + serialize(v, indent + 1) for v in value]
        return "[\n" + ",\n".join(rows) + "\n" + pad + "]"
    return json.dumps(value, ensure_ascii=False)


def load_catalog(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def empty_catalog():
    return {"sourceLanguage": SOURCE, "strings": {}, "version": "1.0"}


# ---------------------------------------------------------------------------- memory files

class MemoryError_(Exception):
    pass


def parse_memory(path):
    """Returns {key: {"zh": value, "en": value-or-None, "line": n}}."""
    entries = {}
    decoder = json.JSONDecoder()
    last = None
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            if raw.startswith((" ", "\t")):
                if last is None or not line.startswith("en"):
                    raise MemoryError_("an indented line must be `en = {…}` under an entry")
                rest = line[2:].lstrip()
                if not rest.startswith("="):
                    raise MemoryError_("expected `en = …`")
                value, end = decoder.raw_decode(rest[1:].lstrip())
                entries[last]["en"] = value
                continue
            key, end = decoder.raw_decode(line)
            if not isinstance(key, str):
                raise MemoryError_("the key must be a JSON string")
            rest = line[end:].lstrip()
            if not rest.startswith("="):
                raise MemoryError_("expected `\"key\" = value`")
            rest = rest[1:].lstrip()
            value, end = decoder.raw_decode(rest)
            trailing = rest[end:].strip()
            if trailing and not trailing.startswith("#"):
                raise MemoryError_(f"unexpected text after the value: {trailing!r}")
            if key in entries:
                raise MemoryError_(f"duplicate key {key!r}")
            entries[key] = {"zh": value, "en": None, "line": number}
            last = key
        except (ValueError, MemoryError_) as error:
            raise SystemExit(f"{path.relative_to(ROOT)}:{number}: {error}")
    return entries


def memory_line(key, entry=None):
    zh = entry["zh"] if entry else ""
    text = json.dumps(key, ensure_ascii=False) + " = " + json.dumps(zh, ensure_ascii=False)
    if entry and entry.get("en") is not None:
        text += "\n  en = " + json.dumps(entry["en"], ensure_ascii=False)
    return text


# ---------------------------------------------------------------------------- placeholders

def placeholders(text):
    """{index: conversion} for printf specifiers, plus the set of ${name} tokens."""
    found = {}
    sequential = 0
    for match in SPECIFIER.finditer(text):
        conv = match.group("conv")
        if conv == "%":
            continue
        if match.group("pos"):
            index = int(match.group("pos"))
        else:
            sequential += 1
            index = sequential
        kind = {"i": "d", "D": "d", "U": "u", "O": "o", "F": "f", "S": "@", "s": "@", "C": "c"}.get(conv, conv)
        kind = (match.group("len") or "").replace("q", "ll").replace("l", "l") + kind
        if kind in ("ld", "lld", "qd"):
            kind = "lld"
        found[index] = kind
    return found, set(m.group("name") for m in TOKEN.finditer(text))


def same_placeholders(source, translation, allow_missing=False):
    src, src_tokens = placeholders(source)
    dst, dst_tokens = placeholders(translation)
    if allow_missing:
        return all(src.get(i) == k for i, k in dst.items()) and dst_tokens <= src_tokens
    return src == dst and src_tokens == dst_tokens


# ---------------------------------------------------------------------------- collect

def run(cmd, **kwargs):
    return subprocess.run(cmd, check=True, **kwargs)


def build():
    """A Release build only for its .stringsdata (own derived data, so Debug builds stay warm)."""
    run(["xcodegen", "generate", "--quiet"], cwd=ROOT)
    result = subprocess.run(["xcodebuild", "-project", "Rolltop.xcodeproj", "-scheme", "Rolltop", "-configuration", "Release",
                             "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(DD), "build", "-quiet"],
                            cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout[-6000:] + result.stderr[-6000:])
        raise SystemExit("the Release build failed")
    STAMP.touch()


def current_stringsdata():
    """The .stringsdata of files that are still sources of the Rolltop target, plus App Shortcuts."""
    file_list = OBJECTS / "Rolltop.SwiftFileList"
    if not file_list.exists():
        raise SystemExit(f"no Release build at {DD.relative_to(ROOT)}; run with --build")
    sources = {pathlib.Path(line.strip()).stem for line in file_list.read_text().splitlines() if line.strip()}
    files = []
    for path in sorted(OBJECTS.glob("*.stringsdata")):
        if path.stem in sources or path.stem == "ExtractedAppShortcutsMetadata":
            files.append(path)
    missing = [s for s in sources if not (OBJECTS / f"{s}.stringsdata").exists()]
    if missing:
        raise SystemExit(f"stringsdata missing for {', '.join(sorted(missing)[:5])}…; run with --build")
    return files


def stale_sources():
    """Swift files changed or added since the last Release build (their strings are not in it).
    The compiler rewrites a .stringsdata (and an object file) only when its content changes,
    so the time of the last successful --build counts too."""
    listed = {pathlib.Path(line.strip()).resolve() for line in (OBJECTS / "Rolltop.SwiftFileList").read_text().splitlines()
              if line.strip()}
    stale = []
    for path in sorted((ROOT / "Rolltop").rglob("*.swift")):
        data, obj = OBJECTS / f"{path.stem}.stringsdata", OBJECTS / f"{path.stem}.o"
        compiled = max((f.stat().st_mtime for f in (data, obj, STAMP) if f.exists()), default=0)
        if path.resolve() not in listed or not data.exists() or path.stat().st_mtime > compiled:
            stale.append(path.relative_to(ROOT))
    return stale


def tables_used(stringsdata):
    """{table: {key: [source files]}}"""
    tables = defaultdict(lambda: defaultdict(list))
    for path in stringsdata:
        data = json.loads(path.read_text(encoding="utf-8"))
        for table, entries in data["tables"].items():
            for entry in entries:
                tables[table][entry["key"]].append(pathlib.Path(data["source"]))
    return tables


def catalogs():
    found = {}
    for path in sorted((ROOT / "Rolltop").rglob("*.xcstrings")):
        if path == INFO_PLIST_CATALOG:
            continue
        if path.stem in found:
            raise SystemExit(f"two catalogs for table {path.stem}: {found[path.stem]} and {path}")
        found[path.stem] = path
    return found


def info_plist_strings():
    with open(INFO_PLIST, "rb") as f:
        plist = plistlib.load(f)
    return {key: value for key, value in plist.items()
            if INFO_PLIST_KEY.match(key) and isinstance(value, str) and value}


# ---------------------------------------------------------------------------- merge + translate

def source_forms(key, entry):
    """The English text(s) a key shows: {"": text} or {category: text} for plural keys."""
    en = entry.get("localizations", {}).get(SOURCE, {})
    plural = en.get("variations", {}).get("plural")
    if plural:
        return {cat: v["stringUnit"]["value"] for cat, v in plural.items()}
    if "stringSet" in en:
        return {f"[{i}]": v for i, v in enumerate(en["stringSet"]["values"])}
    if "stringUnit" in en:
        return {"": en["stringUnit"]["value"]}
    return {"": key}


def apply_memory(table, catalog, memory, problems):
    """Writes en plural forms and zh-Hans from memory into a synced catalog."""
    strings = catalog["strings"]
    used = set()
    for key in list(strings):
        entry = strings[key]
        if entry.get("extractionState") == "stale":
            del strings[key]
            continue
        localizations = entry.setdefault("localizations", {})
        localizations.pop(TARGET, None)
        tm = memory.get(key)
        if tm is None:
            problems["untranslated"].append((table, key))
            if not localizations:
                entry.pop("localizations")
            continue
        used.add(key)
        en_override, zh = tm["en"], tm["zh"]
        if en_override is not None:
            if not (isinstance(en_override, dict) and set(en_override) == PLURAL_CATEGORIES[SOURCE]):
                problems["plural"].append((table, key, "en = {…} needs exactly the keys one and other"))
                continue
            localizations[SOURCE] = {"variations": {"plural": {
                cat: {"stringUnit": {"state": "translated", "value": text}}
                for cat, text in en_override.items()}}}
        source = source_forms(key, entry)
        if isinstance(zh, list):
            if not all(isinstance(v, str) and v for v in zh) or not zh:
                problems["mismatch"].append((table, key, "phrase list must hold non-empty strings"))
                continue
            for phrase in zh:
                if TOKEN.findall(phrase) != ["applicationName"] and "${applicationName}" not in phrase:
                    problems["mismatch"].append((table, key, f"phrase without ${{applicationName}}: {phrase}"))
            localizations[TARGET] = {"stringSet": {"state": "translated", "values": zh}}
            continue
        if not isinstance(zh, str) or not zh:
            problems["untranslated"].append((table, key))
            continue
        reference = source.get("other", source.get("", key))
        if not same_placeholders(reference, zh):
            problems["mismatch"].append((table, key, zh))
        for category, text in source.items():
            if not same_placeholders(reference, text, allow_missing=(category == "one")):
                problems["mismatch"].append((table, key, f"en {category}: {text}"))
        if set(source) - {""} and set(source) != PLURAL_CATEGORIES[SOURCE]:
            problems["plural"].append((table, key, f"en categories {sorted(source)}"))
        if "other" in source:
            localizations[TARGET] = {"variations": {"plural": {
                "other": {"stringUnit": {"state": "translated", "value": zh}}}}}
        else:
            localizations[TARGET] = {"stringUnit": {"state": "translated", "value": zh}}
    return used


def info_plist_catalog(memory, problems, existing):
    catalog = empty_catalog()
    used = set()
    for key, value in sorted(info_plist_strings().items()):
        entry = {"comment": INFO_PLIST_COMMENTS.get(key, f"Privacy - {key}"), "extractionState": "extracted_with_value",
                 "localizations": {SOURCE: {"stringUnit": {"state": "new", "value": value}}}}
        old = existing.get("strings", {}).get(key, {})
        if old.get("shouldTranslate") is False:
            entry["shouldTranslate"] = False
        tm = memory.get(key)
        if tm is None or not isinstance(tm["zh"], str) or not tm["zh"]:
            problems["untranslated"].append(("InfoPlist", key))
        else:
            used.add(key)
            if not same_placeholders(value, tm["zh"]):
                problems["mismatch"].append(("InfoPlist", key, tm["zh"]))
            entry["localizations"][TARGET] = {"stringUnit": {"state": "translated", "value": tm["zh"]}}
        catalog["strings"][key] = entry
    return catalog, used


# ---------------------------------------------------------------------------- report

# House style for the English source (DESIGN.md, US English).
BRITISH = re.compile(r"\b(colour|centre|licence|neighbour|behaviour|favourite|organis|recognis|customis|"
                     r"minimis|maximis|initialis|synchronis|analys(e|ed|ing)\b|catalogue|dialogue|cancelled|cancelling|"
                     r"greyed|grey\b|acknowledgement|travell|labelled|labelling|modell|programme|whilst|amongst)", re.I)
STYLE = [
    (re.compile(r"[A-Za-z]'[A-Za-z]"), "straight apostrophe (use ’)"),
    (BRITISH, "British spelling"),
    (re.compile(r"!(?!=)"), "exclamation mark"),
    (re.compile(r"\b(please|simply|just)\b", re.I), "please/simply/just"),
]


def english_style(table, key, catalog_entry):
    """Style problems in the English a key shows (the key and its plural forms)."""
    found = []
    for text in {key, *source_forms(key, catalog_entry).values()}:
        for pattern, what in STYLE:
            if pattern.search(text):
                found.append((table, key, what))
    return sorted(set(found))


def normalized(text):
    """What two keys share when they differ only in quote style, hyphenation, spacing or a final period."""
    text = text.replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"')
    text = re.sub(r"[\s\-\u2011]+", " ", text).strip()
    return text[:-1] if text.endswith(".") and not text.endswith("..") else text


def near_duplicates(all_keys):
    """Groups of keys that should probably be one string. Case and ellipses are not compared
    (Title Case commands and sentence-case labels, “Edit…” and “Edit”, are different strings);
    a final period only counts within one table (a fragment and a sentence in two features)."""
    groups = defaultdict(set)
    for table, key in all_keys:
        groups[normalized(key)].add((table, key))
    result = []
    for members in groups.values():
        if len({key for _, key in members}) < 2:
            continue
        stripped = {(t, k.rstrip(".")) for t, k in members}
        if len({k for _, k in stripped}) == 1 and len({t for t, _ in members}) == len(members):
            continue
        result.append(sorted(members))
    return sorted(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--build", action="store_true", help="run a Release build first")
    parser.add_argument("--check", action="store_true", help="write nothing; exit 1 when anything is out of date")
    parser.add_argument("--stubs", action="store_true", help="append untranslated keys to the memory files")
    parser.add_argument("--quiet", action="store_true", help="print only problems and the summary")
    args = parser.parse_args()

    if args.build:
        build()
    stringsdata = current_stringsdata()
    if not args.build:
        stale = stale_sources()
        if stale:
            raise SystemExit(f"the last Release build is older than {', '.join(map(str, stale[:3]))}"
                             f"{' and others' if len(stale) > 3 else ''}; run with --build")
    used_tables = tables_used(stringsdata)
    existing = catalogs()

    problems = defaultdict(list)
    for table, keys in used_tables.items():
        if table not in existing:
            # A table without a catalog gets one next to the code that uses it.
            dirs = sorted({p.parent for paths in keys.values() for p in paths})
            folder = dirs[0] if len(dirs) == 1 else ROOT / "Rolltop" / "Resources"
            existing[table] = folder / f"{table}.xcstrings"
            problems["new catalog"].append((table, str(existing[table].relative_to(ROOT))))

    work = pathlib.Path(tempfile.mkdtemp(prefix="rolltop-l10n-"))
    try:
        copies = {}
        for table, path in existing.items():
            copy = work / f"{table}.xcstrings"
            if path.exists():
                shutil.copyfile(path, copy)
            else:
                copy.write_text(serialize(empty_catalog()), encoding="utf-8")
            copies[table] = copy
        data_dir = work / "stringsdata"
        data_dir.mkdir()
        for path in stringsdata:
            shutil.copyfile(path, data_dir / path.name)
        run(["xcrun", "xcstringstool", "sync", *map(str, copies.values()),
             "--stringsdata", *map(str, sorted(data_dir.glob("*.stringsdata")))])

        results = {}
        summary = []
        all_keys = []
        unused_memory = []
        for table in sorted(copies):
            catalog = load_catalog(copies[table])
            tm_path = TM_DIR / f"{table}.tm"
            memory = parse_memory(tm_path) if tm_path.exists() else {}
            used = apply_memory(table, catalog, memory, problems)
            if not catalog["strings"] and table not in used_tables:
                problems["empty catalog"].append((table, str(existing[table].relative_to(ROOT))))
            results[existing[table]] = catalog
            translated = sum(1 for e in catalog["strings"].values() if TARGET in e.get("localizations", {}))
            summary.append((table, len(catalog["strings"]), translated))
            all_keys += [(table, k) for k in catalog["strings"]]
            for k, entry in catalog["strings"].items():
                problems["style"] += english_style(table, k, entry)
            unused_memory += [(table, k) for k in memory if k not in catalog["strings"]]
            if args.stubs:
                missing = [k for k in catalog["strings"] if k not in memory]
                if missing:
                    with open(tm_path, "a", encoding="utf-8") as f:
                        if tm_path.stat().st_size if tm_path.exists() else 0:
                            f.write("\n")
                        f.write("# Untranslated (added by --stubs)\n")
                        for k in sorted(missing):
                            f.write(memory_line(k) + "\n")

        tm_path = TM_DIR / "InfoPlist.tm"
        memory = parse_memory(tm_path) if tm_path.exists() else {}
        old = load_catalog(INFO_PLIST_CATALOG) if INFO_PLIST_CATALOG.exists() else {}
        catalog, used = info_plist_catalog(memory, problems, old)
        results[INFO_PLIST_CATALOG] = catalog
        summary.append(("InfoPlist", len(catalog["strings"]), len(used)))
        unused_memory += [("InfoPlist", k) for k in memory if k not in catalog["strings"]]
        if args.stubs:
            missing = [k for k in catalog["strings"] if k not in memory]
            if missing:
                with open(tm_path, "a", encoding="utf-8") as f:
                    for k in missing:
                        f.write(memory_line(k) + "\n")

        changed = []
        for path, catalog in results.items():
            text = serialize(catalog)
            old_text = path.read_text(encoding="utf-8") if path.exists() else None
            if text != old_text:
                changed.append(path)
                if not args.check:
                    path.write_text(text, encoding="utf-8")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    # Report.
    if not args.quiet:
        print(f"{'table':<16}{'strings':>8}{'zh-Hans':>9}")
        for table, total, translated in summary:
            print(f"{table:<16}{total:>8}{translated:>9}")
        print(f"{'total':<16}{sum(t for _, t, _ in summary):>8}{sum(t for _, _, t in summary):>9}")
    for kind in ("new catalog", "empty catalog"):
        for table, path in problems[kind]:
            print(f"{kind}: {table} -> {path}")
    for table, key in problems["untranslated"]:
        print(f"untranslated: [{table}] {json.dumps(key, ensure_ascii=False)}")
    for table, key, detail in problems["mismatch"]:
        print(f"placeholders differ: [{table}] {json.dumps(key, ensure_ascii=False)} -> {detail}")
    for table, key, detail in problems["plural"]:
        print(f"plural categories: [{table}] {json.dumps(key, ensure_ascii=False)}: {detail}")
    for table, key, detail in problems["style"]:
        print(f"English style: [{table}] {json.dumps(key, ensure_ascii=False)}: {detail}")
    for table, key in unused_memory:
        print(f"memory entry not used by the code: [{table}] {json.dumps(key, ensure_ascii=False)}")
    for group in near_duplicates(all_keys):
        print("near-duplicates: " + " | ".join(f"[{t}] {json.dumps(k, ensure_ascii=False)}" for t, k in group))
    for path in changed:
        print(("out of date: " if args.check else "wrote ") + str(path.relative_to(ROOT)))
    print(f"untranslated {len(problems['untranslated'])}, placeholder mismatches {len(problems['mismatch'])}, "
          f"plural problems {len(problems['plural'])}, English style {len(problems['style'])}, "
          f"unused memory {len(unused_memory)}")
    failed = problems["untranslated"] or problems["mismatch"] or problems["plural"] or problems["style"]
    if args.check and (changed or failed or unused_memory):
        return 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
