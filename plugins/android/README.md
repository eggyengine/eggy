# Android

Export your game for Android phones and tablets. Open **File > Export** and pick **Android**
to build a test-signed APK you can install on a device or an emulator. A test-signed APK isn't
ready for a store.

Choose:

- **Android version**: the oldest Android the game runs on, from Android 13 to Android 16.
- **Architecture**: ARM64 for phones and tablets, or x86-64 for emulators.

## Requirements

- Exporting from macOS, or from Linux on x86-64.
- Python 3.12 or later.
- A device with Vulkan 1.3.

The first export downloads the Android SDK, NDK and JDK, and accepts Google's Android SDK
licences for you. Choosing a new Android version downloads that version too.

## Preferences

Set these in **Edit > Preferences** under Android:

- **Api level**: the Android version File > Export starts on.
- **Architecture**: the processor File > Export starts on.

## Dev plugin

Android only runs in the editor: exported games leave it out.
