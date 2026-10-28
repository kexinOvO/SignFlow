#!/usr/bin/env python3
"""Redact verification command output; app task logging uses Swift LogRedactor."""
import re
import sys

def redact(text):
    text = re.sub(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "[已脱敏]", text)
    return re.sub(r"(?i)((?:password|token|secret)\s*[=:]\s*)[^\s,;]+", r"\1[已脱敏]", text)

if len(sys.argv) > 1:
    from pathlib import Path
    for name in sys.argv[1:]:
        path = Path(name)
        path.write_text(redact(path.read_text(errors="replace")))
else:
    for line in sys.stdin:
        print(redact(line), end="", flush=True)
