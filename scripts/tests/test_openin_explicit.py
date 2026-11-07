"""Source contract regressions, not device/runtime acceptance."""
import pathlib, unittest
R=pathlib.Path(__file__).resolve().parents[2]
class OpenInRouting(unittest.TestCase):
 def test_apple_id_is_explicit_real_path(self):
  store=(R/'ios-app/Apps/AppsStore.swift').read_text()
  route=store.split('func installIncomingWithAppleID',1)[1].split('func importIPA',1)[0]
  self.assertIn('commitPending(to: .real',route)
  self.assertNotIn('MirsaInstallMode',route)
  self.assertIn('explicitIncomingInstall = true',route)
  real=store.split('private func installAsReal',1)[1].split('// MARK:',1)[0]
  self.assertIn('networkReady(vm)',real); self.assertIn('SideloadService.install(',real)
 def test_certificate_passes_selected_identity_and_ota_fail_closed(self):
  root=(R/'ios-app/ContentView.swift').read_text()
  self.assertIn('identity: identity, store: AppsStore.shared',root)
  cert=(R/'ios-app/Apps/CertificateInstall.swift').read_text().split('guard FileManager.default.fileExists',1)[0]
  self.assertIn('OwnCertificateDevice.require()',cert)
  self.assertIn('material:identity.material,options:PersonalProjectOptions()',cert)
  self.assertNotIn('pairingFilePath',cert)
  ota=(R/'ios-app/Apps/CertificateOTA.swift').read_text()
  self.assertIn('cachedUDID: device',ota);self.assertIn('if let explicitMaterial',ota)
 def test_lifetime_and_duplicate_gate(self):
  s=(R/'ios-app/ContentView.swift').read_text()
  self.assertIn('incomingHandoff = {',s)
  self.assertIn('defer {\n                    OpenInIPA.remove(source)',s)
  self.assertEqual(s.count('incomingSources.insert('),2)
  self.assertIn('!incomingProcessing',s)
  self.assertIn('if let handoff = incomingHandoff',s)
 def test_all_explicit_labels_have_four_languages(self):
  s=(R/'ios-app/Apps/IncomingIPAConfirmationSheet.swift').read_text()
  trans=(R/'ios-app/Apps/MirsaTrExtra.swift').read_text()
  for key in ['Install with Apple ID','Save to my library','Sign & install with certificate']:
   self.assertIn('tr("'+key+'",',s)
   self.assertEqual(trans.count('"'+key+'":'),2)
  self.assertIn('.leftToRight',s)
  self.assertIn('onImportProject',s); self.assertIn('onSaveLibrary',s)
if __name__=='__main__': unittest.main()
