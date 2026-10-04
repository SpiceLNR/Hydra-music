import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:hydra_music/main.dart';

void main() {
  testWidgets('home screen shows the four main tiles', (tester) async {
    // размер экрана типичного телефона (360x800 логических пикселей)
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const HydraApp());

    expect(find.text('HYDRA MUSIC'), findsOneWidget);
    expect(find.text('Плейлисты'), findsOneWidget);
    expect(find.text('Устройства'), findsOneWidget);
    expect(find.text('Корзина'), findsOneWidget);
    expect(find.text('Настройки'), findsOneWidget);
  });
}
