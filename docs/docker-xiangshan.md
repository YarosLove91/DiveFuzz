# DiveFuzz + XiangShan в Docker

Как собрать и запустить **реальный симулятор XiangShan прямо внутри Docker**,
не устанавливая на хост ни JDK, ни `mill`, ни Verilator, ни Scala/Chisel, ни сам
XiangShan. На хосте нужны только `docker` и `git`.

Документ дополняет [`DOCKER_RU.md`](DOCKER_RU.md), где описан базовый образ
DiveFuzz и его внутреннее устройство.

---

## 1. Два образа: что где лежит

Архитектура намеренно разделена на два образа. Базовый образ остаётся лёгким и
не меняется, тяжёлая RTL-сборка живёт отдельно.

### `divefuzz:latest` (и его amd64-двойник `divefuzz:amd64`)

Собирается корневым `Dockerfile` через `./docker/build.sh`. Содержит:

* исходники DiveFuzz;
* Python 3.13 и закреплённые зависимости из `requirements.txt`;
* bare-metal тулчейн `riscv64-unknown-elf-*`;
* закреплённый форк Spike (`ref/riscv-isa-sim-adapter`) и собранное
  Python-расширение `spike_engine`;
* smoke-DUT-фикстуру (`docker/smoke-dut/emu`) — **только** для быстрой проверки
  обвязки, это не модель процессора.

Реальных DUT внутри нет: их подключают bind-mount'ом.

### `divefuzz-xiangshan:latest`

Собирается через `docker/xiangshan.Dockerfile` (команда
`./docker/xiangshan-build.sh`). Это **тот же базовый образ плюс собранный
эмулятор XiangShan**:

* всё содержимое `divefuzz:amd64`;
* `/opt/xiangshan/build/emu` — эмулятор XiangShan, собранный Verilator'ом
  внутри Docker из закреплённого коммита;
* `/opt/xiangshan/ready-to-run/` — эталонные модели и бинарники от upstream
  (в том числе `riscv64-spike-so` для differential testing);
* `/opt/xiangshan/build-info.txt` — какие именно коммиты и версии инструментов
  были использованы при сборке.

Один контейнер и генерирует сиды, и исполняет их на DUT — межконтейнерная
обвязка не нужна. Тяжёлая build-стадия (JDK, `mill`, кеш coursier, Verilator,
десятки гигабайт сгенерированного C++) отбрасывается и в финальный образ не
попадает.

---

## 2. Почему XiangShan не ставится на хост

На вычислительном узле обычно уже стоит какая-то Java и какие-то сборочные
инструменты, и разные RTL-проекты требуют разных версий. XiangShan этой ревизии
требует конкретной связки:

| Компонент | Версия | Откуда взялось |
| --- | --- | --- |
| JDK | OpenJDK 21 (`21.0.12.1+1-1~deb13u1`) | Debian 13; в trixie нет `openjdk-17` |
| mill | `0.12.3` | файл `.mill-version` в самом XiangShan на закреплённом коммите |
| Verilator | `5.032-1+b2` | Debian 13; `difftest/verilator.mk` включает `--no-timing` (≥ 5.000) и `--quiet-stats` (≥ 5.024) |
| Chisel | `6.7.0` | `build.sc` XiangShan |
| firtool | `1.62.0` | резолвится Chisel'ом 6.7.0 |
| XiangShan | коммит `d5cc24e8…` | gitlink `dut/XiangShan` в этом репозитории |
| difftest, rocket-chip, ready-to-run, huancun, fudian, utility, yunsuan, coupledL2, openLLC, ChiselAIA | коммиты, записанные в самом XiangShan | `make init` внутри образа |

Установка этого набора на хост ломает соседние проекты (в первую очередь
конфликтом версий Java и mill) и не воспроизводится между узлами кластера.
В образе набор зафиксирован и одинаков везде.

---

## 3. Только `linux/amd64` — и почему это не выбор

`divefuzz-xiangshan` собирается и запускается **только под `linux/amd64`**. Это
не предпочтение, а ограничение upstream. Проверено на закреплённом коммите:

1. **Нет firtool под linux-arm64.** `build.sc` XiangShan фиксирует Chisel 6.7.0,
   который резолвит firtool 1.62.0. Maven-артефакт
   `org.chipsalliance:llvm-firtool:1.62.0` содержит бинарники только для
   `macos-x64`, `linux-x64` и `windows-x64`; релиз CIRCT `firtool-1.62.0` даёт
   ровно те же три ассета. Без firtool шага Chisel → SystemVerilog просто нет.
2. **Эталонные модели — x86-64.** `ready-to-run/riscv64-spike-so` и
   `riscv64-nemu-interpreter-so` это `ELF 64-bit LSB shared object, x86-64`.
   Эмулятор под aarch64 не сможет их `dlopen()`.

На arm64-хосте (Apple Silicon) образ собирается и работает **под эмуляцией
QEMU** — результат корректный, но очень медленный. Штатная платформа —
нативный x86_64.

