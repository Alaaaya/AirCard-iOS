"""Synchronous on-device file handshake, independent of xcodebuild log buffering."""
import json, os, pathlib, subprocess, sys, time

device, _log, out = sys.argv[1:]
output = pathlib.Path(out)
output.mkdir(parents=True, exist_ok=True)
container = None
seen = set()
while True:
    if container is None:
        result = subprocess.run(['xcrun', 'simctl', 'get_app_container', device,
                                 'com.alaa.mirsa', 'data'], capture_output=True, text=True)
        if result.returncode == 0:
            container = pathlib.Path(result.stdout.strip()) / 'Library' / 'Caches' / 'MirsaRuntimeCapture'
    if container is not None:
        try:
            request = json.loads((container / 'request.json').read_text())
            token, name = request['token'], request['name']
            if token not in seen:
                if name not in ('project-real-keyboard-visible-focused-field',
                                'project-real-keyboard-hidden-CTA-restored'):
                    raise ValueError('Unexpected screenshot request name')
                path = output / (name + '.png')
                result = subprocess.run(['xcrun', 'simctl', 'io', device, 'screenshot', str(path)],
                                        capture_output=True, text=True, timeout=15)
                ack = {'token': token, 'ok': result.returncode == 0 and path.exists(),
                       'error': result.stderr}
                (container / 'ack.tmp').write_text(json.dumps(ack))
                os.replace(container / 'ack.tmp', container / 'ack.json')
                seen.add(token)
                print('Captured', name, 'ok=', ack['ok'], flush=True)
        except (FileNotFoundError, json.JSONDecodeError):
            pass
    time.sleep(.05)
