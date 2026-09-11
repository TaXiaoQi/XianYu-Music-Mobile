# -*- coding: utf-8 -*-
"""软著配套文档：隐私政策 PDF 生成（内容复用官网 privacy.html）"""
import os
import re
from html import unescape
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import inch
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import Paragraph, SimpleDocTemplate
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

ROOT = "d:\\Program Files\\XianYu-Music"
SOFTWARE_NAME = "弦予音乐软件 V1.0.2"
COPYRIGHT_HOLDER = "李军奇"
HTML_SRC = os.path.join(ROOT, "XianYu-Music-Website", "privacy.html")
OUT = os.path.join(ROOT, "XianYu-Music-Mobile", "soft-copyright",
                   "弦予音乐软件V1.0.2-隐私政策.pdf")

pdfmetrics.registerFont(TTFont("CJK", r"C:\Windows\Fonts\msyh.ttc"))
pdfmetrics.registerFont(TTFont("CJKBold", r"C:\Windows\Fonts\msyhbd.ttc"))

title_style = ParagraphStyle("T", fontName="CJKBold", fontSize=20,
                             leading=30, alignment=TA_CENTER, spaceAfter=20)
h_style = ParagraphStyle("H", fontName="CJKBold", fontSize=13,
                         leading=20, spaceBefore=14, spaceAfter=6)
body_style = ParagraphStyle("B", fontName="CJK", fontSize=11,
                            leading=20, spaceAfter=4, alignment=TA_LEFT,
                            wordWrap="CJK")

PAGE_TOTAL = {"v": 0}


def parse_html():
    html = open(HTML_SRC, encoding="utf-8").read()
    m = re.search(r'<main class="policy">(.*?)</main>', html, re.S)
    block = m.group(1) if m else html
    tm = re.search(r'<h1[^>]*>(.*?)</h1>', block, re.S)
    title = strip_tags(tm.group(1)).strip() if tm else "隐私政策"
    um = re.search(r'<p class="policy__updated">(.*?)</p>', block, re.S)
    updated = strip_tags(um.group(1)).strip() if um else ""
    story = [Paragraph(f"{title}", title_style)]
    if updated:
        c = ParagraphStyle("u", parent=title_style, fontName="CJK", fontSize=10.5,
                           alignment=TA_CENTER, spaceAfter=18, textColor="grey")
        story.append(Paragraph(updated, c))
    token_re = re.compile(r'<h2[^>]*>.*?</h2>|<p[^>]*>.*?</p>|<ul>.*?</ul>', re.S)
    items = []  # (style, raw_text)
    for tok in token_re.findall(block):
        if tok.startswith("<h2"):
            items.append((h_style, strip_tags(tok)))
        elif tok.startswith("<ul"):
            lis = re.findall(r"<li>(.*?)</li>", tok, re.S)
            for li in lis:
                items.append((body_style, "•\u3000" + strip_tags(li)))
        elif tok.startswith("<p"):
            items.append((body_style, strip_tags(tok)))
    # 统一转义并按标点切分过长段落，避免单段超高
    for style, text in _wrap_long(items):
        story.append(Paragraph(escape_amp(text), style))
    return story


def escape_amp(s):
    return s.replace("&", "&amp;").replace("<", "&lt;")


def _wrap_long(paras):
    """把过长段落按标点/空格折为多行段落，避免 reportlab 单段超高"""
    out = []
    for style, text in paras:
        # 先按中文标点、空格切分，保持语义
        pieces = re.split(r'(?<=[。；，！？：；\s])', text)
        for piece in pieces:
            # 仍超长的片段（多为长 URL）再按固定长度强行切断
            while len(piece) > 60:
                out.append((style, piece[:60]))
                piece = piece[60:]
            out.append((style, piece))
    return out


def strip_tags(html_frag):
    # 移除标签但保留文本，处理常见实体
    plain = re.sub(r"<[^>]+>", "", html_frag)
    return unescape(plain).strip()


def add_header_footer(canvas, doc):
    canvas.saveState()
    width, height = A4
    canvas.setFont("CJK", 10.5)
    canvas.drawString(0.8 * inch, height - 0.5 * inch, COPYRIGHT_HOLDER)
    canvas.drawCentredString(width / 2, height - 0.5 * inch, SOFTWARE_NAME)
    canvas.drawRightString(width - 0.8 * inch, height - 0.5 * inch, str(doc.page))
    canvas.setStrokeColorRGB(0.75, 0.75, 0.75)
    canvas.setLineWidth(0.5)
    canvas.line(0.8 * inch, height - 0.62 * inch, width - 0.8 * inch, height - 0.62 * inch)
    canvas.setFont("CJK", 8.5)
    canvas.drawCentredString(width / 2, 0.45 * inch,
                             f"© 2026 {COPYRIGHT_HOLDER} · 第 {doc.page} 页 / 共 {PAGE_TOTAL['v']} 页")
    canvas.restoreState()


def main():
    class CountingDoc(SimpleDocTemplate):
        def afterFlowable(self, flowable):
            PAGE_TOTAL["v"] = self.page
            super().afterFlowable(flowable)

    cdoc = CountingDoc(OUT + ".tmp.pdf", pagesize=A4,
                       leftMargin=0.9 * inch, rightMargin=0.9 * inch,
                       topMargin=0.9 * inch, bottomMargin=0.8 * inch,
                       title=SOFTWARE_NAME, author=COPYRIGHT_HOLDER)
    cdoc.build(parse_html())
    total = PAGE_TOTAL["v"]
    os.remove(OUT + ".tmp.pdf")
    print(f"隐私政策总页数: {total}")

    PAGE_TOTAL["v"] = total
    doc = SimpleDocTemplate(OUT, pagesize=A4,
                            leftMargin=0.9 * inch, rightMargin=0.9 * inch,
                            topMargin=0.9 * inch, bottomMargin=0.8 * inch,
                            title=SOFTWARE_NAME, author=COPYRIGHT_HOLDER)
    doc.build(parse_html(), onFirstPage=add_header_footer,
              onLaterPages=add_header_footer)
    print("隐私政策 PDF 已生成:", OUT)


if __name__ == "__main__":
    main()