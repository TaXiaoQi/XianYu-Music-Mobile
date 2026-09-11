# -*- coding: utf-8 -*-
import re, os
pdf = r"D:\Program Files\XianYu-Music\XianYu-Music-Mobile\soft-copyright\弦予音乐软件V1.0.2-操作说明书.pdf"
print("size", os.path.getsize(pdf))
data = open(pdf, "rb").read()
print("starts with %PDF:", data[:5])
# 统计叶子页面对象
pages = re.findall(rb"/Type\s*/Page[^s]", data)
print("pattern /Type /Page count:", len(pages))
# 根页树 Kids 数量
m = re.search(rb"/Count\s+(\d+)", data)
print("/Count in first Pages:", m.group(1) if m else None)
print("/Count all:", re.findall(rb"/Count\s+(\d+)", data)[:10])