---

## 4. Два режима работы

Сборка RTL XiangShan — серверная нагрузка. Ноутбук стоит считать средой для
проверки обвязки, а не целевой средой.

### 4.1 Local sanity mode (ноутбук, в том числе Apple Silicon)

Что имеет смысл делать локально:

```shell
./docker/build.sh                          # базовый образ DiveFuzz
docker run --rm divefuzz:latest probe      # проверка зависимостей
./docker/smoke-test-host.sh                # smoke на фикстуре
```

Smoke-тест проверяет **только обвязку контейнера**: генерацию, конвейер
`.S → .elf → .img`, подстановку `$1` и запуск DUT с нужным `cwd`. Он ничего не
говорит о XiangShan.

Локальную сборку XiangShan можно *попробовать*, но аккуратно:

```shell
XS_BUILD_JOBS=2 XS_JVM_XMX=8G ./docker/xiangshan-build.sh
```

На arm64-Mac весь amd64-тулчейн исполняется под эмуляцией QEMU. Только
elaboration Chisel занимает десятки минут, фаза Verilator + g++ — существенно
дольше. `XS_BUILD_JOBS=6` на Docker VM с 15.6 ГБ уже слишком агрессивно:
каждый job g++ хочет ~1 ГБ **поверх** JVM heap. Поэтому для ноутбука:
`XS_BUILD_JOBS=1..2` и `XS_JVM_XMX` не выше 8G.

**Полная локальная сборка XiangShan на Mac не является поддерживаемым
сценарием.** Если она не проходит по ресурсам или времени — это ограничение
ноутбука и эмуляции, а не Docker-workflow.

#### Замеренный результат на MacBook (arm64 → amd64 под эмуляцией)

Три попытки, все упёрлись в память на стадии **firtool**. Хост: Apple Silicon,
24 ГБ RAM, macOS 15.3.1; образ `linux/amd64` под эмуляцией.

| Docker VM | `XS_JVM_XMX` | jobs | Что произошло |
| --- | --- | --- | --- |
| 7.65 ГБ | 10G ⁽¹⁾ | 6 | убито на 2835 с, elaboration **не** дошла до конца |
| 15.6 ГБ | 10G | 6 | elaboration ✅ за 352 с → убито на 425 с в firtool |
| 15.6 ГБ | 6G | 2 | elaboration ✅ за 1862 с → убито на 1932 с в firtool |

⁽¹⁾ первая попытка шла с `6G`, но на VM 7.65 ГБ это тот же перерасход.

Во всех трёх случаях: `OutOfMemoryError` в логе **отсутствует**, BuildKit пишет
`ResourceExhausted: cannot allocate memory` — то есть это kernel/native OOM.

Вывод: `MinimalConfig` на этом ноутбуке под эмуляцией не собирается. Снижение
heap помогает elaboration пережить нехватку памяти (1862 с против 352 с — в 5
раз медленнее из-за GC), но firtool всё равно не влезает. Сборку нужно
выполнять на нативном linux/amd64 узле — см. раздел 4.2.

### 4.2 Server/cluster mode (нативный linux/amd64 — штатный путь)

```shell
./docker/build.sh                                   # 1. базовый образ
./docker/xiangshan-build.sh                         # 2. образ с эмулятором XiangShan
./docker/xiangshan-validate-host.sh                 # 3. настоящая валидация на XiangShan
./docker/do_all_and_shutdown.sh work/my_run.yaml    # 4. неинтерактивный прогон
```

Шаг 2 при необходимости сам собирает базовый образ, так что шаг 1 можно
пропустить. На хосте при этом не появляется ни Java, ни mill, ни Verilator, ни
исходников XiangShan — только `docker` и `git`.

Рекомендуемые ресурсы для сервера — раздел 10.

---

## 5. Сборка образа

```shell
./docker/xiangshan-build.sh
```

Скрипт:

1. читает закреплённый коммит XiangShan прямо из репозитория
   (`git ls-tree HEAD dut/XiangShan`) и URL из `.gitmodules` — подмена на
   плавающую ветку невозможна, а сабмодуль при этом даже не обязан быть
   инициализирован локально;
2. собирает базовый образ `divefuzz:amd64` под `linux/amd64`;
3. собирает `divefuzz-xiangshan:latest`, внутри которого выкачивает XiangShan
   на этот коммит, выполняет `make init` (сабмодули встают на коммиты,
   записанные самим XiangShan), `make deps` и `make emu`;
4. печатает `build-info.txt` собранного образа.

Полезные переменные окружения:

```shell
XS_CONFIG=MinimalConfig     # конфигурация ядра (по умолчанию)
XS_EMU_THREADS=1            # потоки эмулятора (Verilator --threads)
XS_NUM_CORES=1              # число ядер в SoC
XS_JVM_XMX=6G               # heap JVM для elaboration Chisel
XS_BUILD_JOBS=8             # make -j для Verilator/g++
SKIP_BASE=1                 # не пересобирать divefuzz:amd64
```

