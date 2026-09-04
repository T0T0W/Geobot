#!/usr/bin/env bash
set -euo pipefail

rm -rf android-hid-client out
git clone --depth 1 --branch v3.1.0 https://github.com/Arian04/android-hid-client.git android-hid-client
cd android-hid-client

AZERTY_FILE="app/src/main/java/me/arianb/usb_hid_client/hid_utils/FrenchAzertyTranslation.kt"
MOUSE_FILE="app/src/main/java/me/arianb/usb_hid_client/input_views/touch_input_handlers/MouseInputHandler.kt"
INPUT_FILE="app/src/main/java/me/arianb/usb_hid_client/input_views/MyInputConnection.kt"

cat > "$AZERTY_FILE" <<'KOT'
package me.arianb.usb_hid_client.hid_utils

import timber.log.Timber
import kotlin.experimental.or

/**
 * Character-to-HID translation for a receiving computer configured with the
 * standard French AZERTY keyboard layout.
 *
 * HID keyboard usages identify physical key positions. Therefore text that is
 * intended to appear as a specific character on an AZERTY host must be mapped
 * to the physical key that produces that character on a French keyboard.
 */
object FrenchAzertyTranslation {
    private const val LEFT_SHIFT: Byte = 0x02
    private const val RIGHT_ALT: Byte = 0x40 // AltGr

    private data class Stroke(val modifier: Byte, val usage: Byte)

    private fun stroke(usage: Int, modifier: Int = 0) =
        Stroke(modifier.toByte(), usage.toByte())

    private val chars: Map<Char, Stroke> = buildMap {
        // Letters: values are USB HID usages for the physical AZERTY positions.
        put('a', stroke(0x14))
        put('b', stroke(0x05))
        put('c', stroke(0x06))
        put('d', stroke(0x07))
        put('e', stroke(0x08))
        put('f', stroke(0x09))
        put('g', stroke(0x0a))
        put('h', stroke(0x0b))
        put('i', stroke(0x0c))
        put('j', stroke(0x0d))
        put('k', stroke(0x0e))
        put('l', stroke(0x0f))
        put('m', stroke(0x33))
        put('n', stroke(0x11))
        put('o', stroke(0x12))
        put('p', stroke(0x13))
        put('q', stroke(0x04))
        put('r', stroke(0x15))
        put('s', stroke(0x16))
        put('t', stroke(0x17))
        put('u', stroke(0x18))
        put('v', stroke(0x19))
        put('w', stroke(0x1d))
        put('x', stroke(0x1b))
        put('y', stroke(0x1c))
        put('z', stroke(0x1a))

        // On French AZERTY, digits are Shift + the number-row physical key.
        put('1', stroke(0x1e, LEFT_SHIFT.toInt()))
        put('2', stroke(0x1f, LEFT_SHIFT.toInt()))
        put('3', stroke(0x20, LEFT_SHIFT.toInt()))
        put('4', stroke(0x21, LEFT_SHIFT.toInt()))
        put('5', stroke(0x22, LEFT_SHIFT.toInt()))
        put('6', stroke(0x23, LEFT_SHIFT.toInt()))
        put('7', stroke(0x24, LEFT_SHIFT.toInt()))
        put('8', stroke(0x25, LEFT_SHIFT.toInt()))
        put('9', stroke(0x26, LEFT_SHIFT.toInt()))
        put('0', stroke(0x27, LEFT_SHIFT.toInt()))

        // Unshifted French AZERTY symbols and accented characters.
        put('&', stroke(0x1e))
        put('é', stroke(0x1f))
        put('"', stroke(0x20))
        put('\'', stroke(0x21))
        put('(', stroke(0x22))
        put('-', stroke(0x23))
        put('è', stroke(0x24))
        put('_', stroke(0x25))
        put('ç', stroke(0x26))
        put('à', stroke(0x27))
        put(')', stroke(0x2d))
        put('=', stroke(0x2e))
        put('²', stroke(0x35))
        put('$', stroke(0x30))
        put('ù', stroke(0x34))
        put('*', stroke(0x31))
        put(',', stroke(0x10))
        put(';', stroke(0x36))
        put(':', stroke(0x37))
        put('!', stroke(0x38))
        put('<', stroke(0x64))

        // Shifted French AZERTY symbols.
        put('°', stroke(0x2d, LEFT_SHIFT.toInt()))
        put('+', stroke(0x2e, LEFT_SHIFT.toInt()))
        put('£', stroke(0x30, LEFT_SHIFT.toInt()))
        put('%', stroke(0x34, LEFT_SHIFT.toInt()))
        put('µ', stroke(0x31, LEFT_SHIFT.toInt()))
        put('?', stroke(0x10, LEFT_SHIFT.toInt()))
        put('.', stroke(0x36, LEFT_SHIFT.toInt()))
        put('/', stroke(0x37, LEFT_SHIFT.toInt()))
        put('§', stroke(0x38, LEFT_SHIFT.toInt()))
        put('>', stroke(0x64, LEFT_SHIFT.toInt()))

        // AltGr characters. Using AltGr for ^ avoids the dead-key behavior of the ^ key.
        put('~', stroke(0x1f, RIGHT_ALT.toInt()))
        put('#', stroke(0x20, RIGHT_ALT.toInt()))
        put('{', stroke(0x21, RIGHT_ALT.toInt()))
        put('[', stroke(0x22, RIGHT_ALT.toInt()))
        put('|', stroke(0x23, RIGHT_ALT.toInt()))
        put('`', stroke(0x24, RIGHT_ALT.toInt()))
        put('\\', stroke(0x25, RIGHT_ALT.toInt()))
        put('^', stroke(0x26, RIGHT_ALT.toInt()))
        put('@', stroke(0x27, RIGHT_ALT.toInt()))
        put(']', stroke(0x2d, RIGHT_ALT.toInt()))
        put('}', stroke(0x2e, RIGHT_ALT.toInt()))
        put('€', stroke(0x08, RIGHT_ALT.toInt()))

        put(' ', stroke(0x2c))
        put('\t', stroke(0x2b))
        put('\n', stroke(0x28))
        put('\r', stroke(0x28))
    }

