#!/usr/bin/env bash
set -euo pipefail

# Build the validated v3 base first (AZERTY + relative touchpad + long press).
bash rebuild_touchpad_v3.sh

cd android-hid-client
MOUSE_FILE="app/src/main/java/me/arianb/usb_hid_client/input_views/touch_input_handlers/MouseInputHandler.kt"

python3 - <<'PY'
from pathlib import Path

p = Path("app/src/main/java/me/arianb/usb_hid_client/input_views/touch_input_handlers/MouseInputHandler.kt")
s = p.read_text()

old = '''        val secondTap = lastTapCoordinates?.let { previousTap ->
            event.eventTime - lastTapUpTime in 0..ViewConfiguration.getDoubleTapTimeout().toLong() &&
                distance(point, previousTap) <= DOUBLE_TAP_SLOP_PX
        } ?: false
'''
new = '''        // Use a touchpad-friendly double-tap detector rather than Android's relatively tight
        // generic double-tap limits. On a phone-sized touch surface the finger often lands a bit
        // farther away on tap #2, especially when the second tap is intentionally held for drag.
        val secondTap = lastTapCoordinates?.let { previousTap ->
            val elapsedSinceFirstTap = event.eventTime - lastTapUpTime
            elapsedSinceFirstTap in 0..DOUBLE_TAP_TIMEOUT_MS &&
                distance(point, previousTap) <= DOUBLE_TAP_SLOP_PX
        } ?: false
'''
if old not in s:
    raise SystemExit("double-tap detector block not found")
s = s.replace(old, new)

old_constants = '''    private companion object {
        const val MOVE_SLOP_PX = 14f
        const val DOUBLE_TAP_SLOP_PX = 90f
        const val TAP_TIMEOUT_MS = 300L
        const val LONG_PRESS_TIMEOUT_MS = 400L
    }
'''
new_constants = '''    private companion object {
        const val MOVE_SLOP_PX = 14f
        // More forgiving than the generic Android double-tap detector because this surface is a
        // relative touchpad, not a button. The second tap may legitimately land somewhat away
        // from the first while still being the user's intended tap-and-hold drag gesture.
        const val DOUBLE_TAP_SLOP_PX = 240f
        const val DOUBLE_TAP_TIMEOUT_MS = 550L
        const val TAP_TIMEOUT_MS = 300L
        const val LONG_PRESS_TIMEOUT_MS = 400L
    }
'''
if old_constants not in s:
    raise SystemExit("constant block not found")
s = s.replace(old_constants, new_constants)
p.write_text(s)

build = Path("app/build.gradle.kts")
s = build.read_text()
s = s.replace(
    'applicationId = "me.arianb.usb_hid_client.azerty.touchpad3"',
    'applicationId = "me.arianb.usb_hid_client.azerty.touchpad4"'
)
s = s.replace(
    'versionName = "v3.1.0-azerty-touchpad3"',
    'versionName = "v3.1.0-azerty-touchpad4"'
)
build.write_text(s)

strings = Path("app/src/main/res/values/strings.xml")
s = strings.read_text().replace(
    '<string name="app_name" translatable="false">USB HID Client AZERTY v3</string>',
    '<string name="app_name" translatable="false">USB HID Client AZERTY v4</string>'
)
strings.write_text(s)
PY

./gradlew --no-daemon :app:assembleDebug
cd ..
mkdir -p out
cp android-hid-client/app/build/outputs/apk/debug/app-debug.apk out/USB-HID-Client-AZERTY-Touchpad-v4.apk
