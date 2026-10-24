# SBER AUDIO — музыкальный плеер на ПЛИС

Плеер на плате Digilent Nexys A7 (ПЛИС `xc7a100tcsg324-1`), SystemVerilog, без процессора: весь звук, файловая система SD-карты и интерфейс на VGA сделаны логикой.

![Экран плеера](doc/image/ui_play.png)

Кадры получены моделированием всего плеера (`src/sim/top_audio.sv`) в Icarus Verilog: [мелодия](doc/image/ui_play.png), [синтезатор, треугольная волна](doc/image/ui_synth.png), [трек SD без карты](doc/image/ui_sd.png), [заставка](doc/image/ui_splash.png).

## Что умеет

| № | Трек | Откуда звук |
|---|---|---|
| 01 | Синтезатор нот | DDS, нота кнопками, октава и форма волны переключателями |
| 02 | Коробейники | мелодия из блочной памяти (BRAM) |
| 03 | Ода к радости | мелодия из BRAM |
| 04, 05 | первые два файла `*.WAV` с microSD | FAT32, WAV 8/16 бит, моно/стерео, любая частота дискретизации |
| 06 | поток с ПК | любой файл (MP3 тоже), ПК декодирует и шлёт по USB-UART |
| — | MIDI-клавиатура | через ноутбук, 8-голосный синтезатор поверх любого трека |

Качество звука:

* 10-голосный DDS-синтезатор: синус, треугольник, меандр, пила; у каждой ноты огибающая ADSR;
* громкость по логарифмической шкале (шаг 2 дБ), все изменения плавные (~20 мс): пауза, громкость и смена трека без щелчков;
* ШИМ 10 бит / 48 кГц с noise shaping первого порядка: шум квантования уходит выше звукового диапазона;
* выход на открытом стоке, усилитель не выключается: тишина = середина шкалы, без хлопков.

Экран 800×600: плейлист, осциллограф с триггером, пианино на 3 октавы (подсвечиваются звучащие ноты, в том числе с MIDI-клавиатуры), время, длительность и прогресс трека, громкость, русский шрифт, дизеринг без полос на градиентах.

## Быстрый старт

Нужны Vivado 2023.2 (`source /tools/Xilinx/Vivado/2023.2/settings64.sh`), Python 3, для проверок Icarus Verilog. Полный список: [doc/DEPENDENCIES.md](doc/DEPENDENCIES.md).

```bash
make bit        # синтез + имплементация без GUI (~10 мин): audio_nexys_a7.bit и reports/
make program    # прошить плату по USB
```

`make bit` в конце печатает `TIMING OK` или `TIMING FAILED`, подробности в `reports/timing.txt`, переходы между клоками в `reports/cdc.txt`.

```bash
make deploy                              # проект Vivado с GUI (как в демо)
make test                                # проверки в Icarus Verilog (~2 мин), без Vivado
make test-sd                             # SD-плеер против модели карты (~4 мин)
cd src/sim && make && ./obj_dir/audio    # симулятор Verilator + SDL2: звук и экран в окне
```

Для проверок без Vivado: `sudo apt install iverilog`, `pip install pillow`.

## Управление

| На плате | В симуляторе | Действие |
|---|---|---|
| BTNC | Пробел | play / pause |
| BTNU / BTND | ↑ / ↓ | громкость (0…15, старт 10) |
| BTNL / BTNR | ← / → | предыдущий / следующий трек |
| SW15 + BTNL / BTNR | N, затем ← / → | на треке 01: предыдущая / следующая нота |
| SW[2:0] | 1 … 8 | октава синтезатора (1…8) |
| SW[4:3] | W | форма волны: синус, треугольник, меандр, пила |
| CPU_RESETN | — | сброс |

Семисегментные индикаторы: номер трека, громкость (hex), нота и октава синтезатора.

## Музыка с SD-карты

Карта в FAT32 (карты до 32 ГБ обычно уже такие). Плеер играет первые два файла `*.WAV` из корня карты. Скрипт перегонит любые файлы, в том числе MP3:

```bash
tools/prepare_sd.sh /media/$USER/SDCARD song1.mp3 song2.mp3
```

Получатся `TRACK1.WAV` и `TRACK2.WAV` (16 бит, моно, 48 кГц), на экране это треки 04 и 05. Если карты нет, в плейлисте написано «SD: нет карты»; карту можно вставить на ходу, плеер переподключится сам.

## Поток с ПК и MIDI-клавиатура

```bash
pip install pyserial mido python-rtmidi       # и ffmpeg: sudo apt install ffmpeg
python3 tools/pc_player.py --list             # порты и MIDI-устройства
python3 tools/pc_player.py song.mp3 --midi auto
```

Файл играет на треке 06 (название файла появляется в плейлисте), MIDI-клавиатура играет поверх любого трека. Подробнее и протокол: `tools/pc_player.py`, `src/rtl/pc_link.sv`.

## Как устроено

