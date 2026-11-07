"""Source wiring regression only; native Security helper tests run in Xcode."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CertificateDisplayWiringTests(unittest.TestCase):
    def test_importer_maps_display_name_from_selected_certificate(self):
        source = (ROOT / "ios-app/Apps/PersonalCertificateView.swift").read_text()
        self.assertIn("name: PersonalCertificateLabel.name(importDetails: details)", source)
        self.assertNotIn('name: details["name"]', source)
        self.assertNotIn('name: details["subject"]', source)

    def test_shared_helper_uses_security_not_textual_dn_parsing(self):
        source = (ROOT / "ios-app/Apps/PersonalProjectFolder.swift").read_text()
        helper = source.split("enum PersonalCertificateLabel {", 1)[1].split("\nstruct PersonalProjectFolderBrowser", 1)[0]
        self.assertIn("SecCertificateCopyCommonName(cert, &value)", helper)
        self.assertIn('importDetails["certificate"]', helper)
        self.assertNotIn('importDetails["name"]', helper)
        self.assertNotIn('importDetails["subject"]', helper)
        self.assertNotIn("components(separatedBy:", helper)
        self.assertIn('personalText("Personal certificate", "شهادة شخصية")', helper)

    def test_all_personal_certificate_presentations_use_mapped_name(self):
        expected = {
            "CertificateInstall.swift": ["Text(id.name)", "PersonalIdentityVault.savedIdentities()"],
            "PersonalCertificateManagerView.swift": ["Text(item.name)", 'Text(item.name + "\\n"', "PersonalIdentityVault.savedIdentities()"],
            "PersonalCertificateView.swift": ["Text(item.name)", "PersonalIdentityVault.savedIdentities()"],
            "PersonalProjectDetailView.swift": ["Text(selected.name)", "identity.name", 'Button(i.name + " · " + i.teamID)', "PersonalIdentityVault.savedIdentities()"],
        }
        for filename, snippets in expected.items():
            with self.subTest(filename=filename):
                source = (ROOT / "ios-app/Apps" / filename).read_text()
                for snippet in snippets:
                    self.assertIn(snippet, source)


if __name__ == "__main__":
    unittest.main()
