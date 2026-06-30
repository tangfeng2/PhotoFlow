# PhotoFlow

Flutter + Rust photo viewer/manager inspired by iOS Photos.

## What is included

- Flutter Material 3 UI with:
  - responsive sidebar
  - zoomable, virtualized library mosaic
  - timeline grouping
  - albums
  - favorites
  - full-screen image viewer
  - metadata panel
- Rust FFI core for fast directory scanning and image metadata extraction.
- Dart fallback scanner when the Rust dynamic library is not built yet.
- GPU-friendly Flutter rendering using decoded image textures, CustomPainter, clipping, and animated transforms. Flutter GPU (flutter_gpu) is still experimental, so the app keeps the renderer isolated and can be upgraded without changing the rest of the app.

## Run

If this folder does not yet contain platform folders, run:

    flutter create --platforms=windows,macos,linux,ios,android .

Build the Rust core:

    cd rust
    cargo build --release

On Windows, copy the Rust DLL into the Flutter runner output:

    powershell -ExecutionPolicy Bypass -File tool/copy_rust_core.ps1

You can also run without the DLL; the app automatically falls back to the Dart scanner.

Then:

    flutter pub get
    flutter run -d windows

### Android

The app uses a native MethodChannel (`AndroidPhotoBridge`) to scan device photos —
no Rust FFI needed on Android.

Make sure an Android device is connected (USB debugging enabled) or an emulator is running:

    flutter run -d android

To build a release APK:

    flutter build apk --release

To build an App Bundle for Play Store:

    flutter build appbundle --release

> Note: On Android, the Rust `photos_core` is **not** used. All photo scanning
> goes through the platform channel to the Kotlin `MainActivity`.

## Library controls

- Mouse wheel / trackpad pinch: zoom in or out of the full photo mosaic.
- Drag: pan around the library.
- Click: select a photo and show metadata.
- Double-click / double-tap: open the frame viewer.
- In the viewer: swipe between photos, pinch/scroll to inspect the current image.

## Rust library names

- Windows: photos_core.dll
- macOS: libphotos_core.dylib
- Linux: libphotos_core.so
