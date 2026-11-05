"""Переводы интерфейса: русский текст в коде (tr('...')) -> английский и украинский.

Запуск из app/:  python ../tools/i18n.py
1. собирает все tr('...') из app/lib (кроме lib/l10n);
2. проверяет, что для каждой строки есть перевод в T и подстановки {..} совпадают;
3. пишет app/lib/l10n/strings_en.dart и strings_uk.dart.

Ключ - русский текст в том виде, как он записан в исходнике Dart (с \\n, \\\\ и т.п.).
Новая строка интерфейса: в коде tr('Текст по-русски', {'x': ...}), сюда - перевод, затем запуск.
Тест app/test/l10n_test.dart в CI падает, если перевода нет.
"""
import pathlib
import re
import sys


def collect_keys():
    """Все tr('...') из app/lib в порядке появления (ключ - текст литерала как в исходнике)."""
    keys = []
    for p in sorted(pathlib.Path("lib").rglob("*.dart")):
        if "l10n" in p.parts:
            continue
        t = p.read_text(encoding="utf-8")
        for m in re.finditer(r"\btr\(\s*'((?:[^'\\]|\\.)*)'", t):
            if m.group(1) not in keys:
                keys.append(m.group(1))
    return keys


T = {
    "код {code}": ("code {code}", "код {code}"),
    "загрузка прервана": ("loading interrupted", "завантаження перервано"),
    "Воспроизведение": ("Playback", "Відтворення"),
    "Платформа не поддерживается: {operatingSystem}": ("Platform not supported: {operatingSystem}", "Платформа не підтримується: {operatingSystem}"),
    "Не удалось загрузить ядро: {e}": ("Could not load the core: {e}", "Не вдалося завантажити ядро: {e}"),
    "неизвестная ошибка ядра": ("unknown core error", "невідома помилка ядра"),
    "Отмена": ("Cancel", "Скасувати"),
    "Новый плейлист": ("New playlist", "Новий плейлист"),
    "Название папки": ("Folder name", "Назва теки"),
    "Создать": ("Create", "Створити"),
    "Переименовать плейлист": ("Rename playlist", "Перейменувати плейлист"),
    "Сохранить": ("Save", "Зберегти"),
    "Удалить можно только пустой плейлист: в «{name}» есть треки.": ("Only an empty playlist can be deleted: “{name}” has tracks.", "Видалити можна лише порожній плейлист: у «{name}» є треки."),
    "Удалить плейлист?": ("Delete playlist?", "Видалити плейлист?"),
    "Пустая папка «{name}» будет удалена.": ("The empty folder “{name}” will be deleted.", "Порожню теку «{name}» буде видалено."),
    "Удалить": ("Delete", "Видалити"),
    "По исполнителю": ("By artist", "За виконавцем"),
    "По названию трека": ("By track title", "За назвою треку"),
    "Как попало": ("Any order", "Довільно"),
    "Открыть": ("Open", "Відкрити"),
    "Переименовать": ("Rename", "Перейменувати"),
    "Удалить плейлист": ("Delete playlist", "Видалити плейлист"),
    "Название трека": ("Track title", "Назва треку"),
    "Название": ("Title", "Назва"),
    "Название записано в файл.": ("Title written to the file.", "Назву записано у файл."),
    "Этот формат не хранит теги: название сохранено только в приложении.": ("This format has no tags: the title is saved in the app only.", "Цей формат не зберігає теги: назву збережено лише в застосунку."),
    "Исполнитель": ("Artist", "Виконавець"),
    "Исполнитель записан в файл.": ("Artist written to the file.", "Виконавця записано у файл."),
    "Этот формат не хранит теги: исполнитель сохранён только в приложении.": ("This format has no tags: the artist is saved in the app only.", "Цей формат не зберігає теги: виконавця збережено лише в застосунку."),
    "Не удалось открыть выбор картинки: {e}": ("Could not open the image picker: {e}", "Не вдалося відкрити вибір зображення: {e}"),
    "Обложка записана в файл.": ("Cover written to the file.", "Обкладинку записано у файл."),
    "Нет другого плейлиста. Создайте его кнопкой в списке плейлистов.": ("There is no other playlist. Create one with the button in the playlist list.", "Іншого плейлиста немає. Створіть його кнопкою у списку плейлистів."),
    "Переместить в…": ("Move to…", "Перемістити до…"),
    "Переместить трек?": ("Move track?", "Перемістити трек?"),
    "«{title}» будет перенесён из «{from}» в «{name}». Файл физически переместится между папками.": ("“{title}” will be moved from “{from}” to “{name}”. The file is physically moved between folders.", "«{title}» буде перенесено з «{from}» до «{name}». Файл фізично переміститься між теками."),
    "Переместить": ("Move", "Перемістити"),
    "Удалить трек?": ("Delete track?", "Видалити трек?"),
    "«{title}» уйдёт в корзину на 30 дней.": ("“{title}” goes to the trash for 30 days.", "«{title}» потрапить до кошика на 30 днів."),
    "Играть": ("Play", "Грати"),
    "Обложка": ("Cover", "Обкладинка"),
    "Удалить навсегда?": ("Delete forever?", "Видалити назавжди?"),
    "«{title}» будет стёрт без возможности восстановления.": ("“{title}” will be erased permanently.", "«{title}» буде стерто без можливості відновлення."),
    "Очистить корзину?": ("Empty the trash?", "Очистити кошик?"),
    "Все треки в корзине ({length}) будут стёрты без возможности восстановления.": ("All tracks in the trash ({length}) will be erased permanently.", "Усі треки в кошику ({length}) буде стерто без можливості відновлення."),
    "Очистить": ("Empty", "Очистити"),
    "Восстановить": ("Restore", "Відновити"),
    "Удалить навсегда": ("Delete forever", "Видалити назавжди"),
    "сегодня, осталось {left} дн.": ("today, {left} d left", "сьогодні, залишилося {left} дн."),
    "{days} дн. назад, осталось {left} дн.": ("{days} d ago, {left} d left", "{days} дн. тому, залишилося {left} дн."),
    "Устройства": ("Devices", "Пристрої"),
    "Корзина": ("Trash", "Кошик"),
    "Настройки": ("Settings", "Налаштування"),
    "Свернуть (выход - в меню значка в трее)": ("Minimize (Exit is in the tray icon menu)", "Згорнути (вихід - у меню значка в треї)"),
    "Закрыть": ("Close", "Закрити"),
    "Нет плейлистов": ("No playlists", "Немає плейлистів"),
    "Плейлистов пока нет.\\nСоздайте плейлист в списке выше или положите папку с музыкой в Музыка\\\\Hydra.": ("No playlists yet.\\nCreate one in the list above or put a music folder into Music\\\\Hydra.", "Плейлистів поки немає.\\nСтворіть плейлист у списку вище або покладіть теку з музикою в Музика\\\\Hydra."),
    "Папка пуста. Положите файлы в Музыка\\\\Hydra\\\\{name}.": ("The folder is empty. Put files into Music\\\\Hydra\\\\{name}.", "Тека порожня. Покладіть файли в Музика\\\\Hydra\\\\{name}."),
    "Корзина пуста.\\nУдалённые треки хранятся здесь 30 дней.": ("The trash is empty.\\nDeleted tracks are kept here for 30 days.", "Кошик порожній.\\nВидалені треки зберігаються тут 30 днів."),
    "Очистить корзину": ("Empty trash", "Очистити кошик"),
    "Ошибка: {a1}": ("Error: {a1}", "Помилка: {a1}"),
    "неизвестная": ("unknown", "невідома"),
    "Сканирую библиотеку…": ("Scanning the library…", "Сканую бібліотеку…"),
    "правый клик - действия": ("right-click for actions", "правий клік - дії"),
    "Ничего не играет": ("Nothing is playing", "Нічого не грає"),
    "Выберите трек в списке": ("Pick a track in the list", "Виберіть трек у списку"),
    "Назад": ("Previous", "Назад"),
    "Пауза": ("Pause", "Пауза"),
    "Вперёд": ("Next", "Вперед"),
    "Показать": ("Show", "Показати"),
    "Выход": ("Exit", "Вихід"),
    "; рядом: {a1}": ("; nearby: {a1}", "; поруч: {a1}"),
    "файла нет по пути «{path}»{hint}": ("no file at “{path}”{hint}", "файлу немає за шляхом «{path}»{hint}"),
    "файл пустой (0 байт)": ("the file is empty (0 bytes)", "файл порожній (0 байтів)"),
    "файл {mb} МБ, начало: {ascii} ({hex})": ("file {mb} MB, starts with: {ascii} ({hex})", "файл {mb} МБ, початок: {ascii} ({hex})"),
    "файл не прочитался: {e}": ("the file could not be read: {e}", "файл не прочитався: {e}"),
    "Папка выбрана, но выбор не сохранился: {error}": ("The folder is selected, but the choice was not saved: {error}", "Теку вибрано, але вибір не зберігся: {error}"),
    "ещё не синхронизировались": ("not synced yet", "ще не синхронізувалися"),
    "устройство": ("device", "пристрій"),
    "Телефон": ("Phone", "Телефон"),
    "Компьютер": ("Computer", "Комп’ютер"),
    "Это не ссылка сопряжения Hydra Music": ("This is not a Hydra Music pairing link", "Це не посилання для з’єднання Hydra Music"),
    "Подключаюсь к устройству...": ("Connecting to the device...", "Підключаюся до пристрою..."),
    "Сеть не запустилась: {message}": ("Network did not start: {message}", "Мережа не запустилася: {message}"),
    "Сопряжение": ("Pairing", "З’єднання"),
    "Синхронизация с «{name}»": ("Syncing with “{name}”", "Синхронізація з «{name}»"),
    "сеть ещё не запущена": ("the network has not started yet", "мережу ще не запущено"),
    "Не удалось воспроизвести {name}{message}": ("Could not play {name}{message}", "Не вдалося відтворити {name}{message}"),
    "Не удалось воспроизвести {name}{message}\\n{info}": ("Could not play {name}{message}\\n{info}", "Не вдалося відтворити {name}{message}\\n{info}"),
    "Удалить устройство?": ("Remove device?", "Видалити пристрій?"),
    "«{name}» исчезнет из списка, и устройства перестанут синхронизироваться. Музыка на обоих устройствах останется на месте. Это устройство тоже уберёт вас из своего списка: сразу, если оно в сети, иначе когда появится (до 14 дней).": ("“{name}” disappears from the list and the devices stop syncing. Music stays on both devices. That device also removes you from its list: right away if it is online, otherwise when it shows up (within 14 days).", "«{name}» зникне зі списку, і пристрої перестануть синхронізуватися. Музика на обох пристроях залишиться на місці. Цей пристрій теж прибере вас зі свого списку: одразу, якщо він у мережі, інакше коли з’явиться (до 14 днів)."),
    "Название устройства": ("Device name", "Назва пристрою"),
    "Например, «Ноутбук»": ("For example, “Laptop”", "Наприклад, «Ноутбук»"),
    "Само устройство называет себя «{originalName}». Новое имя видно только здесь; пустое поле вернёт исходное.": ("The device calls itself “{originalName}”. The new name is visible only here; an empty field restores the original.", "Сам пристрій називає себе «{originalName}». Нове ім’я видно лише тут; порожнє поле поверне початкове."),
    "Добавить устройство": ("Add device", "Додати пристрій"),
    "Показать QR-код на этом устройстве": ("Show a QR code on this device", "Показати QR-код на цьому пристрої"),
    "Сканировать QR-код другого устройства": ("Scan another device's QR code", "Сканувати QR-код іншого пристрою"),
    "Ввести ссылку сопряжения": ("Enter a pairing link", "Ввести посилання для з’єднання"),
    "Журнал": ("Log", "Журнал"),
    "устройства": ("devices", "пристрої"),
    "Пока нет ни одного устройства. Оба устройства должны быть в одной Wi-Fi сети. Нажмите «Добавить устройство»: на одном покажите QR-код, на другом отсканируйте его.": ("No devices yet. Both devices must be on the same Wi-Fi network. Tap “Add device”: show the QR code on one and scan it on the other.", "Поки немає жодного пристрою. Обидва пристрої мають бути в одній мережі Wi-Fi. Натисніть «Додати пристрій»: на одному покажіть QR-код, на іншому відскануйте його."),
    "Сеть запускается...": ("Network is starting...", "Мережа запускається..."),
    "Идёт синхронизация...": ("Syncing...", "Триває синхронізація..."),
    "{a1} · синхронизация: {lastSyncLabel}": ("{a1} · synced: {lastSyncLabel}", "{a1} · синхронізація: {lastSyncLabel}"),
    "в сети": ("online", "у мережі"),
    "не в сети": ("offline", "не в мережі"),
    "Синхронизировать": ("Sync", "Синхронізувати"),
    "библиотека": ("library", "бібліотека"),
    "главная": ("home", "головна"),
    "Плейлисты": ("Playlists", "Плейлисти"),
    "синхронизация": ("sync", "синхронізація"),
    "хранится 30 дней": ("kept for 30 days", "зберігається 30 днів"),
    "Нужен доступ ко всем файлам, чтобы работать с папкой Music/Hydra.": ("Access to all files is needed to work with the Music/Hydra folder.", "Потрібен доступ до всіх файлів, щоб працювати з текою Music/Hydra."),
    "Разрешить доступ": ("Allow access", "Дозволити доступ"),
    "Повторить": ("Retry", "Повторити"),
    "журнал": ("log", "журнал"),
    "Журнал пока пуст.": ("The log is empty.", "Журнал поки порожній."),
    "Нет подключения к локальной сети (Wi-Fi).": ("No local network (Wi-Fi) connection.", "Немає підключення до локальної мережі (Wi-Fi)."),
    "Устройство добавлено": ("Device added", "Пристрій додано"),
    "QR-код": ("QR code", "QR-код"),
    "Код действует ещё {a1}:{a2}. На втором устройстве откройте «Устройства» -> «Добавить устройство» -> «Сканировать».": ("The code is valid for {a1}:{a2}. On the other device open “Devices” -> “Add device” -> “Scan”.", "Код дійсний ще {a1}:{a2}. На іншому пристрої відкрийте «Пристрої» -> «Додати пристрій» -> «Сканувати»."),
    "Код устарел.": ("The code has expired.", "Код застарів."),
    "Оба устройства должны быть в одной Wi-Fi сети.": ("Both devices must be on the same Wi-Fi network.", "Обидва пристрої мають бути в одній мережі Wi-Fi."),
    "Показать новый код": ("Show a new code", "Показати новий код"),
    "Ссылка скопирована": ("Link copied", "Посилання скопійовано"),
    "Скопировать ссылку (для ввода вручную)": ("Copy the link (for manual entry)", "Скопіювати посилання (для введення вручну)"),
    "Наведите камеру на QR-код на втором устройстве": ("Point the camera at the QR code on the other device", "Наведіть камеру на QR-код на іншому пристрої"),
    "Камера не найдена": ("No camera found", "Камеру не знайдено"),
    "кадров проверено: {_frames}": ("frames checked: {_frames}", "кадрів перевірено: {_frames}"),
    "ошибка разбора: {e}": ("decoding error: {e}", "помилка розбору: {e}"),
    "QR прочитан, но это не код сопряжения Hydra Music": ("QR read, but it is not a Hydra Music pairing code", "QR прочитано, але це не код з’єднання Hydra Music"),
    "сканировать QR": ("scan QR", "сканувати QR"),
    "Камера недоступна: {_error}": ("Camera unavailable: {_error}", "Камера недоступна: {_error}"),
    "Ввести ссылку вручную": ("Enter the link manually", "Ввести посилання вручну"),
    "Ссылка сопряжения": ("Pairing link", "Посилання для з’єднання"),
    "Подключиться": ("Connect", "Підключитися"),
    "Это не похоже на ссылку сопряжения": ("This does not look like a pairing link", "Це не схоже на посилання для з’єднання"),
    "Сохранено, теги записаны в файл.": ("Saved, tags written to the file.", "Збережено, теги записано у файл."),
    "Этот формат не хранит теги: изменения сохранены только в приложении.": ("This format has no tags: changes are saved in the app only.", "Цей формат не зберігає теги: зміни збережено лише в застосунку."),
    "плеер": ("player", "плеєр"),
    "Настройки трека": ("Track settings", "Налаштування треку"),
    "Изменить обложку": ("Change cover", "Змінити обкладинку"),
    "Название композиции": ("Track title", "Назва композиції"),
    "Нет другого плейлиста. Создайте его на экране «Плейлисты».": ("There is no other playlist. Create one on the “Playlists” screen.", "Іншого плейлиста немає. Створіть його на екрані «Плейлисти»."),
    "«{title}» будет перенесён из «{name}» в «{a1}». Файл физически переместится между папками.": ("“{title}” will be moved from “{name}” to “{a1}”. The file is physically moved between folders.", "«{title}» буде перенесено з «{name}» до «{a1}». Файл фізично переміститься між теками."),
    "Порядок треков": ("Track order", "Порядок треків"),
    "Порядок: {_sortLabel}": ("Order: {_sortLabel}", "Порядок: {_sortLabel}"),
    "Готово": ("Done", "Готово"),
    "редактирование": ("editing", "редагування"),
    "Обновить": ("Refresh", "Оновити"),
    "Папка пуста. Положите файлы в Music/Hydra/{name} и нажмите «Обновить».": ("The folder is empty. Put files into Music/Hydra/{name} and tap “Refresh”.", "Тека порожня. Покладіть файли в Music/Hydra/{name} і натисніть «Оновити»."),
    "Тяните за тёмную область справа, чтобы изменить порядок. Карандаш переименовывает плейлист.": ("Drag the dark area on the right to reorder. The pencil renames the playlist.", "Тягніть за темну ділянку праворуч, щоб змінити порядок. Олівець перейменовує плейлист."),
    "плейлисты": ("playlists", "плейлисти"),
    "Плейлистов пока нет.\\nСоздайте плейлист кнопкой ниже или положите папку с музыкой в Music/Hydra.": ("No playlists yet.\\nCreate one with the button below or put a music folder into Music/Hydra.", "Плейлистів поки немає.\\nСтворіть плейлист кнопкою нижче або покладіть теку з музикою в Music/Hydra."),
    "Новая папка библиотеки": ("New library folder", "Нова тека бібліотеки"),
    "Не удалось открыть выбор папки: {e}": ("Could not open the folder picker: {e}", "Не вдалося відкрити вибір теки: {e}"),
    "Папка библиотеки": ("Library folder", "Тека бібліотеки"),
    "Выбрано: {picked}\\n\\n«Перенести»: все плейлисты и корзина переедут\\nиз: {old}\\nв: {target}\\nЕсли папки на разных дисках, это может занять много времени. Если что-то пойдёт не так, всё вернётся на место.\\n\\n«Использовать эту»: ничего не переносится, приложение начнёт работать с выбранной папкой как с библиотекой (например, после переустановки, когда музыка уже лежит там).\\n\\nМузыка остановится, идущая синхронизация прервётся.": (
        "Selected: {picked}\\n\\n“Move”: all playlists and the trash move\\nfrom: {old}\\nto: {target}\\nIf the folders are on different drives, this may take a long time. If anything goes wrong, everything is put back.\\n\\n“Use this one”: nothing is moved, the app starts using the selected folder as the library (for example, after reinstalling, when the music is already there).\\n\\nPlayback stops and a running sync is interrupted.",
        "Вибрано: {picked}\\n\\n«Перенести»: усі плейлисти й кошик переїдуть\\nз: {old}\\nдо: {target}\\nЯкщо теки на різних дисках, це може тривати довго. Якщо щось піде не так, усе повернеться на місце.\\n\\n«Використати цю»: нічого не переноситься, застосунок почне працювати з вибраною текою як з бібліотекою (наприклад, після перевстановлення, коли музика вже лежить там).\\n\\nМузика зупиниться, синхронізація, що триває, перерветься."),
    "Использовать эту": ("Use this one", "Використати цю"),
    "Перенести": ("Move", "Перенести"),
    "Теперь библиотека: {picked}": ("The library is now: {picked}", "Тепер бібліотека: {picked}"),
    "Не удалось открыть папку: {e}": ("Could not open the folder: {e}", "Не вдалося відкрити теку: {e}"),
    "Переношу файлы…": ("Moving files…", "Переношу файли…"),
    "Библиотека перенесена: файлов {a1}{a2}": ("Library moved: {a1} files{a2}", "Бібліотеку перенесено: файлів {a1}{a2}"),
    ". Не удалось убрать старые файлы: {left} (папка занята)": (". Could not remove old files: {left} (folder in use)", ". Не вдалося прибрати старі файли: {left} (тека зайнята)"),
    "Перенос не выполнен, всё осталось на месте: {message}": ("Not moved, everything stayed in place: {message}", "Перенесення не виконано, усе залишилося на місці: {message}"),
    "Перенос не выполнен: {e}": ("Not moved: {e}", "Перенесення не виконано: {e}"),
    "Не запустилось: {internetError}": ("Did not start: {internetError}", "Не запустилося: {internetError}"),
    "Заработает после перезапуска приложения.": ("Takes effect after the app restarts.", "Запрацює після перезапуску застосунку."),
    "Relay-сервер": ("Relay server", "Relay-сервер"),
    "Через него устройства связываются, когда напрямую не получается. Пустое поле - общедоступные серверы n0. Музыка идёт зашифрованной.": ("Devices connect through it when a direct connection fails. An empty field means the public n0 servers. Music travels encrypted.", "Через нього пристрої з’єднуються, коли напряму не виходить. Порожнє поле - загальнодоступні сервери n0. Музика передається зашифрованою."),
    "По умолчанию": ("Default", "Типово"),
    "Relay: серверы по умолчанию": ("Relay: default servers", "Relay: типові сервери"),
    "Relay-сервер сохранён": ("Relay server saved", "Relay-сервер збережено"),
    "Relay не изменён: {err}": ("Relay not changed: {err}", "Relay не змінено: {err}"),
    "Имя этого устройства": ("This device's name", "Ім’я цього пристрою"),
    "Например, «Телефон Даши»": ("For example, “Dasha's phone”", "Наприклад, «Телефон Даші»"),
    "Так это устройство увидят остальные. Они узнают новое имя при следующей синхронизации.": ("This is how other devices see this one. They learn the new name at the next sync.", "Так цей пристрій бачитимуть інші. Вони дізнаються нове ім’я під час наступної синхронізації."),
    "Имя не сохранено: {err}": ("Name not saved: {err}", "Ім’я не збережено: {err}"),
    "настройки": ("settings", "налаштування"),
    "Это устройство": ("This device", "Цей пристрій"),
    "Имя": ("Name", "Ім’я"),
    "Синхронизация": ("Sync", "Синхронізація"),
    "Автоматически": ("Automatic", "Автоматично"),
    "Только во время зарядки": ("Only while charging", "Лише під час заряджання"),
    "Через интернет": ("Over the internet", "Через інтернет"),
    "Через интернет только по Wi-Fi": ("Internet only over Wi-Fi", "Через інтернет лише по Wi-Fi"),
    "по умолчанию": ("default", "типово"),
    "Разрешить работу в фоне": ("Allow background work", "Дозволити роботу у фоні"),
    "Библиотека": ("Library", "Бібліотека"),
    "Папка": ("Folder", "Тека"),
    "Окно": ("Window", "Вікно"),
    "Сторона": ("Side", "Сторона"),
    "Слева": ("Left", "Ліворуч"),
    "Справа": ("Right", "Праворуч"),
    "Сворачивать при клике мимо": ("Collapse on outside click", "Згортати при кліку повз"),
    "Обновления": ("Updates", "Оновлення"),
    "Ядро не запустилось: {error}": ("The core did not start: {error}", "Ядро не запустилося: {error}"),
    "внизу шторки": ("at the bottom of the panel", "внизу шторки"),
    "на главном экране под плитками": ("on the home screen below the tiles", "на головному екрані під плитками"),
    "Доступна версия {a1}: плашка {where}.": ("Version {a1} is available: see the banner {where}.", "Доступна версія {a1}: плашка {where}."),
    "Установлена последняя версия.": ("You have the latest version.", "Встановлено останню версію."),
    "Не удалось связаться с GitHub. Проверьте интернет.": ("Could not reach GitHub. Check the internet connection.", "Не вдалося зв’язатися з GitHub. Перевірте інтернет."),
    "Обновление {a1} уже скачивается или готово: плашка {where}.": ("Update {a1} is already downloading or ready: see the banner {where}.", "Оновлення {a1} вже завантажується або готове: плашка {where}."),
    "Обновления проверяются только у сборок из GitHub.": ("Updates are checked only for builds from GitHub.", "Оновлення перевіряються лише для збірок з GitHub."),
    "сборка {kBuild} · локальная, обновления не проверяются": ("build {kBuild} · local, updates are not checked", "збірка {kBuild} · локальна, оновлення не перевіряються"),
    "Проверяю…": ("Checking…", "Перевіряю…"),
    "сборка {kBuild}": ("build {kBuild}", "збірка {kBuild}"),
    "сборка {kBuild} · проверено в {a1}": ("build {kBuild} · checked at {a1}", "збірка {kBuild} · перевірено о {a1}"),
    "Версия {kVersion}": ("Version {kVersion}", "Версія {kVersion}"),
    "Проверить": ("Check", "Перевірити"),
    "Запускать вместе с Windows": ("Start with Windows", "Запускати разом з Windows"),
    "Не получилось: {_error}": ("Failed: {_error}", "Не вийшло: {_error}"),
    "Трек вернулся в плейлист: файл придёт с другого устройства при синхронизации": ("The track is back in the playlist: the file will arrive from another device at the next sync", "Трек повернувся до плейлиста: файл прийде з іншого пристрою під час синхронізації"),
    "удалён сегодня": ("deleted today", "видалено сьогодні"),
    "удалён {days} дн. назад": ("deleted {days} d ago", "видалено {days} дн. тому"),
    "{when}, осталось {left} дн.": ("{when}, {left} d left", "{when}, залишилося {left} дн."),
    "корзина": ("trash", "кошик"),
    "Корзина пуста.\\nУдалённые треки хранятся здесь 30 дней, затем стираются окончательно.": ("The trash is empty.\\nDeleted tracks are kept here for 30 days, then erased permanently.", "Кошик порожній.\\nВидалені треки зберігаються тут 30 днів, потім стираються остаточно."),
    " · файл на другом устройстве": (" · file is on another device", " · файл на іншому пристрої"),
    "Навсегда": ("Forever", "Назавжди"),
    "неизвестная ошибка": ("unknown error", "невідома помилка"),
    "слишком много перенаправлений": ("too many redirects", "забагато перенаправлень"),
    "сервер ответил {statusCode}": ("the server replied {statusCode}", "сервер відповів {statusCode}"),
    "загрузка прервалась": ("the download was interrupted", "завантаження перервалося"),
    "файл повреждён, скачайте заново": ("the file is damaged, download it again", "файл пошкоджено, завантажте заново"),
    "не удалось распаковать архив": ("could not unpack the archive", "не вдалося розпакувати архів"),
    "нет прав на запись в папку программы": ("no permission to write to the program folder", "немає прав на запис у теку програми"),
    "разрешите Hydra Music устанавливать приложения и нажмите «Установить» ещё раз": ("allow Hydra Music to install apps and tap “Install” again", "дозвольте Hydra Music встановлювати застосунки й натисніть «Встановити» ще раз"),
    "нет связи с GitHub": ("no connection to GitHub", "немає зв’язку з GitHub"),
    "GitHub не отвечает": ("GitHub is not responding", "GitHub не відповідає"),
    "Папка плейлиста «{name}» пропала (треков: {count}).": ("The folder of playlist “{name}” is gone (tracks: {count}).", "Тека плейлиста «{name}» зникла (треків: {count})."),
    "В плейлисте «{name}» пропали файлы (треков: {count}).": ("Files are gone from playlist “{name}” (tracks: {count}).", "У плейлисті «{name}» зникли файли (треків: {count})."),
    "Удалить на всех устройствах?": ("Delete on all devices?", "Видалити на всіх пристроях?"),
    "Треки уйдут в корзину на 30 дней и на остальных устройствах тоже.": ("The tracks go to the trash for 30 days on the other devices too.", "Треки потраплять до кошика на 30 днів і на інших пристроях теж."),
    "Пока вы не ответите, ничего не удаляется и не уходит на другие устройства.": ("Until you answer, nothing is deleted or sent to other devices.", "Поки ви не відповісте, нічого не видаляється й не надсилається на інші пристрої."),
    "Вернуть с других устройств": ("Get back from other devices", "Повернути з інших пристроїв"),
    "Удалить везде": ("Delete everywhere", "Видалити всюди"),
    "Да": ("Yes", "Так"),
    "Вкл": ("On", "Увімк"),
    "Выкл": ("Off", "Вимк"),
    "Сейчас играет": ("Now playing", "Зараз грає"),
    "Сейчас играет: {title}": ("Now playing: {title}", "Зараз грає: {title}"),
    "Повтор": ("Repeat", "Повтор"),
    "Стандартный": ("Standard", "Стандартний"),
    "Разнобой": ("Shuffle", "Вперемішку"),
    "Анархия": ("Anarchy", "Анархія"),
    "Установить обновление?": ("Install the update?", "Встановити оновлення?"),
    "Воспроизведение прервётся: Android закроет приложение на время установки.": ("Playback will stop: Android closes the app during installation.", "Відтворення перерветься: Android закриє застосунок на час встановлення."),
    "Воспроизведение прервётся: программа закроется и сразу запустится в новой версии.": ("Playback will stop: the program closes and starts again in the new version.", "Відтворення перерветься: програма закриється й одразу запуститься в новій версії."),
    "Установить": ("Install", "Встановити"),
    "{a1} МБ": ("{a1} MB", "{a1} МБ"),
    "{a1} из {size}": ("{a1} of {size}", "{a1} з {size}"),
    "Доступна версия {version}": ("Version {version} is available", "Доступна версія {version}"),
    "Скачано {progress}": ("Downloaded {progress}", "Завантажено {progress}"),
    "Размер {size}": ("Size {size}", "Розмір {size}"),
    "Скачать": ("Download", "Завантажити"),
    "Загрузка версии {version}: пауза": ("Downloading version {version}: paused", "Завантаження версії {version}: пауза"),
    "Загрузка версии {version}": ("Downloading version {version}", "Завантаження версії {version}"),
    "Продолжить": ("Resume", "Продовжити"),
    "Стоп": ("Stop", "Стоп"),
    "Версия {version}: проверяю и распаковываю…": ("Version {version}: verifying and unpacking…", "Версія {version}: перевіряю та розпаковую…"),
    "Версия {version} готова": ("Version {version} is ready", "Версія {version} готова"),
    "Не удалось установить: {error}": ("Could not install: {error}", "Не вдалося встановити: {error}"),
    "Android попросит подтвердить установку. После неё откройте приложение снова.": ("Android will ask you to confirm the installation. Open the app again afterwards.", "Android попросить підтвердити встановлення. Після нього відкрийте застосунок знову."),
    "Программа закроется на пару секунд и запустится уже обновлённой.": ("The program closes for a couple of seconds and starts again updated.", "Програма закриється на кілька секунд і запуститься вже оновленою."),
    "Устанавливаю версию {version}…": ("Installing version {version}…", "Встановлюю версію {version}…"),
    "Не удалось скачать версию {version}": ("Could not download version {version}", "Не вдалося завантажити версію {version}"),
    "Язык": ("Language", "Мова"),
    "Как в системе": ("Same as system", "Як у системі"),
    "Автосинхронизация включена": ("Auto sync is on", "Автосинхронізацію ввімкнено"),
}

