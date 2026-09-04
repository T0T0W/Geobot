#!/usr/bin/env bash
set -euo pipefail

# Build validated v8 first, then change only the navigation-key layout.
bash rebuild_touchpad_v8.sh

cd android-hid-client

python3 - <<'PY'
from pathlib import Path

p = Path("app/src/main/java/me/arianb/usb_hid_client/input_views/Touchpad.kt")
s = p.read_text()

old = '''        // BIOS / UEFI navigation keys. These are normal one-shot HID key presses,
        // unlike the boot keys above which deliberately send a short burst.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp),
        ) {
            QuickNavKey("UP", 0x52, Modifier.weight(1f), onNavKey)
            QuickNavKey("ENTER", 0x28, Modifier.weight(1f), onNavKey)
            QuickNavKey("ESC", 0x29, Modifier.weight(1f), onNavKey)
            QuickNavKey("BACK", 0x2a, Modifier.weight(1f), onNavKey)
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp),
        ) {
            QuickNavKey("LEFT", 0x50, Modifier.weight(1f), onNavKey)
            QuickNavKey("DOWN", 0x51, Modifier.weight(1f), onNavKey)
            QuickNavKey("RIGHT", 0x4f, Modifier.weight(1f), onNavKey)
            QuickNavKey("TAB", 0x2b, Modifier.weight(1f), onNavKey)
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp),
        ) {
            QuickNavKey("HOME", 0x4a, Modifier.weight(1f), onNavKey)
            QuickNavKey("END", 0x4d, Modifier.weight(1f), onNavKey)
            QuickNavKey("PG UP", 0x4b, Modifier.weight(1f), onNavKey)
            QuickNavKey("PG DN", 0x4e, Modifier.weight(1f), onNavKey)
        }
'''

new = '''        // BIOS / UEFI navigation keys. Arrow keys use the same inverted-T layout
        // as a physical keyboard: UP centered above LEFT / DOWN / RIGHT.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp),
        ) {
            QuickNavSpacer(Modifier.weight(1f))
            QuickNavKey("UP", 0x52, Modifier.weight(1f), onNavKey)
            QuickNavSpacer(Modifier.weight(1f))
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp),
        ) {
            QuickNavKey("LEFT", 0x50, Modifier.weight(1f), onNavKey)
            QuickNavKey("DOWN", 0x51, Modifier.weight(1f), onNavKey)
            QuickNavKey("RIGHT", 0x4f, Modifier.weight(1f), onNavKey)
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp),
        ) {
            QuickNavKey("ENTER", 0x28, Modifier.weight(1f), onNavKey)
            QuickNavKey("ESC", 0x29, Modifier.weight(1f), onNavKey)
            QuickNavKey("BACK", 0x2a, Modifier.weight(1f), onNavKey)
            QuickNavKey("TAB", 0x2b, Modifier.weight(1f), onNavKey)
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp),
        ) {
            QuickNavKey("HOME", 0x4a, Modifier.weight(1f), onNavKey)
            QuickNavKey("END", 0x4d, Modifier.weight(1f), onNavKey)
            QuickNavKey("PG UP", 0x4b, Modifier.weight(1f), onNavKey)
            QuickNavKey("PG DN", 0x4e, Modifier.weight(1f), onNavKey)
        }
'''
if old not in s:
    raise SystemExit("v8 navigation rows not found")
s = s.replace(old, new)

marker = '''@Composable
private fun QuickNavKey(
'''
spacer = '''@Composable
private fun QuickNavSpacer(
    modifier: Modifier,
) {
    Surface(
        modifier = modifier.fillMaxHeight(),
        color = MaterialTheme.colorScheme.background,
    ) {}
}

@Composable
private fun QuickNavKey(
'''
if marker not in s:
    raise SystemExit("QuickNavKey marker not found")
s = s.replace(marker, spacer, 1)

p.write_text(s)

build = Path("app/build.gradle.kts")
b = build.read_text()
b = b.replace(
    'applicationId = "me.arianb.usb_hid_client.azerty.touchpad8"',
    'applicationId = "me.arianb.usb_hid_client.azerty.touchpad9"'
)
b = b.replace(
    'versionName = "v3.1.0-azerty-touchpad8"',
    'versionName = "v3.1.0-azerty-touchpad9"'
)
build.write_text(b)

strings = Path("app/src/main/res/values/strings.xml")
t = strings.read_text().replace(
    '<string name="app_name" translatable="false">USB HID Client AZERTY v8</string>',
    '<string name="app_name" translatable="false">USB HID Client AZERTY v9</string>'
)
strings.write_text(t)
PY

./gradlew --no-daemon :app:assembleDebug
cd ..
mkdir -p out
cp android-hid-client/app/build/outputs/apk/debug/app-debug.apk out/USB-HID-Client-AZERTY-Touchpad-v9.apk
