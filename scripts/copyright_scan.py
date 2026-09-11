# -*- coding: utf-8 -*-
"""软著材料扫描：收集自研源代码文件清单，统计规模并排查敏感/第三方内容。"""
import os, re, sys

ROOT = r"d:\Program Files\XianYu-Music\XianYu-Music-Mobile"

# 排除目录：第三方/生成/vendored/构建
EXCLUDE_DIRS = {
    "third_party", "build", ".dart_tool", ".git", ".idea", ".trae",
    "poc_ohos", "ohos", "test", "node_modules", "tool", "docs",
    "releases", "scripts", "assets", "android", "ios", "windows",
    "linux", "macos", "web", "l10n", "rust", "integration_test",
}
# rust 内也排除纯生成文件
RUST_EXCLUDE = {"frb_generated.rs", "api.ts"}

SENSITIVE_PATTERNS = [
    (re.compile(r'https?://\S+', re.I), "URL"),
    (re.compile(r'(?i)(password|passwd|secret|token|api[_-]?key)\s*[:=]'), "凭据"),
    (re.compile(r'(?i)(BEGIN [A-Z ]*PRIVATE KEY|BEGIN RSA)'), "私钥"),
    (re.compile(r'(?i)(dskey|aes[_-]?key|encrypt.*key)'), "加密密钥"),
    (re.compile(r'10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+'), "内网IP"),
]

def walk(d, base_key):
    out = []
    for root, dirs, files in os.walk(d):
        dirs[:] = [x for x in dirs if x not in EXCLUDE_DIRS]
        for f in files:
            if f.endswith(".dart") or f.endswith(".rs"):
                fp = os.path.join(root, f)
                rel = os.path.relpath(fp, ROOT)
                if base_key == "rust" and f in RUST_EXCLUDE:
                    continue
                out.append(rel)
    return out

if __name__ == "__main__":
    dart_files = walk(ROOT, "dart")
    rust_base = os.path.join(ROOT, "rust", "src")
    rust_files = []
    for root, dirs, files in os.walk(rust_base):
        for f in files:
            if f.endswith(".rs") and f not in RUST_EXCLUDE:
                rust_files.append(os.path.relpath(os.path.join(root, f), ROOT))

    print(f"[Dart 自研文件] {len(dart_files)} 个")
    print(f"[Rust 自研文件] {len(rust_files)} 个")

    total_lines = 0
    dl = dr = sl = sr = 0
    for fp in dart_files:
        p = os.path.join(ROOT, fp)
        n = sum(1 for _ in open(p, encoding="utf-8", errors="ignore"))
        total_lines += n
    for fp in rust_files:
        p = os.path.join(ROOT, fp)
        n = sum(1 for _ in open(p, encoding="utf-8", errors="ignore"))
        total_lines += n
    print(f"[合计代码行] {total_lines} 行  ->  按每页50行约 {total_lines//50} 页")

    print("\n===== 敏感内容命中(仅提示，软著按需规避) =====")
    hits = []
    for fp in dart_files + rust_files:
        p = os.path.join(ROOT, fp)
        try:
            for i, line in enumerate(open(p, encoding="utf-8", errors="ignore"), 1):
                for pat, tag in SENSITIVE_PATTERNS:
                    if pat.search(line):
                        hits.append((fp, i, tag, line.strip()[:90]))
                        break
        except Exception:
            pass
    for h in hits[:60]:
        print(f"{h[0]}:{h[1]} [{h[2]}] {h[3]}")
    print(f"...共 {len(hits)} 处命中(含注释/文档性 URL)")

    # 顶级入口文件（用于源程序 PDF 首部，体现软件主流程）
    print("\n===== 建议源程序首部文件(主流程/Dart入口) =====")
    for f in ["lib/main.dart", "lib/app.dart", "lib/src/core/rust_init.dart",
              "lib/src/core/platform_caps.dart", "lib/src/player/player_provider.dart"]:
        p = os.path.join(ROOT, f)
        if os.path.exists(p):
            print(f"  {f}  ({os.path.getsize(p)} bytes)")