#!/usr/bin/env bash
set -euo pipefail

# Build the validated v9 UI/touchpad first.
bash rebuild_touchpad_v9.sh

cd android-hid-client

python3 - <<'PY'
from pathlib import Path

# Pass the failed HID report to MainViewModel so it can repair permissions and retry it once.
p = Path("app/src/main/java/me/arianb/usb_hid_client/report_senders/ReportSender.kt")
s = p.read_text()
old = '''    suspend fun start(onSuccess: () -> Unit, onException: (e: IOException) -> Unit) = withContext(Dispatchers.IO) {
        for (report in reportsChannel) {
            try {
                Timber.d("REPORT HEX (len = %d): %s", report.size, report.toHexString())
                sendReport(report)
                onSuccess()
            } catch (e: IOException) {
                Timber.d(e)
                onException(e)
            }
        }
    }
'''
new = '''    suspend fun start(onSuccess: () -> Unit, onException: (e: IOException, failedReport: ByteArray) -> Unit) = withContext(Dispatchers.IO) {
        for (report in reportsChannel) {
            try {
                Timber.d("REPORT HEX (len = %d): %s", report.size, report.toHexString())
                sendReport(report)
                onSuccess()
            } catch (e: IOException) {
                Timber.d(e)
                // Give the caller the exact failed report so a permission repair can retry it.
                onException(e, report)
            }
        }
    }
'''
if old not in s:
    raise SystemExit("ReportSender.start block not found")
p.write_text(s.replace(old, new))

# Automatically repair /dev/hidg* ownership/mode/SELinux context before sender startup,
# and transparently repair+retry once if an EACCES/permission denied still occurs later.
p = Path("app/src/main/java/me/arianb/usb_hid_client/MainViewModel.kt")
s = p.read_text()

old = '''                senderFlow.collectLatest { sender ->
                    sender.start(
                        onSuccess = {
                            // This is called when no exception was thrown, meaning everything is good :)
                            // so let's set the UI state back to default (no errors)
                            _uiState.update { MyUiState() }
                        },
                        onException = { e ->
                            val characterDevicePath = sender.characterDevicePath
                            if (e is FileNotFoundException && characterDeviceMissing(characterDevicePath)) {
                                Timber.i("Character device '$characterDevicePath' doesn't exist. The user probably skipped the character device creation prompt.")
                            } else {
                                handleException(e, sender.characterDevicePath)
                            }
                        }
                    )
                }
'''
new = '''                senderFlow.collectLatest { sender ->
                    // Device nodes can be recreated by Android/USB gadget setup with root-owned
                    // permissions. Repair them proactively every time a sender becomes active.
                    if (rootStateHolder.hasRootPermissions() && sender.characterDevicePath.exists()) {
                        Timber.i("Auto-fixing HID permissions before sender start: %s", sender.characterDevicePath.path)
                        characterDeviceManager.fixCharacterDevicePermissions(sender.characterDevicePath)
                    }

                    sender.start(
                        onSuccess = {
                            _uiState.update { MyUiState() }
                        },
                        onException = { e, failedReport ->
                            val characterDevicePath = sender.characterDevicePath
                            if (e is FileNotFoundException && characterDeviceMissing(characterDevicePath)) {
                                Timber.i("Character device '$characterDevicePath' doesn't exist. The user probably skipped the character device creation prompt.")
                            } else if (isPermissionDenied(e) && rootStateHolder.hasRootPermissions()) {
                                // Equivalent to pressing the old FIX button, but automatic. Then
                                // retry exactly the report that failed so the user's input is not lost.
                                Timber.w("HID permission denied on %s; repairing automatically and retrying once", characterDevicePath.path)
                                characterDeviceManager.fixCharacterDevicePermissions(characterDevicePath)
                                try {
                                    sender.sendReport(failedReport)
                                    _uiState.update { MyUiState() }
                                    Timber.i("Automatic HID permission repair succeeded for %s", characterDevicePath.path)
                                } catch (retryException: IOException) {
                                    Timber.e(retryException, "Automatic HID permission retry failed")
                                    handleException(retryException, characterDevicePath)
                                }
                            } else {
                                handleException(e, characterDevicePath)
                            }
                        }
                    )
                }
'''
if old not in s:
    raise SystemExit("MainViewModel sender loop not found")
s = s.replace(old, new)

marker = '''    private fun handleException(e: IOException, devicePath: DevicePath) {
'''
helper = '''    private fun isPermissionDenied(e: IOException): Boolean {
        val exceptionString = e.message ?: Log.getStackTraceString(e)
        val lowercase = exceptionString.lowercase()
        return lowercase.contains("permission denied") || lowercase.contains("eacces")
    }

    private fun handleException(e: IOException, devicePath: DevicePath) {
'''
if marker not in s:
    raise SystemExit("handleException marker not found")
s = s.replace(marker, helper, 1)
p.write_text(s)

# Give this build a separate package/name.
build = Path("app/build.gradle.kts")
b = build.read_text()
b = b.replace(
    'applicationId = "me.arianb.usb_hid_client.azerty.touchpad9"',
    'applicationId = "me.arianb.usb_hid_client.azerty.touchpad10"'
)
b = b.replace(
    'versionName = "v3.1.0-azerty-touchpad9"',
    'versionName = "v3.1.0-azerty-touchpad10"'
)
build.write_text(b)

strings = Path("app/src/main/res/values/strings.xml")
t = strings.read_text().replace(
    '<string name="app_name" translatable="false">USB HID Client AZERTY v9</string>',
    '<string name="app_name" translatable="false">USB HID Client AZERTY v10</string>'
)
strings.write_text(t)
PY

./gradlew --no-daemon :app:assembleDebug
cd ..
mkdir -p out
cp android-hid-client/app/build/outputs/apk/debug/app-debug.apk out/USB-HID-Client-AZERTY-Touchpad-v10.apk
