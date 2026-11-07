#!/usr/bin/env python3
"""Read-only fixture verifier: never loads or executes Mach-O input."""
import hashlib, plistlib, pathlib, struct, subprocess, tempfile, zipfile, json, sys
ipa=pathlib.Path(sys.argv[1])
be=lambda d,o:struct.unpack_from('>I',d,o)[0]
le=lambda d,o:struct.unpack_from('<I',d,o)[0]
proof={}
with zipfile.ZipFile(ipa) as z:
    prefix='Payload/Fixture.app/'
    for bundle in ['', 'PlugIns/Ext.appex/', 'Frameworks/F.framework/']:
        resources=plistlib.loads(z.read(prefix+bundle+'_CodeSignature/CodeResources'))
        for rel,item in resources.get('files2',resources.get('files',{})).items():
            if isinstance(item,dict) and 'cdhash' in item: continue
            path=prefix+bundle+rel
            if path not in z.namelist():continue
            d=z.read(path)
            if isinstance(item,bytes):assert hashlib.sha1(d).digest()==item
            elif isinstance(item,dict):
                if 'hash2' in item:assert hashlib.sha256(d).digest()==item['hash2'],path
                if 'hash' in item:assert hashlib.sha1(d).digest()==item['hash'],path
    for rel in ['Main','Frameworks/OwnTweak.dylib','PlugIns/Ext.appex/Ext','PlugIns/Ext.appex/Frameworks/OwnTweak.dylib','Frameworks/F.framework/F','Frameworks/F.framework/Frameworks/OwnTweak.dylib']:
        d=z.read(prefix+rel);assert le(d,0)==0xfeedfacf and le(d,4)==0x100000c and le(d,8)==0
        off=32;sig=None;deps=[]
        for _ in range(le(d,16)):
            cmd,size=le(d,off),le(d,off+4)
            if cmd==0x1d:sig=d[le(d,off+8):le(d,off+8)+le(d,off+12)]
            if cmd in [0xc,0x80000018]:deps.append(d[off+le(d,off+8):off+size].split(b'\0')[0].decode())
            off+=size
        assert sig and be(sig,0)==0xfade0cc0
        blobs={}
        for i in range(be(sig,8)):
            slot,pos=be(sig,12+i*8),be(sig,16+i*8);blobs[slot]=sig[pos:pos+be(sig,pos+4)]
        cd=blobs[0];assert be(cd,0)==0xfade0c02
        hash_off,special,count,limit=be(cd,16),be(cd,24),be(cd,28),be(cd,32)
        hs,ht,page=cd[36],cd[37],1<<cd[39]
        hashfn={1:hashlib.sha1,2:hashlib.sha256}[ht]
        for i in range(count):assert hashfn(d[i*page:min((i+1)*page,limit)]).digest()[:hs]==cd[hash_off+i*hs:hash_off+(i+1)*hs]
        ent=plistlib.loads(blobs[5][8:]) if 5 in blobs else {}
        if rel in ['Main','PlugIns/Ext.appex/Ext']:
            expected='MIRSATEST.com.mirsa.loader.fixture'+('.ext' if rel!='Main' else '')
            assert ent['application-identifier']==expected
        else:
            for slot in [5,7]:
                if slot in blobs:
                    payload=blobs[slot][8:]
                    if slot==5:assert plistlib.loads(payload)=={}
        assert 0x10000 in blobs
        with tempfile.TemporaryDirectory() as tmp:
            p=pathlib.Path(tmp);(p/'cd').write_bytes(cd);(p/'cms').write_bytes(blobs[0x10000][8:])
            subprocess.run(['openssl','cms','-verify','-binary','-inform','DER','-in',str(p/'cms'),'-content',str(p/'cd'),'-noverify','-out',str(p/'out')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        proof[rel]={'size':len(d),'pages_verified':count,'cms_signature_verified':True,'dependencies':deps}
    for bundle,exe in [('', 'Main'),('PlugIns/Ext.appex/','Ext'),('Frameworks/F.framework/','F')]:
        assert proof[bundle+exe]['dependencies']==['/usr/lib/libSystem.B.dylib','@loader_path/Frameworks/OwnTweak.dylib']
    assert z.read(prefix+'embedded.mobileprovision')==b'SYNTHETIC-TEST-PROFILE-NOT-APPLE-AUTHORIZED'
    assert z.read(prefix+'PlugIns/Ext.appex/embedded.mobileprovision')==b'SYNTHETIC-EXTENSION-PROFILE-NOT-APPLE-AUTHORIZED'
print(json.dumps(proof,indent=2))
