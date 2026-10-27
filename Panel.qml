import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The clock's calendar popup: a month grid with ISO week numbers, built to
// sit beside the weather panel — same hero-over-detail composition, same
// spacing scale, same small-caps labels.
//
// The grid is a read-out rather than a picker: today is outlined, and the
// only thing that moves is which month is on screen — chevrons, the scroll
// wheel, and the arrow keys all step it.
//
// Local addition (axpico.clock): Google Calendar events. gcal-events.py,
// next to this file, prints the visible weeks' events with their Google
// colors; days get a colored dot per event (hover lists them). Under the
// month sits an agenda of the next seven days, or — once a day is clicked —
// that day's events, each with its time range, location, calendar,
// description, and call link. See the "Google Calendar" block below.
//
// BarWidget.qml owns the bar label and hands this panel the button to
// anchor against.
Panel {
  id: root
  moduleName: "omarchy.clock"
  ipcTarget: "omarchy.clock"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Today. SystemClock keeps this honest across midnight so the
  //      highlight rolls over without the panel being reopened.
  property date today: new Date()
  readonly property string todayKey: Model.keyForDate(today)

  // The month on screen. Stepping moves this and nothing else: the grid is
  // a read-out, not a picker, so there is no per-day cursor to keep in sync.
  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth()

  readonly property date viewDate: new Date(viewYear, viewMonth, 1)
  readonly property bool viewingCurrentMonth: viewYear === today.getFullYear() && viewMonth === today.getMonth()

  // Pinned to today, not to the month being browsed — stepping through the
  // calendar does not change how much of the year is gone.
  readonly property real yearDone: Model.yearProgress(today.getFullYear(), today.getMonth(), today.getDate())
  readonly property int yearDonePercent: Model.yearProgressPercent(today.getFullYear(), today.getMonth(), today.getDate())

  // Memento mori, for anyone who goes looking: double-tapping the year bar
  // asks for a birth year and a life expectancy, and a second bar tracks one
  // against the other. A birth year rather than an age, so it keeps counting
  // on its own. Without one the bar stays hidden.
  readonly property int birthYear: Model.parseBirthYear(setting("birthYear", 0), today.getFullYear())
  readonly property int age: Model.ageFromBirthYear(birthYear, today.getFullYear())
  readonly property int lifeExpectancy: Model.parseLifeExpectancy(setting("lifeExpectancy", 0))
  readonly property real lifeDone: Model.lifeProgress(age, lifeExpectancy)
  readonly property int lifeDonePercent: Model.lifeProgressPercent(age, lifeExpectancy)
  property bool editingLife: false

  // Unset falls through to the locale's own first day, so a fresh install
  // starts out matching the rest of the desktop rather than a hardcoded
  // convention. Clicking the grid's "W" heading writes the choice back to
  // shell.json.
  readonly property int weekStart: Model.normalizedWeekStart(setting("weekStartDay", null), Qt.locale().firstDayOfWeek)
  // The interface is English throughout, so day names are not taken from the
  // system locale. Where the week starts still is: that is a regional
  // convention rather than a translation, and it stays overridable above.
  readonly property var labelLocale: Qt.locale("en_US")
  readonly property string nextWeekStartLabel: labelLocale.dayName(Model.toggledWeekStart(weekStart), Locale.LongFormat)
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthGrid(viewYear, viewMonth, weekStart, todayKey)


  // Guarded so the widget renders before the bar is injected (the bar-widget
  // contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int cellWidth: Style.space(52)
  readonly property int cellHeight: Style.space(34)
  readonly property int cellSpacing: Style.space(2)
  readonly property int weekColumnWidth: Style.space(32)
  readonly property int gutterWidth: Style.space(14)

  function open() {
    refresh()
    root.controller.show()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins, while
    // a handoff to a panel that does not manage the flag still leaves it
    // cleared rather than stuck on.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    // Dismissing the panel mid-edit would otherwise leave the inputs up,
    // waiting behind a closed popup for the next time it opens.
    if (root.editingLife) root.cancelEditingLife()
    root.selectedKey = ""
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still
  // holding must not keep the center indicators revealed behind the panel.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    root.today = new Date()
    root.goToToday()
    root.loadEvents()
  }

  // ---- Google Calendar, via gcal-events.py (gcalcli's login, Google's
  //      colors). Fetched when the popup opens, when the month changes, and
  //      every 15 minutes while it stays open. Any failure (script error,
  //      gcalcli login expired, offline) just leaves the grid bare, so the
  //      calendar never breaks because of it.
  // ponytail: read-only, every calendar selected in Google; add a filter or
  // event creation if ever needed.

  // Events by day: { "YYYY-MM-DD": [event, ...] }. The key is the same one
  // Model.monthGrid puts on each day cell, so a cell looks its events up
  // directly. An event is { startDate, time, endDate, endTime, title, color,
  // location, calendar, link, url, description }: times are "HH:MM", or ""
  // for all-day events; `color` is "#rrggbb", or "" for the theme accent.
  // Multi-day events also sit on their later days, marked `continued`.
  property var events: ({})

  // The day clicked in the grid, or "" for the seven-day agenda.
  property string selectedKey: ""
  readonly property int agendaLength: 7
  readonly property var agenda: Model.agendaDays(events, todayKey, agendaLength)
  readonly property string nowTime: Qt.formatTime(clock.date, "HH:mm")

  // The [start, end) dates to fetch, as "YYYY-MM-DD": the six weeks the grid
  // shows (spill-over days get dots too), stretched to cover the agenda when
  // the grid is browsing an earlier month.
  function eventsRange() {
    var first = weeks[0].days[0].key
    var end = Model.addDaysToKey(weeks[weeks.length - 1].days[6].key, 1)
    var agendaEnd = Model.addDaysToKey(todayKey, agendaLength)
    if (agendaEnd > end) end = agendaEnd
    if (todayKey < first) first = todayKey
    return [first, end]
  }

  // Starts a fetch for the visible range. Only one runs at a time: a call
  // while one is in flight is dropped, and onExited catches up if the month
  // moved in the meantime.
  function loadEvents() {
    if (eventsProc.running) return
    eventsProc.command = ["/usr/bin/python3", String(Qt.resolvedUrl("gcal-events.py")).replace("file://", "")].concat(eventsRange())
    eventsProc.running = true
  }

  // Turns the script's TSV into `events`. Columns are found by header name,
  // so their order doesn't matter and any missing column just reads as "".
  // Output without start_date and title headers (an error message, say)
  // leaves `events` as it was.
  function parseEvents(text) {
    var lines = String(text).split("\n").filter(function(l) { return l.length > 0 })
    if (lines.length === 0) return
    var head = lines[0].split("\t")
    if (head.indexOf("start_date") < 0 || head.indexOf("title") < 0) return
    var map = {}
    for (var i = 1; i < lines.length; i++) {
      var cols = lines[i].split("\t")
      var col = function(name) { var at = head.indexOf(name); return at >= 0 ? (cols[at] || "") : "" }
      var key = col("start_date")
      if (!map[key]) map[key] = []
      map[key].push({
        startDate: key, time: col("start_time"), endDate: col("end_date") || key, endTime: col("end_time"),
        title: col("title"), color: col("color"), location: col("location"), calendar: col("calendar"),
        link: col("link"), url: col("url"), description: col("description")
      })
    }
    root.events = Model.expandMultiDay(map)
  }

  // One event as a display line: "09:30–11:00  Title", or "All day  Title".
  function eventLine(ev) {
    return Model.timeRange(ev) + "  " + ev.title
  }

  // "TODAY", "TOMORROW", or "THU 29 OCT" over a day's events.
  function dayHeading(key) {
    if (key === todayKey) return "TODAY"
    if (key === Model.addDaysToKey(todayKey, 1)) return "TOMORROW"
    var parts = key.split("-")
    var d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
    return (labelLocale.dayName(d.getDay(), Locale.ShortFormat) + " " + Model.shortDate(key)).toUpperCase()
  }

  // Clicking a day shows its events under the grid; clicking it again goes
  // back to the agenda. A spill-over day also brings its month on screen.
  function selectDay(day) {
    if (root.selectedKey === day.key) { root.selectedKey = ""; return }
    if (!day.inMonth) { root.viewYear = day.year; root.viewMonth = day.month }
    root.selectedKey = day.key
  }

  // Month stepping rebuilds `weeks`; refetch only while someone is looking.
  onWeeksChanged: if (root.opened) loadEvents()

  // Runs gcal-events.py. On a failed run the old events are cleared rather
  // than left stale. If the month changed while it ran, its command no
  // longer matches the visible range, so fetch again for the new one.
  Process {
    id: eventsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseEvents(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.events = ({})
      var range = root.eventsRange()
      if (command[command.length - 2] !== range[0] || command[command.length - 1] !== range[1]) root.loadEvents()
    }
  }

  // Keeps a popup that is left open in step with the calendar.
  Timer {
    interval: 15 * 60 * 1000
    repeat: true
    running: root.opened
    onTriggered: root.loadEvents()
  }

  function goToToday() {
    root.selectedKey = ""
    root.viewYear = today.getFullYear()
    root.viewMonth = today.getMonth()
  }

  function moveMonth(delta) {
    var next = Model.stepMonth(viewYear, viewMonth, delta)
    root.viewYear = next.year
    root.viewMonth = next.month
  }

  function moveYear(delta) {
    moveMonth(delta * 12)
  }

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value. With no
  // writable entry (the widget is not in the layout) it stays a session-only
  // preference rather than doing nothing. The host widget builds its own
  // entry when the label format is cycled, so it has to be kept in step or
  // it would write this key straight back out from a stale copy.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setWeekStart(day) {
    var next = Model.normalizedWeekStart(day, root.weekStart)
    if (next === root.weekStart) return
    persistSettings({ weekStartDay: Model.weekStartSettingName(next) })
  }

  function startEditingLife() {
    root.editingLife = true
    Qt.callLater(function() {
      bornField.text = root.birthYear > 0 ? String(root.birthYear) : ""
      expectancyField.text = String(root.lifeExpectancy)
      bornField.selectAll()
      bornField.forceActiveFocus()
    })
  }

  function cancelEditingLife() {
    root.editingLife = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // Shared by both fields: Tab hops to the other one, Enter commits the pair,
  // Escape drops the lot.
  function handleLifeKey(event, other) {
    if (event.key === Qt.Key_Escape) {
      root.cancelEditingLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.commitLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      other.selectAll()
      other.forceActiveFocus()
      event.accepted = true
    }
  }

  // Double-tapping the life bar puts it away again. The expectancy stays in
  // the config so setting a birth year again brings your own number back
  // rather than the default.
  function clearLife() {
    if (root.birthYear <= 0) return
    persistSettings({ birthYear: 0 })
  }

  function commitLife() {
    var born = Model.parseBirthYear(bornField.text, today.getFullYear())
    var span = Model.parseLifeExpectancy(expectancyField.text)
    if (born !== root.birthYear || span !== root.lifeExpectancy)
      persistSettings({ birthYear: born, lifeExpectancy: span })
    cancelEditingLife()
  }

  function toggleWeekStart() {
    setWeekStart(Model.toggledWeekStart(root.weekStart))
  }

  // English short day names, matching the rest of the interface.
  function weekdayLabel(weekday) {
    return String(labelLocale.dayName(weekday, Locale.ShortFormat)).toUpperCase()
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      if (Model.keyForDate(clock.date) === String(root.todayKey)) return
      var followToday = root.viewingCurrentMonth
      root.today = clock.date
      if (followToday) root.goToToday()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(calendarColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLife
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.moveMonth(dx)
        if (dy !== 0) root.moveYear(dy)
      }
      onActivateRequested: root.goToToday()
      // Escape backs out of a selected day before it closes the panel.
      onCloseRequested: {
        if (root.selectedKey !== "") root.selectedKey = ""
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "[") root.moveMonth(-1)
        else if (t === "]") root.moveMonth(1)
        else if (t === "{") root.moveYear(-1)
        else if (t === "}") root.moveYear(1)
        else if (t === "t" || t === "T") root.goToToday()
        else if (t === "w" || t === "W") root.toggleWeekStart()
      }

      Flickable {
        id: calendarScroll
        anchors.fill: parent
        contentWidth: calendarColumn.width
        contentHeight: calendarColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height || contentWidth > width

        Column {
          id: calendarColumn
          // Never narrower than the grid. The popup width is capped to what
          // the screen allows, and a fixed seven-column grid would otherwise
          // lose its last days off the edge instead of scrolling.
          width: Math.max(calendarScroll.width, gridColumn.width)
          spacing: Style.space(8)

          // ---- Hero: today, centered. Once the view has stepped back
          //      it is also the way home — clicking the date you are
          //      looking for beats hunting for a reset button.
          Item {
            width: parent.width
            height: heroRow.height

            Row {
              id: heroRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(22)

              Text {
                // Baseline-aligned, not center-aligned: "July 26" carries a
                // descender, so centering the two boxes leaves the icon
                // sitting visibly low against the digits.
                anchors.baseline: heroDate.baseline
                text: "󰃭"
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                // Decorative, and deliberately outside the Style.font.*
                // scale. Sized so the glyph reads at the cap height of the
                // date beside it rather than towering over it.
                font.pixelSize: 48
              }

              Text {
                id: heroDate
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: Qt.formatDate(root.today, "MMMM d")
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: 52
                font.bold: true
              }
            }

            MouseArea {
              id: heroMouse
              x: heroRow.x
              y: heroRow.y
              width: heroRow.width
              height: heroRow.height
              enabled: !root.viewingCurrentMonth
              hoverEnabled: enabled
              cursorShape: Qt.PointingHandCursor
              onClicked: root.goToToday()

              PanelToolTip {
                visible: heroMouse.containsMouse
                text: "Back to today"
                fontFamily: root.contentFontFamily
              }
            }
          }

          // ---- Year progress, doubling as the rule under the hero:
          //      a plain hairline said nothing, and whole days done
          //      over days in the year says the same thing louder.
          Item {
            width: parent.width
            height: yearBlock.y + yearBlock.height

            Item {
              id: yearBlock
              y: Style.space(6)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(yearLabel.implicitHeight, Style.space(10))

              TapHandler {
                enabled: !root.editingLife
                onDoubleTapped: root.startEditingLife()
              }

              Row {
                visible: root.editingLife
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "BORN"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: bornField
                  width: Style.space(70)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "year"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, expectancyField) }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.verticalCenterOffset: 0
                  leftPadding: Style.space(6)
                  text: "LIVE TO"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: expectancyField
                  width: Style.space(60)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "90"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, bornField) }
                }
              }

              Text {
                id: yearLabel
                textFormat: Text.PlainText
                visible: !root.editingLife
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.today.getFullYear()
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: yearPercent
                textFormat: Text.PlainText
                visible: !root.editingLife
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.yearDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                id: yearTrack
                visible: !root.editingLife
                anchors.left: yearLabel.right
                anchors.right: yearPercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.yearDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }
            }
          }

          // ---- Memento mori. Only here once someone has gone looking and
          //      given an age; the same rail as the year above it, measured
          //      against a nominal lifetime.
          Item {
            visible: root.birthYear > 0
            width: parent.width
            height: visible ? lifeBlock.height : 0

            Item {
              id: lifeBlock
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(lifeLabel.implicitHeight, Style.space(10))

              Text {
                id: lifeLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "LIFE"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: lifePercent
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.lifeDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                anchors.left: lifeLabel.right
                anchors.right: lifePercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.lifeDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }

              TapHandler {
                onDoubleTapped: root.clearLife()
              }

              MouseArea {
                id: lifeMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton

                PanelToolTip {
                  visible: lifeMouse.containsMouse
                  text: "Memento Mori"
                  fontFamily: root.contentFontFamily
                }
              }
            }
          }

          // ---- Month grid: week numbers down a gutter on the left, then
          //      the seven day columns. Always six rows, so the popup is
          //      exactly as tall in February as it is in August.
          Item {
            width: parent.width
            height: gridColumn.y + gridColumn.height

            WheelHandler {
              onWheel: function(event) {
                // Horizontal wheels and touchpad side-scrolls report y === 0;
                // without this they would every one read as "next month".
                if (event.angleDelta.y === 0) return
                root.moveMonth(event.angleDelta.y > 0 ? -1 : 1)
              }
            }

            Column {
              id: gridColumn
              // The meter above is a solid rule; the grid needs room to
              // read as its own block rather than hanging off it.
              y: Style.space(18)
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(3)

              Row {
                id: headerRow
                spacing: root.cellSpacing

                // The week-number heading doubles as the week-start toggle.
                // It is the one control in the panel whose meaning is not
                // self-evident, so it carries a tooltip naming the day the
                // click will switch to.
                Rectangle {
                  width: root.weekColumnWidth
                  height: Style.space(16)
                  radius: Style.cornerRadius
                  color: weekStartMouse.containsMouse
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: "W"
                    color: weekStartMouse.containsMouse
                      ? Style.hoverStateColor(root.contentForeground, Color.accent)
                      : Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }

                  MouseArea {
                    id: weekStartMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleWeekStart()
                  }

                  PanelToolTip {
                    visible: weekStartMouse.containsMouse
                    text: "Start weeks on " + root.nextWeekStartLabel
                    fontFamily: root.contentFontFamily
                  }
                }

                Item {
                  width: root.gutterWidth
                  height: Style.space(16)
                }

                Repeater {
                  model: root.weekdays

                  Text {
                    textFormat: Text.PlainText
                    required property var modelData
                    width: root.cellWidth
                    height: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: root.weekdayLabel(modelData)
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }
                }
              }

              Repeater {
                model: root.weeks

                Row {
                  required property var modelData
                  spacing: root.cellSpacing

                  Text {
                    textFormat: Text.PlainText
                    width: root.weekColumnWidth
                    height: root.cellHeight
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.week
                    color: Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Item {
                    width: root.gutterWidth
                    height: root.cellHeight
                  }

                  Repeater {
                    model: modelData.days

                    Rectangle {
                      required property var modelData

                      width: root.cellWidth
                      height: root.cellHeight
                      radius: Style.cornerRadius
                      // Today is outlined, not filled: a lit-up block shouts
                      // over a grid this quiet. The fill is reserved for the
                      // day picked to show its events, and for hover.
                      color: modelData.key === root.selectedKey
                        ? Style.selectedFillFor(root.contentForeground, Color.accent)
                        : (dayMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent")
                      border.width: modelData.today ? Style.spacing.hairline : 0
                      border.color: Style.normalBorderFor(root.contentForeground, Color.accent)

                      Text {
                        textFormat: Text.PlainText
                        anchors.centerIn: parent
                        text: modelData.day
                        color: modelData.inMonth
                          ? (modelData.weekend ? Qt.darker(root.contentForeground, 1.45) : root.contentForeground)
                          : Qt.darker(root.contentForeground, 2.2)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: modelData.today
                      }

                      // This cell's events from the Google Calendar block, [] if none.
                      readonly property var dayEvents: root.events[modelData.key] || []

                      // One dot per event in its Google color, capped at three.
                      Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Style.space(4)
                        spacing: Style.space(2)

                        Repeater {
                          model: dayEvents.slice(0, 3)

                          Rectangle {
                            required property var modelData
                            width: Style.space(4)
                            height: width
                            radius: width / 2
                            color: modelData.color || Color.accent
                          }
                        }
                      }

                      // Clicking picks the day whose events are listed under
                      // the grid; hovering a day with events previews them.
                      MouseArea {
                        id: dayMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectDay(modelData)
                      }

                      PanelToolTip {
                        visible: dayMouse.containsMouse && dayEvents.length > 0
                        text: dayEvents.map(root.eventLine).join("\n")
                        fontFamily: root.contentFontFamily
                      }
                    }
                  }
                }
              }
            }

            // Hairline down the week-number gutter, drawn only beside the
            // day rows so it does not cut through the header band.
            Rectangle {
              x: gridColumn.x + root.weekColumnWidth + root.cellSpacing + Math.round((root.gutterWidth - width) / 2)
              y: gridColumn.y + headerRow.height + gridColumn.spacing
              width: Style.spacing.hairline
              height: gridColumn.height - headerRow.height - gridColumn.spacing
              color: root.contentForeground
              opacity: 0.1
            }
          }

          // ---- Month stepping, spanning the grid it drives. The chevrons
          //      sit on the grid's outer bounds, the same edges the year
          //      rail above uses, so the row reads as the panel's other
          //      full-width rail instead of a cluster floating in space.
          //      The label is centered and fixed-width, so it holds still
          //      from "MAY" to "SEPTEMBER".
          Item {
            width: parent.width
            height: monthNav.height

            Item {
              id: monthNav
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: monthLabel.implicitHeight + Style.space(10)

              Text {
                id: monthLabel
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                // Fixed width so the chevrons hold still between a
                // "MAY 2026" and a "SEPTEMBER 2026".
                width: Style.space(130)
                horizontalAlignment: Text.AlignHCenter
                text: Qt.formatDate(root.viewDate, "MMMM yyyy").toUpperCase()
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
              }

              PanelActionButton {
                // Pulled out by the button's own padding so the glyph, not
                // its hit box, lines up with the "2026" on the year rail.
                anchors.left: parent.left
                anchors.leftMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅁"
                tooltipText: "Previous month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(-1)
              }

              PanelActionButton {
                anchors.right: parent.right
                anchors.rightMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅂"
                tooltipText: "Next month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(1)
              }
            }
          }

          // ---- Events under the month, in the same small-caps voice as the
          //      YEAR rail: the next seven days by default, or the day
          //      clicked in the grid. Each day gets a heading, each event
          //      a row of its own. A week of lectures runs long, so the
          //      list scrolls on its own below a cap and the grid stays put.
          Flickable {
            anchors.horizontalCenter: parent.horizontalCenter
            width: gridColumn.width
            height: Math.min(eventList.implicitHeight, Style.space(260))
            contentHeight: eventList.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            Column {
              id: eventList
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.selectedKey !== ""
                  ? [{ key: root.selectedKey, events: root.events[root.selectedKey] || [] }]
                  : root.agenda

                Column {
                  id: dayBlock
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(1)

                  Item {
                    width: parent.width
                    height: dayLabel.implicitHeight

                    Text {
                      id: dayLabel
                      textFormat: Text.PlainText
                      text: root.dayHeading(dayBlock.modelData.key)
                      color: Qt.darker(root.contentForeground, 1.5)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.letterSpacing: 1
                    }

                    // Only while a day is picked: the way back to the agenda.
                    Text {
                      visible: root.selectedKey !== ""
                      anchors.right: parent.right
                      textFormat: Text.PlainText
                      text: "NEXT " + root.agendaLength + " DAYS"
                      color: backMouse.containsMouse
                        ? Style.hoverStateColor(root.contentForeground, Color.accent)
                        : Qt.darker(root.contentForeground, 1.9)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 1

                      MouseArea {
                        id: backMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectedKey = ""
                      }
                    }
                  }

                  Text {
                    visible: dayBlock.modelData.events.length === 0
                    textFormat: Text.PlainText
                    text: "No events"
                    color: Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                  }

                  Repeater {
                    model: dayBlock.modelData.events

                    // One event, two lines: a stripe in its color, the time
                    // range and title, then the place (up to its first comma,
                    // links dropped: the camera button carries those).
                    // Hovering shows the rest: full location, calendar, and
                    // description. Clicking opens the event in Google Calendar;
                    // the camera button joins the call when there is one.
                    // Events already over are dimmed.
                    Item {
                      id: row
                      required property var modelData
                      readonly property var event: modelData
                      readonly property bool past: Model.eventPast(modelData, dayBlock.modelData.key, root.todayKey, root.nowTime)
                      readonly property string place: String(event.location || "").split(",")[0].replace(/\s*[–-]?\s*https?:\/\/\S+/g, "").trim() || (event.location && event.link ? "Online" : "")
                      readonly property string more: [
                        event.location ? " " + event.location : "",
                        event.calendar ? " " + event.calendar : "",
                        event.description ? Model.wrapText(event.description, 64) : ""
                      ].filter(function(part) { return part !== "" }).join("\n")

                      width: dayBlock.width
                      height: details.implicitHeight + Style.space(4)
                      opacity: past ? 0.45 : 1

                      Rectangle {
                        anchors.fill: parent
                        radius: Style.cornerRadius
                        color: rowMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent"
                      }

                      MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: row.event.url ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: if (row.event.url) Qt.openUrlExternally(row.event.url)
                      }

                      PanelToolTip {
                        visible: rowMouse.containsMouse && row.more !== ""
                        text: row.more
                        fontFamily: root.contentFontFamily
                      }

                      Rectangle {
                        id: stripe
                        x: Style.space(4)
                        y: Style.space(3)
                        width: Style.space(3)
                        height: parent.height - Style.space(6)
                        radius: Style.cornerRadius > 0 ? width / 2 : 0
                        color: row.event.color || Color.accent
                      }

                      Column {
                        id: details
                        anchors.left: stripe.right
                        anchors.leftMargin: Style.space(8)
                        anchors.right: callButton.visible ? callButton.left : parent.right
                        anchors.rightMargin: Style.space(4)
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                          width: parent.width
                          textFormat: Text.PlainText
                          elide: Text.ElideRight
                          text: Model.timeRange(row.event) + "  " + row.event.title
                          color: root.contentForeground
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.body
                        }

                        Text {
                          visible: row.place !== ""
                          width: parent.width
                          textFormat: Text.PlainText
                          elide: Text.ElideRight
                          text: " " + row.place
                          color: Qt.darker(root.contentForeground, 1.6)
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }

                      PanelActionButton {
                        id: callButton
                        visible: !!row.event.link
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        size: Style.space(20)
                        iconText: "󰕧"
                        tooltipText: "Join call"
                        foreground: root.contentForeground
                        fontFamily: root.contentFontFamily
                        onClicked: Qt.openUrlExternally(row.event.link)
                      }
                    }
                  }
                }
              }

              Text {
                visible: root.selectedKey === "" && root.agenda.length === 0
                textFormat: Text.PlainText
                text: "Nothing in the next " + root.agendaLength + " days"
                color: Qt.darker(root.contentForeground, 1.9)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
              }
            }
          }
        }
      }
    }
  }
}
