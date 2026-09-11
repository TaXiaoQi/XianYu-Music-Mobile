# -*- coding: utf-8 -*-
import subprocess, os
poppler = r"C:\Users\小奇\AppData\Roaming\TRAE SOLO CN\ModularData\ai-agent\vm\tools\app\poppler"
ppm = os.path.join(poppler, "pdftoppm.exe")
pdf = r"d:\Program Files\XianYu-Music\XianYu-Music-Mobile\soft-copyright\弦予音乐软件V1.0.2-操作说明书.pdf"
outdir = r"D:\xianyu-poc_temp"  # 用无空格可写目录
os.makedirs(outdir, exist_ok=True)
out_pre = os.path.join(outdir, "manual_last")
# 渲染第5页
r = subprocess.run([ppm, "-png", "-r", "100", "-f", "5", "-l", "5", pdf, out_pre],
                   cwd=outdir, capture_output=True)
print("rc:", r.returncode)
print(r.stderr.decode("utf-8", "replace")[-500:])
for f in os.listdir(outdir):
    print("out:", f, os.path.getsize(os.path.join(outdir, f)))