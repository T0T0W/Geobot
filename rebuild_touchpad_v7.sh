#!/usr/bin/env bash
set -euo pipefail

# Start from the known-good AZERTY + relative touchpad base.
bash build_hid_client.sh

cd android-hid-client
MOUSE_FILE="app/src/main/java/me/arianb/usb_hid_client/input_views/touch_input_handlers/MouseInputHandler.kt"
TOUCHPAD_FILE="app/src/main/java/me/arianb/usb_hid_client/input_views/Touchpad.kt"
VM_FILE="app/src/main/java/me/arianb/usb_hid_client/MainViewModel.kt"

# Clean touchpad state machine: NO double-tap hold at all.
# Gestures kept: move, tap=left click, long press=left hold, second finger=right click.
cat > "$MOUSE_FILE" <<'KOT'
package me.arianb.usb_hid_client.input_views.touch_input_handlers

import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import me.arianb.usb_hid_client.report_senders.pointer_device_senders.MouseSender
import me.arianb.usb_hid_client.report_senders.pointer_device_senders.PointerDeviceSender
import kotlin.math.hypot
import kotlin.math.roundToInt

/**
 * Relative laptop/RDP-style touchpad.
 *
 * Gestures:
 * - one finger move: relative pointer movement
 * - one finger tap: left click
 * - one finger hold ~400 ms: held left button; release finger to release button
 * - second finger DOWN while first remains: immediate right click
 *
 * Double-tap hold is intentionally NOT implemented.
 */
