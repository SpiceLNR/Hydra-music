"""Переводы сообщений ядра (ошибки и журнал сети) на английский и украинский.

Запуск из корня репозитория:  python tools/i18n_core.py
Собирает строки вызовов tr("…") / trf("…") из core/src и ffi/src, проверяет, что у каждой есть
перевод, что подстановки {имя} совпадают и что строки подробностей журнала ('#' в начале)
остаются строками подробностей, и переписывает core/src/i18n_table.rs.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# русский: (английский, украинский)
T = {
    # картинки и перенос библиотеки
    "хэш картинки": ("image hash", "хеш зображення"),
    "путь к новой папке должен быть полным": ("the new folder path must be absolute", "шлях до нової теки має бути повним"),
    "новая папка не может совпадать со старой или лежать внутри неё (и наоборот)": (
        "the new folder cannot be the old one or lie inside it (or the other way round)",
        "нова тека не може збігатися зі старою або лежати всередині неї (і навпаки)"),
    "на месте новой папки лежит файл": ("there is a file where the new folder should be", "на місці нової теки лежить файл"),
    "новая папка должна быть пустой": ("the new folder must be empty", "нова тека має бути порожньою"),
    "у новой папки нет родителя": ("the new folder has no parent", "нова тека не має батьківської"),
    "у новой папки нет имени": ("the new folder has no name", "нова тека не має назви"),
    "файл скопирован с ошибкой: {a1}": ("file copied with an error: {a1}", "файл скопійовано з помилкою: {a1}"),
    "был у нас": ("was ours", "був у нас"),
    "новый": ("new", "новий"),
    "обложки": ("covers", "обкладинки"),
    # библиотека
    "в плейлисте есть треки: сначала удалите или перенесите их": (
        "the playlist has tracks: delete or move them first",
        "у плейлисті є треки: спочатку видаліть або перенесіть їх"),
    "в папке плейлиста остались посторонние файлы; приложение их не удаляет": (
        "the playlist folder still has other files; the app does not delete them",
        "у теці плейлиста залишилися сторонні файли; застосунок їх не видаляє"),
    "название не может быть пустым": ("the name cannot be empty", "назва не може бути порожньою"),
    "название слишком длинное": ("the name is too long", "назва задовга"),
    "название или исполнитель слишком длинные": ("the title or artist is too long", "назва або виконавець задовгі"),
    "файла трека нет на диске": ("the track file is not on disk", "файлу треку немає на диску"),
    "трек стёрт из корзины насовсем": ("the track was permanently erased from the trash", "трек остаточно стерто з кошика"),
    "неизвестное правило порядка: {mode}": ("unknown sort rule: {mode}", "невідоме правило порядку: {mode}"),
    "папка библиотеки выглядит пустой; удаление треков отменено": (
        "the library folder looks empty; track deletion cancelled",
        "тека бібліотеки виглядає порожньою; видалення треків скасовано"),
    "нет такого ожидающего удаления": ("no such pending removal", "немає такого очікуваного видалення"),
    # шифрованный канал
    "шифрованный канал: {e}": ("encrypted channel: {e}", "шифрований канал: {e}"),
    "рукопожатие не завершено": ("handshake not finished", "рукостискання не завершено"),
    "нет ключа собеседника": ("no peer key", "немає ключа співрозмовника"),
    "это не Hydra Music": ("this is not Hydra Music", "це не Hydra Music"),
    "сопряжение сейчас не открыто на этом устройстве": (
        "pairing is not open on this device right now",
        "сполучення зараз не відкрито на цьому пристрої"),
    "синхронизация остановлена": ("sync stopped", "синхронізацію зупинено"),
    "повреждён заголовок сообщения": ("message header is damaged", "пошкоджено заголовок повідомлення"),
    "слишком большое сообщение": ("message too large", "завелике повідомлення"),
    "пустой кадр": ("empty frame", "порожній кадр"),
    "длина сообщения не сошлась": ("message length mismatch", "довжина повідомлення не збіглася"),
    "имя устройства не может быть пустым": ("the device name cannot be empty", "назва пристрою не може бути порожньою"),
    # интернет
    "время ожидания вышло": ("timed out", "час очікування минув"),
    "адрес устройства повреждён: {e}": ("device address is damaged: {e}", "адресу пристрою пошкоджено: {e}"),
    "устройство не отвечает": ("the device does not respond", "пристрій не відповідає"),
    "адрес relay-сервера не подходит: «{url}»": ("unsuitable relay server address: “{url}”", "адреса relay-сервера не підходить: «{url}»"),
    "адрес relay-сервера должен начинаться с https://: «{url}»": (
        "the relay server address must start with https://: “{url}”",
        "адреса relay-сервера має починатися з https://: «{url}»"),
    # узел
    "через интернет": ("over the internet", "через інтернет"),
    "по сети, {addr}": ("over the network, {addr}", "мережею, {addr}"),
    "устройство ответило и закрыло соединение ({via}). Проверьте, что QR-код на втором устройстве ещё действует (3 минуты) и что на нём не идёт другая синхронизация; причина записана в журнале того устройства": (
        "the device answered and closed the connection ({via}). Check that the QR code on the other device is still valid (3 minutes) and that it is not busy with another sync; the reason is in that device's log",
        "пристрій відповів і закрив з'єднання ({via}). Перевірте, що QR-код на другому пристрої ще дійсний (3 хвилини) і що на ньому не йде інша синхронізація; причину записано в журналі того пристрою"),
    "устройство закрыло соединение ({via}): скорее всего, оно занято другой синхронизацией; попытка повторится сама": (
        "the device closed the connection ({via}): it is probably busy with another sync; it will be retried automatically",
        "пристрій закрив з'єднання ({via}): найімовірніше, він зайнятий іншою синхронізацією; спроба повториться сама"),
    "секрет сопряжения повреждён": ("pairing secret is damaged", "секрет сполучення пошкоджено"),
    "Связь через интернет включена": ("Internet connection enabled", "Зв'язок через інтернет увімкнено"),
    "Связь через интернет включена (relay: {relay})": ("Internet connection enabled (relay: {relay})", "Зв'язок через інтернет увімкнено (relay: {relay})"),
    "Связь через интернет не запустилась: {e}": ("Internet connection failed to start: {e}", "Зв'язок через інтернет не запустився: {e}"),
    "сборка без связи через интернет": ("this build has no internet connection support", "збірка без зв'язку через інтернет"),
    "связь через интернет не включена": ("internet connection is not enabled", "зв'язок через інтернет не увімкнено"),
    "Подключаюсь через интернет": ("Connecting over the internet", "Підключаюся через інтернет"),
    "через интернет: {e}": ("over the internet: {e}", "через інтернет: {e}"),
    "нет адреса устройства": ("no device address", "немає адреси пристрою"),
    "Слушаю порт {port}": ("Listening on port {port}", "Слухаю порт {port}"),
    "Поиск устройств недоступен: {e}": ("Device discovery unavailable: {e}", "Пошук пристроїв недоступний: {e}"),
    "Входящее подключение отклонено: уже идёт другая синхронизация": (
        "Incoming connection rejected: another sync is already running",
        "Вхідне підключення відхилено: вже йде інша синхронізація"),
    "из интернета": ("from the internet", "з інтернету"),
    "Входящее подключение ({from}): {e}": ("Incoming connection ({from}): {e}", "Вхідне підключення ({from}): {e}"),
    "устройство не входит в семью": ("the device is not in the family", "пристрій не входить до родини"),
    "Сопряжение": ("Pairing", "Сполучення"),
    "Синхронизация": ("Sync", "Синхронізація"),
    "нельзя синхронизироваться с самим собой": ("cannot sync with itself", "не можна синхронізуватися з самим собою"),
    "Добавлено устройство «{name}»": ("Device “{name}” added", "Додано пристрій «{name}»"),
    "«{name}» удалило это устройство из своего списка: оно убрано и у нас": (
        "“{name}” removed this device from its list: it has been removed here too",
        "«{name}» видалив цей пристрій зі свого списку: його прибрано й у нас"),
    "устройство представилось чужим именем": ("the device introduced itself with someone else's identity", "пристрій назвався чужим ім'ям"),
    "не удалось подключиться ({a1})": ("could not connect ({a1})", "не вдалося підключитися ({a1})"),
    "Уже идёт другая синхронизация, подождите": ("Another sync is already running, please wait", "Вже йде інша синхронізація, зачекайте"),
    "Готово": ("Done", "Готово"),
    "Синхронизация с «{peer_name}»: получено файлов {files_received}, отправлено {files_sent}": (
        "Sync with “{peer_name}”: files received {files_received}, sent {files_sent}",
        "Синхронізація з «{peer_name}»: отримано файлів {files_received}, надіслано {files_sent}"),
    "Передано {a1} МБ за {a2} с: {a3} МБ/с ({a4})": ("Transferred {a1} MB in {a2} s: {a3} MB/s ({a4})", "Передано {a1} МБ за {a2} с: {a3} МБ/с ({a4})"),
    "Ошибка: {e}": ("Error: {e}", "Помилка: {e}"),
    "ключ устройства повреждён": ("device key is damaged", "ключ пристрою пошкоджено"),
    "ключ устройства не совпал с QR-кодом": ("the device key does not match the QR code", "ключ пристрою не збігся з QR-кодом"),
    "такого устройства нет в семье": ("no such device in the family", "такого пристрою немає в родині"),
    "«{name}» сейчас не видно в сети": ("“{name}” is not visible on the network right now", "«{name}» зараз не видно в мережі"),
    "Синхронизация с «{name}»": ("Sync with “{name}”", "Синхронізація з «{name}»"),
    "Повторная попытка через {pause} с": ("Retrying in {pause} s", "Повторна спроба через {pause} с"),
    "не удалось подключиться": ("could not connect", "не вдалося підключитися"),
    "ключ устройства изменился: отзовите его и добавьте заново": (
        "the device key has changed: remove the device and add it again",
        "ключ пристрою змінився: відкличте його й додайте знову"),
    "занято другой синхронизацией": ("busy with another sync", "зайнято іншою синхронізацією"),
    "ключ устройства изменился": ("the device key has changed", "ключ пристрою змінився"),
    "«{name}» уведомлено об удалении": ("“{name}” notified of the removal", "«{name}» повідомлено про видалення"),
    "«{name}» пока не уведомлено об удалении: {e}": ("“{name}” not yet notified of the removal: {e}", "«{name}» поки не повідомлено про видалення: {e}"),
    "Имя этого устройства: «{name}»": ("This device's name: “{name}”", "Назва цього пристрою: «{name}»"),
    # сеанс синхронизации
    "синхронизация: {e}": ("sync: {e}", "синхронізація: {e}"),
    "у «{name}» другая версия протокола ({proto}), обновите приложение на обоих устройствах": (
        "“{name}” uses a different protocol version ({proto}), update the app on both devices",
        "у «{name}» інша версія протоколу ({proto}), оновіть застосунок на обох пристроях"),
    "Сверяю списки": ("Comparing lists", "Звіряю списки"),
    "#Описи: у меня {a1} треков (без хэша {a2}), у них {a3} (без хэша {a4}); совмещено id: {adopted}": (
        "#Inventories: I have {a1} tracks ({a2} without hash), they have {a3} ({a4} without hash); ids matched: {adopted}",
        "#Описи: у мене {a1} треків (без хешу {a2}), у них {a3} (без хешу {a4}); суміщено id: {adopted}"),
    "Обмениваюсь изменениями": ("Exchanging changes", "Обмінююся змінами"),
    "#Файлы, нужные обоим устройствам из-за расхождения хэша: {a1}; журнал исправил я: {healed}": (
        "#Files both devices need because of a hash mismatch: {a1}; journal fixed by me: {healed}",
        "#Файли, потрібні обом пристроям через розбіжність хешу: {a1}; журнал виправив я: {healed}"),
    "#В корзину из-за чужого удаления, например: {a1}": (
        "#Moved to trash because of a remote deletion, for example: {a1}",
        "#До кошика через чуже видалення, наприклад: {a1}"),
    "#Файл на месте, но хэш не совпал: {hash_mismatch}, например: {a1}": (
        "#File is present but the hash differs: {hash_mismatch}, for example: {a1}",
        "#Файл на місці, але хеш не збігся: {hash_mismatch}, наприклад: {a1}"),
    "#Мне нужны, например: {a1}": ("#I need, for example: {a1}", "#Мені потрібні, наприклад: {a1}"),
    "#Принято операций {new_ops}, в корзину {trashed}; мне нужно файлов {a1}, им нужно {a2}": (
        "#Operations accepted {new_ops}, to trash {trashed}; files I need {a1}, they need {a2}",
        "#Прийнято операцій {new_ops}, до кошика {trashed}; мені потрібно файлів {a1}, їм потрібно {a2}"),
    "{a1} МБ за {a2} с, {a3} МБ/с": ("{a1} MB in {a2} s, {a3} MB/s", "{a1} МБ за {a2} с, {a3} МБ/с"),
    "#Хэш в журнале не совпадал с моим файлом, исправил: {playlist}/{file_name}": (
        "#Journal hash did not match my file, fixed: {playlist}/{file_name}",
        "#Хеш у журналі не збігався з моїм файлом, виправив: {playlist}/{file_name}"),
    "Отправляю файлы: {a1} из {total}": ("Sending files: {a1} of {total}", "Надсилаю файли: {a1} з {total}"),
    "#Отправлено файлов {a1} из {total}: {a2}": ("#Files sent {a1} of {total}: {a2}", "#Надіслано файлів {a1} з {total}: {a2}"),
    "файлы пришли не в том порядке": ("files arrived out of order", "файли прийшли не в тому порядку"),
    "#Файл не прислан (у отправителя его нет или он ещё не получен): {playlist}/{file_name}": (
        "#File not sent (the sender does not have it or has not received it yet): {playlist}/{file_name}",
        "#Файл не надіслано (у відправника його немає або він ще не отриманий): {playlist}/{file_name}"),
    "Получаю файлы: {a1} из {total}": ("Receiving files: {a1} of {total}", "Отримую файли: {a1} з {total}"),
    "файл длиннее, чем объявлено": ("the file is longer than announced", "файл довший, ніж оголошено"),
    "#Получено файлов {a1} из {total}: {a2}": ("#Files received {a1} of {total}: {a2}", "#Отримано файлів {a1} з {total}: {a2}"),
    "#Файл отклонён: {playlist}/{file_name}: прислан хэш {a1}, в журнале {a2}": (
        "#File rejected: {playlist}/{file_name}: received hash {a1}, journal has {a2}",
        "#Файл відхилено: {playlist}/{file_name}: надіслано хеш {a1}, у журналі {a2}"),
    # теги
    "теги: {e}": ("tags: {e}", "теги: {e}"),
    "не удалось прочитать картинку: {e}": ("could not read the image: {e}", "не вдалося прочитати зображення: {e}"),
    "не удалось сжать картинку: {e}": ("could not compress the image: {e}", "не вдалося стиснути зображення: {e}"),
    "формат не поддерживает теги": ("the format does not support tags", "формат не підтримує теги"),
    # мост
    "реестр: {e}": ("registry: {e}", "реєстр: {e}"),
    "не удалось включить автозапуск: {e}": ("could not enable autostart: {e}", "не вдалося увімкнути автозапуск: {e}"),
    "не удалось выключить автозапуск: {e}": ("could not disable autostart: {e}", "не вдалося вимкнути автозапуск: {e}"),
    "автозапуск есть только на Windows": ("autostart is available only on Windows", "автозапуск є лише на Windows"),
    "args: нужны строки": ("args: strings expected", "args: потрібні рядки"),
    "args: нужен список строк": ("args: a list of strings expected", "args: потрібен список рядків"),
    "не удалось запустить {program}: {e}": ("could not start {program}: {e}", "не вдалося запустити {program}: {e}"),
}

CALL = re.compile(r'(?<![\w.:])(?:tr|trf)\("((?:[^"\\]|\\.)*)"')
HOLE = re.compile(r"\{[^{}]*\}")


def keys_in_sources():
    keys = []
    for root in ("core/src", "ffi/src"):
        for p in sorted((ROOT / root).rglob("*.rs")):
            if p.name == "i18n_table.rs":
                continue
            for m in CALL.finditer(p.read_text(encoding="utf-8")):
                if m.group(1) not in keys:
                    keys.append(m.group(1))
    return keys


def rs(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    keys = keys_in_sources()
    errors = [f"нет перевода: {k}" for k in keys if k not in T]
    errors += [f"лишний перевод (строки нет в коде): {k}" for k in T if k not in keys]
    for ru, (en, uk) in T.items():
        for lang, s in (("en", en), ("uk", uk)):
            if sorted(HOLE.findall(ru)) != sorted(HOLE.findall(s)):
                errors.append(f"{lang}: подстановки не совпадают: {ru}")
            if ru.startswith("#") != s.startswith("#"):
                errors.append(f"{lang}: знак '#' в начале: {ru}")
    if errors:
        print("\n".join(errors))
        sys.exit(1)
    lines = [
        "// Сгенерировано tools/i18n_core.py: не править руками.",
        "// (русский, английский, украинский)",
        "pub static TABLE: &[(&str, &str, &str)] = &[",
    ]
    for k in keys:
        en, uk = T[k]
        lines.append(f"    ({rs(k)}, {rs(en)}, {rs(uk)}),")
    lines.append("];")
    out = ROOT / "core/src/i18n_table.rs"
    out.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"{len(keys)} строк -> {out.relative_to(ROOT)}")


main()
