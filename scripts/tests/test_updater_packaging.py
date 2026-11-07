import importlib.util
import json
import pathlib
import plistlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

class UpdaterPackagingTests(unittest.TestCase):
    def test_monotonic(self):
        m = load('stamp_ci_build')
        numbers = [m.ci_build(88, 1), m.ci_build(88, 2), m.ci_build(89, 1), m.ci_build(100, 1)]
        self.assertEqual(numbers, ['2.88.1', '2.88.2', '2.89.1', '3.0.1'])
        self.assertEqual(numbers, sorted(numbers, key=lambda s: tuple(map(int, s.split('.')))))
        for run, attempt in [(0, 1), (1, 100), (99999999, 1)]:
            with self.assertRaises(ValueError): m.ci_build(run, attempt)
    def test_parent_extension(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d)
            child = root / 'PlugIns/Live.appex/Info.plist'
            child.parent.mkdir(parents=True)
            for p in [root / 'Info.plist', child]:
                p.write_bytes(plistlib.dumps({'CFBundleVersion':'1.3.2','CFBundleShortVersionString':'1.3.2'}))
            load('stamp_ci_build').stamp(root, '2.89.1')
            for p in [root / 'Info.plist', child]:
                self.assertEqual(plistlib.loads(p.read_bytes())['CFBundleVersion'], '2.89.1')
                self.assertEqual(plistlib.loads(p.read_bytes())['CFBundleShortVersionString'], '1.3.2')
    def test_notes_explicit_target(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / 'notes.json'
            module = load('curated_release_notes')
            self.assertEqual(module.metadata(p, '1.3.89'), {'releaseNotes':{}})
            p.write_text(json.dumps({'1.3.89': {'ar':'تحسين التثبيت', 'en':'Installation improvements'}}))
            self.assertEqual(module.metadata(p, '1.3.90'), {'releaseNotes':{}})
            self.assertEqual(module.metadata(p, '1.3.89')['releaseNotes']['ar'], 'تحسين التثبيت')
    def test_bounded_pinned_verification_wiring(self):
        source = (ROOT / 'ios-app/Apps/AppsExtras.swift').read_text().split('// MARK: - Mirsa updates itself')[1]
        verification = source.split('private func actualBuild')[1].split('/// "Later"')[0]
        self.assertNotIn('SideloadService.unzip', verification)
        self.assertNotIn('URLSession.shared.download', verification)
        self.assertIn('DiscoveryDownloader(limits:', verification)
        self.assertIn('maxBytes: 128 * 1024 * 1024', verification)
        self.assertIn('totalTimeout: 120', verification)
        for bound in ['maxTotalUncompressed = 512 * 1024 * 1024', 'maxEntries = 10_000',
                      'maxPathDepth = 32', 'rejectSymlinks = true', 'maxPlist = 1024 * 1024']:
            self.assertIn(bound, verification)
        self.assertIn('defer { try? FileManager.default.removeItem(at: file) }', verification)
        self.assertEqual(source.count('cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30'), 2)
        self.assertIn('let verified = try await Self.verifiedUpdate(ipa)', source)

    def test_no_commit_fallback_or_wifi_requirement(self):
        workflow = (ROOT / '.github/workflows/unsigned-ipa.yml').read_text()
        self.assertNotIn('git log', workflow)
        updater = (ROOT / 'ios-app/Apps/AppsExtras.swift').read_text().split('// MARK: - Mirsa updates itself')[1]
        self.assertNotIn('Wi-Fi', updater)
        self.assertIn('Enable LocalDevVPN and check your pairing file.', updater)
        self.assertIn('فعّل LocalDevVPN وتأكد من صحة ملف الاقتران.', updater)
        self.assertNotIn('filter(\\.isNumber)', updater)
        self.assertIn('CFBundleVersion', updater)

if __name__ == '__main__': unittest.main()
