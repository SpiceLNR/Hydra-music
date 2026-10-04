import 'package:flutter_test/flutter_test.dart';
import 'package:hydra_music/main.dart';

void main() {
  testWidgets('home screen shows the four main tiles', (tester) async {
    await tester.pumpWidget(const HydraApp());

    expect(find.text('HYDRA MUSIC'), findsOneWidget);
    expect(find.text('Плейлисты'), findsOneWidget);
    expect(find.text('Устройства'), findsOneWidget);
    expect(find.text('Корзина'), findsOneWidget);
    expect(find.text('Настройки'), findsOneWidget);
  });
}