    fun keyCharToScanCodes(key: Char): Pair<Byte, Byte>? {
        val lowercase = key.lowercaseChar()
        val base = chars[key] ?: chars[lowercase]
        if (base == null) {
            Timber.e("AZERTY key '$key' could not be converted to an HID code")
            return null
        }

        val modifier = if (key.isUpperCase() && key.lowercaseChar() != key) {
            base.modifier or LEFT_SHIFT
        } else {
            base.modifier
        }
        return Pair(modifier, base.usage)
    }
}
KOT

cat > "$MOUSE_FILE" <<'KOT'
package me.arianb.usb_hid_client.input_views.touch_input_handlers

import android.view.MotionEvent
import android.view.ViewConfiguration
import me.arianb.usb_hid_client.report_senders.pointer_device_senders.MouseSender
import me.arianb.usb_hid_client.report_senders.pointer_device_senders.PointerDeviceSender
import kotlin.math.hypot
import kotlin.math.roundToInt

/**
 * Laptop/RDP-style relative touchpad input.
 *
 * Gestures:
 * - one-finger motion: relative pointer movement
 * - one-finger tap: left click
 * - double tap: double left click
 * - double tap then drag: hold left button and drag
 * - two-finger tap: right click
 */
class MouseInputHandler(
    private val mouseSender: MouseSender
) : PointerDeviceInputHandler() {
    private data class Coordinates(val x: Float, val y: Float)

    private var previousCoordinates: Coordinates? = null
    private var downCoordinates: Coordinates? = null
    private var twoFingerStartCoordinates: Coordinates? = null
    private var currentTouchpadButtonState = PointerDeviceSender.TouchpadButtonState(false, false)

    private var gestureDownTime: Long = 0
    private var lastTapUpTime: Long = Long.MIN_VALUE
    private var lastTapCoordinates: Coordinates? = null
    private var gestureMoved = false
    private var hadTwoFingers = false
    private var twoFingerMoved = false
    private var dragActive = false

    fun handleTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val point = Coordinates(event.getX(0), event.getY(0))
                previousCoordinates = point
                downCoordinates = point
                twoFingerStartCoordinates = null
                gestureDownTime = event.eventTime
                gestureMoved = false
                hadTwoFingers = false
                twoFingerMoved = false

                val isSecondTap = lastTapCoordinates?.let { last ->
                    event.eventTime - lastTapUpTime in 0..ViewConfiguration.getDoubleTapTimeout().toLong() &&
                        distance(point, last) <= DOUBLE_TAP_SLOP_PX
                } ?: false

                if (isSecondTap) {
                    // Start the second click immediately. If the finger moves, this naturally
                    // becomes click-and-drag; if it is released, it completes a double-click.
                    dragActive = true
                    lastTapUpTime = Long.MIN_VALUE
                    lastTapCoordinates = null
                    setButtons(left = true, right = false)
                }
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                hadTwoFingers = true
                twoFingerStartCoordinates = centroidOfFirstTwo(event)
                previousCoordinates = null

                // A second finger changes the gesture into a right-click gesture, so cancel a
                // pending double-tap drag if there was one.
                if (dragActive) {
                    dragActive = false
                    setButtons(left = false, right = false)
                }
            }

            MotionEvent.ACTION_MOVE -> {
                if (event.pointerCount >= 2 || hadTwoFingers) {
                    if (event.pointerCount >= 2) {
                        val centroid = centroidOfFirstTwo(event)
                        val start = twoFingerStartCoordinates
                        if (start != null && distance(centroid, start) > TWO_FINGER_TAP_SLOP_PX) {
                            twoFingerMoved = true
                        }
                    }
                    previousCoordinates = null
                    return true
                }

                val point = Coordinates(event.getX(0), event.getY(0))
                val down = downCoordinates
                if (down != null && distance(point, down) > MOVE_SLOP_PX) {
                    gestureMoved = true
                }

                previousCoordinates?.let { previous ->
                    sendMovement(point.x - previous.x, point.y - previous.y)
                }
                previousCoordinates = point
            }

            MotionEvent.ACTION_POINTER_UP -> {
                hadTwoFingers = true
                previousCoordinates = null
            }

            MotionEvent.ACTION_UP -> {
                val duration = event.eventTime - gestureDownTime
                val upPoint = Coordinates(event.getX(0), event.getY(0))

                if (hadTwoFingers) {
                    if (!twoFingerMoved && duration <= TWO_FINGER_TAP_TIMEOUT_MS) {
                        click(left = false, right = true)
                    }
                    cancelGestureState()
                    return true
                }

                if (dragActive) {
                    // Releasing the second tap either finishes a normal double-click or a drag.
                    dragActive = false
                    setButtons(left = false, right = false)
                    cancelGestureState(clearLastTap = true)
                    return true
                }

                if (!gestureMoved && duration <= TAP_TIMEOUT_MS) {
                    click(left = true, right = false)
                    lastTapUpTime = event.eventTime
                    lastTapCoordinates = upPoint
                } else {
                    lastTapUpTime = Long.MIN_VALUE
                    lastTapCoordinates = null
                }

                previousCoordinates = null
                downCoordinates = null
            }

            MotionEvent.ACTION_CANCEL -> {
                if (dragActive || currentTouchpadButtonState.isLeftButtonPressed || currentTouchpadButtonState.isRightButtonPressed) {
                    setButtons(left = false, right = false)
                }
                cancelGestureState(clearLastTap = true)
            }
        }
        return true
    }

    /** Legacy helper kept for existing call sites/tests. */
    fun sendAbsoluteMouseMovement(
        absoluteX: Short,
        absoluteY: Short,
        touchpadButtonState: PointerDeviceSender.TouchpadButtonState? = null,
    ) {
        touchpadButtonState?.let { currentTouchpadButtonState = it }
        val point = Coordinates(absoluteX.toFloat(), absoluteY.toFloat())
        previousCoordinates?.let { previous ->
            sendMovement(point.x - previous.x, point.y - previous.y)
        }
        previousCoordinates = point
    }

    fun sendRelativeMouseMovement(
        relativeX: Byte,
        relativeY: Byte,
        touchpadButtonState: PointerDeviceSender.TouchpadButtonState?
    ) {
        touchpadButtonState?.let { currentTouchpadButtonState = it }
        mouseSender.sendMouseReport(relativeX, relativeY, currentTouchpadButtonState)
    }

    fun sendButtonStateUpdate(touchpadButtonState: PointerDeviceSender.TouchpadButtonState) {
        currentTouchpadButtonState = touchpadButtonState
        mouseSender.sendMouseReport(0, 0, currentTouchpadButtonState)
    }

    private fun sendMovement(deltaX: Float, deltaY: Float) {
        var remainingX = deltaX.roundToInt()
        var remainingY = deltaY.roundToInt()

        // HID relative X/Y fields are signed bytes. Split large deltas instead of allowing
        // Byte overflow, which otherwise produces sudden jumps in the opposite direction.
        while (remainingX != 0 || remainingY != 0) {
            val x = remainingX.coerceIn(-127, 127)
            val y = remainingY.coerceIn(-127, 127)
            mouseSender.sendMouseReport(x.toByte(), y.toByte(), currentTouchpadButtonState)
            remainingX -= x
            remainingY -= y
        }
    }

    private fun click(left: Boolean, right: Boolean) {
        setButtons(left, right)
        setButtons(left = false, right = false)
    }

    private fun setButtons(left: Boolean, right: Boolean) {
        currentTouchpadButtonState = PointerDeviceSender.TouchpadButtonState(left, right)
        mouseSender.sendMouseReport(0, 0, currentTouchpadButtonState)
    }

    private fun centroidOfFirstTwo(event: MotionEvent): Coordinates = Coordinates(
        (event.getX(0) + event.getX(1)) / 2f,
        (event.getY(0) + event.getY(1)) / 2f,
    )

    private fun distance(a: Coordinates, b: Coordinates): Float =
        hypot(a.x - b.x, a.y - b.y)

    private fun cancelGestureState(clearLastTap: Boolean = false) {
        previousCoordinates = null
        downCoordinates = null
        twoFingerStartCoordinates = null
        gestureMoved = false
        hadTwoFingers = false
        twoFingerMoved = false
        dragActive = false
        if (clearLastTap) {
            lastTapUpTime = Long.MIN_VALUE
            lastTapCoordinates = null
        }
    }

    private companion object {
        const val MOVE_SLOP_PX = 14f
        const val DOUBLE_TAP_SLOP_PX = 90f
        const val TWO_FINGER_TAP_SLOP_PX = 28f
        const val TAP_TIMEOUT_MS = 300L
        const val TWO_FINGER_TAP_TIMEOUT_MS = 500L
    }
}
KOT

