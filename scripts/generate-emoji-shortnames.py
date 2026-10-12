#!/usr/bin/env python3
"""Regenerates Sources/RocketNative/EmojiShortnames.swift from the React Native
client's emojibase-derived tables, so all clients agree on shortcodes.

    scripts/generate-emoji-shortnames.py [ref]   # ref defaults to develop
"""
import json, re, sys, urllib.request

REPO = 'https://raw.githubusercontent.com/RocketChat/Rocket.Chat.ReactNative'
OUT = 'Sources/RocketNative/EmojiShortnames.swift'

def fetch(ref, path):
    with urllib.request.urlopen(f'{REPO}/{ref}/{path}') as r:
        return r.read().decode('utf-8')

ref = sys.argv[1] if len(sys.argv) > 1 else 'develop'
lines = fetch(ref, 'app/lib/constants/emojis/data.ts').split('\n')
legacy = json.loads(fetch(ref, 'app/lib/constants/emojis/legacyShortnames.json'))
start = next(i for i,l in enumerate(lines) if l.startswith('export const shortnameToUnicodeMap'))
pairs = {}
pat = re.compile(r"""^\s*(['"])(:[^'"]+:)\1\s*:\s*(['"])(.+)\3,?\s*$""")
for l in lines[start+1:]:
    if l.startswith('};'): break
    m = pat.match(l)
    if not m: raise SystemExit('unparsed: ' + l)
    pairs[m.group(2)[1:-1]] = json.loads('"' + m.group(4).replace('\\\'', "'") + '"')
generated = len(pairs)
for k, v in legacy.items():
    pairs.setdefault(k.strip(':'), v)
for k, v in pairs.items():
    assert '\t' not in k + v and '\n' not in k + v and '"""' not in v and '\\' not in k + v
body = '\n'.join(f'{k}\t{v}' for k, v in pairs.items())
open(OUT, 'w', encoding='utf-8').write(f'''// Generated from Rocket.Chat.ReactNative (MIT): app/lib/constants/emojis/data.ts
// (`shortnameToUnicodeMap`, built from emojibase with joypixels names first,
// matching the web client) plus legacyShortnames.json. Do not edit by hand.
// {generated} generated + {len(pairs) - generated} legacy shortnames.

/// One `shortname<TAB>unicode` pair per line, parsed lazily by `EmojiMap`.
/// A string literal compiles far faster than a dictionary literal this size.
let emojiShortnameTable = """
{body}
"""
''')
print(generated, len(pairs))
