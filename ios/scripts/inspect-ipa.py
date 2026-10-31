"""Read-only verification of the device IPA; no signing credentials required."""
import hashlib
import json
import plistlib
import struct
import sys
import zipfile
from pathlib import Path

target = Path(sys.argv[1])
with zipfile.ZipFile(target) as archive:
    assert archive.testzip() is None, 'Corrupt ZIP entry'
    app = 'Payload/SaldoLeve.app/'
    widget = app + 'PlugIns/SaldoLeveWidgets.appex/'
    main = plistlib.loads(archive.read(app + 'Info.plist'))
    extension = plistlib.loads(archive.read(widget + 'Info.plist'))
    assert main['CFBundleIdentifier'] == 'br.com.ilucascesar.saldoleve'
    assert main['CFBundleShortVersionString'] == (sys.argv[2] if len(sys.argv) > 2 else '2.2.0')
    assert extension['CFBundleIdentifier'] == main['CFBundleIdentifier'] + '.widgets'
    assert extension['CFBundleVersion'] == main['CFBundleVersion']
    assert extension['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension'
    assert 'iPhoneOS' in main['CFBundleSupportedPlatforms']
    assert 'iPhoneOS' in extension['CFBundleSupportedPlatforms']
    for prefix, name in [(app, 'SaldoLeve'), (widget, 'SaldoLeveWidgets')]:
        data = archive.read(prefix + name)
        magic, cpu, subtype, filetype, count, size, flags, reserved = struct.unpack_from('<8I', data)
        assert magic == 0xFEEDFACF and cpu == 0x100000C, 'Expected ARM64 Mach-O'
        position = 32
        platform = None
        for _ in range(count):
            command, length = struct.unpack_from('<2I', data, position)
            assert length >= 8
            if command == 0x32:
                platform = struct.unpack_from('<I', data, position + 8)[0]
            position += length
        assert platform == 2, 'Simulator or non-iOS executable in IPA'
        config = json.loads(archive.read(prefix + 'config.json'))
        assert config['serverURL'] == 'https://tools.ilucas.com.br/SaldoLeveApp/sistema.php'
    assert b'--ui-preview' not in archive.read(app + 'SaldoLeve'), 'Debug fixture enabled in Release'
    assert 'Cartão principal'.encode() not in archive.read(app + 'SaldoLeve'), 'Synthetic finance fixtures in Release'
    settings = plistlib.loads(archive.read(app + 'Settings.bundle/Root.plist'))
    assert settings['PreferenceSpecifiers']
    if tuple(map(int, main['CFBundleShortVersionString'].split('.'))) >= (2, 5, 2):
        assert main['UIApplicationSceneManifest']['UIApplicationSupportsMultipleScenes'] is False, 'Scene lifecycle is required by the iOS 27 SDK'
        for prefix in [app, widget]:
            info = plistlib.loads(archive.read(prefix + 'Info.plist'))
            assert int(info['DTSDKName'].removeprefix('iphoneos').split('.')[0]) >= 27, 'Portrait widgets require the iOS 27 SDK'
        assert b'systemExtraLargePortrait' in archive.read(widget + 'SaldoLeveWidgets'), 'Portrait widget family missing'
        if tuple(map(int, main['CFBundleShortVersionString'].split('.'))) >= (2, 5, 3):
            assert b'SaldoLevePortraitWidgets' in archive.read(widget + 'SaldoLeveWidgets'), 'Dedicated portrait widget missing'
    if tuple(map(int, main['CFBundleShortVersionString'].split('.'))) >= (2, 5, 0):
        assert main.get('NSContactsUsageDescription'), 'Contacts purpose is required'
        assert b'--preview-contacts' not in archive.read(app + 'SaldoLeve'), 'Contact fixtures in Release'
        assert b'--preview-birthdays' not in archive.read(app + 'SaldoLeve'), 'Birthday fixtures in Release'
    if tuple(map(int, main['CFBundleShortVersionString'].split('.'))) >= (2, 7, 0):
        assert main.get('NSLocationWhenInUseUsageDescription'), 'Location purpose is required'
        assert not main.get('NSLocationAlwaysAndWhenInUseUsageDescription'), 'Only "While Using" location is requested'
        shortcuts = [item.get('UIApplicationShortcutItemType') for item in main.get('UIApplicationShortcutItems', [])]
        assert len(shortcuts) == 3 and all(shortcuts), 'Home Screen quick actions missing'
        assert any(name.startswith(app + 'Metadata.appintents/') for name in archive.namelist()), 'Siri App Intents metadata missing'
    if tuple(map(int, main['CFBundleShortVersionString'].split('.'))) >= (2, 7, 1):
        assert main.get('NSRemindersFullAccessUsageDescription') and main.get('NSRemindersUsageDescription'), 'Reminders purpose is required'
        assert b'nativeRemindersImport' in archive.read(app + 'SaldoLeve'), 'Reminders import missing'
print(json.dumps({'file': str(target.resolve()), 'version': main['CFBundleShortVersionString'], 'build': main['CFBundleVersion'],
                  'app': main['CFBundleIdentifier'], 'widget': extension['CFBundleIdentifier'], 'platform': 'iPhoneOS/arm64',
                  'bytes': target.stat().st_size, 'sha256': hashlib.sha256(target.read_bytes()).hexdigest()}, ensure_ascii=False))
