#!/usr/bin/env python3
"""Validate native String Catalogs. No dependencies beyond Python and macOS plutil."""
import argparse
import itertools
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
# Preserve ABI types and argument positions, while allowing translations to reorder/repeat them.
FORMAT = re.compile(r"%(?:([1-9][0-9]*)\$)?(?:(#@[^@]+@)|([-+ #0]*[0-9]*(?:\.[0-9]+)?)(hh|ll|h|l|L|z|j|t)?([@diuoxXfFeEgGaAcCsSp])|(%))")


def merge(left, right):
    result = dict(left)
    for position, kind in right.items():
        if position in result and result[position] != kind:
            raise ValueError(f"argument {position} has conflicting types: {result[position]} / {kind}")
        result[position] = kind
    return result


def formats(value, substitutions=None, start=1):
    """All possible index→type signatures, expanding catalog plural substitutions."""
    substitutions = substitutions or {}
    signatures = [{}]
    next_argument = start
    for match in FORMAT.finditer(value):
        position, reference, _, length, kind, percent = match.groups()
        if percent:
            continue
        index = int(position) if position else next_argument
        next_argument = index + 1
        if reference:
            name = reference[2:-1]
            if name not in substitutions:
                raise ValueError(f"unknown substitution {name}")
            sub = substitutions[name]
            index = sub['argNum']
            additions = [merge({index: sub['formatSpecifier']}, signature)
                         for signature in signatures_for(sub, substitutions, index)]
        else:
            additions = [{index: (length or '') + ('d' if kind == 'i' else kind)}]
        signatures = [merge(a, b) for a, b in itertools.product(signatures, additions)]
    return signatures


def signatures_for(node, substitutions=None, start=1):
    substitutions = node.get('substitutions', substitutions or {})
    if 'stringUnit' in node:
        unit = node['stringUnit']
        if unit.get('state') != 'translated' or not unit.get('value', '').strip():
            raise ValueError('missing, empty, or unfinished translation')
        return formats(unit['value'], substitutions, start)
    if 'variations' in node:
        signatures = []
        for dimension, variants in node['variations'].items():
            if dimension == 'plural' and 'other' not in variants:
                raise ValueError('plural is missing the required other category')
            for variant in variants.values():
                signatures.extend(signatures_for(variant, substitutions, start))
        if signatures:
            return signatures
    raise ValueError('translation has no string unit or variants')


def project_languages():
    project = json.loads(subprocess.check_output([
        'plutil', '-convert', 'json', '-o', '-', str(ROOT / 'AhaKey Studio.xcodeproj/project.pbxproj')
    ]))
    settings = project['objects'][project['rootObject']]
    return set(settings['knownRegions']) - {'Base'}


def validate():
    languages = project_languages()
    errors = []
    app_keys = set()
    total = 0
    for path in sorted((ROOT / 'AhaKey Studio/Localization').glob('*.xcstrings')):
        catalog = json.loads(path.read_text())
        source = catalog['sourceLanguage']
        for key, entry in catalog['strings'].items():
            if entry.get('shouldTranslate') is False:
                continue
            total += 1
            location = f'{path.name}: {key}'
            localizations = entry.get('localizations', {})
            if set(localizations) != languages:
                errors.append(f'{location}: languages {sorted(localizations)} != project {sorted(languages)}')
            try:
                expected = signatures_for(localizations[source])[0]
                for language, node in localizations.items():
                    for actual in signatures_for(node):
                        if actual != expected:
                            errors.append(f'{location} [{language}]: argument types/positions {actual} != {expected}')
            except (ValueError, KeyError) as error:
                errors.append(f'{location}: {error}')
        if path.stem == 'Localizable':
            app_keys = set(catalog['strings'])
    # Explicit keys are used by both the app and the statically linked VibeBar.
    for directory in ['AhaKey Studio', 'Modules/VibeBar']:
        for path in (ROOT / directory).rglob('*.swift'):
            for key in re.findall(r'String\(localized:\s*"([^"\\]+)"', path.read_text()):
                if key not in app_keys:
                    errors.append(f'{path.relative_to(ROOT)}: missing catalog key {key}')
    if not app_keys:
        errors.append('Localizable.xcstrings is missing or empty')
    return languages, total, errors


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--languages', action='store_true', help='Print validated shipping languages for CI')
    args = parser.parse_args()
    languages, total, errors = validate()
    if errors:
        raise SystemExit('\n'.join(errors))
    print(' '.join(sorted(languages)) if args.languages else
          f'Validated {total} entries in {len(languages)} languages: {", ".join(sorted(languages))}.')