```
 кнопки ─> debounce ─> player_ctrl ─────────────┐
                                                ▼
 BRAM мелодии ──> melody_player ──> poly_synth (10 голосов, ADSR) ─┐
 MIDI (UART) ───────────────────────────────┘                      ├─> audio_core: микшер, громкость,
 microSD ─> sd_card (SPI) ─> sd_player (FAT32, WAV) ─> FIFO ───────┤   плавные переходы, ШИМ + noise shaping ─> AUD_PWM
 USB-UART ─> pc_link (пакеты, кредиты) ─> FIFO ────────────────────┘
                                                │ статус, маска нот, сэмплы
                                                ▼
 screen_text_ctrl ─> async FIFO ─┐   cdc_bus, scope_capture (двойной буфер)
                                 ▼                 ▼
                         player_screen: display_ctrl + vga_ui ─> VGA 800×600
```

Клоки: `clk_audio` 49.15865 МГц (весь звук, SD, UART), `pixel_clk` 39.941 МГц (экран), 5 МГц (сброс, индикаторы). Между доменами только безопасные переходы: `cdc_bus` (handshake), асинхронные FIFO с указателями Грея, двухпортовая BRAM осциллографа, синхронизаторы на два триггера.

Всё, кроме клоков, сбросов и дебаунсеров, собрано в `src/rtl/player_top.sv`: этот же модуль работает и на плате, и в симуляторе.

## Проверки

| Проверка | Что проверяет | Как запустить |
|---|---|---|
| `tb_async_fifo` | 20 000 слов через FIFO между несвязанными клоками: порядок, без потерь | `make test` |
| `tb_pc_link` | UART-пакеты: звук, MIDI (on / off / velocity 0 / all off), название, кредиты | `make test` |
| `tb_audio_core` | высота нот (A4 = 440.0 Гц), мелодия, пауза, плавность; пишет WAV | `make test` → `build/audio_core.wav` |
| `tb_sd_player` | модель SD-карты с образом FAT32: монтирование, каталог, цепочка кластеров, WAV 16 бит моно и 8 бит стерео — каждый отсчёт сверяется | `make test-sd` |
| `tb_vga_ui` | рендер кадра экрана в PNG | см. ниже |

```bash
iverilog -g2012 -o /tmp/ui -s tb_vga_ui src/rtl/display_ctrl.sv src/rtl/sber_logo_rom.sv src/rtl/vga_ui.sv src/tb/tb_vga_ui.sv
cd src/rtl/mem && vvp -n /tmp/ui +FRAMES=2 +OUT=/tmp/frame.txt && cd -
python3 tools/frame_to_png.py /tmp/frame.txt frame.png
```

## Структура файлов

```
├── Makefile                     deploy, bit, program, test, test-sd, tables
├── doc/
│   ├── 1_О_цифровом_звуке.md    теория по звуку
│   ├── 3_Описание демо.md       исходный демо-проект организаторов
│   ├── 5_Защита_и_демо.md       сценарий демонстрации и чек-лист
│   └── DEPENDENCIES.md          что установить
├── src/
│   ├── top/audio_nexys_a7.sv    топ платы: клоки, сбросы, дебаунсеры, выводы
│   ├── top/audio_nexys_a7.xdc   выводы (кнопки, VGA, звук, UART, microSD) и клоки
│   ├── rtl/
│   │   ├── player_top.sv        весь плеер
│   │   ├── player_ctrl.sv       кнопки: play, громкость, треки, ноты
│   │   ├── audio_core.sv        микшер, громкость, плавные переходы, ШИМ
│   │   ├── poly_synth.sv        10-голосный DDS-синтезатор с ADSR
│   │   ├── melody_player.sv     мелодии из BRAM
│   │   ├── stream_reader.sv     сэмплы из FIFO с частотой файла
│   │   ├── sd_card.sv           microSD в режиме SPI
│   │   ├── sd_player.sv         FAT32 + WAV
│   │   ├── pc_link.sv, uart.sv  связь с ПК: звук, MIDI, название
│   │   ├── screen_text_ctrl.sv  изменяемый текст экрана
│   │   ├── player_screen.sv     таймер, CDC статуса, осциллограф, экран
│   │   ├── vga_ui.sv            картинка
│   │   ├── scope_capture.sv, cdc_bus.sv, async_fifo.sv, play_timer.sv
│   │   ├── display_ctrl.sv, sber_logo_rom.sv, reset_*.sv, button_debouncer.sv, sevseg_ctrl.sv
│   │   ├── button_ctrl.sv, tone_generator.sv, fifo.sv, pwm.sv, vga_demo.sv, font_rom.sv   (из демо, не используются)
│   │   └── mem/                 таблицы: шрифт, текст экрана, синус, ноты, мелодии, строки
│   ├── sim/                     симулятор Verilator + SDL2
│   ├── tb/                      тестбенчи и модель SD-карты
│   └── tcl/                     deploy.tcl, build.tcl, program.tcl
└── tools/
    ├── pc_player.py             плеер на ПК: поток файла и MIDI по USB-UART
    ├── prepare_sd.sh            музыка на SD-карту
    ├── gen_tables.py            синус, частоты нот, мелодии, строки
    ├── gen_font.py, gen_screen.py   шрифт 8×16 CP866, статичный текст экрана
    ├── make_sd_image.py         образ FAT32 для теста
    ├── samples_to_wav.py, frame_to_png.py   результаты тестов -> WAV / PNG
```

Новые RTL-файлы кладите в `src/rtl/`: `deploy.tcl` добавляет в проект всё из `src/rtl/` и `src/top/`, включая `*.mem`. Папка репозитория может называться как угодно.
