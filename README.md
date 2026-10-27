# Clock & Agenda

An Omarchy bar clock whose popup shows a month calendar with ISO week numbers
and your Google Calendar events.

- Days get a colored dot per event, in the event's Google Calendar color; hover to list them.
- Below the month: an agenda of the next seven days, or the events of a clicked day,
  with time range, location, calendar, description, and video-call link.
- Hidden calendars and declined events are skipped; recurring events are expanded.

Based on Omarchy's built-in `omarchy.clock`. It replaces it in the bar.

## Requirements

The agenda reuses [gcalcli](https://github.com/insanum/gcalcli)'s Google login,
so you sign in once with gcalcli and nothing else:

```bash
omarchy pkg add gcalcli python-google-api-python-client
gcalcli init
```

Without a gcalcli login (or offline) the plugin still works as a plain clock and calendar.

## Install

```bash
omarchy plugin add https://github.com/axpico/omarchy-clock-agenda --enable
```

Then put `axpico.clock` in place of `omarchy.clock` in the bar
(`~/.config/omarchy/shell.json`), for example:

```json
{ "id": "axpico.clock", "format": "dddd HH:mm", "formatAlt": "d MMMM 'W'ww yyyy" }
```

## Remove

```bash
omarchy plugin remove axpico.clock
```

Put `omarchy.clock` back in the bar. The plugin writes nothing outside its own folder
except refreshing gcalcli's OAuth token in `~/.local/share/gcalcli/oauth`.

## License

MIT
