#!/usr/bin/env python3
"""Maintain OpenDuckFrame's English-first String Catalog.

The authoritative locale list is AppLanguage.supported in
Apps/Mac/UI/Localization.swift. The catalog, language menu, and release gate
all parse that one list.

Commands:
  status          Show completion for each supported locale.
  check [--full]  Validate references, locale set, and format placeholders.
                  --full additionally requires every locale for every key.
  export <dir>    Write missing keys to <dir>/<locale>.json, with English and
                  Simplified Chinese reference text.
  merge <dir>     Merge translated {key: value} locale JSON files.
"""

from __future__ import annotations

import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Apps" / "Mac" / "Resources" / "Localizable.xcstrings"
SWIFT_SOURCE = ROOT / "Apps" / "Mac" / "UI" / "Localization.swift"
SOURCE_LANG = "en"
REFERENCE_LANG = "zh-Hans"
SOURCE_DIRS = (
    "Apps/Mac/UI",
    "Apps/Mac/QuickLook",
    "Apps/Mac/CaptionsHost",
    "Apps/Mac/CaptionsUI",
    "Modules/MediaCore",
    "Modules/VideoEnhancement",
    "Modules/Captions",
    "Platform/macOS",
)
SOURCE_EXTS = (".swift", ".mm", ".m", ".cpp", ".hpp", ".h")

FORMAT_SPEC = re.compile(
    r"%(?:(?P<position>[1-9][0-9]*)\$)?"
    r"(?P<format>[-+ #0]*[0-9*]*(?:\.[0-9*]+)?(?:hh|h|ll|l|q|z|t|L)?"
    r"[@dDuUxXoOfeEgGcCsSpaAF])"
)
SWIFT_REF = re.compile(
    r'\b(?:L|NSLocalizedString)\(\s*"((?:[^"\\]|\\.)+)"'
)
OBJC_REF = re.compile(r'NSLocalizedString\(\s*@"((?:[^"\\]|\\.)+)"')


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def specs(value: str) -> list[tuple[int, str]]:
    # Compare each argument's type/format independently of sentence order.
    return sorted((int(m['position'] or i), m['format'])
                  for i, m in enumerate(FORMAT_SPEC.finditer(value.replace("%%", "")), 1))


def supported_languages() -> list[str]:
    text = SWIFT_SOURCE.read_text(encoding="utf-8")
    match = re.search(
        r"supported:\s*\[String\]\s*=\s*\[(.*?)\]", text, re.DOTALL
    )
    if not match:
        fail("cannot parse AppLanguage.supported in Apps/Mac/UI/Localization.swift")
    languages = re.findall(r'"([A-Za-z-]+)"', match.group(1))
    if (
        len(languages) < 2
        or SOURCE_LANG not in languages
        or REFERENCE_LANG not in languages
        or len(languages) != len(set(languages))
    ):
        fail(f"invalid AppLanguage.supported list: {languages}")
    return languages


def load_catalog() -> dict:
    with CATALOG.open(encoding="utf-8") as handle:
        catalog = json.load(handle)
    if catalog.get("sourceLanguage") != SOURCE_LANG:
        fail(
            f"catalog sourceLanguage must be {SOURCE_LANG!r}, got "
            f"{catalog.get('sourceLanguage')!r}"
        )
    if not isinstance(catalog.get("strings"), dict):
        fail("catalog has no strings object")
    return catalog


def value_of(entry: dict, language: str) -> str | None:
    unit = entry.get("localizations", {}).get(language, {}).get("stringUnit", {})
    if unit.get("state") == "translated" and unit.get("value"):
        return unit["value"]
    return None


def missing_by_language(catalog: dict, languages: list[str]) -> dict[str, list[str]]:
    missing = {language: [] for language in languages}
    for key, entry in catalog["strings"].items():
        for language in languages:
            if value_of(entry, language) is None:
                missing[language].append(key)
    return missing


def referenced_keys() -> dict[str, set[str]]:
    references: dict[str, set[str]] = {}
    for directory in SOURCE_DIRS:
        source_root = ROOT / directory
        if not source_root.is_dir():
            continue
        for path in source_root.rglob("*"):
            if not path.is_file() or path.suffix not in SOURCE_EXTS:
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            for pattern in (SWIFT_REF, OBJC_REF):
                for match in pattern.finditer(text):
                    references.setdefault(match.group(1), set()).add(
                        path.relative_to(ROOT).as_posix()
                    )
    return references


def cmd_status() -> None:
    languages = supported_languages()
    catalog = load_catalog()
    missing = missing_by_language(catalog, languages)
    print(f"Catalog keys: {len(catalog['strings'])}")
    for language in languages:
        count = len(missing[language])
        status = "complete" if count == 0 else f"missing {count}"
        print(f"  {language:8s} {status}")
    incomplete = [language for language in languages if missing[language]]
    if incomplete:
        print(
            "Incomplete locales: "
            + " ".join(incomplete)
            + " (export, translate, merge, then check --full)"
        )


