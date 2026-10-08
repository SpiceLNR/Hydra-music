import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

/// Убирает у окна рамку Windows: заголовок, толстую рамку изменения размера и системные
/// кнопки. Нужно по двум причинам: обычное окно Windows нельзя сделать уже ~136 px
/// (а свёрнутая «кнопка» у края - 40 px), и у такой рамки есть невидимая кромка в 8 px,
/// из-за которой окно не прижимается вплотную к краю экрана.
/// Размер окна после этого меняет само приложение (см. `DockController`).
class Win32Frame {
  static const int _gwlStyle = -16;
  // WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX
  static const int _frameBits = 0x00C00000 | 0x00080000 | 0x00040000 | 0x00020000 | 0x00010000;
  // SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED
  static const int _swpFlags = 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0020;

  /// Возвращает true, если окно найдено и рамка снята. Любая ошибка даёт false:
  /// приложение продолжит работать с обычной рамкой.
  static bool makeBorderless(String title) {
    if (!Platform.isWindows) return false;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final findWindow = user32.lookupFunction<
          IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
          int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');
      final getLong = user32
          .lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>('GetWindowLongPtrW');
      final setLong = user32.lookupFunction<IntPtr Function(IntPtr, Int32, IntPtr),
          int Function(int, int, int)>('SetWindowLongPtrW');
      final setPos = user32.lookupFunction<
          Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
          int Function(int, int, int, int, int, int, int)>('SetWindowPos');

      final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
      final name = title.toNativeUtf16();
      var hwnd = findWindow(cls, name);
      if (hwnd == 0) hwnd = findWindow(cls, nullptr);
      malloc.free(cls);
      malloc.free(name);
      if (hwnd == 0) return false;

      final style = getLong(hwnd, _gwlStyle);
      setLong(hwnd, _gwlStyle, style & ~_frameBits);
      setPos(hwnd, 0, 0, 0, 0, 0, _swpFlags);

      // Windows 11: не скруглять углы окна (в Metro углы прямые).
      try {
        final dwm = DynamicLibrary.open('dwmapi.dll');
        final setAttr = dwm.lookupFunction<
            Int32 Function(IntPtr, Uint32, Pointer<Uint32>, Uint32),
            int Function(int, int, Pointer<Uint32>, int)>('DwmSetWindowAttribute');
        final pref = malloc<Uint32>();
        pref.value = 1; // DWMWCP_DONOTROUND
        setAttr(hwnd, 33, pref, 4); // DWMWA_WINDOW_CORNER_PREFERENCE
        malloc.free(pref);
      } catch (_) {
        // старая Windows: атрибута нет, углы и так прямые
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
