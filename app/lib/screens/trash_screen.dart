import 'package:flutter/material.dart';

import '../widgets/metro_widgets.dart';

/// Корзина: восстановить или удалить окончательно. Каркас с пустым списком;
/// данные придут из таблицы trash в Rust-ядре.
class TrashScreen extends StatelessWidget {
  const TrashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('корзина')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Корзина пуста.\nУдалённые треки хранятся здесь 30 дней, '
            'затем стираются окончательно.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              const Expanded(
                child: ElevatedButton(onPressed: null, child: Text('Восстановить')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => confirmAction(
                    context,
                    title: 'Удалить навсегда?',
                    message: 'Это действие нельзя отменить.',
                    confirmLabel: 'Удалить',
                    danger: true,
                  ),
                  child: const Text('Очистить'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