cat > "$INPUT_FILE" <<'KOT'
package me.arianb.usb_hid_client.input_views

import android.os.Build
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.TextAttribute
import me.arianb.usb_hid_client.hid_utils.FrenchAzertyTranslation
import me.arianb.usb_hid_client.hid_utils.KeyCodeTranslation
import me.arianb.usb_hid_client.report_senders.KeySender
import timber.log.Timber

class MyInputConnection(
    private val keySender: KeySender,
    targetView: View,
    fullEditor: Boolean
) : BaseInputConnection(targetView, fullEditor) {
    override fun sendKeyEvent(event: KeyEvent?): Boolean {
        if (event == null) {
            Timber.w("input connection received null KeyEvent")
            return false
        }
        Timber.d("input connection received KeyEvent: %s", event.toString())

        val keyCode = event.keyCode
        if (event.action != KeyEvent.ACTION_DOWN || keyCode == KeyEvent.KEYCODE_UNKNOWN) {
            return false
        }

        if (KeyEvent.isModifierKey(keyCode)) {
            return true
        }

        // Software keyboards produce semantic characters. Translate those characters to the
        // physical USB HID key that generates the same character on a French AZERTY host.
        val device = event.device
        val isVirtualInput = device == null || device.isVirtual || event.deviceId == KeyCharacterMap.VIRTUAL_KEYBOARD
        if (isVirtualInput) {
            val unicode = event.unicodeChar
            if (unicode > 0) {
                FrenchAzertyTranslation.keyCharToScanCodes(unicode.toChar())?.let { scanCodes ->
                    keySender.addStandardKey(scanCodes.first, scanCodes.second)
                    return true
                }
            }
        }

        // Keep physical keyboards location-based. A physical key should be relayed to the same
        // physical HID position, independent of the Android-side printed layout.
        if (!isVirtualInput) {
            val rawKeyCode = getRawKeyCode(event, keyCode)
            if (rawKeyCode != null && rawKeyCode != KeyEvent.KEYCODE_UNKNOWN) {
                val rawScanCode = KeyCodeTranslation.keyCodeToScanCode(rawKeyCode)
                if (rawScanCode != null) {
                    val modifiers = KeyCodeTranslation.getModifiersScanCode(event)
                    keySender.addStandardKey(modifiers, rawScanCode)
                    return true
                }
            }
        }

        // Special/fallback handling for non-printable keys.
        KeyCodeTranslation.problematicKeyEventKeys[keyCode]?.let { scanCodes ->
            keySender.addStandardKey(scanCodes.first, scanCodes.second)
            return true
        }

        val keyScanCode = KeyCodeTranslation.keyCodeToScanCode(keyCode)
        if (keyScanCode == null) {
            Timber.w("Unsupported keycode '${KeyEvent.keyCodeToString(keyCode)}' ($keyCode).")
            return false
        }

        if (KeyCodeTranslation.isMediaKey(keyCode)) {
            keySender.addMediaKey(keyScanCode)
        } else {
            val modifiers = KeyCodeTranslation.getModifiersScanCode(event)
            keySender.addStandardKey(modifiers, keyScanCode)
        }
        return true
    }

    private fun getRawKeyCode(event: KeyEvent, keyCode: Int): Int? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return event.device?.getKeyCodeForKeyLocation(keyCode)
        }
        return null
    }

    override fun commitText(text: CharSequence, newCursorPosition: Int, textAttribute: TextAttribute?): Boolean {
        // Some IMEs commit text instead of generating KeyEvents. Relay committed printable text
        // through the AZERTY translator as well.
        for (char in text) {
            val scanCodes = FrenchAzertyTranslation.keyCharToScanCodes(char) ?: return false
            keySender.addStandardKey(scanCodes.first, scanCodes.second)
        }
        return true
    }
}
KOT

