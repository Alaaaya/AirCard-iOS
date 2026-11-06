"""Wiring guards complement the Rust real TLS/socket regression tests."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
class TransportWiring(unittest.TestCase):
    def test_both_real_download_paths_share_pinning(self):
        downloader = (ROOT/"ios-app/Discovery/DiscoveryDownloader.swift").read_text()
        providers = (ROOT/"ios-app/Discovery/DiscoveryProviders.swift").read_text()
        view = (ROOT/"ios-app/Discovery/DiscoveryView.swift").read_text()
        self.assertIn("DiscoveryDownloader(limits: limits)", providers)
        self.assertIn("downloader.download(url)", providers)
        self.assertIn("let d = DiscoveryDownloader()", view)
        self.assertIn("d.download(url)", view)
        self.assertIn("al_discovery_download(", downloader)
        self.assertIn("IPAValidator.validate(file: dest", downloader)
        self.assertNotIn("session.downloadTask", downloader)
        self.assertNotIn("DiscoveryDNSPolicy.permits", downloader)
        self.assertIn('throw Failure.unsafe("Pinned download transport is unavailable.")', downloader)
    def test_no_proxy_no_credentials_no_unchecked_redirects(self):
        rust = (ROOT/"rust-core/src/discovery_transport.rs").read_text()
        for required in [".no_proxy()", "Policy::none()", ".resolve_to_addrs(host, addrs)",
                         "checked_peer(response.remote_addr(), &addrs)?",
                         "safe_url(&url)?", ".referer(false)", ".create_new(true)"]:
            self.assertIn(required, rust)
        for forbidden in ["danger_accept_invalid", ".basic_auth(", ".bearer_auth(", ".cookie_store("]:
            self.assertNotIn(forbidden, rust)
if __name__ == "__main__":
    unittest.main()
