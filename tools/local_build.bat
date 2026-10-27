@echo off
rem Локальная сборка Hydra Music на Windows (то же, что делает CI).
rem Использование:  tools\local_build.bat test | android | windows
rem Нужно: Rust (rustup), Flutter SDK, Python, Android Studio (SDK + NDK), cargo-ndk.
setlocal
cd /d "%~dp0.."
set ROOT=%CD%

if "%1"=="test" goto test
if "%1"=="android" goto android
if "%1"=="windows" goto windows
echo Укажите: test, android или windows
exit /b 1

:test
pushd core && cargo test --all-features || (popd & exit /b 1)
popd
pushd ffi && cargo test --all-features || (popd & exit /b 1)
popd
echo === Тесты Rust прошли ===
exit /b 0

:android
if not exist "%ROOT%\app\android" (
  pushd app && call flutter create --platforms=android,windows --project-name hydra_music --org com.spicelnr . && popd
)
pushd app && python ..\tools\patch_android_manifest.py && popd
rem NDK берём самый свежий из SDK Android Studio
if "%ANDROID_NDK_HOME%"=="" (
  for /d %%d in ("%LOCALAPPDATA%\Android\Sdk\ndk\*") do set ANDROID_NDK_HOME=%%d
)
echo NDK: %ANDROID_NDK_HOME%
rustup target add aarch64-linux-android
where cargo-ndk >nul 2>nul || cargo install cargo-ndk --locked
pushd ffi
cargo ndk -t arm64-v8a --platform 24 -o ..\app\android\app\src\main\jniLibs build --release || (popd & exit /b 1)
popd
pushd app
call flutter pub get
call flutter analyze --no-fatal-infos
call flutter test
call flutter build apk --release || (popd & exit /b 1)
popd
echo === APK: app\build\app\outputs\flutter-apk\app-release.apk ===
echo Установка на телефон по USB:  adb install -r app\build\app\outputs\flutter-apk\app-release.apk
exit /b 0

:windows
pushd ffi && cargo build --release || (popd & exit /b 1)
popd
if not exist "%ROOT%\app\windows" (
  pushd app && call flutter create --platforms=windows --project-name hydra_music --org com.spicelnr . && popd
)
pushd app && python ..\tools\patch_android_manifest.py windows && popd
set CL=/D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS
pushd app
call flutter pub get
call flutter build windows --release || (popd & exit /b 1)
popd
copy /y ffi\target\release\hydra_ffi.dll app\build\windows\x64\runner\Release\
echo === Готово: app\build\windows\x64\runner\Release\ ===
exit /b 0
