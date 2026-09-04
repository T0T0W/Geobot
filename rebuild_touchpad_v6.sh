#!/usr/bin/env bash
set -euo pipefail

# Rebuild the known-good AZERTY + relative touchpad base.
bash build_hid_client.sh

cd android-hid-client
MOUSE_FILE="app/src/main/java/me/arianb/usb_hid_client/input_views/touch_input_handlers/MouseInputHandler.kt"

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
 * - one finger hold ~400 ms: held left button
 * - quick tap, release, quick second tap held briefly: held left button
 * - quick second tap released immediately: normal double-click
 * - second finger DOWN while first remains: immediate right click
 *
 * The second-tap hold uses a very short confirmation interval. This prevents a normal
 * click followed by immediately touching the pad to move the cursor from accidentally
 * turning into a stuck left-button hold.
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

    private var gestureDownTime: Long = 0L
    private var gestureMoved = false
    private var rightClickTriggered = false

    private var longPressActive = false
    private var longPressRunnable: Runnable? = null

    private var lastTapUpTime: Long = Long.MIN_VALUE
    private var lastTapCoordinates: Coordinates? = null

    private var secondTapCandidate = false
    private var secondTapHoldActive = false
    private var secondTapConfirmRunnable: Runnable? = null

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
        cancelSecondTapConfirmation()

        val index = event.actionIndex.coerceAtLeast(0)
        activePointerId = event.getPointerId(index)
        val point = pointAt(event, index)
        previousCoordinates = point
        downCoordinates = point
        gestureDownTime = event.eventTime
        gestureMoved = false
        rightClickTriggered = false
        longPressActive = false
        secondTapHoldActive = false

        val elapsed = event.eventTime - lastTapUpTime
        val nearPreviousTap = lastTapCoordinates?.let { previous ->
            distance(point, previous) <= DOUBLE_TAP_SLOP_PX
        } ?: false

        val isSecondTap = lastTapUpTime != Long.MIN_VALUE &&
            elapsed in 0..DOUBLE_TAP_GAP_MS &&
            nearPreviousTap

        if (isSecondTap) {
            // Do not press the button on the exact DOWN instant. Give the finger a tiny window
            // to prove it is being held instead of immediately used for cursor movement.
            secondTapCandidate = true
            scheduleSecondTapHoldConfirmation()
        } else {
            secondTapCandidate = false
            clearLastTap()
            scheduleLongPress()
        }
    }

    private fun scheduleSecondTapHoldConfirmation() {
        val runnable = Runnable {
            if (
                secondTapCandidate &&
                activePointerId != null &&
                !gestureMoved &&
                !rightClickTriggered &&
                !secondTapHoldActive
            ) {
                secondTapCandidate = false
                secondTapHoldActive = true
                clearLastTap()
                setButtons(left = true, right = false)
            }
        }
        secondTapConfirmRunnable = runnable
        handler.postDelayed(runnable, SECOND_TAP_HOLD_CONFIRM_MS)
    }

    private fun cancelSecondTapConfirmation() {
        secondTapConfirmRunnable?.let(handler::removeCallbacks)
        secondTapConfirmRunnable = null
    }

    private fun scheduleLongPress() {
        val runnable = Runnable {
            if (
                activePointerId != null &&
                !gestureMoved &&
                !rightClickTriggered &&
                !secondTapCandidate &&
                !secondTapHoldActive &&
                !longPressActive
            ) {
                longPressActive = true
                clearLastTap()
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
        cancelSecondTapConfirmation()
        secondTapCandidate = false
        clearLastTap()

        if (event.pointerCount >= 2 && !rightClickTriggered) {
            // Never leave left pressed while emitting a right click.
            if (
                longPressActive ||
                secondTapHoldActive ||
                currentTouchpadButtonState.isLeftButtonPressed
            ) {
                longPressActive = false
                secondTapHoldActive = false
                setButtons(left = false, right = false)
            }

            click(left = false, right = true)
            rightClickTriggered = true

            currentActivePoint(event)?.let { previousCoordinates = it }
        }
    }

    private fun onMove(event: MotionEvent) {
        val point = currentActivePoint(event) ?: return
        val down = downCoordinates

        if (down != null) {
            val movedDistance = distance(point, down)

            if (secondTapCandidate && movedDistance > SECOND_TAP_PREHOLD_SLOP_PX) {
                // This was a quick retouch to resume pointer motion, not tap-and-hold.
                secondTapCandidate = false
                cancelSecondTapConfirmation()
                clearLastTap()
                gestureMoved = true
            } else if (!secondTapHoldActive && !longPressActive && movedDistance > MOVE_SLOP_PX) {
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
        cancelSecondTapConfirmation()

        val duration = event.eventTime - gestureDownTime
        val upPoint = pointAt(event, event.actionIndex.coerceAtLeast(0))

        if (secondTapHoldActive) {
            secondTapHoldActive = false
            setButtons(left = false, right = false)
            resetGesture(clearTapHistory = true)
            return
        }

        if (longPressActive) {
            longPressActive = false
            setButtons(left = false, right = false)
            resetGesture(clearTapHistory = true)
            return
        }

        if (secondTapCandidate) {
            // Released before the hold confirmation: this is an ordinary second click.
            secondTapCandidate = false
            click(left = true, right = false)
            resetGesture(clearTapHistory = true)
            return
        }

        if (!rightClickTriggered && !gestureMoved && duration <= TAP_TIMEOUT_MS) {
            click(left = true, right = false)
            lastTapUpTime = event.eventTime
            lastTapCoordinates = upPoint
        } else {
            clearLastTap()
        }

        resetGesture(clearTapHistory = false)
    }

    private fun onCancel() {
        cancelLongPress()
        cancelSecondTapConfirmation()

        if (
            currentTouchpadButtonState.isLeftButtonPressed ||
            currentTouchpadButtonState.isRightButtonPressed
        ) {
            setButtons(left = false, right = false)
        }

        resetGesture(clearTapHistory = true)
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

    private fun clearLastTap() {
        lastTapUpTime = Long.MIN_VALUE
        lastTapCoordinates = null
    }

    private fun distance(a: Coordinates, b: Coordinates): Float =
        hypot(a.x - b.x, a.y - b.y)

    private fun resetGesture(clearTapHistory: Boolean) {
        cancelLongPress()
        cancelSecondTapConfirmation()
        activePointerId = null
        previousCoordinates = null
        downCoordinates = null
        gestureMoved = false
        rightClickTriggered = false
        longPressActive = false
        secondTapCandidate = false
        secondTapHoldActive = false
        if (clearTapHistory) clearLastTap()
    }

    private companion object {
        const val MOVE_SLOP_PX = 14f
        const val SECOND_TAP_PREHOLD_SLOP_PX = 18f
        const val DOUBLE_TAP_SLOP_PX = 120f
        const val DOUBLE_TAP_GAP_MS = 260L
        const val SECOND_TAP_HOLD_CONFIRM_MS = 80L
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
    'applicationId = "me.arianb.usb_hid_client.azerty"',
    'applicationId = "me.arianb.usb_hid_client.azerty.touchpad6"'
)
s = s.replace(
    'versionName = "v3.1.0-azerty-touchpad"',
    'versionName = "v3.1.0-azerty-touchpad6"'
)
build.write_text(s)

strings = Path("app/src/main/res/values/strings.xml")
s = strings.read_text().replace(
    '<string name="app_name" translatable="false">USB HID Client AZERTY</string>',
    '<string name="app_name" translatable="false">USB HID Client AZERTY v6</string>'
)
strings.write_text(s)
PY

./gradlew --no-daemon :app:assembleDebug
cd ..
mkdir -p out
cp android-hid-client/app/build/outputs/apk/debug/app-debug.apk out/USB-HID-Client-AZERTY-Touchpad-v6.apk