class MouseInputHandler(
    private val mouseSender: MouseSender
) : PointerDeviceInputHandler() {
    private data class Coordinates(val x: Float, val y: Float)

    private val handler = Handler(Looper.getMainLooper())

    private var activePointerId: Int? = null
    private var previousCoordinates: Coordinates? = null
    private var downCoordinates: Coordinates? = null
    private var currentTouchpadButtonState = PointerDeviceSender.TouchpadButtonState(false, false)

    private var gestureDownTime = 0L
    private var gestureMoved = false
    private var rightClickTriggered = false
    private var longPressActive = false
    private var longPressRunnable: Runnable? = null

    fun handleTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> onDown(event)
            MotionEvent.ACTION_POINTER_DOWN -> onPointerDown(event)
            MotionEvent.ACTION_MOVE -> onMove(event)
            MotionEvent.ACTION_POINTER_UP -> onPointerUp(event)
            MotionEvent.ACTION_UP -> onUp(event)
            MotionEvent.ACTION_CANCEL -> onCancel()
        }
        return true
    }

    private fun onDown(event: MotionEvent) {
        cancelLongPress()

        // Safety: every fresh one-finger gesture starts with mouse buttons released.
        // This guarantees a previous interrupted gesture can never leave Windows in a stuck hold.
        if (currentTouchpadButtonState.isLeftButtonPressed || currentTouchpadButtonState.isRightButtonPressed) {
            setButtons(left = false, right = false)
        }

        val index = event.actionIndex.coerceAtLeast(0)
        activePointerId = event.getPointerId(index)
        val point = pointAt(event, index)
        previousCoordinates = point
        downCoordinates = point
        gestureDownTime = event.eventTime
        gestureMoved = false
        rightClickTriggered = false
        longPressActive = false

        scheduleLongPress()
    }

    private fun scheduleLongPress() {
        val runnable = Runnable {
            if (
                activePointerId != null &&
                !gestureMoved &&
                !rightClickTriggered &&
                !longPressActive
            ) {
                longPressActive = true
                setButtons(left = true, right = false)
            }
        }
        longPressRunnable = runnable
        handler.postDelayed(runnable, LONG_PRESS_TIMEOUT_MS)
    }

    private fun cancelLongPress() {
        longPressRunnable?.let(handler::removeCallbacks)
        longPressRunnable = null
    }

    private fun onPointerDown(event: MotionEvent) {
        cancelLongPress()

        if (event.pointerCount >= 2 && !rightClickTriggered) {
            if (longPressActive || currentTouchpadButtonState.isLeftButtonPressed) {
                longPressActive = false
                setButtons(left = false, right = false)
            }

            click(left = false, right = true)
            rightClickTriggered = true

            // Finger #1 keeps moving the pointer. Refresh baseline to avoid a jump.
            currentActivePoint(event)?.let { previousCoordinates = it }
        }
    }

    private fun onMove(event: MotionEvent) {
        val point = currentActivePoint(event) ?: return

        val down = downCoordinates
        if (down != null && !longPressActive && distance(point, down) > MOVE_SLOP_PX) {
            gestureMoved = true
            cancelLongPress()
        }

        previousCoordinates?.let { previous ->
            sendMovement(point.x - previous.x, point.y - previous.y)
        }
        previousCoordinates = point
    }

    private fun onPointerUp(event: MotionEvent) {
        val liftedIndex = event.actionIndex
        val liftedId = event.getPointerId(liftedIndex)

        if (liftedId == activePointerId) {
            val replacementIndex = (0 until event.pointerCount).firstOrNull { it != liftedIndex }
            if (replacementIndex != null) {
                activePointerId = event.getPointerId(replacementIndex)
                previousCoordinates = pointAt(event, replacementIndex)
                downCoordinates = previousCoordinates
            } else {
                activePointerId = null
                previousCoordinates = null
            }
        } else {
            currentActivePoint(event)?.let { previousCoordinates = it }
        }
    }

    private fun onUp(event: MotionEvent) {
        cancelLongPress()
        val duration = event.eventTime - gestureDownTime

        if (longPressActive) {
            longPressActive = false
            setButtons(left = false, right = false)
            resetGesture()
            return
        }

        if (!rightClickTriggered && !gestureMoved && duration <= TAP_TIMEOUT_MS) {
            click(left = true, right = false)
        }

        // Absolute safety release after every completed gesture.
        if (currentTouchpadButtonState.isLeftButtonPressed || currentTouchpadButtonState.isRightButtonPressed) {
            setButtons(left = false, right = false)
        }
        resetGesture()
    }

    private fun onCancel() {
        cancelLongPress()
        if (currentTouchpadButtonState.isLeftButtonPressed || currentTouchpadButtonState.isRightButtonPressed) {
            setButtons(left = false, right = false)
        }
        resetGesture()
    }

    private fun currentActivePoint(event: MotionEvent): Coordinates? {
        var pointerId = activePointerId
        var index = pointerId?.let { event.findPointerIndex(it) } ?: -1

        if (index < 0 && event.pointerCount > 0) {
            index = 0
            pointerId = event.getPointerId(index)
            activePointerId = pointerId
        }

        return if (index >= 0) pointAt(event, index) else null
    }

    private fun pointAt(event: MotionEvent, index: Int) = Coordinates(
        event.getX(index),
        event.getY(index),
    )

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

    private fun distance(a: Coordinates, b: Coordinates): Float =
        hypot(a.x - b.x, a.y - b.y)

    private fun resetGesture() {
        cancelLongPress()
        activePointerId = null
        previousCoordinates = null
        downCoordinates = null
        gestureMoved = false
        rightClickTriggered = false
        longPressActive = false
    }

    private companion object {
        const val MOVE_SLOP_PX = 14f
        const val TAP_TIMEOUT_MS = 300L
        const val LONG_PRESS_TIMEOUT_MS = 400L
    }
}
KOT

# Add a reliable boot-key burst helper to the ViewModel.
python3 - <<'PY'
from pathlib import Path

p = Path("app/src/main/java/me/arianb/usb_hid_client/MainViewModel.kt")
s = p.read_text()
if "import kotlinx.coroutines.delay\n" not in s:
    s = s.replace("import kotlinx.coroutines.flow.update\n", "import kotlinx.coroutines.flow.update\nimport kotlinx.coroutines.delay\n")

needle = '''    fun addMediaKey(key: Byte) =
        keySender.value.addMediaKey(key)
'''
replacement = '''    fun addMediaKey(key: Byte) =
        keySender.value.addMediaKey(key)

    /**
     * Sends a short burst of the same keyboard key for BIOS/UEFI/boot-menu detection.
     * Firmware often polls USB keyboards intermittently, so a burst is much more reliable
     * than a single key press during POST.
     */
    fun sendBootKeyBurst(key: Byte) {
        viewModelScope.launch {
            repeat(10) {
                keySender.value.addStandardKey(0, key)
                delay(90)
            }
        }
    }
'''
if needle not in s:
    raise SystemExit("MainViewModel keyboard insertion point not found")