Пример для большого сервера:

```shell
XS_CONFIG=DefaultConfig XS_JVM_XMX=40G XS_BUILD_JOBS=32 ./docker/xiangshan-build.sh
```

> `MinimalConfig` — умышленный дефолт. `DefaultConfig` (дефолт самого Makefile
> XiangShan) требует ~40 ГБ heap только для elaboration и многократно больше
> времени и диска на Verilator.

> **Память.** `XS_JVM_XMX` должен быть заметно меньше памяти Docker VM
> (ориентир — не больше ~60 %), иначе JVM убьёт kernel OOM killer, а не Java.
> На Docker Desktop с дефолтными ~8 ГБ VM значение `6G` падает; рабочая
> комбинация для `MinimalConfig` — VM 16 ГБ и `XS_JVM_XMX=10G`. Подробности и
> как отличить два вида OOM — в разделе 10.3.

---

## 6. Минимальная проверка

```shell
./docker/xiangshan-validate-host.sh
```

Это **не** smoke-тест: DUT здесь — настоящий эмулятор XiangShan. Проверяется по
шагам:

1. в runtime-образе отсутствуют `mill`, `verilator`, `java`, `javac`, `sbt` —
   доказательство того, что сборочный тулчейн остался в отброшенной стадии;
2. `/opt/xiangshan/build/emu` существует и отвечает на `--help`;
3. DiveFuzz сгенерировал `.S`, затем `.elf`, затем `.img` штатным конвейером;
4. в логе есть строка `Command: ./build/emu -i "/work/seeds/img_file/….img"` —
   то есть `$1` подставился реальным путём сгенерированного сида;
5. рабочая директория совпала с `emu_path` (`/opt/xiangshan`);
6. в per-seed логе есть собственный вывод эмулятора (`HIT GOOD TRAP`,
   `simulated … flash`, `ABORT at pc` и т. п.);
7. сиды и логи видны с хоста в `docker-xiangshan-out/`.

Расхождение с эталоном (`HIT BAD TRAP`) **не** считается провалом проверки: это
находка фаззера, а не поломка контейнера. Скрипт сообщает о ней отдельной
строкой `INFO`.

Без differential testing:

```shell
./docker/xiangshan-validate-host.sh --no-diff
```

---

## 7. Полноценный запуск фаззинга

```shell
mkdir -p work
cp docker/xiangshan.yaml work/my_run.yaml
# отредактировать seeds_num / ins_num / threads

docker run --rm --platform linux/amd64 \
    -v "$PWD/work:/work" \
    divefuzz-xiangshan:latest --config /work/my_run.yaml
```

Или неинтерактивно, под сценарий кластера, — см. раздел 9.

---

## 8. Настройка YAML

`docker/xiangshan.yaml` — готовый Docker-safe конфиг без единого хостового
пути. Ключевые поля:

```yaml
dut_target:
- name: "XiangShan (in-container Verilator emulator)"
  threads: 1                    # сколько сидов исполняется параллельно (~2 ГБ на процесс)
  version: commit:d5cc24e
  diff_ref: Spike
  emu_path: /opt/xiangshan      # контейнерный путь; сюда делается chdir
  cmd: ./build/emu -i $1 --diff ./ready-to-run/riscv64-spike-so

seeds:
- name: xiangshan
  input: divefuzz
  divefuzz:
    gen_only: false
    threads: 1                  # параллелизм генератора (независим от верхнего)
    dive_enable: true
    mode: generate
    seeds_output: /work/seeds   # смонтированный, переживает контейнер
    seeds_num: 1
    ins_num: 20
    is_cva6: false
    is_rv32: false
    template_type: 'xiangshan'
```

Что важно помнить:

* `emu_path` и все пути в `cmd` — **контейнерные**, не хостовые;
* `./build/emu` и `./ready-to-run/…` относительные специально: они разрешаются
  только если `cwd == emu_path`, что и проверяет валидация;
* `$1` заменяется на путь к `.img`, обёрнутый в двойные кавычки, поэтому
  пробелы в пути безопасны;
* `seeds_output` обязан быть под `/work`, иначе сиды останутся внутри
  контейнера и пропадут;
* `template_type: 'xiangshan'` завершает программу инструкцией `0x0000006b`
  (trap difftest), поэтому эмулятор останавливается сам, а не по таймауту.

Масштабирование: `seeds_num` — сколько сидов сгенерировать, `ins_num` — длина
каждого. Для реального прогона обычно `seeds_num: 100+`, `ins_num: 100…1000`.

---

## 9. Запуск на вычислительном кластере

```shell
# один раз на узле (или один раз на общий registry)
./docker/xiangshan-build.sh

# сам прогон, без входа внутрь контейнера
./docker/do_all_and_shutdown.sh --config work/my_run.yaml --work /scratch/divefuzz-run
```

