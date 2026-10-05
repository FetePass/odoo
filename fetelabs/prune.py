#!/usr/bin/env python3
"""Remove the Odoo modules FeteLABS does not ship.

Reads fetelabs/modules.json. Removes:
  * every l10n_* module not listed under "localisations",
  * every module listed under "remove",
  * every module that depends, directly or not, on one of those.

It refuses to run if the closure would remove a localisation we keep, so a
new upstream dependency can never take one out silently.

It also drops the data that names a removed module (the payment provider
records in payment/data/payment_provider_data.xml, which point at
base.module_<name> and would fail to load once that module is gone).

Run it again after every merge from upstream:

    python3 fetelabs/prune.py           # report what it would do
    python3 fetelabs/prune.py --apply   # git rm the modules, patch the data
    python3 fetelabs/prune.py --check   # exit 1 if anything is left to prune (CI)
"""
import ast
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ADDON_DIRS = [ROOT / 'addons', ROOT / 'odoo' / 'addons']
CONFIG = json.loads((ROOT / 'fetelabs' / 'modules.json').read_text())

# Data files that list modules by xml id. Each entry is a file and the
# element it removes when that element names a removed module.
DATA_PATCHES = [
    (ROOT / 'addons/payment/data/payment_provider_data.xml', 'record'),
]


def modules():
    found = {}
    for base in ADDON_DIRS:
        for manifest in sorted(base.glob('*/__manifest__.py')):
            data = ast.literal_eval(manifest.read_text())
            found[manifest.parent.name] = (manifest.parent, data.get('depends', []))
    return found


def plan(found):
    keep = set(CONFIG['localisations'])
    missing = sorted(keep - set(found))
    if missing:
        sys.exit(f'modules.json keeps localisations that are not in the tree: {missing}')
    removed = {}
    for name in found:
        if name.startswith('l10n_') and name not in keep:
            removed[name] = 'localisation for a country FeteLABS does not serve'
    for name, why in CONFIG['remove'].items():
        if name in found:
            removed[name] = why
    changed = True
    while changed:
        changed = False
        for name, (_, depends) in found.items():
            if name in removed:
                continue
            gone = [d for d in depends if d in removed]
            if gone:
                removed[name] = f'depends on {", ".join(gone)}'
                changed = True
    hit = sorted(keep & set(removed))
    if hit:
        sys.exit(f'refusing: pruning would remove kept localisations {hit}: '
                 + '; '.join(f'{m} ({removed[m]})' for m in hit))
    return removed


def element_blocks(text, tag):
    pattern = re.compile(rf'\n?[ \t]*<{tag}\b[^>]*>.*?</{tag}>[ \t]*', re.S)
    return list(pattern.finditer(text))


def data_patch(removed, apply):
    pending = []
    for path, tag in DATA_PATCHES:
        if not path.exists():
            continue
        text = path.read_text()
        drop = [
            m for m in element_blocks(text, tag)
            if any(f'base.module_{name}"' in m.group(0) for name in removed)
        ]
        if not drop:
            continue
        pending.append(f'{path.relative_to(ROOT)}: {len(drop)} <{tag}> naming removed modules')
        if apply:
            for m in reversed(drop):
                text = text[:m.start()] + text[m.end():]
            path.write_text(text)
    return pending


def main():
    apply = '--apply' in sys.argv
    check = '--check' in sys.argv
    found = modules()
    removed = plan(found)
    present = {n: r for n, r in removed.items() if found[n][0].exists()}
    patches = data_patch(removed, apply)

    for name in sorted(present):
        print(f'remove {name:45} {present[name]}')
    for line in patches:
        print(f'patch  {line}')
    print(f'{len(present)} of {len(found)} modules to remove, '
          f'{len(found) - len(present)} kept')

    if check:
        sys.exit(1 if present or patches else 0)
    if apply and present:
        paths = [str(found[n][0].relative_to(ROOT)) for n in sorted(present)]
        for i in range(0, len(paths), 200):
            subprocess.run(['git', 'rm', '-r', '-q', '--', *paths[i:i + 200]],
                           cwd=ROOT, check=True)


if __name__ == '__main__':
    main()
