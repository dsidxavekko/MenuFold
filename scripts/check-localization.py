#!/usr/bin/env python3
"""Checks App/Localizable.xcstrings (no dependencies, works without Xcode).

  scripts/check-localization.py [--strict] [--no-swift] [catalog]

Errors (exit 1): a key without en/de/pl/fr/es in state "translated"; placeholders (%@, %lld, %d,
%1$@ ...) that differ from the key; incomplete plural variations (pl/uk: one/few/many/other,
fr/es/en/de: one/other). Warnings: stale keys (errors with --strict) and unlocalized string
literals in NSAlert / NSMenuItem calls under App/ (a simple heuristic; allowlist below).
The key "MenuFold" (the product name) is exempt from the translation check.
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGS = ["en", "de", "pl", "fr", "es", "it", "pt-BR", "ja", "zh-Hans", "tr"]
PLURALS = {
    "pl": {"one", "few", "many", "other"}, "uk": {"one", "few", "many", "other"},
    "it": {"one", "many", "other"}, "pt-BR": {"one", "many", "other"},
    "ja": {"other"}, "zh-Hans": {"other"},
}
DEFAULT_PLURALS = {"one", "other"}
EXEMPT_KEYS = {"MenuFold"}
PH = re.compile(r"%(?:\d+\$)?(?:l{0,2}|h{0,2}|z|q)?[@dDuUfFsScCxXoOeEgGaAp]")
# Literals that are fine as they are (no words to translate, or brand names).
LITERAL_ALLOW = {"MenuFold", "Sparkle"}


def placeholders(s):
    return sorted(re.sub(r"\d+\$", "", m) for m in PH.findall(s.replace("%%", "")))


def units(loc):
    """Yield (label, stringUnit, is_plural_form) for a language entry."""
    if "stringUnit" in loc:
        yield "", loc["stringUnit"], False
    for kind, forms in (loc.get("variations") or {}).items():
        for form, v in forms.items():
            if "stringUnit" in v:
                yield f"{kind}.{form}", v["stringUnit"], True


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv
    path = args[0] if args else os.path.join(ROOT, "App", "Localizable.xcstrings")
    with open(path, encoding="utf-8") as f:
        catalog = json.load(f)
    errors, warnings = [], []
    for key, entry in catalog["strings"].items():
        if entry.get("extractionState") == "stale":
            (errors if strict else warnings).append(f"stale key: {key!r}")
            continue
        if key in EXEMPT_KEYS:
            continue
        locs = entry.get("localizations", {})
        key_ph = placeholders(key)
        for lang in LANGS:
            loc = locs.get(lang)
            if not loc:
                errors.append(f"{key!r}: no {lang} translation")
                continue
            plural = (loc.get("variations") or {}).get("plural")
            if plural is not None:
                need = PLURALS.get(lang, DEFAULT_PLURALS)
                missing = need - set(plural)
                if missing:
                    errors.append(f"{key!r} [{lang}]: plural forms missing: {sorted(missing)}")
            for label, unit, is_plural in units(loc):
                where = f"{key!r} [{lang}{'.' + label if label else ''}]"
                if unit.get("state") != "translated":
                    errors.append(f"{where}: state is {unit.get('state')!r}, not 'translated'")
                value = unit.get("value", "")
                if not value.strip():
                    errors.append(f"{where}: empty value")
                    continue
                vph = placeholders(value)
                if is_plural:
                    # a plural form may drop the number ("one" -> "a day"), but not invent placeholders
                    bad = [p for p in vph if p not in key_ph]
                    if bad:
                        errors.append(f"{where}: unexpected placeholders {bad} (key has {key_ph})")
                elif vph != key_ph:
                    errors.append(f"{where}: placeholders {vph} differ from key's {key_ph}")
            if plural is None and "stringUnit" not in loc:
                errors.append(f"{key!r} [{lang}]: neither a stringUnit nor plural variations")

    if "--no-swift" not in sys.argv:
        warnings += unlocalized_literals()

    for w in warnings:
        print(f"::warning::{w}" if os.environ.get("GITHUB_ACTIONS") else f"warning: {w}")
    for e in errors:
        print(f"::error::{e}" if os.environ.get("GITHUB_ACTIONS") else f"error: {e}")
    print(f"{len(catalog['strings'])} keys, {len(errors)} errors, {len(warnings)} warnings")
    return 1 if errors else 0


# NSAlert / NSMenuItem texts travel as plain String, so a bare literal there never gets localized.
CALLS = re.compile(
    r"(addButton\(withTitle:|NSMenuItem\(title:|\.messageText\s*=|\.informativeText\s*=|\.title\s*=)\s*\"((?:[^\"\\]|\\.)*)\"")


def unlocalized_literals():
    out = []
    for base, _, files in os.walk(os.path.join(ROOT, "App")):
        for name in files:
            if not name.endswith(".swift"):
                continue
            p = os.path.join(base, name)
            with open(p, encoding="utf-8") as f:
                for n, line in enumerate(f, 1):
                    if "// l10n-ok" in line:
                        continue
                    for m in CALLS.finditer(line):
                        lit = m.group(2)
                        if not re.search(r"[A-Za-zА-Яа-яІіЇїЄєҐґ]", lit) or lit in LITERAL_ALLOW:
                            continue
                        rel = os.path.relpath(p, ROOT)
                        out.append(f"{rel}:{n}: unlocalized literal {lit!r} (use String(localized:), or add // l10n-ok)")
    return out


if __name__ == "__main__":
    sys.exit(main())