`docker/do_all_and_shutdown.sh`:

* собирает образ, если его нет (или по `--build`);
* копирует ваш YAML в рабочий каталог и передаёт его как `/work/<имя>.yaml`;
* монтирует рабочий каталог в `/work`;
* запускает контейнер под вашим uid/gid (`--user "$(id -u):$(id -g)"`), чтобы
  файлы на смонтированном разделе принадлежали вам;
* пишет транскрипт запуска в `<work>/run-<timestamp>.log`;
* завершает работу с кодом возврата контейнера;
* по флагу `--shutdown` выключает узел через 60 секунд.

`--shutdown` **выключен по умолчанию** — он гасит машину, поэтому его нужно
запрашивать явно.

Артефакты после прогона:

| Что | Где (на хосте) | Где (в контейнере) |
| --- | --- | --- |
| Ассемблер | `<work>/seeds/*.S` | `/work/seeds/*.S` |
| ELF | `<work>/seeds/elf_file/*.elf` | `/work/seeds/elf_file/*.elf` |
| IMG (то, что уходит в DUT) | `<work>/seeds/img_file/*.img` | `/work/seeds/img_file/*.img` |
| Логи конфигурации сидов | `<work>/outputs/<config>-<seed>.log` | `/work/outputs/…` |
| Логи каждого сида (вывод эмулятора) | `<work>/outputs/<config>-<seed>_<img>.log` | `/work/outputs/…` |
| Транскрипт запуска | `<work>/run-<timestamp>.log` | — |

---

## 10. Ресурсы: ручки, лимиты, минимумы

### 10.1 Все ручки в одном месте

| Ручка | Что задаёт | Где задаётся | Дефолт | Ориентир |
| --- | --- | --- | --- | --- |
| `XS_JVM_XMX` | heap JVM для elaboration Chisel | env для `xiangshan-build.sh`, либо `--build-arg` | `6G` | ≲ 60 % памяти Docker VM; `MinimalConfig` — `10G`, `DefaultConfig` — `40G` |
| `XS_BUILD_JOBS` | `make -j` для Verilator/g++ | env / `--build-arg` | `$(nproc)` | ~1 ГБ RAM на job; на 16 ГБ VM — не больше 6–8 |
| `XS_CONFIG` | конфигурация ядра XiangShan | env / `--build-arg` | `MinimalConfig` | `DefaultConfig` — только на большом сервере |
| `XS_EMU_THREADS` | потоки эмулятора (Verilator `--threads`) | env / `--build-arg` | `1` | влияет на скорость прогона, не сборки |
| `XS_NUM_CORES` | число ядер в SoC | env / `--build-arg` | `1` | больше ядер — кратно дороже сборка |
| Память Docker | верхняя граница для всего | **вне** образа: Docker Desktop → Settings → Resources → Memory; на Linux — сам хост | Docker Desktop: ~8 ГБ | ≥ 16 ГБ для `MinimalConfig` |
| Диск Docker | место под build-стадию | там же | зависит от установки | ≥ 60 ГБ свободных |
| `dut_target.threads` | сколько сидов гонится параллельно | YAML | — | ~2 ГБ RAM на процесс эмулятора |
| `divefuzz.threads` | параллелизм генератора | YAML | — | независим от предыдущего |
| Target platform | архитектура образа | зашита: `--platform linux/amd64` во всех скриптах | `linux/amd64` | менять нельзя, см. раздел 3 |
| Work/output path | куда монтируется `/work` | `-v <host>:/work`; `--work` у `do_all_and_shutdown.sh` | `./docker-xiangshan-out`, `./divefuzz-run` | сиды и логи переживают контейнер только здесь |

### Пересборка при смене ручек

Ручки `XS_CONFIG`, `XS_JVM_XMX`, `XS_BUILD_JOBS`, `XS_EMU_THREADS`,
`XS_NUM_CORES` объявлены в `xiangshan.Dockerfile` **непосредственно перед**
шагом `make emu`, а не в начале стадии. Это не косметика: инструкция `ARG` —
часть графа сборки, и смена её значения инвалидирует все последующие слои.
Объяви они выше — каждый подбор heap заново ставил бы JDK, клонировал
XiangShan и перекачивал все зависимости Chisel.

**Гарантия:** смена `XS_JVM_XMX` или `XS_BUILD_JOBS` перезапускает только
`make emu`; `apt`, mill, clone, `make init` и `make deps` берутся из кеша.
Это важно, потому что подбор памяти под конкретный узел почти всегда требует
нескольких попыток.

### Ожидаемые стадии сборки

Замеры на arm64-Mac под эмуляцией amd64 (Docker VM 15.6 ГБ). На нативном
x86_64-сервере всё это существенно быстрее, но соотношение стадий сохраняется.

