# -*- coding: utf-8 -*-
"""软著操作说明书 PDF 生成（reportlab SimpleDocTemplate + onPage 页眉页码）"""
import os
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import inch
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import Paragraph, SimpleDocTemplate
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

ROOT = r"d:\Program Files\XianYu-Music\XianYu-Music-Mobile"
SOFTWARE_NAME = "弦予音乐软件 V1.0.2"
COPYRIGHT_HOLDER = "李军奇"
CONTENT = os.path.join(ROOT, "soft-copyright", "操作说明书_内容.md")
OUT = os.path.join(ROOT, "soft-copyright", "弦予音乐软件V1.0.2-操作说明书.pdf")

FONTS = {
    "cjk": r"C:\Windows\Fonts\msyh.ttc",
    "cjk_bold": r"C:\Windows\Fonts\msyhbd.ttc",
}
pdfmetrics.registerFont(TTFont("CJK", FONTS["cjk"]))
pdfmetrics.registerFont(TTFont("CJKBold", FONTS["cjk_bold"]))

title_style = ParagraphStyle("T", fontName="CJKBold", fontSize=20,
                             leading=30, alignment=TA_CENTER, spaceAfter=20)
h1_style = ParagraphStyle("H1", fontName="CJKBold", fontSize=13,
                          leading=20, spaceBefore=14, spaceAfter=6)
body_style = ParagraphStyle("B", fontName="CJK", fontSize=11,
                            leading=20, spaceAfter=4, alignment=TA_LEFT)

PAGE_TOTAL = {"v": 0}

# 显式章节标题集合
CHAPTER_HEADS = {
    "一、", "二、", "三、", "四、", "五、", "六、", "七、", "八、",
    "九、", "十、", "十一、", "十二、", "十三、", "十四、", "十五、", "十六、",
}

def build_story():
    story = []
    with open(CONTENT, encoding="utf-8") as f:
        for raw in f:
            s = raw.rstrip("\n").strip()
            if not s:
                continue
            # 软件标题行
            if s.startswith("弦予音乐软件 V1.0.2 操作说明书"):
                story.append(Paragraph(s, title_style))
            elif any(s.startswith(h) for h in CHAPTER_HEADS):
                story.append(Paragraph(s.replace("\t", "\u00a0\u00a0\u00a0\u00a0"), h1_style))
            else:
                # 小节标题（数字. 开头）加粗显示
                if len(s) > 3 and s[0].isdigit() and s[1:2] in (".", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"):
                    st = ParagraphStyle("sub", parent=body_style, fontName="CJKBold", spaceBefore=6)
                    story.append(Paragraph(s, st))
                else:
                    story.append(Paragraph(s, body_style))
    return story

def add_page_header_footer(canvas, doc):
    canvas.saveState()
    width, height = A4
    # 页眉
    canvas.setFont("CJK", 10.5)
    canvas.drawString(0.8 * inch, height - 0.5 * inch, COPYRIGHT_HOLDER)
    canvas.drawCentredString(width / 2, height - 0.5 * inch, SOFTWARE_NAME)
    canvas.drawRightString(width - 0.8 * inch, height - 0.5 * inch, str(doc.page))
    # 页眉分隔线
    canvas.setStrokeColorRGB(0.75, 0.75, 0.75)
    canvas.setLineWidth(0.5)
    canvas.line(0.8 * inch, height - 0.62 * inch, width - 0.8 * inch, height - 0.62 * inch)
    # 页脚：版权与共几页
    canvas.setFont("CJK", 8.5)
    footer_text = f"© 2026 {COPYRIGHT_HOLDER} · 第 {doc.page} 页 / 共 {PAGE_TOTAL['v']} 页"
    canvas.drawCentredString(width / 2, 0.45 * inch, footer_text)
    canvas.setStrokeColorRGB(0.9, 0.9, 0.9)
    canvas.line(0.8 * inch, 0.6 * inch, width - 0.8 * inch, 0.6 * inch)
    canvas.restoreState()

def main():
    global PAGE_TOTAL
    # 第一遍：构建到临时路径，同时通过 afterFlowable 捕获总页数
    class CountingDoc(SimpleDocTemplate):
        def afterFlowable(self, flowable):
            try:
                PAGE_TOTAL["v"] = self.page
            except Exception:
                pass
            super().afterFlowable(flowable)

    tmp = OUT + ".tmp.pdf"
    count_doc = CountingDoc(
        tmp, pagesize=A4,
        leftMargin=0.8 * inch, rightMargin=0.8 * inch,
        topMargin=0.9 * inch, bottomMargin=0.8 * inch,
        title=SOFTWARE_NAME, author=COPYRIGHT_HOLDER,
    )
    count_doc.build(build_story())  # 每次 build 都用全新 story，避免 flowable 复用
    total = PAGE_TOTAL["v"]
    print(f"第一遍记录总页数: {total}")
    os.remove(tmp)

    # 第二遍：正式构建，页脚用真实总页数（全新 story）
    PAGE_TOTAL["v"] = total
    doc = SimpleDocTemplate(
        OUT, pagesize=A4,
        leftMargin=0.8 * inch, rightMargin=0.8 * inch,
        topMargin=0.9 * inch, bottomMargin=0.8 * inch,
        title=SOFTWARE_NAME, author=COPYRIGHT_HOLDER,
    )
    doc.build(build_story(), onFirstPage=add_page_header_footer,
              onLaterPages=add_page_header_footer)
    print("说明书 PDF 已生成:", OUT)

if __name__ == "__main__":
    main()