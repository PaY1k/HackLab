# Зависимости демо-проекта

Список собран по файлам сборки (`Makefile`, `src/sim/Makefile`, `src/tcl/deploy.tcl`, `src/sim/main_audio.cpp`) и по документации (`doc/3_Описание демо.md`, `doc/1_О_цифровом_звуке.md`). Команды установки даны для Ubuntu 22.04.

## 1. Сборка и прошивка платы (обязательно)

| Инструмент | Зачем | Откуда видно | Установка |
|---|---|---|---|
| **GNU Make** | `make deploy`, `make clear`, `make clean` | `Makefile` | `build-essential` или `make` |
| **AMD Vivado 2023.2** (бесплатная редакция ML Standard поддерживает `xc7a100tcsg324-1`) | создание проекта, синтез, имплементация, битстрим, Hardware Manager; IP `clk_wiz:6.0` | `Makefile` (`vivado -mode tcl`), `deploy.tcl`, `src/ipcores/clk_wiz_0/clk_wiz_0.xci` | установщик с сайта AMD |
| **Драйверы JTAG-кабеля** Digilent/FTDI (правила udev) | прошивка платы по Micro-USB из Hardware Manager | Описание демо, «Прошивка платы» | `sudo <Vivado>/data/xicom/cable_drivers/lin64/install_script/install_drivers/install_drivers`, затем переподключить плату |
| `libtinfo5` (рекомендуется) | Vivado 2023.x на Ubuntu 22.04 без неё может зависать на синтезе | известная проблема Vivado на Ubuntu 22.04 | `sudo apt install libtinfo5` |

Чтобы `vivado` был в `PATH`, нужно один раз в каждом терминале (или в `~/.bashrc`) выполнить:

```bash
source /tools/Xilinx/Vivado/2023.2/settings64.sh
```

IP `clk_wiz_0` создан в Vivado 2023.2. В более новых версиях Vivado его нужно обновить (Upgrade IP). В более старых версиях IP будет заблокирован, и проект не соберётся.

## 2. Симулятор на Verilator (обязательно для `src/sim`)

| Инструмент | Зачем | Откуда видно | Пакет |
|---|---|---|---|
| **Verilator** | перевод `top_audio.sv` и `src/rtl/*.sv` в C++ | `src/sim/Makefile` | `verilator` |
| **g++** (C++14 и новее) | компиляция модели и `main_audio.cpp` (в коде есть разделители разрядов `49'158'650`) | `src/sim/Makefile`, `main_audio.cpp` | `build-essential` |
| **GNU Make** | `make audio`; Verilator сам вызывает `make` для `obj_dir` | `src/sim/Makefile` | `build-essential` |
| **SDL2 (dev)** и `sdl2-config` | окно с семисегментником, клавиатура, вывод звука | `#include <SDL2/SDL.h>`, `sdl2-config --cflags/--libs` | `libsdl2-dev` |
| Perl | Verilator 4.x — это Perl-скрипт | зависимость пакета `verilator` | ставится автоматически |
| Графическая сессия и звук (X11/Wayland, PulseAudio/PipeWire) | SDL открывает окно и аудиоустройство | `main_audio.cpp` | есть в настольной Ubuntu |

```bash
sudo apt install build-essential verilator libsdl2-dev
```

## 3. Для заданий хакатона (по желанию)

Эти инструменты упоминаются в документации или понадобятся для типичных направлений работы. Для самого демо-проекта они не нужны.

| Инструмент | Зачем | Пакет |
|---|---|---|
| `ffmpeg` | перекодировать MP3/WAV в «сырые» сэмплы 48 кГц (`doc/1_О_цифровом_звуке.md`, §8) | `ffmpeg` |
| `xxd` | превратить бинарный файл в текст для `$readmemh` | `xxd` (в старых версиях `vim-common`) |
| Python 3 | генерация таблиц (синус, ноты мелодии) для `$readmemh` | `python3` |
| Git | контроль версий командного кода | `git` |
| RISC-V тулчейн | программно-аппаратное направление: прошивка для soft CPU | `gcc-riscv64-unknown-elf` |
| Терминал для UART (`picocom`, `minicom`, `screen`) | вывод отладочной печати soft CPU через USB-UART платы | `picocom` |
| GTKWave | просмотр временных диаграмм, если включить трассировку Verilator (`--trace`) | `gtkwave` |

## 4. Для плеера (этот репозиторий)

| Инструмент | Зачем | Установка |
|---|---|---|
| Icarus Verilog 11+ | `make test`, `make test-sd`, рендер кадра экрана без Vivado | `sudo apt install iverilog` |
| Python 3 + Pillow | генераторы таблиц и шрифта, кадр -> PNG | `pip install pillow` |
| ffmpeg | `tools/prepare_sd.sh`, `tools/pc_player.py` | `sudo apt install ffmpeg` |
| pyserial, mido, python-rtmidi | `tools/pc_player.py`: поток с ПК и MIDI-клавиатура | `pip install pyserial mido python-rtmidi` |

Доступ к USB-UART платы без sudo: `sudo usermod -aG dialout $USER`, затем перелогиниться.

