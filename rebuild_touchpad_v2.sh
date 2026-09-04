#!/usr/bin/env bash
set -euo pipefail

# Reuse the first custom build script to clone v3.1.0 and apply the French AZERTY patches.
bash build_hid_client.sh

cd android-hid-client
MOUSE_FILE="app/src/main/java/me/arianb/usb_hid_client/input_views/touch_input_handlers/MouseInputHandler.kt"

cat > "$MOUSE_FILE" <<'KOT'
package me.arianb.usb_hid_client.input_views.touch_input_handlers

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
        val index = event.actionIndex.coerceAtLeast(0)
        activePointerId = event.getPointerId(index)
        val point = pointAt(event, index)
        previousCoordinates = point
        downCoordinates = point
        gestureDownTime = event.eventTime
        gestureMoved = false
        rightClickTriggered = false

        val secondTap = lastTapCoordinates?.let { previousTap ->
            event.eventTime - lastTapUpTime in 0..ViewConfiguration.getDoubleTapTimeout().toLong() &&
                distance(point, previousTap) <= DOUBLE_TAP_SLOP_PX
        } ?: false

        if (secondTap) {
            // The first tap already emitted click #1. Pressing here starts click #2. If the
            // finger is released quickly it is a normal double-click; if it stays down and
            // moves, it is exactly the laptop-style "double tap, hold and drag" gesture.
            dragActive = true
            lastTapUpTime = Long.MIN_VALUE
            lastTapCoordinates = null
            setButtons(left = true, right = false)
        } else {
            dragActive = false
        }
    }

    private fun onPointerDown(event: MotionEvent) {
        // The requested right-click gesture is sequential: finger #1 can already be resting on
        // the pad; the instant finger #2 touches down, emit a right click. No simultaneous tap
        // timing is required.
        if (event.pointerCount >= 2 && !rightClickTriggered) {
            if (dragActive) {
                dragActive = false
                setButtons(left = false, right = false)
            }

            click(left = false, right = true)
            rightClickTriggered = true
            lastTapUpTime = Long.MIN_VALUE
            lastTapCoordinates = null

            // Keep the current primary pointer as the motion source and refresh its baseline so
            // the right click itself never introduces a jump or a frozen interval.
            currentActivePoint(event)?.let { previousCoordinates = it }
        }
    }

    private fun onMove(event: MotionEvent) {
        val point = currentActivePoint(event) ?: return

        val down = downCoordinates
        if (down != null && distance(point, down) > MOVE_SLOP_PX) {
            gestureMoved = true
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
            // Transfer pointer control to another finger that is still down. MotionEvent still
            // contains the lifted pointer during ACTION_POINTER_UP, so explicitly skip it.
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
            // Primary finger is unchanged. Refresh its baseline to guarantee no delta spike when
            // the secondary finger disappears.
            currentActivePoint(event)?.let { previousCoordinates = it }
        }
    }

    private fun onUp(event: MotionEvent) {
        val duration = event.eventTime - gestureDownTime
        val upPoint = pointAt(event, event.actionIndex.coerceAtLeast(0))

        if (dragActive) {
            // Release the held left button only when the second tap is finally lifted.
            dragActive = false
            setButtons(left = false, right = false)
            resetGesture(clearLastTap = true)
            return
        }

        // A gesture that produced a right click must not also turn into a left click when the
        // final finger is lifted.
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

        // Relative HID X/Y are signed bytes. Split larger motion rather than overflowing and
        // causing a cursor jump in the opposite direction.
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
        activePointerId = null
        previousCoordinates = null
        downCoordinates = null
        gestureMoved = false
        rightClickTriggered = false
        dragActive = false
        if (clearLastTap) {
            lastTapUpTime = Long.MIN_VALUE
            lastTapCoordinates = null
        }
    }

    private companion object {
        const val MOVE_SLOP_PX = 14f
        const val DOUBLE_TAP_SLOP_PX = 90f
        const val TAP_TIMEOUT_MS = 300L
    }
}
KOT

python3 - <<'PY'
from pathlib import Path

build = Path("app/build.gradle.kts")
s = build.read_text()
s = s.replace('applicationId = "me.arianb.usb_hid_client.azerty"', 'applicationId = "me.arianb.usb_hid_client.azerty.touchpad2"')
s = s.replace('versionName = "v3.1.0-azerty-touchpad"', 'versionName = "v3.1.0-azerty-touchpad2"')
build.write_text(s)

strings = Path("app/src/main/res/values/strings.xml")
s = strings.read_text().replace(
    '<string name="app_name" translatable="false">USB HID Client AZERTY</string>',
    '<string name="app_name" translatable="false">USB HID Client AZERTY v2</string>'
)
strings.write_text(s)
PY

./gradlew --no-daemon :app:assembleDebug
cd ..
mkdir -p out
cp android-hid-client/app/build/outputs/apk/debug/app-debug.apk out/USB-HID-Client-AZERTY-Touchpad-v2.apk