python3 - <<'PY'
from pathlib import Path
import re

manual = Path("app/src/main/java/me/arianb/usb_hid_client/input_views/ManualInput.kt")
s = manual.read_text()
s = s.replace(
    "import me.arianb.usb_hid_client.hid_utils.KeyCodeTranslation\n",
    "import me.arianb.usb_hid_client.hid_utils.FrenchAzertyTranslation\n"
)
s = s.replace("KeyCodeTranslation.keyCharToScanCodes(char)", "FrenchAzertyTranslation.keyCharToScanCodes(char)")
manual.write_text(s)

touchpad = Path("app/src/main/java/me/arianb/usb_hid_client/input_views/Touchpad.kt")
s = touchpad.read_text()
pattern = re.compile(r"@Composable\nprivate fun TouchpadForMouse\(.*?\n\}\n\n@Composable\nprivate fun TouchpadContactSurfaceArea", re.S)
replacement = '''@Composable
private fun TouchpadForMouse(
    mouseInputHandler: MouseInputHandler
) {
    // Full-size laptop/RDP-style touch surface. Mouse buttons are gesture-driven:
    // tap = left click, two-finger tap = right click, double-tap + drag = drag.
    TouchpadContactSurfaceArea(
        modifier = Modifier.fillMaxSize(),
        onTouchEvent = { motionEvent ->
            mouseInputHandler.handleTouchEvent(motionEvent)
        },
    )
}

@Composable
private fun TouchpadContactSurfaceArea'''
s2, count = pattern.subn(replacement, s)
if count != 1:
    raise SystemExit(f"TouchpadForMouse replacement count was {count}")
touchpad.write_text(s2)

build = Path("app/build.gradle.kts")
s = build.read_text()
s = s.replace('applicationId = "me.arianb.usb_hid_client"', 'applicationId = "me.arianb.usb_hid_client.azerty"')
s = s.replace('versionName = "v3.1.0"', 'versionName = "v3.1.0-azerty-touchpad"')
build.write_text(s)

strings = Path("app/src/main/res/values/strings.xml")
s = strings.read_text().replace(
    '<string name="app_name" translatable="false">USB HID Client</string>',
    '<string name="app_name" translatable="false">USB HID Client AZERTY</string>'
)
strings.write_text(s)
PY

./gradlew --no-daemon :app:assembleDebug
mkdir -p ../out
cp app/build/outputs/apk/debug/app-debug.apk ../out/USB-HID-Client-AZERTY-Touchpad.apk
