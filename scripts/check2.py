# -*- coding: utf-8 -*-
import warnings
warnings.filterwarnings("ignore")
from pypdf import PdfReader

pdf = r"D:\Program Files\XianYu-Music\XianYu-Music-Mobile\soft-copyright\弦予音乐软件V1.0.2-操作说明书.pdf"
r = PdfReader(pdf)
print("pages:", len(r.pages))
for i in range(len(r.pages)):
    t = r.pages[i].extract_text() or ""
    has_c = "©" in t
    print(f"page {i+1}: len={len(t)} footer_copyright={has_c} contains_end={'（本说明书结束）' in t}")