| Стадия | Что делает | Время (эмуляция) |
| --- | --- | --- |
| `apt` toolchain | JDK 21, Verilator, build-essential | ~105 с |
| mill | скачивание и sha256-проверка | ~9 с |
| `git fetch` XiangShan | один закреплённый коммит | ~2 с |
| `make init` | 10 сабмодулей + cde/hardfloat/openNCB | ~81 с |
| `make deps` | Chisel, firtool, зависимости Scala | ~79 с |
| `make emu` → elaboration | Chisel внутри JVM | ~350 с |
| `make emu` → firtool | нативный lowering в SystemVerilog | **пик по памяти** |
| `make emu` → Verilator + g++ | тысячи `.cpp` | самая долгая стадия, часы |

Первые пять стадий вместе занимают ~5 минут. Всё остальное время — `make emu`.

Пример для сервера:

```shell
XS_CONFIG=DefaultConfig \
XS_JVM_XMX=40G \
XS_BUILD_JOBS=32 \
./docker/xiangshan-build.sh
```

### 10.2 Минимально рекомендуемое

| | `MinimalConfig` | `DefaultConfig` |
| --- | --- | --- |
| RAM (Docker VM / хост) | 16 ГБ | 64 ГБ |
| `XS_JVM_XMX` | `10G` | `40G` |
| Свободный диск | 60 ГБ | 200 ГБ+ |
| CPU | 4+ | 16+ |

### 10.3 Два OOM и как их различить

Это самая частая ошибка при переносе на новый узел, и лечатся они
**противоположным** образом:

| Признак в логе | Что это | Лечение |
| --- | --- | --- |
| нет Java-стектрейса; BuildKit пишет `cannot allocate memory` / `ResourceExhausted`; `Subprocess failed` | **kernel OOM killer** — суммарное потребление не влезает в память VM | увеличить **память Docker VM** и/или **снизить** `XS_JVM_XMX` (см. ловушку с firtool ниже) |
| `java.lang.OutOfMemoryError: Java heap space` | **Java heap OOM** — heap реально мал | увеличить **`XS_JVM_XMX`** (в пределах правила ≲ 60 % VM) |
| `Killed` / OOM во время компиляции C++ | слишком много параллельных g++ | снизить **`XS_BUILD_JOBS`** |
| `no space left on device` | кончился диск Docker | `docker builder prune`; увеличить диск |

#### Ловушка: firtool — это отдельный нативный процесс

Самая неочевидная часть. Шаг `build/rtl/SimTop.sv` состоит из **двух** фаз:

1. elaboration Chisel — работает **внутри JVM**, ограничен `XS_JVM_XMX`;
2. lowering firtool (Chisel → SystemVerilog) — это **отдельный нативный
   бинарник**, его память **не входит** в `XS_JVM_XMX` и лежит *поверх* него.

Поэтому большой heap может сделать хуже. Наблюдение на VM 15.6 ГБ с
`XS_JVM_XMX=10G`:

```
#18 352.6 [814] [warn] There were 133 warning(s) during hardware elaboration.
#18 425.7 xiangshan.test.runMain Subprocess failed
ERROR: ... ResourceExhausted: ... cannot allocate memory
```

Elaboration **успешно завершилась** на 352-й секунде, а убило процесс уже
на фазе firtool: 10 ГБ heap + нативный firtool + накладные расходы эмуляции не
поместились в 15.6 ГБ.

Как определить, что вы попали именно сюда: в логе есть строка
`There were N warning(s) during hardware elaboration`, и падение произошло
**после** неё. Лечение — **снизить** `XS_JVM_XMX` (оставить firtool место),
а не повышать его.

Порядок действий при firtool OOM:

1. снизить `XS_JVM_XMX` (например, 10G → 6G) — самое дешёвое;
2. если не помогло — увеличить память Docker VM / узла;
3. `XS_BUILD_JOBS` здесь ни при чём: до Verilator дело ещё не дошло.

#### OOM на стадии Verilator/g++

Другая стадия, другое лечение. Признаки: падение **после** появления
`build/rtl/SimTop.sv`, в логе видны вызовы `verilator` или компиляция
`.cpp`-файлов, сообщения вида `g++: fatal error: Killed signal terminated
program cc1plus` или просто `Killed`.

Причина: Verilator генерирует тысячи `.cpp`, и `make -j` компилирует их
параллельно; каждый job берёт ~1 ГБ.

Лечение — **снизить `XS_BUILD_JOBS`** (`XS_JVM_XMX` здесь уже не при чём, JVM
своё отработала):

```shell
XS_BUILD_JOBS=2 ./docker/xiangshan-build.sh
```

Благодаря позднему объявлению ARG (см. раздел 10.1) повтор перезапустит только
`make emu`.

## 11. Требуемые ресурсы (детально)

Оценки для `MinimalConfig`, `NUM_CORES=1`:

