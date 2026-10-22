"""Offline checks for SDK reuse, failure recovery and archive validation."""
import hashlib
import io
from pathlib import Path
import shutil
import unittest
from unittest.mock import patch
import zipfile

import sdk_setup as sdk


class SdkSetupTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(".zig-cache/export-sdk-tests").resolve()
        shutil.rmtree(self.root, ignore_errors=True)
        self.root.mkdir(parents=True)
        self.addCleanup(shutil.rmtree, self.root)

    def touch(self, name):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch()
        return path

    def test_completed_download_is_verified_and_not_downloaded_again(self):
        archive = self.touch("sdk.zip")
        archive.write_bytes(b"verified SDK")
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        with patch.object(sdk.urllib.request, "urlopen") as fetch:
            self.assertEqual(archive, sdk.download("https://example.invalid/sdk", archive, digest))
            fetch.assert_not_called()

    def test_bad_cached_download_is_removed(self):
        archive = self.touch("sdk.zip")
        with self.assertRaisesRegex(RuntimeError, "SHA-256 mismatch"):
            sdk.download("https://example.invalid/sdk", archive, "0" * 64)
        self.assertFalse(archive.exists())

    def test_truncated_download_never_becomes_a_cached_archive(self):
        response = io.BytesIO(b"partial")
        response.headers = {"Content-Length": "100"}
        archive = self.root / "sdk.zip"
        with patch.object(sdk.urllib.request, "urlopen", return_value=response):
            with self.assertRaisesRegex(RuntimeError, "Incomplete download"):
                sdk.download("https://example.invalid/sdk", archive)
        self.assertFalse(archive.exists())
        self.assertFalse(archive.with_suffix(".zip.partial").exists())

    def test_extraction_rejects_parent_traversal(self):
        archive = self.root / "bad.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("../escaped", "not allowed")
        with self.assertRaisesRegex(RuntimeError, "unsafe path"):
            sdk.unpack(archive, self.root / "extract")
        self.assertFalse((self.root / "escaped").exists())

    def test_invalid_explicit_emsdk_does_not_install_over_it(self):
        with patch.dict(sdk.os.environ, {}, clear=True), patch.object(sdk, "download") as fetch:
            with self.assertRaisesRegex(RuntimeError, "Configured emsdk"):
                sdk.web(self.root, str(self.root / "custom"))
            fetch.assert_not_called()

    def test_existing_web_sdk_and_dawn_port_are_reused(self):
        self.touch("installed/upstream/emscripten/emcc")
        self.touch("installed/upstream/emscripten/cache/ports/emdawnwebgpu/emdawnwebgpu_pkg/webgpu/include/webgpu/webgpu.h")
        with patch.object(sdk, "run") as run, patch.object(sdk, "download") as fetch:
            result = sdk.web(self.root, str(self.root / "installed"))
            self.assertEqual(str(self.root / "installed"), result["EMSDK"])
            run.assert_not_called()
            fetch.assert_not_called()

    def test_installed_android_packages_and_explicit_jdk_are_reused(self):
        for name in ("cmdline-tools/latest/bin/sdkmanager", "platforms/android-35/android.jar",
                     "build-tools/36.0.0/apksigner", "ndk/27.1.12297006/source.properties"):
            self.touch("android/" + name)
        self.touch("jdk/bin/javac")
        with patch.dict(sdk.os.environ, {"JAVA_HOME": str(self.root / "jdk")}, clear=True), \
             patch.object(sdk.platform, "machine", return_value="x86_64"), \
             patch.object(sdk.sys, "platform", "linux"), patch.object(sdk, "run") as run, \
             patch.object(sdk, "download") as fetch:
            result = sdk.android(self.root, str(self.root / "android"))
            self.assertEqual(str(self.root / "android"), result["ANDROID_HOME"])
            self.assertEqual(str(self.root / "jdk"), result["JAVA_HOME"])
            run.assert_not_called()
            fetch.assert_not_called()

    def test_another_api_level_installs_its_platform_and_ndk(self):
        for name in ("cmdline-tools/latest/bin/sdkmanager", "platforms/android-35/android.jar",
                     "build-tools/36.0.0/apksigner", "ndk/27.1.12297006/source.properties"):
            self.touch("android/" + name)
        self.touch("jdk/bin/javac")

        def install(argv, **_kwargs):
            for name in ("platforms/android-36/android.jar", "ndk/30.0.16248370/source.properties"):
                self.touch("android/" + name)

        with patch.dict(sdk.os.environ, {"JAVA_HOME": str(self.root / "jdk")}, clear=True), \
             patch.object(sdk.platform, "machine", return_value="x86_64"), \
             patch.object(sdk.sys, "platform", "linux"), patch.object(sdk, "run", side_effect=install) as run, \
             patch.object(sdk.subprocess, "run"):
            sdk.android(self.root, str(self.root / "android"), 36, "30.0.16248370")
            self.assertIn("platforms;android-36", run.call_args.args[0])
            self.assertIn("ndk;30.0.16248370", run.call_args.args[0])

    def test_missing_dawn_port_is_prepared_before_compilation(self):
        self.touch("installed/upstream/emscripten/emcc")
        with patch.object(sdk, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "emdawnwebgpu"):
                sdk.web(self.root, str(self.root / "installed"))
            self.assertEqual("emdawnwebgpu", run.call_args.args[0][-1])

    def test_missing_jdk_downloads_pinned_temurin_and_reuses_it(self):
        def extract(_archive, stage):
            (stage / "jdk-17/bin").mkdir(parents=True)
            (stage / "jdk-17/bin/javac").touch()

        with patch.dict(sdk.os.environ, {}, clear=True), patch.object(sdk.shutil, "which", return_value=None), \
             patch.object(sdk.sys, "platform", "linux"), patch.object(sdk.platform, "machine", return_value="x86_64"), \
             patch.object(sdk.urllib.request, "urlopen", return_value=io.BytesIO(b"0" * 64 + b" archive.tar.gz")), \
             patch.object(sdk, "download", return_value=self.root / "jdk.tar.gz") as fetch, \
             patch.object(sdk, "unpack", side_effect=extract):
            home = sdk.java_home(self.root)
            self.assertTrue((home / "bin/javac").exists())
            self.assertIn("jdk-17.0.16%2B8", fetch.call_args.args[0])
            self.assertEqual(home, sdk.java_home(self.root))
            fetch.assert_called_once()


if __name__ == "__main__":
    unittest.main()
