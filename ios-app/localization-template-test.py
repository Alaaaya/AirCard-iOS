
import re
s=open("Apps/MirsaTr.swift").read()
m=re.search(r"static let templates.*?= \[\n(.*?)\n    \]",s,re.S)
rows=re.findall(r'\("((?:[^"\\]|\\.)*)", "((?:[^"\\]|\\.)*)", "((?:[^"\\]|\\.)*)"\)',m.group(1))
print("templates",len(rows))
for en,c,k in rows:
    n=en.count("{}")
    assert n>=1 and c.count("{}")==n and k.count("{}")==n,en
    assert en.strip("{}")!="", en
    assert re.search(r"[A-Za-z]",en.replace("{}","")),en
print("PASS templates placeholders aligned, anchored full-string match")
