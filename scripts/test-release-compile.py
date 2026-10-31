#!/usr/bin/env python3
"""Compile the exact Android release command using an ephemeral CI-only key.

The fixture APK is deleted and never published. The production publisher still
requires its protected permanent certificate and verifies the resulting APK.
"""
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    config = json.loads((ROOT / 'android-release.json').read_text())
    apk = ROOT / config['apk']
    with tempfile.TemporaryDirectory(prefix='haven-ci-release-', dir=os.environ.get('RUNNER_TEMP')) as directory:
        key = Path(directory) / 'fixture.jks'
        password = secrets.token_urlsafe(32)
        env = {**os.environ, 'CI_FIXTURE_PASSWORD': password,
               'HAVEN_KEYSTORE': str(key), 'HAVEN_KEY_ALIAS': config['key_alias'],
               'HAVEN_STORE_PASSWORD': password, 'HAVEN_KEY_PASSWORD': password}
        subprocess.run(['keytool', '-genkeypair', '-keystore', str(key),
                        '-storepass:env', 'CI_FIXTURE_PASSWORD', '-keypass:env', 'CI_FIXTURE_PASSWORD',
                        '-alias', config['key_alias'], '-keyalg', 'RSA', '-keysize', '2048',
                        '-validity', '1', '-dname', 'CN=Haven CI fixture only'], env=env, check=True)
        key.chmod(0o600)
        try:
            subprocess.run(config['build'], cwd=ROOT / config['project_dir'], env=env, check=True)
            if not apk.is_file() or apk.stat().st_size < 1_000_000:
                raise RuntimeError('The release compile did not produce an APK')
            print('Exact Android release command compiled; CI-only fixture APK will be deleted')
        finally:
            apk.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
