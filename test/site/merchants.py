#!/usr/bin/env python3
"""The PunchCard app embeds a copy of /merchants.json (so its start-up is synchronous).
This fails if the two drift, and if any registry address is not EIP-55 checksummed.

    python3 test/site/merchants.py            # check
    python3 test/site/merchants.py --sync     # rewrite the app's embedded copy from merchants.json
"""
import json, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REG = ROOT / 'merchants.json'
APP = ROOT / 'app' / 'index.html'
LINE = re.compile(r'^const PC_REGISTRY=(.*);$', re.M)

reg = json.loads(REG.read_text())
app = APP.read_text()
m = LINE.search(app)
if not m:
    sys.exit('✗ no PC_REGISTRY line in app/index.html')

if '--sync' in sys.argv:
    APP.write_text(app[:m.start(1)] + json.dumps(reg, separators=(',', ':')) + app[m.end(1):])
    print('✓ app/index.html now embeds merchants.json')
    sys.exit(0)

ok = True
if json.loads(m.group(1)) != reg:
    print('✗ app/index.html embeds a different registry than merchants.json — run with --sync'); ok = False
for a in sorted(set(re.findall(r'0x[0-9a-fA-F]{40}', REG.read_text()))):
    cs = subprocess.run(['cast', 'to-check-sum-address', a], capture_output=True, text=True).stdout.strip()
    if a != cs:
        print(f'✗ {a} is not checksummed (should be {cs})'); ok = False
slugs = [x['slug'] for x in reg['merchants']]
if len(slugs) != len(set(slugs)):
    print('✗ duplicate merchant slug'); ok = False
for x in reg['merchants']:
    for p in (x['page'], x['pos'], x['token']['logo']):
        f = ROOT / p.lstrip('/')
        if not (f.exists() or (f / 'index.html').exists()):
            print(f'✗ {x["slug"]}: {p} does not exist in the site'); ok = False
print('✓ registry and app agree; addresses checksummed; pages exist' if ok else '')
sys.exit(0 if ok else 1)
