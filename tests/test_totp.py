"""Backend tests for bin/totp. Every test runs against a temp store with a
throwaway key (SESAME_KEY), so the real keyring and store are never touched."""

import base64
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "bin" / "totp"


def load_module():
    spec = importlib.util.spec_from_loader("totp_backend", loader=None)
    module = importlib.util.module_from_spec(spec)
    exec(compile(BIN.read_text(), str(BIN), "exec"), module.__dict__)
    return module


class Sandbox(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = dict(os.environ, SESAME_DIR=self.tmp.name,
                        SESAME_KEY=base64.b64encode(os.urandom(32)).decode())

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *args, stdin=None, ok=True):
        result = subprocess.run([sys.executable, str(BIN), *args], input=stdin, env=self.env,
                                capture_output=True, text=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def run_json(self, *args, stdin=None):
        return json.loads(self.run_cli(*args, stdin=stdin).stdout)


class TotpMath(unittest.TestCase):
    def setUp(self):
        self.m = load_module()

    def test_rfc6238_sha1(self):
        code, _, _ = self.m.totp("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", now=59)
        self.assertEqual(code, "287082")
        code, _, _ = self.m.totp("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", now=1111111109, digits=8)
        self.assertEqual(code, "07081804")

    def test_rfc6238_sha256_sha512(self):
        # RFC 6238 seeds: "1234567890" repeated to 32 / 64 bytes.
        seed = (b"1234567890" * 7)
        s256 = base64.b32encode(seed[:32]).decode()
        s512 = base64.b32encode(seed[:64]).decode()
        self.assertEqual(self.m.totp(s256, now=59, digits=8, algorithm="SHA256")[0], "46119246")
        self.assertEqual(self.m.totp(s512, now=59, digits=8, algorithm="SHA512")[0], "90693936")

    def test_remaining(self):
        _, counter, remaining = self.m.totp("JBSWY3DPEHPK3PXP", now=59)
        self.assertEqual((counter, remaining), (1, 1))

    def test_secret_normalisation(self):
        self.assertEqual(self.m.normalize_secret("jbsw y3dp-ehpk 3pxp"), "JBSWY3DPEHPK3PXP")
        with self.assertRaises(self.m.TotpError):
            self.m.normalize_secret("not base32 !")

    def test_parse_otpauth(self):
        account = self.m.parse_otpauth(
            "otpauth://totp/Acme%20Corp:alice%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=Acme%20Corp&digits=8&period=60&algorithm=SHA256")
        self.assertEqual(account["issuer"], "Acme Corp")
        self.assertEqual(account["name"], "alice@example.com")
        self.assertEqual((account["digits"], account["period"], account["algorithm"]), (8, 60, "SHA256"))

    def test_parse_otpauth_rejects_hotp(self):
        with self.assertRaises(self.m.TotpError):
            self.m.parse_otpauth("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=1")

    def test_parse_migration(self):
        # Hand-built Google Authenticator export with one TOTP entry:
        # secret "Hello!\xde\xad\xbe\xef" (= JBSWY3DPEHPK3PXP), name alice, issuer Acme, SHA1, 6 digits, TOTP.
        secret = base64.b32decode("JBSWY3DPEHPK3PXP")
        params = (b"\x0a" + bytes([len(secret)]) + secret
                  + b"\x12\x05alice" + b"\x1a\x04Acme" + b"\x20\x01" + b"\x28\x01" + b"\x30\x02")
        payload = b"\x0a" + bytes([len(params)]) + params + b"\x10\x01"
        uri = "otpauth-migration://offline?data=" + base64.b64encode(payload).decode()
        accounts = self.m.parse_migration(uri)
        self.assertEqual(len(accounts), 1)
        self.assertEqual(accounts[0]["secret"], "JBSWY3DPEHPK3PXP")
        self.assertEqual((accounts[0]["issuer"], accounts[0]["name"]), ("Acme", "alice"))

    def test_otpauth_roundtrip(self):
        account = {"name": "bob", "issuer": "Site", "secret": "JBSWY3DPEHPK3PXP",
                   "digits": 8, "period": 45, "algorithm": "SHA512"}
        self.assertEqual(self.m.parse_otpauth(self.m.to_otpauth(account)) | {"secret": "JBSWY3DPEHPK3PXP"}, account)


class Cli(Sandbox):
    URI = "otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"

    def test_add_list_remove(self):
        result = self.run_json("add", "--stdin", stdin=self.URI)
        self.assertEqual(len(result["added"]), 1)
        self.assertNotIn("secret", result["added"][0])
        account_id = result["added"][0]["id"]

        again = self.run_json("add", "--uri", self.URI)
        self.assertEqual((len(again["added"]), len(again["skipped"])), (0, 1))

        listing = self.run_json("list")
        self.assertEqual([a["id"] for a in listing["accounts"]], [account_id])
        self.assertRegex(listing["accounts"][0]["code"], r"^\d{6}$")
        self.assertNotIn("secret", listing["accounts"][0])

        self.run_json("remove", account_id, "--yes")
        self.assertEqual(self.run_json("list")["accounts"], [])

    def test_store_is_encrypted_and_private(self):
        self.run_json("add", "--uri", self.URI)
        store = Path(self.tmp.name) / "store.json"
        self.assertEqual(store.stat().st_mode & 0o777, 0o600)
        raw = store.read_text()
        self.assertNotIn("JBSWY3DPEHPK3PXP", raw)
        self.assertNotIn("GitHub", raw)
        self.assertEqual(json.loads(raw)["format"], "sesame-store")

    def test_wrong_key_fails_cleanly(self):
        self.run_json("add", "--uri", self.URI)
        self.env["SESAME_KEY"] = base64.b64encode(os.urandom(32)).decode()
        result = self.run_cli("list", ok=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("decrypt", result.stderr)

    def test_export_and_import(self):
        self.run_json("add", "--uri", self.URI)
        exported = self.run_cli("export").stdout
        self.assertIn("secret=JBSWY3DPEHPK3PXP", exported)
        dump = Path(self.tmp.name) / "dump.txt"
        dump.write_text(exported)
        self.run_json("remove", self.run_json("list")["accounts"][0]["id"], "--yes")
        result = self.run_json("import", str(dump))
        self.assertEqual(len(result["added"]), 1)

    def test_import_flathack_json(self):
        dump = Path(self.tmp.name) / "accounts.json"
        dump.write_text(json.dumps([{"id": "x", "name": "me", "issuer": "Old", "secret": "JBSWY3DPEHPK3PXP",
                                     "digits": 6, "period": 30, "algorithm": "SHA1"}]))
        result = self.run_json("import", str(dump))
        self.assertEqual(result["added"][0]["issuer"], "Old")

    def test_rename(self):
        account_id = self.run_json("add", "--uri", self.URI)["added"][0]["id"]
        renamed = self.run_json("rename", account_id, "--issuer", "GitHub Work")
        self.assertEqual(renamed["issuer"], "GitHub Work")

    @unittest.skipUnless(subprocess.run(["which", "qrencode", "zbarimg"], capture_output=True).returncode == 0,
                         "qrencode/zbarimg not installed")
    def test_decode_qr_image(self):
        image = Path(self.tmp.name) / "qr.png"
        subprocess.run(["qrencode", "-o", str(image), "-s", "6", self.URI], check=True)
        preview = self.run_json("decode", str(image))
        self.assertEqual(preview["found"][0]["issuer"], "GitHub")
        self.assertNotIn("secret", preview["found"][0])
        self.assertEqual(self.run_json("list")["accounts"], [])  # preview never stores
        stored = self.run_json("decode", str(image), "--add")
        self.assertEqual(len(stored["added"]), 1)
        self.assertEqual(len(self.run_json("list")["accounts"]), 1)

    def test_decode_non_qr_image(self):
        image = Path(self.tmp.name) / "blank.png"
        subprocess.run(["convert", "-size", "64x64", "xc:white", str(image)], capture_output=True)
        if not image.exists():
            self.skipTest("imagemagick not installed")
        self.assertEqual(self.run_json("decode", str(image)), {"found": [], "invalid": []})


if __name__ == "__main__":
    unittest.main()
