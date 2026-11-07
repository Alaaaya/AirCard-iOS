
import re,sys
from pathlib import Path
s=(Path(__file__).resolve().parent / "Apps/MirsaFormats.swift").read_text()
def ar(n):
    n=abs(n)
    if n==0:return"zero"
    if n==1:return"one"
    if n==2:return"two"
    if 3<=n%100<=10:return"few"
    if 11<=n%100<=99:return"many"
    return"other"
def oth(n):return"one"if abs(n)==1 else"other"
fm=re.search(r"static let formats.*?= \[\n(.*?)\n    \]\n",s,re.S).group(1)
pl=re.search(r"static let plurals.*?= \[\n(.*)\n    \]\n}",s,re.S).group(1)
ph=lambda x:sorted(re.findall(r"%(?:\d\$)?[@d]",x))
bad=0
for line in fm.split("\n"):
    m=re.findall(r'"(en|ar|ckb|kmr)": "((?:[^"\\]|\\.)*)"',line)
    d=dict(m);assert set(d)=={"en","ar","ckb","kmr"},line[:60]
    base=sorted(re.sub(r"\d\$","",p) for p in ph(d["en"]))
    for l in d:
        if sorted(re.sub(r"\d\$","",p) for p in ph(d[l]))!=base: print("PLACEHOLDER MISMATCH",l,d[l][:50]);bad+=1
blocks=re.findall(r'"(\w+)": \[\n((?:\s+"(?:en|ar|ckb|kmr)": \[.*\],\n)+)\s+\],',pl)
print("formats ok, plural keys",len(blocks))
for k,b in blocks:
    for l,c in re.findall(r'"(\w+)": \[(.*)\],',b):
        forms=dict(re.findall(r'"(\w+)": "((?:[^"\\]|\\.)*)"',c))
        assert "other" in forms,(k,l)
        for n in (0,1,2,3,11,100):
            cat=(ar if l=="ar" else oth)(n)
            f=forms.get(cat,forms["other"])
            if k!="x" and "%d" not in f and cat not in("one","two","zero"):
                print("NO %d",k,l,n);bad+=1
            out=f.replace("%d",str(n))
            assert "%" not in out,(k,l,n,out)
print("PASS plurals 0/1/2/3/11/100 x4 langs" if not bad else "FAIL")
sys.exit(1 if bad else 0)
