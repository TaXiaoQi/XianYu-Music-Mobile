# -*- coding: utf-8 -*-
"""
软著源代码PDF生成
- 中国版权保护中心规范：前30页 + 后30页，每页不少于50行，页眉标注软件全称+版本+页码
- 仅剔除明显第三方/生成代码，保留自研核心
"""
import os
import sys
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import inch
from fontTools.ttLib import TTFont

ROOT = r"d:\Program Files\XianYu-Music\XianYu-Music-Mobile"
SOFTWARE_NAME = "弦予音乐软件 V1.0.2"
COPYRIGHT_HOLDER = "李军奇"
FONTS = {
    "code": r"C:\Windows\Fonts\consola.ttf",
    "cjk": r"C:\Windows\Fonts\msyh.ttc"
}

# 文件排序：入口优先→核心→主要功能→Rust核心（非生成）→最后端。
# 确保入口在开头，底层核心在结尾，符合软著「呈现完整逻辑流程」要求
SORT_ORDER = [
    # 入口
    "lib/main.dart",
    "lib/app.dart",
    # 核心基座
    "lib/src/core/application_logger.dart",
    "lib/src/core/platform_caps.dart",
    "lib/src/core/rust_init.dart",
    "lib/src/core/settings.dart",
    "lib/src/core/db_path.dart",
    "lib/src/core/app_logger.dart",
    # 认证
    "lib/src/auth/auth_provider.dart",
    "lib/src/auth/account_api.dart",
    # 播放核心
    "lib/src/player/player_provider.dart",
    "lib/src/player/player_widget.dart",
    "lib/src/player/player_page.dart",
    "lib/src/player/cast_provider.dart",
    # 歌词
    "lib/src/lyrics/lyrics_reader.dart",
    "lib/src/lyrics/aligned_lyrics.dart",
    "lib/src/lyrics/lyrics_painter.dart",
    "lib/src/lyrics/floating_lyrics.dart",
    # 插件引擎
    "lib/src/plugin/plugin_engine.dart",
    "lib/src/plugin/plugin_store.dart",
    "lib/src/plugin/plugin_provider.dart",
    "lib/src/plugin/plugin_install.dart",
    # 界面主框架
    "lib/src/navigation/routes.dart",
    "lib/src/navigation/shell.dart",
    "lib/src/widgets/scaffold_background.dart",
    "lib/src/home/home_page.dart",
    "lib/src/library/local_library_page.dart",
    "lib/src/search/search_page.dart",
    "lib/src/playlist/playlist_detail_page.dart",
    # 下载/更新
    "lib/src/download/download_state.dart",
    "lib/src/download/download_task.dart",
    "lib/src/update/update_checker.dart",
    # 深链
    "lib/src/deeplink/deep_link_handler.dart",
    "lib/src/deeplink/import_open_plugin.dart",
    # 分享
    "lib/src/share/share_system.dart",
    "lib/src/sync/sync_state.dart",
    "lib/src/sync/sync_provider.dart",
]

EXCLUDE_EXACT = {
    "lib/src/rust/api.dart",
    "lib/src/rust/frb_generated.dart",
    "lib/src/rust/frb_generated.io.dart",
    "lib/src/rust/frb_generated.web.dart",
}
EXCLUDE_DIRS_EXACT = {"third_party", "l10n", "test"}
EXCLUDE_FILE_SUFFIX = (".g.dart", ".freezed.dart")
# 脱敏规则：替换 defaultAuthApiSecret 真实值为 ***
DESENSITIZE_MAP = {
    "const defaultAuthApiSecret = 'bf027fedb4d1b4f969c10495f12f17042bf0de02de128200';":
    "const defaultAuthApiSecret = '***';",
}

LINES_PER_PAGE = 50
MARGIN_TOP = 0.6 * inch
MARGIN_LEFT = 0.4 * inch
MARGIN_RIGHT = 0.3 * inch
LINE_HEIGHT = 0.15 * inch
FONT_SIZE = 8

