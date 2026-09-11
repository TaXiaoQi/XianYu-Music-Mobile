# -*- coding: utf-8 -*-
import warnings
warnings.filterwarnings("ignore")
from pypdf import PdfReader

pdf = r"D:\Program Files\XianYu-Music\XianYu-Music-Mobile\soft-copyright\弦予音乐软件V1.0.2-源代码.pdf"
import os
print("size", os.path.getsize(pdf))
r = PdfReader(pdf)
print("pages:", len(r.pages))
t1 = r.pages[0].extract_text() or ""
t60 = r.pages[59].extract_text() or ""
print("page1 head:", t1[:60].replace("\n", " ")[:60])
print("page1 has 李军奇:", "李军奇" in t1[:3] or t1.startswith("李军奇"))
print("page60 tail has ssrf/resolver:", ("resolver" in t60) or ("ssrf" in t60.lower()) or ("forbidden_ip" in t60))
# 每页行数抽样
import re
lens = [len(re.sub(r'\s+', ' ', (r.pages[i].extract_text() or ''))) for i in [0,15,45,59]]
print("文本长度抽样:", lens)