def cmd_check(full: bool) -> None:
    languages = supported_languages()
    catalog = load_catalog()
    strings = catalog["strings"]
    references = referenced_keys()
    failures: list[str] = []

    for key, sites in sorted(references.items()):
        if key not in strings:
            failures.append(f"missing key {key!r}, referenced by {sorted(sites)}")

    for key in sorted(strings):
        if key not in references:
            failures.append(f"unused catalog key {key!r}")

    for key, entry in strings.items():
        localizations = entry.get("localizations", {})
        for language in localizations:
            if language not in languages:
                failures.append(
                    f"key {key!r} contains unsupported locale {language!r}"
                )

        source = value_of(entry, SOURCE_LANG)
        reference = value_of(entry, REFERENCE_LANG)
        if source is None:
            failures.append(f"key {key!r} has no {SOURCE_LANG} translation")
            continue
        if reference is None:
            failures.append(f"key {key!r} has no {REFERENCE_LANG} translation")
        for language, localization in localizations.items():
            value = localization.get("stringUnit", {}).get("value", "")
            if value and specs(value) != specs(source):
                failures.append(
                    f"key {key!r} has mismatched {language} placeholders: "
                    f"{specs(value)} vs {specs(source)}"
                )

    if full:
        for language, keys in missing_by_language(catalog, languages).items():
            if keys:
                preview = keys[:5]
                suffix = "..." if len(keys) > 5 else ""
                failures.append(
                    f"locale {language} is missing {len(keys)} keys: "
                    f"{preview}{suffix}"
                )

    if failures:
        for message in failures:
            print(f"FAIL: {message}")
        raise SystemExit(1)
    scope = "all-locales" if full else "development"
    print(
        f"Localization check passed ({scope}; {len(strings)} keys x "
        f"{len(languages)} locales)."
    )


def cmd_export(output_directory: str) -> None:
    languages = supported_languages()
    catalog = load_catalog()
    output = Path(output_directory)
    output.mkdir(parents=True, exist_ok=True)
    wrote = 0
    for language, keys in missing_by_language(catalog, languages).items():
        if not keys:
            continue
        payload = {}
        for key in keys:
            entry = catalog["strings"][key]
            payload[key] = {
                SOURCE_LANG: value_of(entry, SOURCE_LANG) or "",
                REFERENCE_LANG: value_of(entry, REFERENCE_LANG) or "",
            }
        path = output / f"{language}.json"
        with path.open("w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        print(f"Exported {path}: {len(keys)} keys")
        wrote += 1
    if wrote == 0:
        print("All supported locales are complete; nothing was exported.")


def cmd_merge(input_directory: str) -> None:
    languages = supported_languages()
    catalog = load_catalog()
    strings = catalog["strings"]
    failures: list[str] = []
    merged = 0

    for path in sorted(Path(input_directory).glob("*.json")):
        language = path.stem
        if language not in languages:
            failures.append(f"{path.name}: unsupported locale {language!r}")
            continue
        with path.open(encoding="utf-8") as handle:
            translations = json.load(handle)
        if not isinstance(translations, dict):
            failures.append(f"{path.name}: expected a JSON object")
            continue
        for key, value in translations.items():
            entry = strings.get(key)
            if entry is None:
                failures.append(f"{language}: unknown key {key!r}")
                continue
            if not isinstance(value, str) or not value:
                failures.append(f"{language}: empty translation for {key!r}")
                continue
            source = value_of(entry, SOURCE_LANG)
            if source is not None and specs(value) != specs(source):
                failures.append(
                    f"{language}: placeholder mismatch for {key!r}: "
                    f"{specs(value)} vs {specs(source)}"
                )
                continue
            localizations = entry.setdefault("localizations", {})
            localizations[language] = {
                "stringUnit": {"state": "translated", "value": value}
            }
            merged += 1

    if failures:
        for message in failures:
            print(f"FAIL: {message}")
        raise SystemExit(1)

    for entry in strings.values():
        localizations = entry.get("localizations", {})
        entry["localizations"] = {
            key: localizations[key] for key in sorted(localizations)
        }
    with CATALOG.open("w", encoding="utf-8") as handle:
        json.dump(catalog, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(f"Merged {merged} translations into {CATALOG.relative_to(ROOT)}")


def main() -> None:
    arguments = sys.argv[1:]
    if not arguments:
        raise SystemExit(__doc__)
    command, rest = arguments[0], arguments[1:]
    if command == "status" and not rest:
        cmd_status()
    elif command == "check" and all(arg == "--full" for arg in rest):
        cmd_check(full="--full" in rest)
    elif command == "export" and len(rest) == 1:
        cmd_export(rest[0])
    elif command == "merge" and len(rest) == 1:
        cmd_merge(rest[0])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
