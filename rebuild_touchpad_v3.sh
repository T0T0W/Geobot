#!/usr/bin/env bash
set -euo pipefail

# Build the validated AZERTY + touchpad v2 base first.
bash rebuild_touchpad_v2.sh

cd android-hid-client
MOUSE_FILE="app/src/main/java/me/arianb/usb_hid_client/input_views/touch_input_handlers/MouseInputHandler.kt"

cat > "$MOUSE_FILE" <<'KOT'
package me.arianb.usb_hid_client.input_views.touch_input_handlers

import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.ViewConfiguration
import me.arianb.usb_hid_client.report_senders.pointer_device_senders.MouseSender
import me.arianb.usb_hid_client.report_senders.pointer_device_senders.PointerDeviceSender
import kotlin.math.hypot
import kotlin.math.roundToInt

/**
 * Relative laptop/RDP-style touchpad input.
 *
 * Gestures:
 * - one finger move: relative pointer movement
 * - one finger tap: left click
 * - one finger press-and-hold: hold left button; moving afterwards drags while held
 * - double tap: double left click
 * - double tap then keep the second tap held + move: left-button drag
 * - while one finger is already down, touching a second finger: immediate right click
 *
 * The second finger never locks pointer motion. The primary finger keeps driving the pointer,
 * and if the primary finger is lifted while another finger remains, control transfers to the
 * remaining finger without a cursor jump.
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

    private var gestureDownTime: Long = 0
    private var lastTapUpTime: Long = Long.MIN_VALUE
    private var lastTapCoordinates: Coordinates? = null
    private var gestureMoved = false
    private var rightClickTriggered = false
    private var dragActive = false
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

        val index = event.actionIndex.coerceAtLeast(0)
        activePointerId = event.getPointerId(index)
        val point = pointAt(event, index)
        previousCoordinates = point
        downCoordinates = point
        gestureDownTime = event.eventTime
        gestureMoved = false
        rightClickTriggered = false
        longPressActive = false

        val secondTap = lastTapCoordinates?.let { previousTap ->
            event.eventTime - lastTapUpTime in 0..ViewConfiguration.getDoubleTapTimeout().toLong() &&
                distance(point, previousTap) <= DOUBLE_TAP_SLOP_PX
        } ?: false

        if (secondTap) {
            // First tap already emitted click #1. Press now starts click #2 and keeps it held.
            // A quick release is a normal double-click; moving while held is drag/select.
            dragActive = true
            lastTapUpTime = Long.MIN_VALUE
            lastTapCoordinates = null
            setButtons(left = true, right = false)
        } else {
            dragActive = false
            scheduleLongPress()
        }
    }

    private fun scheduleLongPress() {
        val runnable = Runnable {
            // Only convert the gesture into a held left click if the same one-finger gesture is
            // still resting in place. This fires even if Android sends no ACTION_MOVE events.
            if (
                activePointerId != null &&
                !gestureMoved &&
                !rightClickTriggered &&
                !dragActive &&
                !longPressActive
            ) {
                longPressActive = true
                lastTapUpTime = Long.MIN_VALUE
                lastTapCoordinates = null
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

        // A second finger means right-click immediately, even if finger #1 has been resting for
        // a while. Release any held left button first so the two mouse buttons never stick.
        if (event.pointerCount >= 2 && !rightClickTriggered) {
            if (dragActive || longPressActive || currentTouchpadButtonState.isLeftButtonPressed) {
                dragActive = false
                longPressActive = false
                setButtons(left = false, right = false)
            }

            click(left = false, right = true)
            rightClickTriggered = true
            lastTapUpTime = Long.MIN_VALUE
            lastTapCoordinates = null

            // Keep finger #1 as the movement source. Refresh the baseline so adding finger #2
            // never causes a jump and never freezes pointer motion.
            currentActivePoint(event)?.let { previousCoordinates = it }
        }
    }

    private fun onMove(event: MotionEvent) {
        val point = currentActivePoint(event) ?: return

        val down = downCoordinates
        if (down != null && distance(point, down) > MOVE_SLOP_PX) {
            if (!longPressActive) {
                gestureMoved = true
                cancelLongPress()
            }
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
            // Transfer motion control to a finger that remains down. ACTION_POINTER_UP still
            // contains the lifted pointer, so explicitly skip its index.
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
        val upPoint = pointAt(event, event.actionIndex.coerceAtLeast(0))

        if (longPressActive) {
            // Long press was a real left-button DOWN. Keep it held during any movement, and only
            // release when the finger finally leaves the pad.
            longPressActive = false
            setButtons(left = false, right = false)
            resetGesture(clearLastTap = true)
            return
        }

        if (dragActive) {
            // Release click #2 / drag exactly when the second tap is lifted.
            dragActive = false
            setButtons(left = false, right = false)
            resetGesture(clearLastTap = true)
            return
        }

        // Never turn a right-click gesture into a left click when the last finger leaves.
        if (!rightClickTriggered && !gestureMoved && duration <= TAP_TIMEOUT_MS) {
            click(left = true, right = false)
            lastTapUpTime = event.eventTime
            lastTapCoordinates = upPoint
        } else {
            lastTapUpTime = Long.MIN_VALUE
            lastTapCoordinates = null
        }

        resetGesture(clearLastTap = false)
    }

    private fun onCancel() {
        cancelLongPress()
        if (currentTouchpadButtonState.isLeftButtonPressed || currentTouchpadButtonState.isRightButtonPressed) {
            setButtons(left = false, right = false)
        }
        resetGesture(clearLastTap = true)
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

    /** Legacy helper retained for existing call sites/tests. */
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

    private fun resetGesture(clearLastTap: Boolean) {
        cancelLongPress()
        activePointerId = null
        previousCoordinates = null
        downCoordinates = null
        gestureMoved = false
        rightClickTriggered = false
        dragActive = false
        longPressActive = false
        if (clearLastTap) {
            lastTapUpTime = Long.MIN_VALUE
            lastTapCoordinates = null
        }
    }

    private companion object {
        const val MOVE_SLOP_PX = 14f
        const val DOUBLE_TAP_SLOP_PX = 90f
        const val TAP_TIMEOUT_MS = 300L
        const val LONG_PRESS_TIMEOUT_MS = 400L
    }
}
KOT

python3 - <<'PY'
from pathlib import Path

build = Path("app/build.gradle.kts")
s = build.read_text()
s = s.replace(
    'applicationId = "me.arianb.usb_hid_client.azerty.touchpad2"',
    'applicationId = "me.arianb.usb_hid_client.azerty.touchpad3"'
)
s = s.replace(
    'versionName = "v3.1.0-azerty-touchpad2"',
    'versionName = "v3.1.0-azerty-touchpad3"'
)
build.write_text(s)

strings = Path("app/src/main/res/values/strings.xml")
s = strings.read_text().replace(
    '<string name="app_name" translatable="false">USB HID Client AZERTY v2</string>',
    '<string name="app_name" translatable="false">USB HID Client AZERTY v3</string>'
)
strings.write_text(s)
PY

./gradlew --no-daemon :app:assembleDebug
cd ..
mkdir -p out
cp android-hid-client/app/build/outputs/apk/debug/app-debug.apk out/USB-HID-Client-AZERTY-Touchpad-v3.apk