| Этап | CPU | RAM | Диск |
| --- | --- | --- | --- |
| Сборка базового образа | любой | ~4 ГБ | ~4 ГБ |
| `make deps` (скачивание Chisel/firtool) | 1 | ~2 ГБ | ~2 ГБ |
| Chisel elaboration | 1–2 | VM ≥ 16 ГБ, `XS_JVM_XMX=10G` | ~2 ГБ |
| Verilator + g++ | чем больше, тем лучше | ~1 ГБ на job | 20–40 ГБ временных файлов |
| Итоговый образ | — | — | ~1.5 ГБ |
| Прогон одного сида | 1 (или `EMU_THREADS`) | ~2 ГБ | мегабайты |

`DefaultConfig` требует существенно больше: ~40 ГБ heap JVM и кратно больше
времени и диска на Verilator.

Диск Docker'а должен быть щедрым: build-стадия занимает десятки гигабайт, и,
хотя она отбрасывается, во время сборки эти данные лежат на диске.

---

## 12. Известные ограничения

* **Только `linux/amd64`.** Причины — в разделе 3. Нативный arm64-образ
  невозможен без пересборки firtool и эталонных моделей под aarch64.
* **`MinimalConfig` по умолчанию.** Это уменьшенное ядро XiangShan. Оно
  реализует не весь ISA, который умеет генерировать DiveFuzz, поэтому часть
  расхождений с эталоном будет объясняться конфигурацией, а не багом ядра. Для
  осмысленного фаззинга собирайте `DefaultConfig`.
* **Расхождение ISA генератора и DUT.** ISA-профиль DiveFuzz по умолчанию
  заканчивается на `_zfa`. Если конфигурация XiangShan не реализует какое-то из
  расширений, differential testing даст ложные срабатывания. Ограничивайте
  набор через `allowed_ext_name`/`architecture` в YAML.
* **Таймаут 300 секунд на сид** зашит в `fuzzer/executor/dut_executor.py` и не
  настраивается через YAML. Длинные сиды на медленном (эмулируемом) хосте будут
  помечены как `TIMEOUT`.
* **`gen_only` ничего не выключает.** Ключ разбирается конфигом, но нигде в пути
  исполнения не используется — DUT запустится в любом случае.
* **Smoke-тест не является доказательством для XiangShan.** Он проверяет только
  обвязку контейнера на фикстуре. Для XiangShan используйте
  `xiangshan-validate`.
* **Real-XiangShan прогон не был выполнен локально.** Сборка эмулятора на
  MacBook (arm64 → amd64 под эмуляцией) трижды упёрлась в память на стадии
  firtool — замеры в разделе 4.1. Соответственно **не проверены на практике**:
  наличие `build/emu` в образе, запуск эмулятора через DiveFuzz, differential
  testing против `riscv64-spike-so`, а также фактическое время стадии
  Verilator + g++. Всё это нужно выполнить на нативном linux/amd64 узле
  командами из раздела 4.2.

---

## 13. Краевые случаи и диагностика

### Конфликт версий Java/JDK

**Симптом:** `Unsupported class file major version`, `NoSuchMethodError` в
Scala-коде, mill падает на старте.

**Причина:** используется не та JVM. Внутри образа JDK ровно один
(OpenJDK 21), и `JAVA_HOME` хоста туда не попадает.

**Что делать:** убедиться, что вы собираете именно через
`docker/xiangshan-build.sh`, а не запускаете `make emu` на хосте. Проверка:
`docker run --rm divefuzz-xiangshan:latest cat /opt/xiangshan/build-info.txt` —
там записана версия JDK, которой собирали. В runtime-образе JDK вообще нет, это
проверяется валидацией.

Если XiangShan обновится и потребует другой mill, сборка упадёт с явным
сообщением (`XiangShan pins mill X, image installed Y`) — надо пересобрать с
`--build-arg MILL_VERSION=… --build-arg MILL_SHA256=…`.

### mill daemon / unix-сокеты на bind mount

**Симптом:** на Docker Desktop (macOS/Windows) mill падает с ошибками вокруг
`out/mill-server`, `AF_UNIX`, `Address already in use`, `No such file or
directory` при попытке собрать XiangShan в примонтированном каталоге.

**Причина:** mill-демон создаёт unix domain socket в `out/`, а сокеты не
работают на bind-mount'ах Docker Desktop (gRPC-FUSE / VirtioFS).

**Как это обойдено здесь:** вся RTL-сборка происходит **в слоях образа**, а не в
bind-mount'е, и Makefile XiangShan вызывает `mill -i` (без демона). Проблема
структурно исключена.

**Если вы всё же собираете вручную в примонтированном каталоге:** используйте
именованный Docker volume вместо bind mount, либо задайте
`MILL_OUTPUT_DIR=/tmp/.mill-out`.

### `make: *** [Makefile:314: deps] Error 127`, хотя `mill` работает

**Симптом:** при сборке образа `make deps` (или `make emu`) падает с `Error 127`,
при этом `mill --version` из шелла в том же образе отрабатывает нормально, и
`command -v mill` находит бинарник.

