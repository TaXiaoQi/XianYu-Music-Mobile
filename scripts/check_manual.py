# -*- coding: utf-8 -*-
import subprocess, os, sys
poppler = r"C:\Users\小奇\AppData\Roaming\TRAE SOLO CN\ModularData\ai-agent\vm\tools\app\poppler"
ppm = os.path.join(poppler, "pdftoppm.exe")
txt = os.path.join(poppler, "pdftotext.exe")
pdf = r"d:\Program Files\XianYu-Music\XianYu-Music-Mobile\soft-copyright\弦予音乐软件V1.0.2-操作说明书.pdf"

# 渲染第1页
out_pre = r"d:\Program Files\XianYu-Music\XianYu-Music-Mobile\soft-copyright\preview\page_check"
subprocess.run([ppm, "-png", "-r", "110", "-f", "1", "-l", "1", pdf, out_pre],
               check=True, capture_output=True)
print("rendered page1")

# pdftotext 末页
res = subprocess.run([txt, "-f", "5", "-l", "5", pdf, "-"],
                     check=True, capture_output=True, text=True, errors="replace")
print("=== 末页文本(pdftotext) ===")
print(res.stdout[-400:])