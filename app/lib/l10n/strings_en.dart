// Создано tools/i18n.py: перевод строк интерфейса (английский).
// Ключ - русский текст из кода, значение - перевод. Подстановки {..} совпадают с ключом.

const Map<String, String> kStringsEn = {
  'код {code}':
      'code {code}',
  'загрузка прервана':
      'loading interrupted',
  'Воспроизведение':
      'Playback',
  'Платформа не поддерживается: {operatingSystem}':
      'Platform not supported: {operatingSystem}',
  'Не удалось загрузить ядро: {e}':
      'Could not load the core: {e}',
  'неизвестная ошибка ядра':
      'unknown core error',
  'Отмена':
      'Cancel',
  'Новый плейлист':
      'New playlist',
  'Название папки':
      'Folder name',
  'Создать':
      'Create',
  'Переименовать плейлист':
      'Rename playlist',
  'Сохранить':
      'Save',
  'Удалить можно только пустой плейлист: в «{name}» есть треки.':
      'Only an empty playlist can be deleted: “{name}” has tracks.',
  'Удалить плейлист?':
      'Delete playlist?',
  'Пустая папка «{name}» будет удалена.':
      'The empty folder “{name}” will be deleted.',
  'Удалить':
      'Delete',
  'По исполнителю':
      'By artist',
  'По названию трека':
      'By track title',
  'Как попало':
      'Any order',
  'Открыть':
      'Open',
  'Переименовать':
      'Rename',
  'Удалить плейлист':
      'Delete playlist',
  'Название трека':
      'Track title',
  'Название':
      'Title',
  'Название записано в файл.':
      'Title written to the file.',
  'Этот формат не хранит теги: название сохранено только в приложении.':
      'This format has no tags: the title is saved in the app only.',
  'Исполнитель':
      'Artist',
  'Исполнитель записан в файл.':
      'Artist written to the file.',
  'Этот формат не хранит теги: исполнитель сохранён только в приложении.':
      'This format has no tags: the artist is saved in the app only.',
  'Не удалось открыть выбор картинки: {e}':
      'Could not open the image picker: {e}',
  'Обложка записана в файл.':
      'Cover written to the file.',
  'Нет другого плейлиста. Создайте его кнопкой в списке плейлистов.':
      'There is no other playlist. Create one with the button in the playlist list.',
  'Переместить в…':
      'Move to…',
  'Переместить трек?':
      'Move track?',
  '«{title}» будет перенесён из «{from}» в «{name}». Файл физически переместится между папками.':
      '“{title}” will be moved from “{from}” to “{name}”. The file is physically moved between folders.',
  'Переместить':
      'Move',
  'Удалить трек?':
      'Delete track?',
  '«{title}» уйдёт в корзину на 30 дней.':
      '“{title}” goes to the trash for 30 days.',
  'Играть':
      'Play',
  'Обложка':
      'Cover',
  'Удалить навсегда?':
      'Delete forever?',
  '«{title}» будет стёрт без возможности восстановления.':
      '“{title}” will be erased permanently.',
  'Очистить корзину?':
      'Empty the trash?',
  'Все треки в корзине ({length}) будут стёрты без возможности восстановления.':
      'All tracks in the trash ({length}) will be erased permanently.',
  'Очистить':
      'Empty',
  'Восстановить':
      'Restore',
  'Удалить навсегда':
      'Delete forever',
  'сегодня, осталось {left} дн.':
      'today, {left} d left',
  '{days} дн. назад, осталось {left} дн.':
      '{days} d ago, {left} d left',
  'Устройства':
      'Devices',
  'Корзина':
      'Trash',
  'Настройки':
      'Settings',
  'Свернуть (выход - в меню значка в трее)':
      'Minimize (Exit is in the tray icon menu)',
  'Закрыть':
      'Close',
  'Нет плейлистов':
      'No playlists',
  'Плейлистов пока нет.\nСоздайте плейлист в списке выше или положите папку с музыкой в Музыка\\Hydra.':
      'No playlists yet.\nCreate one in the list above or put a music folder into Music\\Hydra.',
  'Папка пуста. Положите файлы в Музыка\\Hydra\\{name}.':
      'The folder is empty. Put files into Music\\Hydra\\{name}.',
  'Корзина пуста.\nУдалённые треки хранятся здесь 30 дней.':
      'The trash is empty.\nDeleted tracks are kept here for 30 days.',
  'Очистить корзину':
      'Empty trash',
  'Ошибка: {a1}':
      'Error: {a1}',
  'неизвестная':
      'unknown',
  'Сканирую библиотеку…':
      'Scanning the library…',
  'правый клик - действия':
      'right-click for actions',
  'Ничего не играет':
      'Nothing is playing',
  'Выберите трек в списке':
      'Pick a track in the list',
  'Назад':
      'Previous',
  'Пауза':
      'Pause',
  'Вперёд':
      'Next',
  'Показать':
      'Show',
  'Выход':
      'Exit',
  '; рядом: {a1}':
      '; nearby: {a1}',
  'файла нет по пути «{path}»{hint}':
      'no file at “{path}”{hint}',
  'файл пустой (0 байт)':
      'the file is empty (0 bytes)',
  'файл {mb} МБ, начало: {ascii} ({hex})':
      'file {mb} MB, starts with: {ascii} ({hex})',
  'файл не прочитался: {e}':
      'the file could not be read: {e}',
  'Папка выбрана, но выбор не сохранился: {error}':
      'The folder is selected, but the choice was not saved: {error}',
  'ещё не синхронизировались':
      'not synced yet',
  'устройство':
      'device',
  'Телефон':
      'Phone',
  'Компьютер':
      'Computer',
  'Синхронизация':
      'Sync',
  'Автосинхронизация включена':
      'Auto sync is on',
  'Это не ссылка сопряжения Hydra Music':
      'This is not a Hydra Music pairing link',
  'Подключаюсь к устройству...':
      'Connecting to the device...',
  'Сеть не запустилась: {message}':
      'Network did not start: {message}',
  'Сопряжение':
      'Pairing',
  'Синхронизация с «{name}»':
      'Syncing with “{name}”',
  'сеть ещё не запущена':
      'the network has not started yet',
  'Не удалось воспроизвести {name}{message}':
      'Could not play {name}{message}',
  'Не удалось воспроизвести {name}{message}\n{info}':
      'Could not play {name}{message}\n{info}',
  'Удалить устройство?':
      'Remove device?',
  '«{name}» исчезнет из списка, и устройства перестанут синхронизироваться. Музыка на обоих устройствах останется на месте. Это устройство тоже уберёт вас из своего списка: сразу, если оно в сети, иначе когда появится (до 14 дней).':
      '“{name}” disappears from the list and the devices stop syncing. Music stays on both devices. That device also removes you from its list: right away if it is online, otherwise when it shows up (within 14 days).',
  'Название устройства':
      'Device name',
  'Например, «Ноутбук»':
      'For example, “Laptop”',
  'Само устройство называет себя «{originalName}». Новое имя видно только здесь; пустое поле вернёт исходное.':
      'The device calls itself “{originalName}”. The new name is visible only here; an empty field restores the original.',
  'Добавить устройство':
      'Add device',
  'Показать QR-код на этом устройстве':
      'Show a QR code on this device',
  'Сканировать QR-код другого устройства':
      'Scan another device\'s QR code',
  'Ввести ссылку сопряжения':
      'Enter a pairing link',
  'Журнал':
      'Log',
  'устройства':
      'devices',
  'Пока нет ни одного устройства. Оба устройства должны быть в одной Wi-Fi сети. Нажмите «Добавить устройство»: на одном покажите QR-код, на другом отсканируйте его.':
      'No devices yet. Both devices must be on the same Wi-Fi network. Tap “Add device”: show the QR code on one and scan it on the other.',
  'Сеть запускается...':
      'Network is starting...',
  'Идёт синхронизация...':
      'Syncing...',
  '{a1} · синхронизация: {lastSyncLabel}':
      '{a1} · synced: {lastSyncLabel}',
  'в сети':
      'online',
  'не в сети':
      'offline',
  'Синхронизировать':
      'Sync',
  'библиотека':
      'library',
  'главная':
      'home',
  'Плейлисты':
      'Playlists',
  'синхронизация':
      'sync',
  'хранится 30 дней':
      'kept for 30 days',
  'Нужен доступ ко всем файлам, чтобы работать с папкой Music/Hydra.':
      'Access to all files is needed to work with the Music/Hydra folder.',
  'Разрешить доступ':
      'Allow access',
  'Повторить':
      'Retry',
  'журнал':
      'log',
  'Журнал пока пуст.':
      'The log is empty.',
  'Нет подключения к локальной сети (Wi-Fi).':
      'No local network (Wi-Fi) connection.',
  'Устройство добавлено':
      'Device added',
  'QR-код':
      'QR code',
  'Код действует ещё {a1}:{a2}. На втором устройстве откройте «Устройства» -> «Добавить устройство» -> «Сканировать».':
      'The code is valid for {a1}:{a2}. On the other device open “Devices” -> “Add device” -> “Scan”.',
  'Код устарел.':
      'The code has expired.',
  'Оба устройства должны быть в одной Wi-Fi сети.':
      'Both devices must be on the same Wi-Fi network.',
  'Показать новый код':
      'Show a new code',
  'Ссылка скопирована':
      'Link copied',
  'Скопировать ссылку (для ввода вручную)':
      'Copy the link (for manual entry)',
  'Наведите камеру на QR-код на втором устройстве':
      'Point the camera at the QR code on the other device',
  'Камера не найдена':
      'No camera found',
  'кадров проверено: {_frames}':
      'frames checked: {_frames}',
  'ошибка разбора: {e}':
      'decoding error: {e}',
  'QR прочитан, но это не код сопряжения Hydra Music':
      'QR read, but it is not a Hydra Music pairing code',
  'сканировать QR':
      'scan QR',
  'Камера недоступна: {_error}':
      'Camera unavailable: {_error}',
  'Ввести ссылку вручную':
      'Enter the link manually',
  'Ссылка сопряжения':
      'Pairing link',
  'Подключиться':
      'Connect',
  'Это не похоже на ссылку сопряжения':
      'This does not look like a pairing link',
  'Сохранено, теги записаны в файл.':
      'Saved, tags written to the file.',
  'Этот формат не хранит теги: изменения сохранены только в приложении.':
      'This format has no tags: changes are saved in the app only.',
  'плеер':
      'player',
  'Настройки трека':
      'Track settings',
  'Изменить обложку':
      'Change cover',
  'Название композиции':
      'Track title',
  'Нет другого плейлиста. Создайте его на экране «Плейлисты».':
      'There is no other playlist. Create one on the “Playlists” screen.',
  '«{title}» будет перенесён из «{name}» в «{a1}». Файл физически переместится между папками.':
      '“{title}” will be moved from “{name}” to “{a1}”. The file is physically moved between folders.',
  'Порядок треков':
      'Track order',
  'Порядок: {_sortLabel}':
      'Order: {_sortLabel}',
  'Готово':
      'Done',
  'редактирование':
      'editing',
  'Обновить':
      'Refresh',
  'Папка пуста. Положите файлы в Music/Hydra/{name} и нажмите «Обновить».':
      'The folder is empty. Put files into Music/Hydra/{name} and tap “Refresh”.',
  'Тяните за тёмную область справа, чтобы изменить порядок. Карандаш переименовывает плейлист.':
      'Drag the dark area on the right to reorder. The pencil renames the playlist.',
  'плейлисты':
      'playlists',
  'Плейлистов пока нет.\nСоздайте плейлист кнопкой ниже или положите папку с музыкой в Music/Hydra.':
      'No playlists yet.\nCreate one with the button below or put a music folder into Music/Hydra.',
  'Новая папка библиотеки':
      'New library folder',
  'Не удалось открыть выбор папки: {e}':
      'Could not open the folder picker: {e}',
  'Папка библиотеки':
      'Library folder',
  'Выбрано: {picked}\n\n«Перенести»: все плейлисты и корзина переедут\nиз: {old}\nв: {target}\nЕсли папки на разных дисках, это может занять много времени. Если что-то пойдёт не так, всё вернётся на место.\n\n«Использовать эту»: ничего не переносится, приложение начнёт работать с выбранной папкой как с библиотекой (например, после переустановки, когда музыка уже лежит там).\n\nМузыка остановится, идущая синхронизация прервётся.':
      'Selected: {picked}\n\n“Move”: all playlists and the trash move\nfrom: {old}\nto: {target}\nIf the folders are on different drives, this may take a long time. If anything goes wrong, everything is put back.\n\n“Use this one”: nothing is moved, the app starts using the selected folder as the library (for example, after reinstalling, when the music is already there).\n\nPlayback stops and a running sync is interrupted.',
  'Использовать эту':
      'Use this one',
  'Перенести':
      'Move',
  'Теперь библиотека: {picked}':
      'The library is now: {picked}',
  'Не удалось открыть папку: {e}':
      'Could not open the folder: {e}',
  'Переношу файлы…':
      'Moving files…',
  'Библиотека перенесена: файлов {a1}{a2}':
      'Library moved: {a1} files{a2}',
  '. Не удалось убрать старые файлы: {left} (папка занята)':
      '. Could not remove old files: {left} (folder in use)',
  'Перенос не выполнен, всё осталось на месте: {message}':
      'Not moved, everything stayed in place: {message}',
  'Перенос не выполнен: {e}':
      'Not moved: {e}',
  'Не запустилось: {internetError}':
      'Did not start: {internetError}',
  'Заработает после перезапуска приложения.':
      'Takes effect after the app restarts.',
  'Relay-сервер':
      'Relay server',
  'Через него устройства связываются, когда напрямую не получается. Пустое поле - общедоступные серверы n0. Музыка идёт зашифрованной.':
      'Devices connect through it when a direct connection fails. An empty field means the public n0 servers. Music travels encrypted.',
  'По умолчанию':
      'Default',
  'Relay: серверы по умолчанию':
      'Relay: default servers',
  'Relay-сервер сохранён':
      'Relay server saved',
  'Relay не изменён: {err}':
      'Relay not changed: {err}',
  'Как в системе':
      'Same as system',
  'Язык':
      'Language',
  'Имя этого устройства':
      'This device\'s name',
  'Например, «Телефон Даши»':
      'For example, “Dasha\'s phone”',
  'Так это устройство увидят остальные. Они узнают новое имя при следующей синхронизации.':
      'This is how other devices see this one. They learn the new name at the next sync.',
  'Имя не сохранено: {err}':
      'Name not saved: {err}',
  'настройки':
      'settings',
  'Это устройство':
      'This device',
  'Имя':
      'Name',
  'Автоматически':
      'Automatic',
  'Только во время зарядки':
      'Only while charging',
  'Через интернет':
      'Over the internet',
  'Через интернет только по Wi-Fi':
      'Internet only over Wi-Fi',
  'по умолчанию':
      'default',
  'Разрешить работу в фоне':
      'Allow background work',
  'Библиотека':
      'Library',
  'Папка':
      'Folder',
  'Окно':
      'Window',
  'Сторона':
      'Side',
  'Слева':
      'Left',
  'Справа':
      'Right',
  'Сворачивать при клике мимо':
      'Collapse on outside click',
  'Обновления':
      'Updates',
  'Ядро не запустилось: {error}':
      'The core did not start: {error}',
  'внизу шторки':
      'at the bottom of the panel',
  'на главном экране под плитками':
      'on the home screen below the tiles',
  'Доступна версия {a1}: плашка {where}.':
      'Version {a1} is available: see the banner {where}.',
  'Установлена последняя версия.':
      'You have the latest version.',
  'Не удалось связаться с GitHub. Проверьте интернет.':
      'Could not reach GitHub. Check the internet connection.',
  'Обновление {a1} уже скачивается или готово: плашка {where}.':
      'Update {a1} is already downloading or ready: see the banner {where}.',
  'Обновления проверяются только у сборок из GitHub.':
      'Updates are checked only for builds from GitHub.',
  'сборка {kBuild} · локальная, обновления не проверяются':
      'build {kBuild} · local, updates are not checked',
  'Проверяю…':
      'Checking…',
  'сборка {kBuild}':
      'build {kBuild}',
  'сборка {kBuild} · проверено в {a1}':
      'build {kBuild} · checked at {a1}',
  'Версия {kVersion}':
      'Version {kVersion}',
  'Проверить':
      'Check',
  'Запускать вместе с Windows':
      'Start with Windows',
  'Не получилось: {_error}':
      'Failed: {_error}',
  'Трек вернулся в плейлист: файл придёт с другого устройства при синхронизации':
      'The track is back in the playlist: the file will arrive from another device at the next sync',
  'удалён сегодня':
      'deleted today',
  'удалён {days} дн. назад':
      'deleted {days} d ago',
  '{when}, осталось {left} дн.':
      '{when}, {left} d left',
  'корзина':
      'trash',
  'Корзина пуста.\nУдалённые треки хранятся здесь 30 дней, затем стираются окончательно.':
      'The trash is empty.\nDeleted tracks are kept here for 30 days, then erased permanently.',
  ' · файл на другом устройстве':
      ' · file is on another device',
  'Навсегда':
      'Forever',
  'неизвестная ошибка':
      'unknown error',
  'слишком много перенаправлений':
      'too many redirects',
  'сервер ответил {statusCode}':
      'the server replied {statusCode}',
  'загрузка прервалась':
      'the download was interrupted',
  'файл повреждён, скачайте заново':
      'the file is damaged, download it again',
  'не удалось распаковать архив':
      'could not unpack the archive',
  'нет прав на запись в папку программы':
      'no permission to write to the program folder',
  'разрешите Hydra Music устанавливать приложения и нажмите «Установить» ещё раз':
      'allow Hydra Music to install apps and tap “Install” again',
  'нет связи с GitHub':
      'no connection to GitHub',
  'GitHub не отвечает':
      'GitHub is not responding',
  'Папка плейлиста «{name}» пропала (треков: {count}).':
      'The folder of playlist “{name}” is gone (tracks: {count}).',
  'В плейлисте «{name}» пропали файлы (треков: {count}).':
      'Files are gone from playlist “{name}” (tracks: {count}).',
  'Удалить на всех устройствах?':
      'Delete on all devices?',
  'Треки уйдут в корзину на 30 дней и на остальных устройствах тоже.':
      'The tracks go to the trash for 30 days on the other devices too.',
  'Пока вы не ответите, ничего не удаляется и не уходит на другие устройства.':
      'Until you answer, nothing is deleted or sent to other devices.',
  'Вернуть с других устройств':
      'Get back from other devices',
  'Удалить везде':
      'Delete everywhere',
  'Да':
      'Yes',
  'Вкл':
      'On',
  'Выкл':
      'Off',
  'Сейчас играет':
      'Now playing',
  'Сейчас играет: {title}':
      'Now playing: {title}',
  'Повтор':
      'Repeat',
  'Стандартный':
      'Standard',
  'Разнобой':
      'Shuffle',
  'Анархия':
      'Anarchy',
  'Установить обновление?':
      'Install the update?',
  'Воспроизведение прервётся: Android закроет приложение на время установки.':
      'Playback will stop: Android closes the app during installation.',
  'Воспроизведение прервётся: программа закроется и сразу запустится в новой версии.':
      'Playback will stop: the program closes and starts again in the new version.',
  'Установить':
      'Install',
  '{a1} МБ':
      '{a1} MB',
  '{a1} из {size}':
      '{a1} of {size}',
  'Доступна версия {version}':
      'Version {version} is available',
  'Скачано {progress}':
      'Downloaded {progress}',
  'Размер {size}':
      'Size {size}',
  'Скачать':
      'Download',
  'Загрузка версии {version}: пауза':
      'Downloading version {version}: paused',
  'Загрузка версии {version}':
      'Downloading version {version}',
  'Продолжить':
      'Resume',
  'Стоп':
      'Stop',
  'Версия {version}: проверяю и распаковываю…':
      'Version {version}: verifying and unpacking…',
  'Версия {version} готова':
      'Version {version} is ready',
  'Не удалось установить: {error}':
      'Could not install: {error}',
  'Android попросит подтвердить установку. После неё откройте приложение снова.':
      'Android will ask you to confirm the installation. Open the app again afterwards.',
  'Программа закроется на пару секунд и запустится уже обновлённой.':
      'The program closes for a couple of seconds and starts again updated.',
  'Устанавливаю версию {version}…':
      'Installing version {version}…',
  'Не удалось скачать версию {version}':
      'Could not download version {version}',
};

/// Формы слов для [plural]: ключ - русская форма «много».
const Map<String, (String, String)> kPluralsEn = {
  'треков': ('track', 'tracks'),
  'плейлистов': ('playlist', 'playlists'),
  'папок': ('folder', 'folders'),
};
