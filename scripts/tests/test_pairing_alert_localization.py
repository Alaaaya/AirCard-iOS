"""Source-level regression for the actual localized pairing/VPN alert entries."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
STRINGS = ROOT / "ios-app/Apps/AppsStrings.swift"


class PairingAlertLocalizationTests(unittest.TestCase):
    def test_pairing_alerts_exact_in_every_localized_table(self):
        source = STRINGS.read_text(encoding="utf-8")
        tables = re.findall(
            r"private static let (\w+): \[String: String\] = \[(.*?)\n    \]",
            source, re.S,
        )
        expected = {
            "en": "Enable LocalDevVPN and check your pairing file.",
            "ar": "فعّل LocalDevVPN وتأكد من صحة ملف الاقتران.",
        }
        self.assertEqual({language for language, _ in tables}, set(expected))
        for language, body in tables:
            for key in ("err.vpn", "err.device"):
                with self.subTest(language=language, key=key):
                    values = re.findall(
                        r'"' + re.escape(key) + r'": ("(?:[^"\\]|\\.)*")', body
                    )
                    self.assertEqual(len(values), 1)
                    value = json.loads(values[0])
                    self.assertEqual(value, expected[language])
                    self.assertNotRegex(value.lower(), r"wi[ -]?fi|wlan|واي\s*فاي")

    def test_alert_call_sites_use_localized_entries(self):
        store = (ROOT / "ios-app/Apps/AppsStore.swift").read_text(encoding="utf-8")
        self.assertIn('error = L.t("err.vpn")', store)
        self.assertIn('return L.t("err.device") + "\\n\\n" + raw', store)


if __name__ == "__main__":
    unittest.main()