**Причина:** релизный артефакт mill — это polyglot-скрипт sh/cmd с приклеенным
JAR'ом, и **у него нет shebang**. GNU make для строк рецепта без shell-мета\-
символов вызывает `execve()` напрямую, минуя шелл. `execve()` на файле без
shebang возвращает `ENOEXEC`, а make рапортует это как `Error 127`
(«command not found»). Из шелла всё работает, потому что `sh` при `ENOEXEC`
сам подхватывает файл как скрипт.

**Как это решено здесь:** проверенный по sha256 артефакт лежит в
`/usr/local/lib/mill/`, а на `PATH` выставлен настоящий скрипт с shebang,
который делает `exec /bin/sh <assembly> "$@"` (launcher использует `$0` как
собственный classpath, поэтому важно передать именно путь к артефакту).

### `/bin/sh: 1: time: not found`

**Симптом:** `make emu` падает сразу на генерации Verilog:
`/bin/sh: 1: time: not found`, `Error 127`.

**Причина:** Makefile XiangShan оборачивает вызовы mill в
`time -avp -o build/time.log`. Это GNU `/usr/bin/time` из пакета `time`, а не
встроенное слово bash: рецепты исполняет `/bin/sh` (dash), у которого такого
builtin нет вовсе.

**Как это решено здесь:** пакет `time` (1.9-0.2) установлен в build-стадии.

### Очень долгая сборка Verilator/эмулятора

**Симптом:** `make emu` идёт часами, кажется, что всё зависло.

**Причина:** Verilator генерирует тысячи `.cpp`, каждый компилируется g++.
Это нормально. Под QEMU (arm64-хост) — умножайте на 5–10.

**Что делать:** пересобирать с `--progress=plain`, чтобы видеть вывод; поднять
`XS_BUILD_JOBS`; собирать на нативном x86_64. Docker BuildKit кеширует слои, так
что `make init`/`make deps` не повторяются при изменении только RTL-параметров.

### Нехватка RAM или диска

**Симптом (наблюдался на практике):** сборка идёт ~47 минут на elaboration
Chisel, затем падает так:

```
1 tasks failed
xiangshan.test.runMain Subprocess failed
make: *** [Makefile:271: build/rtl/SimTop.sv] Error 1
ERROR: ... did not complete successfully: cannot allocate memory
```

**Как отличить два разных OOM.** Это важно, потому что лечатся они
противоположным образом:

* **нет** Java-стектрейса, BuildKit пишет `cannot allocate memory` /
  `ResourceExhausted` — JVM убил **kernel OOM killer**: heap не влезает в
  память VM. Нужно **увеличить память Docker**, а не `XS_JVM_XMX`;
* есть `java.lang.OutOfMemoryError: Java heap space` — heap действительно мал,
  нужно **увеличить `XS_JVM_XMX`**.

Конкретный замер: `XS_JVM_XMX=6G` на VM Docker Desktop с 7.65 ГБ гарантированно
убивается kernel'ом (6 ГБ heap + overhead JVM ≈ вся память VM). Рабочая
комбинация для `MinimalConfig` — VM ≥ 16 ГБ и `XS_JVM_XMX=10G`.

**Правило:** `XS_JVM_XMX` ≲ 60 % памяти Docker VM.

**Что делать:**

* kernel OOM — поднять память Docker VM (Docker Desktop → Settings →
  Resources → Memory), затем при желании поднять `XS_JVM_XMX`;
* `java.lang.OutOfMemoryError` — поднять `XS_JVM_XMX` (в пределах правила выше);
* OOM во время g++ — **снизить** `XS_BUILD_JOBS` (каждый job ест ~1 ГБ);
* нет места — `docker builder prune`, увеличить диск Docker'а; build-стадия
  занимает десятки гигабайт.

На Docker Desktop память и диск задаются в настройках приложения, не флагами
`docker run`. На Linux-сервере с нативным Docker ограничения задаёт сам хост, и
такой проблемы обычно нет.

### Права на `/work`

**Симптом:** `Permission denied` при записи в `/work/seeds` или `/work/outputs`.

**Причина:** контейнер работает под non-root пользователем `divefuzz` (uid 1000),
а смонтированный каталог принадлежит другому uid.

**Что делать:** запускать с `--user "$(id -u):$(id -g)"` (именно так делает
`do_all_and_shutdown.sh`), либо использовать именованный volume, либо
`chown 1000:1000` каталог на хосте.

### arm64 против amd64

**Симптом:** `exec format error`; `rosetta error`; сборка падает на firtool с
чем-то вроде `cannot execute binary file`.

**Причина:** попытка собрать/запустить нативно под arm64. См. раздел 3.

**Что делать:** всегда передавать `--platform linux/amd64` (все скрипты в
`docker/` делают это сами), включить QEMU-эмуляцию в Docker Desktop, а для
реальной работы использовать x86_64-узел.

