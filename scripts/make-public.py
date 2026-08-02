#!/usr/bin/env python3
"""
Add `public` to:
  - top-level: class, struct, enum, protocol, extension, actor, typealias
  - members at 4-space indent: func, init, subscript, deinit
  - members at 4-space indent: var/let that are type-annotated declarations

Conservative: never touches `let foo = ...` in a function body.
"""
import re
import sys
import pathlib

ACCESS = r'(public|private|internal|fileprivate|open|package)'
TOP_TYPE = r'(class|struct|enum|protocol|extension|actor|final\s+class|final\s+actor)'
MEMBER_FUNCS = r'(func|init|subscript|deinit|typealias|static\s+func|class\s+func|public\s+static\s+func|public\s+class\s+func)'
MEMBER_VARS_TYPED = r'(var|let|static\s+var|static\s+let|class\s+var|class\s+let)'


def has_access_modifier(stripped: str) -> bool:
    return bool(re.search(rf'\b{ACCESS}\b', stripped[:120]))


def add_public_before_keyword(stripped: str, indent: str, keyword_pat: str) -> str:
    m = re.match(rf'^({keyword_pat})\b', stripped)
    if not m:
        return indent + stripped
    if has_access_modifier(stripped):
        return indent + stripped
    return f"{indent}public {stripped}"


def process(src: str) -> str:
    out = []
    for line in src.split('\n'):
        stripped = line.lstrip()
        if not stripped or stripped.startswith('//') or stripped.startswith('/*') or stripped.startswith('*'):
            out.append(line)
            continue
        indent = line[:len(line) - len(stripped)]

        # Top level (no leading whitespace)
        if not line[0:1].isspace():
            line = add_public_before_keyword(stripped, indent, TOP_TYPE)
        # 4-space-indented members
        elif line.startswith('    ') and not line.startswith('        '):
            # Order matters: try func-like first (more specific)
            line = add_public_before_keyword(stripped, indent, MEMBER_FUNCS)
            stripped = line.lstrip()
            indent = line[:len(line) - len(stripped)]
            # For var/let, only if type-annotated: `var foo: T` or `let foo: T`
            if re.match(rf'^(public\s+)?({MEMBER_VARS_TYPED})\s+\w+\s*:', stripped):
                line = add_public_before_keyword(stripped, indent, MEMBER_VARS_TYPED)
        out.append(line)
    return '\n'.join(out)


if __name__ == '__main__':
    for arg in sys.argv[1:]:
        p = pathlib.Path(arg)
        src = p.read_text()
        new = process(src)
        if new != src:
            p.write_text(new)
            print(f"updated: {p}")
