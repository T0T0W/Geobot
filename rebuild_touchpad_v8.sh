#!/usr/bin/env bash
set -euo pipefail

# Build the validated v7 base first: AZERTY, clean touchpad, boot-key burst buttons.
bash rebuild_touchpad_v7.sh

cd android-hid-client

python3 - <<'PY'
from pathlib import Path

p = Path("app/src/main/java/me/arianb/usb_hid_client/input_views/Touchpad.kt")
s = p.read_text()

old_call = '''            TouchpadForMouse(
                mouseInputHandler = mouseInputHandler,
                onBootKey = { key -> mainViewModel.sendBootKeyBurst(key) },
            )
'''
new_call = '''            TouchpadForMouse(
                mouseInputHandler = mouseInputHandler,
                onBootKey = { key -> mainViewModel.sendBootKeyBurst(key) },
                onNavKey = { key -> mainViewModel.addStandardKey(0, key) },
            )
'''
if old_call not in s:
    raise SystemExit("TouchpadForMouse call site not found")
s = s.replace(old_call, new_call)

old_sig = '''private fun TouchpadForMouse(
    mouseInputHandler: MouseInputHandler,
    onBootKey: (Byte) -> Unit,
) {
'''
new_sig = '''private fun TouchpadForMouse(
    mouseInputHandler: MouseInputHandler,
    onBootKey: (Byte) -> Unit,
    onNavKey: (Byte) -> Unit,
) {
'''
if old_sig not in s:
    raise SystemExit("TouchpadForMouse signature not found")
s = s.replace(old_sig, new_sig)

needle = '''        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp),
        ) {
            QuickBootKey("F8", 0x41, Modifier.weight(1f), onBootKey)
            QuickBootKey("F10", 0x43, Modifier.weight(1f), onBootKey)
            QuickBootKey("F11", 0x44, Modifier.weight(1f), onBootKey)
        }
        TouchpadContactSurfaceArea(
'''
replacement = '''        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp),
        ) {
            QuickBootKey("F8", 0x41, Modifier.weight(1f), onBootKey)
            QuickBootKey("F10", 0x43, Modifier.weight(1f), onBootKey)
            QuickBootKey("F11", 0x44, Modifier.weight(1f), onBootKey)
        }

        // BIOS / UEFI navigation keys. These are normal one-shot HID key presses,
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

        TouchpadContactSurfaceArea(
'''
if needle not in s:
    raise SystemExit("boot rows insertion point not found")
s = s.replace(needle, replacement)

marker = '''@Composable
private fun TouchpadContactSurfaceArea(
'''
nav_composable = '''@Composable
private fun QuickNavKey(
    label: String,
    hidKey: Int,
    modifier: Modifier,
    onNavKey: (Byte) -> Unit,
) {
    Surface(
        onClick = { onNavKey(hidKey.toByte()) },
        modifier = modifier.fillMaxHeight(),
        color = MaterialTheme.colorScheme.background,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary),
    ) {
        Text(
            text = label,
            modifier = Modifier.wrapContentSize(Alignment.Center),
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun TouchpadContactSurfaceArea(
'''
if marker not in s:
    raise SystemExit("TouchpadContactSurfaceArea marker not found")
s = s.replace(marker, nav_composable, 1)
p.write_text(s)

build = Path("app/build.gradle.kts")
b = build.read_text()
b = b.replace(
    'applicationId = "me.arianb.usb_hid_client.azerty.touchpad7"',
    'applicationId = "me.arianb.usb_hid_client.azerty.touchpad8"'
)
b = b.replace(
    'versionName = "v3.1.0-azerty-touchpad7"',
    'versionName = "v3.1.0-azerty-touchpad8"'
)
build.write_text(b)

strings = Path("app/src/main/res/values/strings.xml")
t = strings.read_text().replace(
    '<string name="app_name" translatable="false">USB HID Client AZERTY v7</string>',
    '<string name="app_name" translatable="false">USB HID Client AZERTY v8</string>'
)
strings.write_text(t)
PY

./gradlew --no-daemon :app:assembleDebug
cd ..
mkdir -p out
cp android-hid-client/app/build/outputs/apk/debug/app-debug.apk out/USB-HID-Client-AZERTY-Touchpad-v8.apk
