import pathlib
import tempfile
import unittest

from apt_fallback import MIRROR, use_fallback


class FallbackTest(unittest.TestCase):
    def test_switches_only_failed_official_sources_and_preserves_apt_policy(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "ubuntu.sources"
            original = "URIs: http://archive.ubuntu.com/ubuntu https://security.ubuntu.com/ubuntu\nSuites: noble-security\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n"
            other = pathlib.Path(folder) / "third-party.list"
            other.write_text("deb https://ppa.launchpadcontent.net/ondrej/php/ubuntu noble main\n")
            for unavailable, fallback_ok, expected in [
                (False, True, original),
                (True, False, original),
                (True, True, original.replace("https://security.ubuntu.com/ubuntu", MIRROR)),
            ]:
                path.write_text(original)
                def probe(url):
                    return fallback_ok if url.startswith(MIRROR) else not (unavailable and "security.ubuntu.com" in url)
                self.assertEqual(use_fallback([path, other], "noble", probe), unavailable and fallback_ok)
                self.assertEqual(path.read_text(), expected)
                self.assertIn("ppa.launchpadcontent.net", other.read_text())

    def test_ports_and_custom_mirrors_are_not_rewritten(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "sources.list"
            original = "deb http://ports.ubuntu.com/ubuntu-ports noble main\ndeb https://mirror.example/ubuntu noble main\n"
            path.write_text(original)
            def probe(url):
                self.fail(f"Unexpected probe: {url}")
            self.assertFalse(use_fallback([path], "noble", probe))
            self.assertEqual(path.read_text(), original)


if __name__ == "__main__":
    unittest.main()
