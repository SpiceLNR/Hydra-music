import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydra_music/desktop/context_menu.dart';
import 'package:hydra_music/desktop/v_slider.dart';
import 'package:hydra_music/main.dart';
import 'package:hydra_music/widgets/metro_widgets.dart';
import 'package:hydra_music/widgets/now_playing_bar.dart';

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
    // пока ничего не играло, панели «Сейчас играет» нет
    expect(find.textContaining('Сейчас играет'), findsNothing);
  });

  testWidgets('MetroToggle flips its value on tap', (tester) async {
    var value = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => MetroToggle(
              value: value,
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(MetroToggle));
    await tester.pump(const Duration(milliseconds: 300));
    expect(value, isTrue);

    await tester.tap(find.byType(MetroToggle));
    await tester.pump(const Duration(milliseconds: 300));
    expect(value, isFalse);
  });

  testWidgets('MetroSwitchRow shows Вкл/Выкл and reacts to a tap on the row', (tester) async {
    var value = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => MetroSwitchRow(
              title: 'Только по Wi-Fi',
              value: value,
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Выкл'), findsOneWidget);
    await tester.tap(find.text('Только по Wi-Fi'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(value, isTrue);
    expect(find.text('Вкл'), findsOneWidget);
  });

  testWidgets('MetroSlider seeks to the tapped position', (tester) async {
    double? changed;
    double? ended;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              child: MetroSlider(
                value: 0,
                max: 100,
                onChanged: (v) => changed = v,
                onChangeEnd: (v) => ended = v,
              ),
            ),
          ),
        ),
      ),
    );

    // нажатие в центре полосы = середина трека
    await tester.tapAt(tester.getCenter(find.byType(MetroSlider)));
    await tester.pump();
    expect(changed, closeTo(50, 1));
    expect(ended, closeTo(50, 1));
  });

  testWidgets('NowPlayingBar is hidden until something has played', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: NowPlayingBar())),
    );
    expect(find.textContaining('Сейчас играет'), findsNothing);
  });

  testWidgets('MetroAction shows its label and reacts to a tap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              Expanded(
                child: MetroAction(icon: Icons.edit, label: 'Название', onPressed: () => taps++),
              ),
              const Expanded(
                child: MetroAction(icon: Icons.delete, label: 'Удалить', onPressed: null),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Название'), findsOneWidget);
    await tester.tap(find.text('Название'));
    await tester.pump();
    expect(taps, 1);
    // кнопка без действия не падает при нажатии
    await tester.tap(find.text('Удалить'));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('MetroVSlider: top of the bar is the maximum, bottom is zero', (tester) async {
    double? last;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: 200,
              child: MetroVSlider(value: 50, onChanged: (v) => last = v),
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byType(MetroVSlider));
    await tester.tapAt(Offset(rect.center.dx, rect.top + 1));
    await tester.pump();
    expect(last, greaterThan(95));
    await tester.tapAt(Offset(rect.center.dx, rect.bottom - 1));
    await tester.pump();
    expect(last, lessThan(5));
  });

  testWidgets('showMetroMenu returns the chosen item', (tester) async {
    String? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                chosen = await showMetroMenu<String>(context, const Offset(20, 20), const [
                  MetroMenuItem(value: 'rename', label: 'Название', icon: Icons.edit),
                  MetroMenuItem(value: 'delete', label: 'Удалить', icon: Icons.delete, danger: true),
                ]);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Название'), findsOneWidget);
    await tester.tap(find.text('Удалить'));
    await tester.pumpAndSettle();
    expect(chosen, 'delete');
  });
}