PLURALS_EN = {"треков": ("track", "tracks"), "плейлистов": ("playlist", "playlists"), "папок": ("folder", "folders")}
PLURALS_UK = {"треков": ("трек", "треки", "треків"), "плейлистов": ("плейлист", "плейлисти", "плейлистів"), "папок": ("тека", "теки", "тек")}


def holes(s):
    return sorted(set(re.findall(r"\{[A-Za-z0-9_]+\}", s)))


def dart_str(s):
    # s уже в виде исходника Dart (с экранированием \n, \\); экранируем только кавычки
    out = []
    i = 0
    while i < len(s):
        if s[i] == "\\":
            out.append(s[i:i + 2]); i += 2; continue
        out.append("\\'" if s[i] == "'" else s[i]); i += 1
    return "'" + "".join(out) + "'"


def main():
    keys = collect_keys()
    missing = [k for k in keys if k not in T]
    unused = [k for k in T if k not in keys]
    bad = [k for k, (en, uk) in T.items() if holes(k) != holes(en) or holes(k) != holes(uk)]
    if missing or bad:
        print("НЕТ ПЕРЕВОДА:", *missing, sep="\n  ")
        print("ПОДСТАНОВКИ НЕ СОВПАДАЮТ:", *bad, sep="\n  ")
        sys.exit(1)
    if unused:
        print("лишние (нет в коде):", *unused, sep="\n  ")
    for lang, idx, plurals in (("en", 0, PLURALS_EN), ("uk", 1, PLURALS_UK)):
        name = "En" if lang == "en" else "Uk"
        lines = [
            f"// Создано tools/i18n.py: перевод строк интерфейса ({'английский' if lang == 'en' else 'украинский'}).",
            "// Ключ - русский текст из кода, значение - перевод. Подстановки {..} совпадают с ключом.",
            "",
            f"const Map<String, String> kStrings{name} = {{",
        ]
        for k in keys:
            lines.append(f"  {dart_str(k)}:\n      {dart_str(T[k][idx])},")
        lines.append("};")
        lines.append("")
        lines.append(f"/// Формы слов для [plural]: ключ - русская форма «много».")
        if lang == "en":
            lines.append("const Map<String, (String, String)> kPluralsEn = {")
            for k, (a, b) in plurals.items():
                lines.append(f"  '{k}': ('{a}', '{b}'),")
        else:
            lines.append("const Map<String, (String, String, String)> kPluralsUk = {")
            for k, (a, b, c) in plurals.items():
                lines.append(f"  '{k}': ('{a}', '{b}', '{c}'),")
        lines.append("};")
        out = pathlib.Path("lib/l10n") / f"strings_{lang}.dart"
        out.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
        print(out, len(keys))


main()
