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
    # 匹配类似 tr('中文') / tr("中文")
    for m in re.finditer(r"tr\(\s*['\"]([^'\"]{1,20})['\"]", txt):
        w = m.group(1)
        if w and not w.isascii() and w not in seen:
            seen.add(w)
            out.append(w)
    return out

files = [
    r"pages\mine\mine_page.dart",
    r"pages\home\home_page.dart",
    r"pages\settings\settings_page.dart",
    r"src\player\player_provider.dart",
]
for f in files:
    p = os.path.join(BASE, f)
    print("="*10, f, "="*10)
    for w in extract_tr(p):
        print("  ", w)