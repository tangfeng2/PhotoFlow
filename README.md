# Photos App

Flutter + Rust photo viewer/manager inspired by iOS Photos.

## What is included

- Flutter Material 3 UI with:
  - responsive sidebar
  - library grid
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

Copy the produced dynamic library beside the app executable, or run without it to use the Dart fallback scanner.

Then:

    flutter pub get
    flutter run -d windows

## Rust library names

- Windows: photos_core.dll
- macOS: libphotos_core.dylib
- Linux: libphotos_core.so