### x86-only артефакты NEMU/difftest

**Симптом:** эмулятор стартует, но падает на загрузке эталонной модели:
`dlopen: … wrong ELF class`, `cannot open shared object file`.

**Причина:** `ready-to-run/*.so` собраны только под x86-64.

**Что делать:** запускать образ как `linux/amd64` (тогда QEMU исполнит и `.so`),
либо отключить differential testing (см. ниже).

### Запуск с `--no-diff`

Если эталонную модель загрузить нельзя (или она не нужна), уберите `--diff` из
`cmd`:

```yaml
  cmd: ./build/emu -i $1 --no-diff
```

Или запустите валидацию с флагом:

```shell
./docker/xiangshan-validate-host.sh --no-diff
```

**Важно:** с `--no-diff` эмулятор исполняет сид, но **сравнения с эталоном не
происходит**. Это проверка работоспособности конвейера, а не поиск багов. Для
настоящего фаззинга differential testing обязателен.

### Хостовые пути против контейнерных в YAML

**Симптом:** `No seed files found`; `cannot access './build/emu'`; логи пустые.

**Причина:** в YAML остались пути с машины разработчика
(`/home/user/XiangShan`, `/Users/…`).

**Что делать:** все пути в конфиге должны быть контейнерными:
`emu_path: /opt/xiangshan`, `seeds_output: /work/seeds`. Ориентир —
`docker/xiangshan.yaml`, в нём хостовых путей нет.

### `$1` и пробелы в пути к сиду

`dut_executor.py` подставляет `dut_config.cmd.replace('$1', f'"{seed_path}"')` и
запускает команду через `shell=True`, поэтому путь уже обёрнут в двойные
кавычки и пробелы безопасны. Но:

* не оборачивайте `$1` в кавычки самостоятельно — получится `""путь""`;
* одинарные кавычки вокруг `$1` сломают подстановку;
* избегайте в путях символов `"`, `` ` ``, `$` — они попадут в shell.

### `gen_only` не отключает исполнение на DUT

Ключ `gen_only` разбирается в `fuzzer/config/dut_config.py`, но нигде в пути
исполнения не читается. Если нужно только сгенерировать сиды, укажите
заведомо безобидный `cmd` (например `/bin/true`) или используйте smoke-фикстуру.

### Эмулятор падает

Порядок разбора:

1. Посмотреть per-seed лог: `<work>/outputs/<config>-<seed>_<img>.log` — там
   полный stdout/stderr эмулятора между маркерами
   `==== TEST OUTPUT BEGIN/END ====`.
2. `HIT BAD TRAP` / `ABORT at pc` — расхождение с эталоном. Это **находка**, а
   не поломка: сохраните `.S`, `.elf` и `.img` соответствующего сида.
3. `Simulation Aborted` без указания расхождения — обычно нехватка памяти или
   таймаут; проверьте лимиты контейнера.
4. Ошибки загрузки `.so` — см. «x86-only артефакты».
5. Воспроизвести вручную, без DiveFuzz:

   ```shell
   docker run --rm -it --platform linux/amd64 \
       -v "$PWD/docker-xiangshan-out:/work" \
       divefuzz-xiangshan:latest bash
   cd /opt/xiangshan
   ./build/emu -i /work/seeds/img_file/seeds_0_.img --diff ./ready-to-run/riscv64-spike-so
   ```

### Где искать логи

| Что | Путь |
| --- | --- |
| Лог сборки образа | вывод `docker/xiangshan-build.sh` (пускайте через `tee`) |
| Что именно собралось | `/opt/xiangshan/build-info.txt` внутри образа |
| Ход выполнения DiveFuzz | stdout контейнера / транскрипт `do_all_and_shutdown.sh` |
| Лог конфигурации сидов | `<work>/outputs/<config>-<seed>.log` |
| Вывод эмулятора по каждому сиду | `<work>/outputs/<config>-<seed>_<img>.log` |
| Проверка зависимостей | `docker run --rm divefuzz-xiangshan:latest probe` |

---

## 14. Быстрая шпаргалка

```shell
# сборка (часы; XiangShan RTL)
./docker/xiangshan-build.sh

# что собралось
docker run --rm --platform linux/amd64 divefuzz-xiangshan:latest \
    cat /opt/xiangshan/build-info.txt

# зависимости базового образа
docker run --rm --platform linux/amd64 divefuzz-xiangshan:latest probe

# настоящая проверка на XiangShan
./docker/xiangshan-validate-host.sh

# то же без differential testing
./docker/xiangshan-validate-host.sh --no-diff

# свой прогон
docker run --rm --platform linux/amd64 -v "$PWD/work:/work" \
    divefuzz-xiangshan:latest --config /work/my_run.yaml

# неинтерактивный прогон на кластере
./docker/do_all_and_shutdown.sh --config work/my_run.yaml --work /scratch/run
```
