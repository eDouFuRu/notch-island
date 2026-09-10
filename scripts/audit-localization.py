#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Read-only audit of app-owned English / Simplified Chinese strings.

Checks catalog coverage, format-argument parity, literal SwiftUI/L() keys,
third-party label constructors, and known runtime labels/errors. It deliberately does not translate media metadata, file
names, calendars, or other user content. This is a static audit, not a claim of
visual UI coverage. Swift interpolated strings require a separate runtime check.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "boringNotch"
LANGUAGES = ("en", "zh-Hans")
FORMAT = re.compile(r"%(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.\d+)?(?:ll|l|h|z)?[@diuoxXfFeEgGcs]")
UI_CALL = re.compile(r"(?:\b(?:L|Text|Label|Button|Picker|Toggle|Section|Stepper|TextField|LabeledContent|Link|DisclosureGroup|Recorder)|\.(?:help|accessibilityLabel|navigationTitle))\s*\(\s*")
THIRD_PARTY_TOGGLE = re.compile(r"\b(Defaults|LaunchAtLogin)\s*\.\s*Toggle\s*\(")


def swift_strings(source):
    """Read Swift quoted literals, including nested strings in interpolations.

    Returns masked source (same offsets), literals, and interpolation spans.
    Raw and multiline strings are skipped: the app uses them for scripts, not UI.
    """
    mask = list(source)
    literals = []
    interpolated = []

    def blank(start, end):
        for j in range(start, end):
            if mask[j] != "\n":
                mask[j] = " "

    def quoted(start):
        i = start + 1
        value = []
        dynamic = False
        while i < len(source):
            if source[i:i + 2] == "\\(":
                dynamic = True
                depth = 1
                i += 2
                while i < len(source) and depth:
                    if source[i] == '"':
                        i = quoted(i)
                        continue
                    depth += (source[i] == "(") - (source[i] == ")")
                    i += 1
                continue
            if source[i] == "\\" and i + 1 < len(source):
                value.append({"n": "\n", "r": "\r", "t": "\t", '"': '"', "\\": "\\"}.get(source[i + 1], source[i + 1]))
                i += 2
                continue
            if source[i] == '"':
                i += 1
                if dynamic:
                    interpolated.append((start, i))
                else:
                    literals.append((start, i, "".join(value)))
                blank(start, i)
                return i
            value.append(source[i])
            i += 1
        return i

    i = 0
    while i < len(source):
        if source[i:i + 2] == "//":
            end = source.find("\n", i)
            end = len(source) if end == -1 else end
            blank(i, end)
            i = end
        elif source[i:i + 2] == "/*":
            start, depth = i, 1
            i += 2
            while i < len(source) and depth:
                if source[i:i + 2] == "/*":
                    depth += 1
                    i += 2
                elif source[i:i + 2] == "*/":
                    depth -= 1
                    i += 2
                else:
                    i += 1
            blank(start, i)
        elif source[i:i + 3] == '"""':
            end = source.find('"""', i + 3)
            end = len(source) if end == -1 else end + 3
            blank(i, end)
            i = end
        elif source[i] == '"':
            i = quoted(i)
        else:
            i += 1
    return "".join(mask), sorted(literals), interpolated


def format_signature(value):
    # Ignore literal percent signs; translations may reorder positional args.
    result = []
    for token in FORMAT.findall(value.replace("%%", "")):
        result.append(re.sub(r"^%\d+\$", "%", token))
    return sorted(result)


def unlocalized_toggle_constructors(source, masked):
    """Defaults' StringProtocol overload produces verbatim Text even for a key.

    Require explicit localized label builders for these third-party toggles.
    LaunchAtLogin has localized overloads too, but its StringProtocol/default
    overload can bypass them. Comments and quoted example code are masked out.
    """
    for call in THIRD_PARTY_TOGGLE.finditer(masked):
        if call.group(1) == "Defaults" and re.match(r"\s*key\s*:", source[call.end():]):
            continue
        yield call.start(), call.group(1)


def verify_constructor_scanner():
    # Production regressions include an intentionally split Defaults.Toggle;
    # comments and quoted sample code must not be treated as live controls.
    cases = (
        ('Defaults.Toggle("Replace system HUD", key: .hudReplacement)', 1),
        ('Defaults\n .Toggle("Player tinting", key: .playerColorTinting)', 1),
        ('Defaults.Toggle(key: .hudReplacement) { Text("Replace system HUD") }', 0),
        ('LaunchAtLogin.Toggle("Launch at login")', 1),
        ('LaunchAtLogin.Toggle { Text("Launch at login") }', 0),
        ('// Defaults.Toggle("Comment", key: .ignored)\nText("Defaults.Toggle(\\"Example\\")")', 0),
    )
    for source, expected in cases:
        masked, _, _ = swift_strings(source)
        found = len(list(unlocalized_toggle_constructors(source, masked)))
        if found != expected:
            raise AssertionError(f"Constructor scanner: {source!r}: expected {expected}, got {found}")
    print(f"Constructor scanner: {len(cases)} regression cases passed")


