#!/usr/bin/env bash
set -euo pipefail

# Build the validated v4 base first.
bash rebuild_touchpad_v4.sh

cd android-hid-client

python3 - <<'PY'
from pathlib import Path

p = Path("app/src/main/java/me/arianb/usb_hid_client/input_views/touch_input_handlers/MouseInputHandler.kt")
s = p.read_text()

old = '''        // Use a touchpad-friendly double-tap detector rather than Android's relatively tight
        // generic double-tap limits. On a phone-sized touch surface the finger often lands a bit
        // farther away on tap #2, especially when the second tap is intentionally held for drag.
        val secondTap = lastTapCoordinates?.let { previousTap ->
            val elapsedSinceFirstTap = event.eventTime - lastTapUpTime
            elapsedSinceFirstTap in 0..DOUBLE_TAP_TIMEOUT_MS &&
                distance(point, previousTap) <= DOUBLE_TAP_SLOP_PX
        } ?: false
'''
new = '''        // This is a RELATIVE touchpad: the absolute landing position of tap #2 is irrelevant.
        // Exact requested gesture: quick tap (DOWN/UP), then the very next DOWN within the
        // double-tap window immediately becomes a held left button. No long-press delay and no
        // spatial matching are involved on the second DOWN.
        val elapsedSinceFirstTap = event.eventTime - lastTapUpTime
        val secondTap = lastTapUpTime != Long.MIN_VALUE &&
            elapsedSinceFirstTap in 0..DOUBLE_TAP_TIMEOUT_MS
'''
if old not in s:
    raise SystemExit("v4 second-tap detector block not found")
s = s.replace(old, new)

# Coordinates are no longer part of double-tap recognition. Keep the old field assignments
# harmlessly for now to minimize changes to the proven single-tap/long-press state machine.
old_constants = '''        const val MOVE_SLOP_PX = 14f
        // More forgiving than the generic Android double-tap detector because this surface is a
        // relative touchpad, not a button. The second tap may legitimately land somewhat away
        // from the first while still being the user's intended tap-and-hold drag gesture.
        const val DOUBLE_TAP_SLOP_PX = 240f
        const val DOUBLE_TAP_TIMEOUT_MS = 550L
        const val TAP_TIMEOUT_MS = 300L
        const val LONG_PRESS_TIMEOUT_MS = 400L
'''
new_constants = '''        const val MOVE_SLOP_PX = 14f
        // Second-tap hold is deliberately time-only because this is a relative touch surface.
        const val DOUBLE_TAP_TIMEOUT_MS = 550L
        const val TAP_TIMEOUT_MS = 300L
        const val LONG_PRESS_TIMEOUT_MS = 400L
'''
if old_constants not in s:
    raise SystemExit("v4 constants block not found")
s = s.replace(old_constants, new_constants)

build = Path("app/build.gradle.kts")
b = build.read_text()
b = b.replace(
    'applicationId = "me.arianb.usb_hid_client.azerty.touchpad4"',
    'applicationId = "me.arianb.usb_hid_client.azerty.touchpad5"'
)
b = b.replace(
    'versionName = "v3.1.0-azerty-touchpad4"',
    'versionName = "v3.1.0-azerty-touchpad5"'
)
build.write_text(b)

strings = Path("app/src/main/res/values/strings.xml")
t = strings.read_text().replace(
    '<string name="app_name" translatable="false">USB HID Client AZERTY v4</string>',
    '<string name="app_name" translatable="false">USB HID Client AZERTY v5</string>'
)
strings.write_text(t)
PY

./gradlew --no-daemon :app:assembleDebug
cd ..
mkdir -p out
cp android-hid-client/app/build/outputs/apk/debug/app-debug.apk out/USB-HID-Client-AZERTY-Touchpad-v5.apk
