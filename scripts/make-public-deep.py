#!/usr/bin/env python3
"""
Make every member of every public/internal class/struct/enum in the
given file public. Run on the framework sources to widen the API.
"""
import re
import sys
import pathlib

if len(sys.argv) < 2:
    print("usage: make-public-deep.py <file> [<file>...]")
    sys.exit(1)

ACCESS = r'(public|private|internal|fileprivate|open|package)'
TYPE_KEYWORDS = r'(class|struct|enum|protocol|extension|final\s+class|actor)'
MEMBER_KEYWORDS = (
    r'(func|var|let|init|subscript|typealias|static\s+func|static\s+var|'
    r'static\s+let|class\s+func|class\s+var|public\s+static\s+func|'
    r'public\s+static\s+var)'
)


def ensure_public_declaration(src: str) -> str:
    """Add `public` to every type declaration and member declaration."""
    lines = src.split('\n')
    out = []
    in_multiline_comment = False
    for line in lines:
        stripped = line.lstrip()
        indent_len = len(line) - len(stripped)
        indent = line[:indent_len]

        # Track multi-line comments so we don't touch commented code.
        if in_multiline_comment:
            out.append(line)
            if '*/' in line:
                in_multiline_comment = False
            continue
        if stripped.startswith('/*'):
            in_multiline_comment = True
            out.append(line)
            continue

        # Skip comment-only lines.
        if stripped.startswith('//') or not stripped:
            out.append(line)
            continue

        # Top-level or nested: type declaration?
        m = re.match(rf'^({TYPE_KEYWORDS})\s+', stripped)
        if m and not re.search(rf'\b{ACCESS}\b', stripped[:80]):
            line = f"{indent}{m.group(1)} public{stripped[len(m.group(1)):]}"

        # Member declaration (function, var, let, init, etc.)
        m = re.match(rf'^({MEMBER_KEYWORDS})\s+', stripped)
        if m and not re.search(rf'\b{ACCESS}\b', stripped[:80]):
            line = f"{indent}{m.group(1).rstrip()}{stripped[len(m.group(1))-1:].replace(m.group(1).rstrip(), m.group(1).rstrip() + ' public ', 1)}"
            # Simpler: insert public after the keyword
            line = indent + m.group(1) + ' public ' + stripped[len(m.group(1)):].lstrip()

        # computed property getters/setters on multi-line decls are handled
        # implicitly because we add `public` on the var line.

        out.append(line)

    return '\n'.join(out)


for arg in sys.argv[1:]:
    p = pathlib.Path(arg)
    src = p.read_text()
    new = ensure_public_declaration(src)
    if new != src:
        p.write_text(new)
        print(f"updated: {p}")