def main():
    verify_constructor_scanner()
    errors = []
    catalog = json.loads((APP / "Localizable.xcstrings").read_text())
    for name in ("Localizable", "InfoPlist"):
        data = json.loads((APP / (name + ".xcstrings")).read_text())
        for key, entry in data["strings"].items():
            if not key:
                continue
            values = {}
            for language in LANGUAGES:
                unit = entry.get("localizations", {}).get(language, {}).get("stringUnit", {})
                if not unit.get("value") or unit.get("state") != "translated":
                    errors.append(f"{name}: missing/unreviewed {language}: {key!r}")
                values[language] = unit.get("value", "")
            if format_signature(values["en"]) != format_signature(values["zh-Hans"]):
                errors.append(f"{name}: format arguments differ: {key!r}")
            if name == "Localizable" and format_signature(key) != format_signature(values["en"]):
                errors.append(f"{name}: source/en format arguments differ: {key!r}")
        print(f"{name}: {len(data['strings'])} entries; checked en and zh-Hans")

    references = {}
    interpolation_count = 0
    for path in sorted(APP.rglob("*.swift")):
        source = path.read_text()
        masked, literals, interpolations = swift_strings(source)
        literal_at = {start: value for start, _, value in literals}

        for start, library in unlocalized_toggle_constructors(source, masked):
            location = f"{path.relative_to(ROOT)}:{source.count(chr(10), 0, start) + 1}"
            errors.append(f"Use an explicit Text label builder for {library}.Toggle: {location}")

        def record(start, value):
            if value:
                references.setdefault(value, []).append(f"{path.relative_to(ROOT)}:{source.count(chr(10), 0, start) + 1}")

        # Direct literal first arguments of SwiftUI views and localization calls.
        for call in UI_CALL.finditer(masked):
            # Masked strings are whitespace; recover first source nonspace.
            start = call.start() + source[call.start():].find("(") + 1
            while start < len(source) and source[start].isspace():
                start += 1
            if start in literal_at:
                record(start, literal_at[start])
            elif any(begin == start for begin, _ in interpolations):
                interpolation_count += 1

        # Runtime L(ternary) branches and native menu literals need explicit
        # coverage even though their values are not first literal arguments.
        for call in re.finditer(r"\bL\s*\(", masked):
            depth, end = 1, call.end()
            while end < len(masked) and depth:
                depth += (masked[end] == "(") - (masked[end] == ")")
                end += 1
            for start, _, value in literals:
                if call.end() <= start < end:
                    record(start, value)
        for start, _, value in literals:
            prefix = source[max(0, start - 100):start]
            if re.search(r"(?:NSMenuItem|addMenuItem)\(title:\s*$", prefix):
                record(start, value)
            if path.name == "OnboardingView.swift" and re.search(r"(?:title|description|privacyNote):\s*$", prefix):
                record(start, value)
            if path.name in ("MusicControllerSelectionView.swift", "MusicControlButton.swift") and re.search(r"return\s*$", prefix):
                if " " in value or value in ("Shuffle", "Previous", "Next", "Repeat", "Volume", "Favorite"):
                    record(start, value)
            if path.name == "InlineHUD.swift" and re.search(r"return\s*$", prefix):
                if value in ("Volume", "Brightness", "Keyboard backlight", "Microphone"):
                    record(start, value)
            # These managers publish localization keys; views localize them at
            # display time so changing language also updates an active error.
            if path.name in ("VolumeManager.swift", "BrightnessManager.swift", "MediaKeyInterceptor.swift"):
                if re.search(r"(?:\b(?:fail|failed)\(\s*|\b(?:lastError|errorMessage)\s*=\s*)$", prefix):
                    record(start, value)
                if path.name == "VolumeManager.swift" and re.search(r"\?\s*nil\s*:\s*$", prefix):
                    record(start, value)

    for key, locations in sorted(references.items()):
        if key not in catalog["strings"]:
            errors.append(f"Uncatalogued UI key {key!r}: {locations[0]}")
    print(f"Source scan: {len(references)} distinct static UI keys; {interpolation_count} interpolated UI expressions need runtime/visual review")
    print("Third-party toggle labels: checked explicit label builders, including multiline constructors")
    for error in errors:
        print("ERROR:", error)
    if errors:
        print(f"FAIL: {len(errors)} localization issues")
        return 1
    print("PASS: static keys and bilingual format arguments are covered; visual fit and dynamic user content are outside this audit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
