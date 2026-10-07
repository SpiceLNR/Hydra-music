#!/usr/bin/env python3
"""Донастраивает Android/Windows-проекты после `flutter create`.

 1. Разрешения в AndroidManifest.xml.
 2. compileSdk = 37 (Android 17) и подавление предупреждения AGP.
 3. Фоновая музыка: служба и приёмник кнопок audio_service, MainActivity -> AudioServiceActivity.
 4. Название приложения «Hydra Music» и иконка (из tools/icons).
 5. Windows: иконка (windows/runner/resources/app_icon.ico) и название окна «Hydra Music».

Запуск (из папки app/):
    python3 ../tools/patch_android_manifest.py           - Android (и иконка Windows, если папка есть)
    python3 ../tools/patch_android_manifest.py windows   - только Windows (сборка на Windows)
Безопасно запускать повторно: уже сделанное пропускается.
"""
import pathlib
import re
import shutil
import sys

# Консоль Windows по умолчанию не умеет русские буквы: печатаем в UTF-8.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

MANIFEST = pathlib.Path("android/app/src/main/AndroidManifest.xml")
GRADLE_KTS = pathlib.Path("android/app/build.gradle.kts")
GRADLE_PROPS = pathlib.Path("android/gradle.properties")
MAIN_DIR = pathlib.Path("android/app/src/main")
ICONS = pathlib.Path(__file__).resolve().parent / "icons"
WIN_ICON = pathlib.Path("windows/runner/resources/app_icon.ico")
WIN_MAIN = pathlib.Path("windows/runner/main.cpp")
WIN_RC = pathlib.Path("windows/runner/Runner.rc")

COMPILE_SDK = 37
APP_LABEL = "Hydra Music"

PERMISSIONS = [
    "android.permission.INTERNET",
    "android.permission.ACCESS_NETWORK_STATE",
    "android.permission.ACCESS_WIFI_STATE",
    "android.permission.CHANGE_WIFI_MULTICAST_STATE",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK",
    "android.permission.FOREGROUND_SERVICE_DATA_SYNC",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.WAKE_LOCK",
    "android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
    "android.permission.RECEIVE_BOOT_COMPLETED",
    "android.permission.MANAGE_EXTERNAL_STORAGE",
    "android.permission.CAMERA",
]

SERVICE_XML = """        <service android:name="com.ryanheise.audioservice.AudioService"
            android:foregroundServiceType="mediaPlayback"
            android:exported="true"
            tools:ignore="Instantiatable">
            <intent-filter>
                <action android:name="android.media.browse.MediaBrowserService"/>
            </intent-filter>
        </service>
        <receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver"
            android:exported="true"
            tools:ignore="Instantiatable">
            <intent-filter>
                <action android:name="android.intent.action.MEDIA_BUTTON"/>
            </intent-filter>
        </receiver>
"""


def patch_manifest() -> int:
    if not MANIFEST.exists():
        print(f"Не найден {MANIFEST}. Сначала выполните: flutter create --platforms=android,windows .")
        return 1
    text = MANIFEST.read_text(encoding="utf-8")
    orig = text

    if "xmlns:tools=" not in text:
        text = text.replace(
            "<manifest ",
            '<manifest xmlns:tools="http://schemas.android.com/tools" ',
            1,
        )

    missing = [p for p in PERMISSIONS if p not in text]
    idx = text.find("<application")
    if idx == -1:
        print("Не найден тег <application> в манифесте.")
        return 1
    if missing:
        block = "".join(f'    <uses-permission android:name="{p}"/>\n' for p in missing)
        text = text[:idx] + block + "    " + text[idx:]
    print(f"Разрешения: добавлено {len(missing)}")

    if "com.ryanheise.audioservice.AudioService" not in text:
        end = text.rfind("</application>")
        if end == -1:
            print("Не найден </application> в манифесте.")
            return 1
        text = text[:end] + SERVICE_XML + "    " + text[end:]
        print("Фоновая служба: добавлена")
    else:
        print("Фоновая служба: уже на месте")

    text = re.sub(r'android:label="[^"]*"', f'android:label="{APP_LABEL}"', text, count=1)
    if 'android:icon="@mipmap/ic_launcher"' not in text:
        text = re.sub(r'(<application\b)', r'\1 android:icon="@mipmap/ic_launcher"', text, count=1)

    if text != orig:
        MANIFEST.write_text(text, encoding="utf-8")
    return 0


