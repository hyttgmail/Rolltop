#!/usr/bin/env python3 -I
"""Fails fast on name clashes between features (docs/CONTRACTS.md, "Naming").

    scripts/check-names.py            # exit 1 and one line per problem

Checks, over Rolltop/, RolltopTests/ and RolltopCore's public types:
  - top-level type names (struct/class/enum/protocol/actor/typealias, not private) are unique;
  - settings key names, service key names and notification names are unique;
  - a feature's settings keys start with `rolltop.<feature-id>.`;
  - a feature uses only its own string table (`table:` / `tableName:` = its directory name);
  - a feature never names a top-level type declared in another feature's directory
    (cross-feature contracts live in Rolltop/App/Contracts).
Command and pane ids are checked at run time by RolltopTests/Core/RegistryNamingTests.swift.
"""
import pathlib
import re
import sys
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent
FEATURES = ROOT / "Rolltop" / "Features"

TYPE_DECL = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?P<mods>(?:(?:public|internal|private|fileprivate|nonisolated|final|indirect|open)\s+)*)"
    r"(?:struct|class|enum|protocol|actor|typealias)\s+(?P<name>[A-Za-z_]\w*)",
    re.M)
SETTINGS_KEY = re.compile(r'SettingsKey<[^>]*(?:<[^>]*>)?[^>]*>\(\s*"(?P<name>[^"]+)"')
SERVICE_KEY = re.compile(r'static var \w+: Self \{\s*\.init\(\s*"(?P<name>[^"]+)"')
NOTIFICATION = re.compile(r'(?:Notification\.Name|NSNotification\.Name)\(\s*(?:rawValue:\s*)?"(?P<name>[^"]+)"')
TABLE = re.compile(r'(?:table|tableName):\s*"(?P<name>[^"]+)"')
COMMENT = re.compile(r"//.*?$|/\*.*?\*/", re.S | re.M)
STRING = re.compile(r'"(?:[^"\\\n]|\\.)*"')

# Feature directory name -> feature id (FeatureModule.id).
FEATURE_IDS = {}


def swift_files(*roots):
    for root in roots:
        yield from sorted(p for p in root.rglob("*.swift") if ".build" not in p.parts)


def strip(source):
    """Source without comments and string literals (for identifier references)."""
    return STRING.sub('""', COMMENT.sub("", source))


def feature_of(path):
    try:
        rel = path.relative_to(FEATURES)
    except ValueError:
        try:
            rel = path.relative_to(ROOT / "RolltopTests")
        except ValueError:
            return None
        name = rel.parts[0]
        return name if (FEATURES / name).is_dir() else None
    return rel.parts[0]


def main():
    problems = []
    for directory in sorted(p for p in FEATURES.iterdir() if p.is_dir()):
        for path in directory.glob("*Feature.swift"):
            match = re.search(r'static let id: FeatureID = "([^"]+)"', path.read_text())
            if match:
                FEATURE_IDS[directory.name] = match.group(1)

    types = defaultdict(list)
    feature_types = defaultdict(set)
    settings_keys = defaultdict(list)
    service_keys = defaultdict(list)
    notifications = defaultdict(list)
    sources = {}

    for path in swift_files(ROOT / "Rolltop", ROOT / "RolltopTests", ROOT / "Packages" / "RolltopCore" / "Sources"):
        # Doc comments carry examples (`static var clipboard: Self { .init("shelf.clipboard") … }`).
        text = re.sub(r"^\s*///.*$", "", path.read_text(), flags=re.M)
        rel = path.relative_to(ROOT)
        sources[path] = text
        in_core = "Packages" in path.parts
        for match in TYPE_DECL.finditer(text):
            mods = match.group("mods")
            if "private" in mods or "fileprivate" in mods:
                continue
            if in_core and "public" not in mods:
                continue
            types[match.group("name")].append(str(rel))
            feature = feature_of(path)
            if feature and "RolltopTests" not in path.parts:
                feature_types[feature].add(match.group("name"))
        if "RolltopTests" in path.parts:
            continue  # test suites use throwaway keys on their own defaults
        for match in SETTINGS_KEY.finditer(text):
            settings_keys[match.group("name")].append(str(rel))
            feature = feature_of(path)
            if feature:
                prefix = f"rolltop.{FEATURE_IDS.get(feature, '?')}."
                if not match.group("name").startswith(prefix):
                    problems.append(f"{rel}: settings key {match.group('name')} does not start with {prefix}")
        for match in SERVICE_KEY.finditer(text):
            service_keys[match.group("name")].append(str(rel))
        for match in NOTIFICATION.finditer(text):
            notifications[match.group("name")].append(str(rel))
        feature = feature_of(path)
        if feature:
            for match in TABLE.finditer(text):
                if match.group("name") != feature:
                    problems.append(f"{rel}: string table {match.group('name')} belongs to another feature (use \"{feature}\")")

    for label, table in (("type", types), ("settings key", settings_keys), ("service key", service_keys),
                         ("notification name", notifications)):
        for name, places in sorted(table.items()):
            if len(places) > 1:
                problems.append(f"duplicate {label} {name}: " + ", ".join(sorted(set(places))))

    owner_of = {}
    for feature, names in feature_types.items():
        for name in names:
            owner_of[name] = feature
    for path, text in sources.items():
        feature = feature_of(path)
        if not feature or "RolltopTests" in path.parts:
            continue
        code = strip(text)
        for name, owner in owner_of.items():
            if owner != feature and re.search(rf"\b{re.escape(name)}\b", code):
                problems.append(f"{path.relative_to(ROOT)}: uses {name} from feature {owner}; "
                                f"put shared contracts in Rolltop/App/Contracts")

    for line in problems:
        print(line)
    if problems:
        print(f"{len(problems)} naming problem(s)", file=sys.stderr)
        return 1
    print("names ok: %d types, %d settings keys, %d service keys" % (len(types), len(settings_keys), len(service_keys)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
