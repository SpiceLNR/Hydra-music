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


SYNC_SERVICE_XML = """        <service android:name=".SyncService"
            android:foregroundServiceType="dataSync"
            android:exported="false"/>
"""

SYNC_SERVICE_KT = """package __PKG__

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/** Служба переднего плана на время синхронизации: не даёт телефону усыпить процесс и сеть,
 *  когда экран погас. Живёт только пока идёт обмен. */
class SyncService : Service() {
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val channelId = "hydra_sync"
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(channelId, "Синхронизация", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val text = intent?.getStringExtra("text") ?: "Синхронизация"
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("Hydra Music")
            .setContentText(if (text.isEmpty()) "Синхронизация" else text)
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(4711, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(4711, notification)
        }
        if (wake == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "hydra:sync").apply {
                setReferenceCounted(false)
                acquire(60 * 60 * 1000L)
            }
        }
        if (wifi == null) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            wifi = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "hydra:sync").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        wake?.let { if (it.isHeld) it.release() }
        wifi?.let { if (it.isHeld) it.release() }
        wake = null
        wifi = null
        super.onDestroy()
    }
}
"""

MAIN_ACTIVITY_KT = """package __PKG__

import android.content.Intent
import android.os.Build
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hydra/sync_service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        try {
                            val intent = Intent(this, SyncService::class.java)
                            intent.putExtra("text", call.argument<String>("text") ?: "")
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            // из фона Android не разрешает запускать такую службу
                            result.success(false)
                        }
                    }
                    "stop" -> {
                        stopService(Intent(this, SyncService::class.java))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
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

    if "SyncService" not in text:
        end = text.rfind("</application>")
        text = text[:end] + SYNC_SERVICE_XML + "    " + text[end:]
        print("Служба синхронизации: добавлена")

    text = re.sub(r'android:label="[^"]*"', f'android:label="{APP_LABEL}"', text, count=1)
    if 'android:icon="@mipmap/ic_launcher"' not in text:
        text = re.sub(r'(<application\b)', r'\1 android:icon="@mipmap/ic_launcher"', text, count=1)

    if text != orig:
        MANIFEST.write_text(text, encoding="utf-8")
    return 0


def patch_activity() -> int:
    files = list(MAIN_DIR.rglob("MainActivity.kt"))
    if not files:
        print("MainActivity.kt не найдена.")
        return 1
    for f in files:
        t = f.read_text(encoding="utf-8")
        m = re.search(r"^package\s+([\w.]+)", t, flags=re.MULTILINE)
        if not m:
            print("В MainActivity.kt нет строки package.")
            return 1
        pkg = m.group(1)
        if "hydra/sync_service" not in t:
            f.write_text(MAIN_ACTIVITY_KT.replace("__PKG__", pkg), encoding="utf-8")
            print("MainActivity: AudioServiceActivity + канал службы синхронизации")
        else:
            print("MainActivity: уже настроена")
        svc = f.parent / "SyncService.kt"
        svc.write_text(SYNC_SERVICE_KT.replace("__PKG__", pkg), encoding="utf-8")
        print("SyncService.kt: записан")
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
    # Окно не показывается само после первого кадра: его показывает приложение
    # (DockController.reveal), уже с нужным размером и без рамки. Иначе при запуске
    # на миг видна белая рамка обычного окна.
    flutter_window = pathlib.Path("windows/runner/flutter_window.cpp")
    if flutter_window.exists():
        text = flutter_window.read_text(encoding="utf-8")
        # блочный комментарий: работает и когда вызов стоит в одной строке с `});`
        new = re.sub(r"(?<!/\* )this->Show\(\);", "/* this->Show(); */", text)
        if new != text:
            flutter_window.write_text(new, encoding="utf-8")
            print("Окно Windows: не показывается до первого кадра")
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