def patch_activity() -> int:
    files = list(MAIN_DIR.rglob("MainActivity.kt")) + list(MAIN_DIR.rglob("MainActivity.java"))
    if not files:
        print("MainActivity не найдена.")
        return 1
    for f in files:
        t = f.read_text(encoding="utf-8")
        if "AudioServiceActivity" in t:
            print("MainActivity: уже AudioServiceActivity")
            continue
        t = t.replace(
            "io.flutter.embedding.android.FlutterActivity",
            "com.ryanheise.audioservice.AudioServiceActivity",
        ).replace("FlutterActivity", "AudioServiceActivity")
        f.write_text(t, encoding="utf-8")
        print("MainActivity: заменена на AudioServiceActivity")
    return 0


def patch_gradle() -> int:
    if not GRADLE_KTS.exists():
        print(f"Не найден {GRADLE_KTS}.")
        return 1
    text = GRADLE_KTS.read_text(encoding="utf-8")
    new_text, n = re.subn(
        r"^(\s*)compileSdk\s*=\s*.*$", rf"\1compileSdk = {COMPILE_SDK}", text, flags=re.MULTILINE
    )
    if n == 0:
        print("Не найдена строка compileSdk в build.gradle.kts.")
        return 1
    if new_text != text:
        GRADLE_KTS.write_text(new_text, encoding="utf-8")
        print(f"compileSdk: выставлен {COMPILE_SDK}")
    else:
        print(f"compileSdk: уже {COMPILE_SDK}")

    props = GRADLE_PROPS.read_text(encoding="utf-8") if GRADLE_PROPS.exists() else ""
    wanted = [
        f"android.suppressUnsupportedCompileSdk={COMPILE_SDK}",
        # Kotlin компилируется внутри процесса Gradle: фоновый демон Kotlin на сборке
        # release падал с «Daemon compilation failed».
        "kotlin.compiler.execution.strategy=in-process",
    ]
    added = [w for w in wanted if w not in props]
    if added:
        if props and not props.endswith("\n"):
            props += "\n"
        GRADLE_PROPS.write_text(props + "\n".join(added) + "\n", encoding="utf-8")
        print(f"gradle.properties: добавлено {len(added)} настр.")
    return 0


def patch_icons() -> int:
    src = ICONS / "android_res"
    if not src.exists():
        print(f"Иконки не найдены: {src}")
        return 1
    res = MAIN_DIR / "res"
    count = 0
    for f in src.rglob("*"):
        if f.is_file():
            dst = res / f.relative_to(src)
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(f, dst)
            count += 1
    print(f"Иконки Android: скопировано {count} файлов")
    return 0


def patch_windows() -> int:
    """Иконка и название окна. Не считается ошибкой, если папки windows нет."""
    if not WIN_ICON.parent.exists():
        print("Папка windows не найдена: пропускаю.")
        return 0
    ico = ICONS / "windows" / "app_icon.ico"
    if ico.exists():
        shutil.copyfile(ico, WIN_ICON)
        print("Иконка Windows: заменена")
    if WIN_MAIN.exists():
        text = WIN_MAIN.read_text(encoding="utf-8")
        new = text.replace('L"hydra_music"', f'L"{APP_LABEL}"')
        if new != text:
            WIN_MAIN.write_text(new, encoding="utf-8")
            print("Название окна Windows: задано")
    cmake = pathlib.Path("windows/CMakeLists.txt")
    flag = "add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)"
    if cmake.exists():
        text = cmake.read_text(encoding="utf-8")
        if flag not in text:
            new = re.sub(r"^(project\(.*\)\s*)$", lambda m: m.group(1) + "\n" + flag + "\n", text, count=1, flags=re.MULTILINE)
            if new != text:
                cmake.write_text(new, encoding="utf-8")
                print("CMake: подавлено устаревание <experimental/coroutine>")
    if WIN_RC.exists():
        text = WIN_RC.read_bytes().decode("utf-8", errors="surrogateescape")
        new = re.sub(
            r'(VALUE "(?:FileDescription|ProductName)", ")[^"]*(")',
            lambda m: f"{m.group(1)}{APP_LABEL}{m.group(2)}",
            text,
        )
        if new != text:
            WIN_RC.write_bytes(new.encode("utf-8", errors="surrogateescape"))
            print("Свойства exe (Windows): заданы")
    return 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "windows":
        return patch_windows()
    rc = patch_manifest() + patch_activity() + patch_gradle() + patch_icons() + patch_windows()
    return 1 if rc else 0


if __name__ == "__main__":
    sys.exit(main())
