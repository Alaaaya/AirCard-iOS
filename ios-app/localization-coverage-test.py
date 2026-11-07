
import re,sys
from pathlib import Path
d=str(Path(__file__).resolve().parent / "Apps") + "/"
a=open(d+"MirsaTr.swift").read(); l=open(d+"MirsaTrLegacy.swift").read()
def block(s,name):
    m=re.search(name+r".*?= \[\n(.*?)\n    \]",s,re.S); return m.group(1)
ck=len(re.findall(r'^        ".*": ',block(a,"static let ckbKeys"),re.M)); kk=len(re.findall(r'^        ".*": ',block(a,"static let kmrKeys"),re.M))
c=len(re.findall(r'^        ".*": ',block(a,"static let ckb:"),re.M)); k=len(re.findall(r'^        ".*": ',block(a,"static let kmr:"),re.M))
ok=(ck==kk and c==k)
print(ck,kk,c,k)
leg=re.findall(r'^        "(.*)": \(("(?:[^"\\]|\\.)*"), ("(?:[^"\\]|\\.)*"), ("(?:[^"\\]|\\.)*")\),$',l,re.M)
print("legacy",len(leg))
bad=[x[0] for x in leg if '""' in (x[1],x[2],x[3])]
print("empty",bad)
assert ok and not bad and "?? ar" in a
print("PASS")
