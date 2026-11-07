#!/usr/bin/env python3
"""Host simulation of OUR constructor with mocked dlopen. NEVER loads tweaks.
This does not establish iOS dyld/signature/runtime compatibility.
"""
import os, pathlib, subprocess, tempfile
HERE=pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='mirsa-own-loader-test-') as tmp:
    root=pathlib.Path(tmp)
    harness=root/'harness.c'
    harness.write_text('''
#include <stdio.h>
#include <stdlib.h>
typedef struct { const char *dli_fname; void *dli_fbase; const char *dli_sname; void *dli_saddr; } Dl_info;
int dladdr(const void *p, Dl_info *out) { (void)p; out->dli_fname=getenv("MIRSA_TEST_SELF");return out->dli_fname!=NULL; }
void *dlopen(const char *p,int mode) { if(mode!=10)exit(10); puts(p);return (void*)1; }
int main(void) { return 0; }
''')
    exe=root/'loader-test'
    subprocess.run(['clang-21','-fno-builtin','-Werror','-Wno-misleading-indentation',str(HERE/'MirsaLoader.c'),str(harness),'-o',str(exe)],check=True)
    frameworks=root/'Frameworks'; frameworks.mkdir()
    self=frameworks/'MirsaLoader.dylib';self.touch()
    for s in ['A.dylib','B.dylib']:(frameworks/s).touch()
    env={**os.environ,'MIRSA_TEST_SELF':str(self)}
    def run(manifest):
        (frameworks/'MirsaLoadOrder.txt').write_bytes(manifest)
        return subprocess.check_output([str(exe)],env=env,text=True).splitlines()
    assert run(b'B.dylib\nA.dylib\n')==[str(frameworks/'B.dylib'),str(frameworks/'A.dylib')]
    bad=[b'',b'A.dylib',b'A.dylib\nA.dylib\n',b'A.dylib\n../Outside\n',b'A.dylib\n/Outside\n',b'A.dylib\nMissing.dylib\n',b'A.dylib\n\0B\n',b'A.dylib\n\n',b'A.dylib\n./B.dylib\n',b'A.dylib\n'+b'x'*1024+b'\n']
    for manifest in bad:assert run(manifest)==[],repr(manifest[:60])
    outside=root/'Outside';outside.touch();(frameworks/'Escape.dylib').symlink_to(outside)
    assert run(b'A.dylib\nEscape.dylib\n')==[]
    print('PASS 12 own-constructor host simulations; dlopen mocked, no tweak executed')
