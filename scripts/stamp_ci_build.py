"""Stamp real bundle builds, not marketing versions or private feed entries."""
import os
import pathlib
import plistlib


def ci_build(run, attempt):
    run, attempt = int(run), int(attempt)
    if run < 1 or not 1 <= attempt <= 99:
        raise ValueError('invalid CI run/attempt')
    serial = run * 100 + attempt
    major, tail = divmod(serial, 10000)
    major += 2  # strictly above legacy actual 1.3.2
    if major > 9999:
        raise ValueError('CI build exhausted Apple build range')
    return f'{major}.{tail // 100}.{tail % 100}'


def stamp(root, build):
    for path in [root / 'Info.plist', *root.glob('PlugIns/**/*.appex/Info.plist')]:
        data = plistlib.loads(path.read_bytes())
        data['CFBundleVersion'] = build
        path.write_bytes(plistlib.dumps(data))


if __name__ == '__main__':
    import sys
    build = ci_build(os.environ['GITHUB_RUN_NUMBER'], os.environ.get('GITHUB_RUN_ATTEMPT', '1'))
    stamp(pathlib.Path(sys.argv[1]), build)
    print(build)
