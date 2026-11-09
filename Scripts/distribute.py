#!/usr/bin/env python3
"""Developer ID release; credentials stay in the local notarytool keychain profile.

    ./build.sh --release
    Scripts/distribute.py --keychain-profile YOUR_PROFILE
"""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
IDENTIFIER = 'is.dsr.tapchat'
DEFAULT_PROFILE = 'TapChatNotary'


def run(args, timeout=120):
    result = subprocess.run([str(x) for x in args], capture_output=True, timeout=timeout)
    if result.returncode:
        # Signing tool output may contain certificate owner or private local paths.
        raise ValueError(f'{Path(str(args[0])).name} failed')
    return result


def developer_identity():
    result = run(['security', 'find-identity', '-v', '-p', 'codesigning'])
    matches = re.findall(r'\b([0-9A-F]{40})\s+"Developer ID Application:[^"\n]+"', result.stdout.decode())
    if len(matches) != 1:
        raise ValueError('Exactly one valid Developer ID Application identity is required')
    return matches[0]


def notarize(path, profile):
    result = subprocess.run(['xcrun', 'notarytool', 'submit', str(path), '--keychain-profile', profile,
                             '--wait', '--output-format', 'json'], capture_output=True, timeout=1800)
    # Apple output can contain account details; check the status only.
    try:
        report = json.loads(result.stdout)
    except (ValueError, TypeError):
        raise ValueError('Notarization failed; check the keychain profile privately') from None
    if result.returncode or not isinstance(report, dict) or report.get('status') != 'Accepted':
        raise ValueError('Apple did not accept the notarization submission; nothing was published')


def sign(path, identity, identifier=None, preserve=False):
    args = ['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp']
    if identifier:
        args += ['--identifier', identifier]
    if preserve:
        args += ['--preserve-metadata=identifier,entitlements']
    run(args + [path])


def sign_updater(app, identity):
    framework = app / 'Contents/Frameworks/Sparkle.framework'
    version = (framework / 'Versions/Current').resolve()
    # Keep Sparkle's identifiers; sign its nested code inside-out.
    for relative, identifier in [('Autoupdate', None),
                                 ('Updater.app', 'org.sparkle-project.Sparkle.Updater'),
                                 ('XPCServices/Downloader.xpc', 'org.sparkle-project.DownloaderService'),
                                 ('XPCServices/Installer.xpc', 'org.sparkle-project.InstallerLauncher')]:
        if not (version / relative).exists():
            raise ValueError('Updater framework has unexpected contents')
        sign(version / relative, identity, identifier, preserve=True)
    sign(framework, identity, 'org.sparkle-project.Sparkle')


def dmg(app, work, name):
    staging = work / 'image'
    staging.mkdir()
    run(['ditto', '--noqtn', app, staging / 'TapChat.app'])
    (staging / 'Applications').symlink_to('/Applications')
    image = work / name
    run(['hdiutil', 'create', '-format', 'UDZO', '-volname', 'TapChat', '-srcfolder', staging, image])
    return image


def distribute(app, output, profile):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != IDENTIFIER:
        raise ValueError('Unexpected app identity')
    version = info['CFBundleShortVersionString']
    name = f'TapChat-{version}-arm64.dmg'
    if (output / name).exists():
        raise ValueError('Release output already exists')
    identity = developer_identity()  # Fail before creating anything.
    with tempfile.TemporaryDirectory(prefix='tapchat-distribution-') as directory:
        work = Path(directory)
        staged = work / 'TapChat.app'
        run(['ditto', '--noqtn', app, staged])
        sign_updater(staged, identity)
        sign(staged, identity, IDENTIFIER)
        run(['codesign', '--verify', '--strict', '--deep', staged])
        archive = work / 'TapChat.zip'
        run(['ditto', '-c', '-k', '--keepParent', staged, archive])
        notarize(archive, profile)
        run(['xcrun', 'stapler', 'staple', staged])
        image = dmg(staged, work, name)
        sign(image, identity, f'{IDENTIFIER}.disk-image')
        notarize(image, profile)
        run(['xcrun', 'stapler', 'staple', image])
        run(['xcrun', 'stapler', 'validate', image])
        run(['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', image])
        run(['hdiutil', 'verify', image])
        # The final image, mounted: its app passes Gatekeeper.
        mounted = plistlib.loads(run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', image]).stdout)
        entry = next(x for x in mounted['system-entities'] if 'mount-point' in x)
        try:
            installed = Path(entry['mount-point']) / 'TapChat.app'
            run(['xcrun', 'stapler', 'validate', installed])
            run(['spctl', '--assess', '--type', 'execute', installed])
        finally:
            run(['hdiutil', 'detach', entry['dev-entry']])
        output.mkdir(parents=True, exist_ok=True)
        run(['ditto', image, output / name])
    print(f'Created {name}; Developer ID signed, notarized and stapled')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', type=Path, default=ROOT / 'build/Release/TapChat.app')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/Distribution')
    parser.add_argument('--keychain-profile', default=DEFAULT_PROFILE, help='Existing notarytool profile; never a password')
    args = parser.parse_args()
    try:
        distribute(args.app.resolve(), args.output.resolve(), args.keychain_profile)
    except (ValueError, OSError, StopIteration, subprocess.TimeoutExpired) as error:
        print(str(error) if isinstance(error, ValueError) else 'Distribution failed; nothing was published')
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
