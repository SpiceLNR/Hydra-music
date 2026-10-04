#!/usr/bin/env python3
"""Добавляет нужные разрешения в AndroidManifest.xml после `flutter create`.

Запуск (из папки app/):  python3 ../tools/patch_android_manifest.py
Безопасно запускать повторно: уже добавленные разрешения пропускаются.
"""
import pathlib
import sys

MANIFEST = pathlib.Path("android/app/src/main/AndroidManifest.xml")

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


def main() -> int:
    if not MANIFEST.exists():
        print(f"Не найден {MANIFEST}. Сначала выполните: flutter create --platforms=android,windows .")
        return 1
    text = MANIFEST.read_text(encoding="utf-8")
    missing = [p for p in PERMISSIONS if p not in text]
    if not missing:
        print("Все разрешения уже на месте.")
        return 0
    block = "".join(f'    <uses-permission android:name="{p}"/>\n' for p in missing)
    marker = "<application"
    idx = text.find(marker)
    if idx == -1:
        print("Не найден тег <application> в манифесте.")
        return 1
    text = text[:idx] + block + "    " + text[idx:]
    MANIFEST.write_text(text, encoding="utf-8")
    print(f"Добавлено разрешений: {len(missing)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
