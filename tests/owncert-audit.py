from pathlib import Path
import unittest
r=Path(__file__).resolve().parents[1]
class Audit(unittest.TestCase):
 def test_keychain(self):
  s=(r/'ios-app/Apps/CertificateOTA.swift').read_text()
  for value in ['kSecAttrAccessibleWhenUnlockedThisDeviceOnly','kSecAttrSynchronizable as String:false','isExcludedFromBackup=true','SecItemDelete','installation:try?','validRecord(value']:
   self.assertIn(value,s)
 def test_no_network_cached(self):
  s=(r/'rust-core/src/personal_sign.rs').read_text().split('fn signing_udid')[1].split('#[cfg(test)]')[0]
  self.assertLess(s.index('return Ok'),s.index('read(&opts.pairing_path)'))
  self.assertNotIn('connect_tunnel',s)
 def test_all_install_routes(self):
  for f in ['AppsStore.swift','CertificateInstall.swift','PersonalSigningOperation.swift']:
   s=(r/'ios-app/Apps'/f).read_text()
   self.assertIn('MirsaInstallMode.ownCertificate',s)
   self.assertIn('CertificateOTA.install',s)
 def test_cache_required_before_sign(self):
  s=(r/'ios-app/Apps/CertificateOTA.swift').read_text()
  self.assertLess(s.index('try OwnCertificateDevice.require()'),s.index('PersonalCertificateSigner.sign'))
  self.assertIn('pairingPath: "", options: options, cachedUDID: device',s)
unittest.main()
