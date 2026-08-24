import SwiftUI

/// Таймер в панели: плашки настроенных таймеров, а пока один идёт — карточка
/// с остатком и кнопками.
///
/// Стоит выше опроса: таймер — это действие, ради которого панель и открыли
/// (особенно на созвоне), а опрос — вопрос вдогонку. Блок появляется, только
/// когда его включили в настройках.
///
/// Всё умещается в одну строку в любом состоянии, и это не украшательство:
/// раскладка блока задаёт высоту панели, а окно меню-бара перерисовывает
/// подложку не в такт с содержимым — от прыжка высоты позади панели остаётся
/// светлый прямоугольник. Поэтому плашки стоят рядом фиксированным рядом,
/// а не облаком: длинное имя таймера иначе переносило бы ряд на вторую строку.
struct TimerBlock: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            row
        }
    }

    // MARK: Заголовок

    /// Общего итога дня рядом с заголовком нет намеренно. Сложить шесть
    /// подходов с эспандером по полминуты и один помидор на двадцать пять
    /// минут — получить «28 минут», число, которое не значит ничего. Счёт
    /// ведётся по каждому таймеру отдельно и живёт в подсказке на его плашке.
    private var header: some View {
        Text("Таймер")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .lineLimit(1)
            .help("Нажмите на таймер, чтобы он пошёл. Пока идёт, счётчик в строке меню показывает остаток, а последние секунды мигает зелёным.")
    }

    // MARK: Ряд

    @ViewBuilder
    private var row: some View {
        if let run = model.timerRun, model.timerPhase != nil {
            // Заливка должна ползти, а не прыгать раз в секунду: на
            // тридцатисекундном таймере один тик модели — это десять точек
            // скачком. Поэтому карточка перерисовывается от экрана, а не
            // от тика: `TimelineView` берёт кадры сам и трогает только этот
            // кусок панели, не заставляя чаще тикать всё остальное.
            // На паузе кадры не нужны — там ничего не движется.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: run.isPaused)) { timeline in
                running(run, now: model.timerNow(timeline.date))
            }
        } else {
            presets
        }
    }

    /// Плашки настроенных таймеров. Ширина у всех одна: имена разной длины
    /// иначе делали бы ряд рваным, а на 340 точках это заметно.
    private var presets: some View {
        let list = model.timerPresets

        return HStack(spacing: 5) {
            if list.isEmpty {
                // Блок включили руками — молчание выглядело бы поломкой.
                Text("Ни одного таймера не настроено")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(list) { preset in
                    Button {
                        model.startTimer(preset)
                    } label: {
                        // Одной строкой, а не именем над длительностью: вторая
                        // строка делает плашку выше карточки идущего таймера,
                        // и панель прыгала бы на каждом запуске.
                        HStack(spacing: 4) {
                            Text(preset.name)
                                .font(.system(size: 11, weight: .medium))
                            Text(TimerRules.length(preset.seconds))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Запустить: \(preset.name), \(TimerRules.length(preset.seconds)). "
                          + TimerRules.launchNote(model.timerLaunchesToday(preset)))
                }
            }
        }
    }

    /// Карточка идущего таймера — на месте плашек и той же высоты.
    private func running(_ run: TimerRun, now: Date) -> some View {
        let phase = TimerRules.phase(run, now: now)
        // `.gone` живёт доли секунды — до ближайшего тика, который снимет
        // таймер. Показываем в это время то же, что и на «Готово»: иначе
        // карточка успела бы мигнуть пустотой.
        let finished = phase == .done || phase == .gone
        let blinking = TimerRules.blinking(run, now: now)
        // Мигание — заливкой и цветом разом: на цветных обоях один только
        // зелёный читается плохо, этот урок в проекте уже оплачен.
        let dim = blinking && !TimerRules.blinkOn(now)
        let alarm = finished || blinking
        let tint: Color = alarm ? .green : .accentColor

        return HStack(spacing: 5) {
            HStack(spacing: 5) {
                TimerDialView(dial: model.settings.timerDial, run: run, now: now)
                    .frame(width: 12, height: 12)
                    .foregroundStyle(alarm && !dim ? Color.green : Color.secondary)

                Text(finished ? "\(TimerRules.doneLabel) · \(run.name)" : run.name)
                    .font(.system(size: 11, weight: .medium))

                Spacer(minLength: 6)

                if !finished {
                    Text(remaining(phase))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .background(fill(progress: TimerRules.progress(run, now: now),
                             tint: tint,
                             strength: dim ? 0.08 : 0.25))
            // Пауза приглушает всю карточку: остановившиеся цифры сами по себе
            // от идущих не отличаются, а глиф на кнопке для этого слишком мелок.
            .opacity(run.isPaused ? 0.55 : 1)

            if !finished {
                if run.isPaused {
                    iconButton("play.fill", help: "Продолжить") { model.resumeTimer() }
                } else {
                    iconButton("pause.fill", help: "Пауза") { model.pauseTimer() }
                }
                iconButton("stop.fill", help: "Остановить — заход не засчитается") {
                    model.stopTimer()
                }
            }
        }
    }

    private func remaining(_ phase: TimerPhase) -> String {
        switch phase {
        case .running(let left), .paused(let left): return TimerRules.clock(left)
        case .done, .gone: return TimerRules.clock(0)
        }
    }

    /// Заливка карточки заодно показывает, сколько прошло: отдельная полоса
    /// прогресса стоила бы блоку лишней строки высоты.
    private func fill(progress: Double, tint: Color, strength: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color.primary.opacity(0.06)
                Rectangle()
                    .fill(tint.opacity(strength))
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .clipShape(Capsule())
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                // Одинаковая ширина у «паузы» и «продолжить»: без неё карточка
                // дёргалась бы на каждое нажатие.
                .frame(width: 12, height: 13)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .foregroundStyle(.secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Циферблат

/// Кольцо или стрелка — то, что видно в строке меню и в карточке.
///
/// Два варианта, потому что на тринадцати точках это решается только глазами:
/// кольцо отвечает на вопрос «сколько осталось», стрелка — на вопрос «идёт ли
/// вообще». Цвет берётся снаружи, из `foregroundStyle`, — тем же способом,
/// каким система красит значок в строке меню.
struct TimerDialView: View {
    var dial: TimerDial
    var run: TimerRun
    var now: Date

    @ViewBuilder
    var body: some View {
        switch dial {
        case .ring: ring
        case .hand: hand
        }
    }

    private var ring: some View {
        // Не меньше сотой доли круга: у полностью пустого кольца исчезает
        // и точка отсчёта, и последняя секунда выглядит как сбой отрисовки.
        let left = max(0.01, 1 - TimerRules.progress(run, now: now))

        return ZStack {
            Circle()
                .stroke(style: StrokeStyle(lineWidth: 1.5))
                .opacity(0.25)
            Circle()
                .trim(from: 0, to: left)
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                // Отсчёт от двенадцати часов, как на любом циферблате.
                .rotationEffect(.degrees(-90))
        }
        .padding(1)
    }

    private var hand: some View {
        ZStack {
            Circle()
                .stroke(style: StrokeStyle(lineWidth: 1.2))
                .opacity(0.3)
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                Path { path in
                    path.move(to: CGPoint(x: side / 2, y: side / 2))
                    path.addLine(to: CGPoint(x: side / 2, y: side * 0.16))
                }
                .stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .rotationEffect(.degrees(TimerRules.handAngle(run, now: now)), anchor: .center)
            }
        }
        .padding(1)
    }
}

// MARK: - Раздел настроек

/// «Таймер» в окне настроек: включить блок в панели, выбрать циферблат
/// и настроить сами таймеры.
struct TimerTab: View {
    @ObservedObject var model: AppModel

    /// Ловец сочетания клавиш. Живёт в разделе, а не в модели: он нужен
    /// ровно на то время, пока человек назначает клавишу, и умирает вместе
    /// с закрытым окном.
    @StateObject private var recorder = HotKeyRecorder()

    var body: some View {
        Form {
            Section {
                Toggle("Показывать таймер в панели", isOn: $model.settings.timerEnabled)

                Picker("В строке меню", selection: $model.settings.timerDial) {
                    ForEach(TimerDial.allCases) { dial in
                        Text(dial.title).tag(dial)
                    }
                }
                .pickerStyle(.radioGroup)
                .help(model.settings.timerDial.hint)
            } header: {
                Text("Таймер")
            } footer: {
                Text("Блок встанет в панели над опросом: нажатие запускает таймер, и счётчик в строке меню на это время превращается в остаток. Последние три секунды он мигает зелёным, потом столько же держится «Готово» — и всё возвращается к обычному виду. Звука и уведомлений нет: таймер виден там же, где и деньги, и ничего не присылает.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if model.settings.timerPresets.isEmpty {
                    Text("Ни одного таймера не настроено").foregroundStyle(.secondary)
                } else {
                    ForEach($model.settings.timerPresets) { $preset in
                        row($preset)
                    }
                }

                Button {
                    model.settings.timerPresets.append(
                        TimerPreset(name: "Таймер", seconds: 10 * 60))
                } label: {
                    Label("Добавить таймер", systemImage: "plus")
                }
                .disabled(model.settings.timerPresets.count >= TimerRules.maxPresets)
            } header: {
                Text("Какие таймеры показывать")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Не больше трёх: плашки стоят в панели одним рядом, а высота панели меняться не должна. Длительность — от \(TimerRules.length(TimerRules.minSeconds)) до \(TimerRules.length(TimerRules.maxSeconds)); имя лучше короткое, длинное в плашке ужмётся.")
                    Text("Сочетание клавиш запускает таймер из любой программы, не открывая панель; повторное нажатие его останавливает. Пока идёт один таймер, чужие сочетания молчат — как и плашки в панели. Разрешений не нужно никаких, но сочетание, уже занятое системой или другой программой, до счётчика не дойдёт, и узнать об этом заранее нельзя: проверьте нажатием.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Ушли из раздела с недожатым сочетанием — ловец надо снять,
        // иначе он продолжил бы глотать нажатия в других разделах.
        .onDisappear { recorder.stop() }
    }

    private func row(_ preset: Binding<TimerPreset>) -> some View {
        HStack(spacing: 8) {
            // Подпись скрыта: в форме она встала бы слева от поля и повторяла
            // бы одно и то же слово три раза подряд. Пустое поле подскажет
            // само — заголовок раздела уже сказал, что это за строки.
            TextField("Название", text: preset.name)
                .labelsHidden()
                .frame(width: 130)

            Spacer(minLength: 8)

            // Минуты и секунды отдельными полями, без выбора единицы: помидор
            // задают в минутах, подход с эспандером — в секундах, и щёлкать
            // переключателем ради этого не нужно.
            TextField("", value: minutes(preset), format: .number)
                .frame(width: 46)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
            Text("мин").font(.caption).foregroundStyle(.secondary)

            TextField("", value: seconds(preset), format: .number)
                .frame(width: 46)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
            Text("с").font(.caption).foregroundStyle(.secondary)

            hotkeyButton(preset)

            Button {
                let id = preset.wrappedValue.id
                model.settings.timerPresets.removeAll { $0.id == id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Убрать этот таймер")
        }
    }

    /// Кнопка назначения сочетания. Она же его и показывает: отдельная
    /// подпись рядом стоила бы ряду ширины, которой у него нет.
    private func hotkeyButton(_ preset: Binding<TimerPreset>) -> some View {
        let id = preset.wrappedValue.id
        let recording = recorder.recording == id
        let assigned = preset.wrappedValue.hotkey

        return Button {
            if recording {
                recorder.stop()
            } else {
                recorder.start(for: id) { hotkey in
                    // Через правило, а не присваиванием: сочетание должно
                    // сняться с того таймера, у которого оно было.
                    model.settings.timerPresets =
                        TimerRules.assigning(hotkey, to: id, in: model.settings.timerPresets)
                }
            }
        } label: {
            Text(recording ? "Жду нажатия" : assigned.map(TimerRules.hotkeyName) ?? "Назначить")
                .font(.system(size: 11, weight: recording || assigned != nil ? .medium : .regular))
                .foregroundStyle(recording ? Color.accentColor
                                 : (assigned == nil ? Color.secondary : Color.primary))
                .lineLimit(1)
                // Ширина постоянная: от «Назначить» к «⌥⌘1» ряд не должен ехать.
                .frame(width: 88)
        }
        .help(recording
              ? "Нажмите сочетание с Cmd, Alt или Ctrl. Esc — отменить, ⌫ — снять сочетание."
              : "Запускать этот таймер с клавиатуры, не открывая панель")
    }

    /// Обе половины длительности правят одно и то же поле, поэтому вторая
    /// половина каждый раз берётся из текущего значения, а не запоминается.
    private func minutes(_ preset: Binding<TimerPreset>) -> Binding<Int> {
        Binding(
            get: { preset.wrappedValue.seconds / 60 },
            set: { preset.wrappedValue.seconds = TimerRules.clamp($0 * 60 + preset.wrappedValue.seconds % 60) }
        )
    }

    private func seconds(_ preset: Binding<TimerPreset>) -> Binding<Int> {
        Binding(
            get: { preset.wrappedValue.seconds % 60 },
            set: { preset.wrappedValue.seconds = TimerRules.clamp(preset.wrappedValue.seconds / 60 * 60 + $0) }
        )
    }
}
