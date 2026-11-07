"""Capture actual OS keyboard from the host, never a synthetic rendering."""
import os,re,subprocess,sys,time
device,log,out=sys.argv[1:]
os.makedirs(out,exist_ok=True)
seen=set()
while True:
    try:
        text=open(log).read()
        for name in re.findall(r'MIRSA_SCREENSHOT_REQUEST (project-real-keyboard-[a-z-]+)',text):
            if name in seen: continue
            subprocess.run(['xcrun','simctl','io',device,'screenshot',os.path.join(out,name+'.png')],check=True)
            seen.add(name)
    except FileNotFoundError:
        pass
    time.sleep(.1)
