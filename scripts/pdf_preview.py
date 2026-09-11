# -*- coding: utf-8 -*-
"""直接把 PDF 指定页渲染为 PNG 检查"""
import sys, os
from pdf2image import convert_from_path

pdf = sys.argv[1]
outdir = sys.argv[2] if len(sys.argv)>2 else r"d:\Program Files\XianYu-Music\XianYu-Music-Mobile\soft-copyright\preview"
os.makedirs(outdir, exist_ok=True)
pages = convert_from_path(pdf, dpi=120, first_page=1, last_page=3)
for i, img in enumerate(pages, 1):
    p = os.path.join(outdir, f"p{i}.png")
    img.save(p)
    print("saved", p)