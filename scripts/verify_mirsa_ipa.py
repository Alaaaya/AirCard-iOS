"""Inspect actual packaged identity and compare it with a production IPA."""
import pathlib
import plistlib
import sys
import zipfile

def inspect(path):
    with zipfile.ZipFile(path) as z:
        plists = [n for n in z.namelist() if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")]
        assert len(plists) == 1, plists
        name = plists[0]
        info = plistlib.loads(z.read(name))
        executable = name.rsplit("/", 1)[0] + "/" + info["CFBundleExecutable"]
        magic = z.read(executable)[:4]
        assert magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"), magic
        return info, executable

if __name__ == "__main__":
    current, executable = inspect(sys.argv[1])
    assert current["CFBundleExecutable"] == "Mirsa", current["CFBundleExecutable"]
    assert executable == "Payload/Mirsa.app/Mirsa", executable
    assert current["CFBundleIdentifier"] == "com.alaa.mirsa"
    assert current["CFBundleDisplayName"] == "Mirsa"
    if len(sys.argv) > 2:
        production, _ = inspect(sys.argv[2])
        assert production["CFBundleIdentifier"] == current["CFBundleIdentifier"]
    print({"executable": executable, "bundle": current["CFBundleIdentifier"], "name": current["CFBundleName"]})