def collect_lines():
    """收集已排序、脱敏、过滤后的全部源代码行"""
    lines = []
    collected = set()

    def add_file(rel_path):
        full = os.path.join(ROOT, rel_path.replace("/", os.sep))
        if not os.path.exists(full):
            print(f"[WARN] 文件不存在，跳过：{rel_path}")
            return
        try:
            with open(full, encoding="utf-8", errors="replace") as f:
                for ln in f:
                    line = ln.rstrip("\n\r")
                    # 脱敏
                    for old, new in DESENSITIZE_MAP.items():
                        if old in line:
                            line = line.replace(old, new)
                    lines.append(line)
            collected.add(rel_path)
            print(f"[OK] {rel_path}  -> {len(lines)} 行")
        except Exception as e:
            print(f"[ERR] 读取 {rel_path}: {e}")

    # 先加硬排序列表（保证入口在前）
    for p in SORT_ORDER:
        add_file(p)
    # 再加剩下的 dart 源文件，按目录顺序，跳过生成层/第三方
    for root, dirs, files in os.walk(os.path.join(ROOT, "lib")):
        rel_root = os.path.relpath(root, ROOT).replace(os.sep, "/")
        any_excluded = any(ed in rel_root.split("/") for ed in EXCLUDE_DIRS_EXACT)
        if any_excluded:
            continue
        for f in sorted(files):
            if not f.endswith(".dart"):
                continue
            if any(f.endswith(suf) for suf in EXCLUDE_FILE_SUFFIX):
                continue
            rel_path = f"{rel_root}/{f}".replace("//", "/").lstrip("/")
            if rel_path in EXCLUDE_EXACT or rel_path in collected:
                continue
            add_file(rel_path)
    # 再加 Rust 核心源文件（剔除 frb_generated），最后放结尾
    for root, dirs, files in os.walk(os.path.join(ROOT, "rust", "src")):
        rel_root = os.path.relpath(root, ROOT).replace(os.sep, "/")
        for f in sorted(files):
            if not f.endswith(".rs"):
                continue
            if f == "frb_generated.rs":
                continue
            rel_path = f"{rel_root}/{f}".replace("//", "/").lstrip("/")
            add_file(rel_path)
    print(f"\n[汇总] 总行数: {len(lines)}，可切分约 {len(lines)//LINES_PER_PAGE + 1} 页")
    return lines

def split_pages(all_lines):
    """切分成页，返回 pages: list[list[str]]"""
    pages = []
    p = []
    for line in all_lines:
        p.append(line)
        if len(p) >= LINES_PER_PAGE:
            pages.append(p)
            p = []
    if p:
        pages.append(p)
    print(f"切分完成：共 {len(pages)} 页")
    return pages

def draw_pdf(pages, out_path):
    """绘制 PDF，满足中国版权保护中心规范"""
    c = canvas.Canvas(out_path, pagesize=A4)
    width, height = A4
    # register fonts
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont
    pdfmetrics.registerFont(TTFont('Code', FONTS['code']))
    pdfmetrics.registerFont(TTFont('CJK', FONTS['cjk']))

    total_pages = len(pages)
    target_pages = 60
    # 取前 30 + 后 30
    if total_pages >= target_pages:
        pages = pages[:30] + pages[-30:]
    print(f"最终输出：{len(pages)} 页")

    current_page = 1
    for page_lines in pages:
        # 页眉
        c.setFont("CJK", 9)
        header_y = height - 0.3 * inch
        c.drawString(MARGIN_LEFT, header_y, COPYRIGHT_HOLDER)
        c.setFont("CJK", 9)
        c.drawCentredString(width/2, header_y, SOFTWARE_NAME)
        c.drawRightString(width - MARGIN_RIGHT, header_y, f"{current_page}")
        current_page += 1

        y = height - MARGIN_TOP
        for line in page_lines:
            y -= LINE_HEIGHT
            # 先尝试全 consola，不行就切分CJK换字体（reportlab 不混排，只能分段，凑合）
            if not line.strip():
                continue
            x = MARGIN_LEFT
            # 简单判断是否有中文，粗分渲染
            has_cjk = any(ord(c) > 127 for c in line)
            if has_cjk:
                c.setFont("CJK", FONT_SIZE)
            else:
                c.setFont("Code", FONT_SIZE)
            c.drawString(x, y, line.expandtabs(4))
        c.showPage()
    c.save()
    print(f"PDF 已保存到: {out_path}")

def main():
    all_lines = collect_lines()
    if not all_lines:
        print("没有收集到源代码")
        sys.exit(1)
    pages = split_pages(all_lines)
    out_dir = os.path.join(ROOT, "soft-copyright")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, f"弦予音乐软件V1.0.2-源代码.pdf")
    draw_pdf(pages, out_path)
    print(f"\n✅ 完成！输出文件：{out_path}")

if __name__ == "__main__":
    main()