s = s.replace(needle, replacement)
p.write_text(s)
PY

# Add BIOS / boot-menu quick buttons above the touchpad.
python3 - <<'PY'
from pathlib import Path
import re

p = Path("app/src/main/java/me/arianb/usb_hid_client/input_views/Touchpad.kt")
s = p.read_text()

# The base custom script made MouseSender use the whole screen. Replace that function with
# a compact two-row quick-key strip plus the touch surface below it.
pattern = re.compile(r'''@Composable\nprivate fun TouchpadForMouse\(\n    mouseInputHandler: MouseInputHandler\n\) \{.*?\n\}\n\n@Composable\nprivate fun TouchpadContactSurfaceArea''', re.S)
replacement = '''@Composable
private fun TouchpadForMouse(
    mouseInputHandler: MouseInputHandler,
    onBootKey: (Byte) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxHeight()
            .fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp),
        ) {
            QuickBootKey("DEL", 0x4c, Modifier.weight(1f), onBootKey)
            QuickBootKey("F2", 0x3b, Modifier.weight(1f), onBootKey)
            QuickBootKey("F12", 0x45, Modifier.weight(1f), onBootKey)
            QuickBootKey("ESC", 0x29, Modifier.weight(1f), onBootKey)
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp),
        ) {
            QuickBootKey("F8", 0x41, Modifier.weight(1f), onBootKey)
            QuickBootKey("F10", 0x43, Modifier.weight(1f), onBootKey)
            QuickBootKey("F11", 0x44, Modifier.weight(1f), onBootKey)
        }
        TouchpadContactSurfaceArea(
            modifier = Modifier.weight(1f),
            onTouchEvent = { motionEvent ->
                mouseInputHandler.handleTouchEvent(motionEvent)
            },
        )
    }
}

@Composable
private fun QuickBootKey(
    label: String,
    hidKey: Int,
    modifier: Modifier,
    onBootKey: (Byte) -> Unit,
) {
    Surface(
        onClick = { onBootKey(hidKey.toByte()) },
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
private fun TouchpadContactSurfaceArea'''
s2, count = pattern.subn(replacement, s)
if count != 1:
    raise SystemExit(f"TouchpadForMouse replacement count was {count}")
s = s2

old_call = '''        is MouseSender -> {
            val mouseInputHandler = remember { MouseInputHandler(it) }

            TouchpadForMouse(mouseInputHandler)
        }
'''
new_call = '''        is MouseSender -> {
            val mouseInputHandler = remember { MouseInputHandler(it) }

            TouchpadForMouse(
                mouseInputHandler = mouseInputHandler,
                onBootKey = { key -> mainViewModel.sendBootKeyBurst(key) },
            )
        }
'''
if old_call not in s:
    raise SystemExit("MouseSender call site not found")
s = s.replace(old_call, new_call)
p.write_text(s)
PY

# Give v7 its own installable package/name.
python3 - <<'PY'
from pathlib import Path

build = Path("app/build.gradle.kts")
s = build.read_text()
s = s.replace(
    'applicationId = "me.arianb.usb_hid_client.azerty"',
    'applicationId = "me.arianb.usb_hid_client.azerty.touchpad7"'
)
s = s.replace(
    'versionName = "v3.1.0-azerty-touchpad"',
    'versionName = "v3.1.0-azerty-touchpad7"'
)
build.write_text(s)

strings = Path("app/src/main/res/values/strings.xml")
s = strings.read_text().replace(
    '<string name="app_name" translatable="false">USB HID Client AZERTY</string>',
    '<string name="app_name" translatable="false">USB HID Client AZERTY v7</string>'
)
strings.write_text(s)
PY

./gradlew --no-daemon :app:assembleDebug
cd ..
mkdir -p out
cp android-hid-client/app/build/outputs/apk/debug/app-debug.apk out/USB-HID-Client-AZERTY-Touchpad-v7.apk
