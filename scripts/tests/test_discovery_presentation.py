"""Static UI contract checks. These do not substitute for simulator screenshots."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]

class DiscoveryPresentationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.view = (ROOT / "ios-app/Discovery/DiscoveryView.swift").read_text()
        cls.providers = (ROOT / "ios-app/Discovery/DiscoveryProviders.swift").read_text()

    def test_reference_cards_and_sections_removed(self):
        self.assertIn('$0.isDownloadable && $0.identity != .reference && $0.origin != .appleMetadata', self.view)
        self.assertNotIn('badge(tr("Reference page"', self.view)
        self.assertNotIn('Button(tr("Open page"', self.view)
        self.assertNotIn('صفحة مرجعية', self.view)
        self.assertNotIn('downloadable + identities', self.providers)
        self.assertNotIn('apple.listings.map(AppleMetadata.candidate)', self.providers)

    def test_valid_source_card_details_preserved(self):
        for required in ['RemoteIcon(url: c.iconURL, size: 56, corner: 13)',
                         'Text(c.name)', 'Text(c.bundleID)', '"v" + c.version', 'c.sourceName']:
            self.assertIn(required, self.view)

    def test_original_download_no_actions_preserved(self):
        for required in ['Button { pendingTrust = c }', 'Text(tr("Download", "تنزيل"))',
                         'Button { store.dismiss(c) }', 'Text(tr("No", "لا"))',
                         'store.trust(c); Task { await store.accept(c) }']:
            self.assertIn(required, self.view)

    def test_empty_arabic_exact(self):
        self.assertIn('static let emptyMessage = "ما لقيت IPA لهالتطبيق"', self.providers)
        self.assertIn('all.isEmpty ? emptyMessage : nil', self.providers)

if __name__ == "__main__":
    unittest.main()
