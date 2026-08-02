#!/usr/bin/env bash
# Adds `public` to top-level type and member declarations in the Sources/ tree.
# Run once when converting the module into a framework.

set -euo pipefail
cd "$(dirname "$0")/../Sources"

# Add public to top-level: class, struct, enum, protocol, extension, func
for f in $(find . -name "*.swift" -not -name "main.swift"); do
  python3 - "$f" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()

def add_public(match):
    keyword = match.group(1)
    # Don't add if already has an access modifier
    rest = match.group(2)
    if re.search(r'\b(public|private|internal|fileprivate|open|package)\b', rest[:60]):
        return match.group(0)
    return f"{keyword} public{rest}"

# Match top-level: class, struct, enum, protocol, extension (file-level), func, var, let
patterns = [
    r'(?m)^(class)\s+',
    r'(?m)^(struct)\s+',
    r'(?m)^(enum)\s+',
    r'(?m)^(protocol)\s+',
    r'(?m)^(extension)\s+',
    r'(?m)^(final\s+class)\s+',
]
# Also nested types via 1-3 indent levels
nested_patterns = [
    r'(?m)^( {2,6})(class)\s+',
    r'(?m)^( {2,6})(struct)\s+',
    r'(?m)^( {2,6})(enum)\s+',
]

for pat in patterns:
    src = re.sub(pat + r'(?=\w)', lambda m: f"{m.group(1)} public ", src)

for pat in nested_patterns:
    src = re.sub(pat + r'(?=\w)', lambda m: f"{m.group(1)}{m.group(2)} public ", src)

p.write_text(src)
PY
done

echo "Done."
