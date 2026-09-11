# -*- coding: utf-8 -*-
import re, os
BASE = r"d:\Program Files\XianYu-Music\XianYu-Music-Mobile\lib"

def extract_tr(path):
    try:
        txt = open(path, encoding="utf-8").read()
    except Exception:
        return []
    seen = set()
    out = []
    for m in re.finditer(r"tr\(\s*['\"]([^'\"]{1,22})['\"]", txt):
        w = m.group(1)
        if w and not w.isascii() and w not in seen:
            seen.add(w)
            out.append(w)
    return out

files = [
    r"pages\player\player_page.dart",
    r"pages\plugin\plugin_page.dart",
    r"src\player\cast_provider.dart",
    r"pages\tools\qmc_decrypt_page.dart",
    r"pages\remote\remote_library_page.dart",
    r"pages\recognize\recognize_page.dart",
    r"src\widgets\floating_search_bar.dart",
]
for f in files:
    p = os.path.join(BASE, f)
    print("="*8, f, "="*8)
    for w in extract_tr(p):
        print("  ", w)