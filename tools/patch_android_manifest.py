#!/usr/bin/env python3
"""Донастраивает Android-проект после `flutter create`.

 1. Добавляет нужные разрешения в AndroidManifest.xml.
 2. Выставляет compileSdk = 37 (Android 17): этого требует пакет permission_handler,
    а шаблон Flutter по умолчанию собирает под 36.

Запуск (из папки app/):  python3 ../tools/patch_android_manifest.py
Безопасно запускать повторно: уже сделанное пропускается.
"""
import pathlib
import re
import sys

MANIFEST = pathlib.Path("android/app/src/main/AndroidManifest.xml")
GRADLE_KTS = pathlib.Path("android/app/build.gradle.kts")
GRADLE_PROPS = pathlib.Path("android/gradle.properties")

COMPILE_SDK = 37

PERMISSIONS = [
    "android.permission.INTERNET",
    "android.permission.ACCESS_NETWORK_STATE",
    "android.permission.ACCESS_WIFI_STATE",
    "android.permission.CHANGE_WIFI_MULTICAST_STATE",  # mDNS в локальной сети
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK",
    "android.permission.FOREGROUND_SERVICE_DATA_SYNC",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.WAKE_LOCK",
    "android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
    "android.permission.RECEIVE_BOOT_COMPLETED",
    "android.permission.MANAGE_EXTERNAL_STORAGE",  # Music/Hydra/ (приложение личное, не для Google Play)
    "android.permission.CAMERA",  # сканирование QR при сопряжении
]


def patch_manifest() -> int:
    if not MANIFEST.exists():
        print(f"Не найден {MANIFEST}. Сначала выполните: flutter create --platforms=android,windows .")
        return 1
    text = MANIFEST.read_text(encoding="utf-8")
    missing = [p for p in PERMISSIONS if p not in text]
    if not missing:
        print("Разрешения: уже на месте.")
        return 0
    block = "".join(f'    <uses-permission android:name="{p}"/>\n' for p in missing)
    idx = text.find("<application")
    if idx == -1:
        print("Не найден тег <application> в манифесте.")
        return 1
    text = text[:idx] + block + "    " + text[idx:]
    MANIFEST.write_text(text, encoding="utf-8")
    print(f"Разрешения: добавлено {len(missing)}")
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

    # Версия Android Gradle Plugin может быть «протестирована» только до 36;
    # это лишь предупреждение, и мы его подавляем.
    flag = f"android.suppressUnsupportedCompileSdk={COMPILE_SDK}"
    props = GRADLE_PROPS.read_text(encoding="utf-8") if GRADLE_PROPS.exists() else ""
    if flag not in props:
        if props and not props.endswith("\n"):
            props += "\n"
        GRADLE_PROPS.write_text(props + flag + "\n", encoding="utf-8")
        print("gradle.properties: добавлено подавление предупреждения о compileSdk")
    return 0


def main() -> int:
    return 1 if (patch_manifest() + patch_gradle()) else 0


if __name__ == "__main__":
    sys.exit(main())
