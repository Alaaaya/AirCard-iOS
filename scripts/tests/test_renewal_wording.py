"""Source contract for renewal-only localization; no Apple SDK needed."""
import pathlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
BASE = "2aa8de95fa5344fe1f325ff66f74cf6e0a93c8ad"

def read(path):
    return (ROOT / path).read_text()

def table(source, language):
    section = source.split("private static let " + language + ":")[1].split("\n    ]")[0]
    return dict(re.findall(r'"([^"]+)": "([^"]*)"', section))

class RenewalWordingTests(unittest.TestCase):
    def test_actions_and_accessible_label_have_no_countdown(self):
        source = read("ios-app/Apps/AppsStrings.swift")
        for lang, expected in (("en", "Renew"), ("ar", "تجديد")):
            strings = table(source, lang)
            self.assertEqual(strings["hero.refresh"], expected)
            self.assertEqual(strings["menu.refresh"], expected)
            self.assertNotRegex(strings["hero.refresh"], r"[%0-9]")
        view = read("ios-app/Apps/AppsView.swift")
        button = view.split("Button(action: store.account != nil || store.hasSavedLogin ? onRefresh : onSignIn)")[1].split(".buttonStyle")[0]
        self.assertIn('L.t("hero.refresh")', button)
        self.assertNotRegex(button, r"days|hero\.renews|hero\.days|RenewalRing")

    def test_success_count_one_and_multiple_both_languages(self):
        source = read("ios-app/Apps/AppsStrings.swift")
        for lang, expected in (("en", "Renewed %d app(s)"), ("ar", "تم تجديد %d تطبيق")):
            value = table(source, lang)["toast.refreshed"]
            self.assertEqual(value, expected)
            for count in (1, 3, 12):
                self.assertEqual(value % count, expected % count)

    def test_nonrenewal_localizations_preserved(self):
        path = "ios-app/Apps/AppsStrings.swift"
        old = subprocess.check_output(["git", "show", BASE + ":" + path], cwd=ROOT, text=True)
        allowed = {"hero.refresh", "menu.refresh", "certs.sub", "settings.autoRefresh", "repair.body", "toast.refreshed"}
        for lang in ("en", "ar"):
            before, after = table(old, lang), table(read(path), lang)
            self.assertEqual(before.keys(), after.keys())
            for key in before.keys() - allowed:
                self.assertEqual(before[key], after[key], key)
        for path in ("ios-app/Apps/SourcesTab.swift", "ios-app/Apps/AppsExtras.swift", "ios-app/Apps/MirsaBrowserView.swift", "ios-app/Discovery/DiscoveryAuth.swift"):
            before = subprocess.check_output(["git", "show", BASE + ":" + path], cwd=ROOT)
            self.assertEqual(before, (ROOT / path).read_bytes(), path)

    def test_shortcut_renewal_success_error_and_titles(self):
        source = read("ios-app/Apps/AppsIntents.swift")
        for phrase in ("Renew Mirsa Apps", "Renew All Apps", "All apps renewed.", "Some apps could not be renewed.", "تجدّدت كل التطبيقات.", "ما قدر يجدّد كل التطبيقات."):
            self.assertIn(phrase, source)
        self.assertIn("vm.refreshNetworkStatus()", source)
        self.assertIn("await store.refreshAccount()", source)

if __name__ == "__main__":
    unittest.main()
