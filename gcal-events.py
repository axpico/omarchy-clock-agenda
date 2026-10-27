#!/usr/bin/env python3
"""Google Calendar events for the clock panel (Panel.qml), as TSV.

Usage: gcal-events.py START_DATE END_DATE   (YYYY-MM-DD, END exclusive)

Output: a header line, then one row per event, sorted by date and time:

    start_date  start_time  title  color    end_date    end_time  location  calendar  link  url  description
    2026-10-14  08:15       Lab    #5484ed  2026-10-14  10:00     Room 3    Uni       ...
    2026-10-15              Trip   #a47ae2  2026-10-17                               <- all-day: empty times

end_date is inclusive (Google's exclusive all-day end minus one day).
link is the video call (Meet) link, url the event in Google Calendar,
description plain text, HTML stripped and cut to 300 characters.

Why not plain `gcalcli agenda --tsv`: gcalcli never reports Google's
colors. This talks to the Calendar API directly, but borrows gcalcli's
stored OAuth token, so `gcalcli init` stays the only login.

Rules:
- Calendars hidden in Google Calendar (unselected) are skipped.
- Events you declined are skipped (matches gcalcli's --nodeclined).
- Recurring events are expanded into single occurrences.
- Times are converted to the local timezone; multi-day events are
  listed on their start day, with end_date telling how far they run.
- Color: the event's own color if it has one, else its calendar's.

Any failure (no token, expired login, offline) raises, exits non-zero,
and the panel just shows no events.
"""
import html
import pickle
import re
import sys
from datetime import date as Date, datetime, timedelta
from pathlib import Path

from google.auth.transport.requests import Request
from googleapiclient.discovery import build

# gcalcli's saved login: a pickled google.oauth2 Credentials object.
TOKEN = Path.home() / ".local/share/gcalcli/oauth"


def clean(text):
    """One line of plain text: tabs and newlines would break the TSV."""
    return re.sub(r"\s+", " ", text or "").strip()


def plain(description):
    """Event descriptions are HTML; keep the text, capped at 300 chars."""
    text = clean(html.unescape(re.sub(r"<[^>]+>", " ", description or "")))
    return text if len(text) <= 300 else text[:299].rstrip() + "…"


# Call links pasted into the location or description rather than attached
# as conference data (Webex rooms, Zoom, Teams).
CALL_URL = re.compile(r"https?://[^\s<>\"]*(?:webex\.com|zoom\.us|teams\.microsoft\.com|meet\.google\.com)[^\s<>\"]*")


def video_link(ev):
    """The Meet link, another provider's video entry point, or a call URL
    found in the location or description."""
    if ev.get("hangoutLink"):
        return ev["hangoutLink"]
    for entry in ev.get("conferenceData", {}).get("entryPoints", []):
        if entry.get("entryPointType") == "video":
            return entry.get("uri", "")
    found = CALL_URL.search((ev.get("location") or "") + " " + html.unescape(ev.get("description") or ""))
    return found.group(0) if found else ""


def main(start, end):
    """Print the events from `start` (inclusive) to `end` (exclusive)."""
    # Access tokens last about an hour; refresh with the stored refresh
    # token and save the result back, the same way gcalcli does.
    with TOKEN.open("rb") as f:
        creds = pickle.load(f)
    if not creds.valid:
        creds.refresh(Request())
        with TOKEN.open("wb") as f:
            pickle.dump(creds, f)

    # Event colors are stored as ids ("1".."11"); this maps them to hex.
    api = build("calendar", "v3", credentials=creds, cache_discovery=False)
    event_colors = api.colors().get().execute().get("event", {})
    # The API wants timezone-aware bounds: local midnight on each date.
    tz = datetime.now().astimezone().tzinfo
    time_min = datetime.fromisoformat(start).replace(tzinfo=tz).isoformat()
    time_max = datetime.fromisoformat(end).replace(tzinfo=tz).isoformat()

    rows = []
    for cal in api.calendarList().list().execute().get("items", []):
        if not cal.get("selected", True):
            continue
        events = api.events().list(
            calendarId=cal["id"], timeMin=time_min, timeMax=time_max,
            singleEvents=True, orderBy="startTime", maxResults=2500,
        ).execute().get("items", [])
        for ev in events:
            # `self` marks your own attendee entry on the event.
            if any(a.get("self") and a.get("responseStatus") == "declined"
                   for a in ev.get("attendees", [])):
                continue
            # Timed events have start.dateTime, all-day ones start.date.
            s, e = ev["start"], ev["end"]
            if "dateTime" in s:
                dt = datetime.fromisoformat(s["dateTime"]).astimezone(tz)
                date, time = dt.strftime("%Y-%m-%d"), dt.strftime("%H:%M")
                et = datetime.fromisoformat(e["dateTime"]).astimezone(tz)
                # Ending at midnight belongs to the day before.
                end_day = et - timedelta(minutes=1) if et.strftime("%H:%M") == "00:00" else et
                end_date, end_time = end_day.strftime("%Y-%m-%d"), et.strftime("%H:%M")
            else:
                date, time = s["date"], ""
                end_date = (Date.fromisoformat(e["date"]) - timedelta(days=1)).isoformat()
                end_time = ""
            color = event_colors.get(ev.get("colorId", ""), {}).get("background") \
                or cal.get("backgroundColor", "")
            rows.append((
                date, time, clean(ev.get("summary")) or "(no title)", color,
                end_date, end_time, clean(ev.get("location")),
                clean(cal.get("summaryOverride") or cal.get("summary")),
                video_link(ev), ev.get("htmlLink", ""), plain(ev.get("description")),
            ))

    print("start_date\tstart_time\ttitle\tcolor\tend_date\tend_time"
          "\tlocation\tcalendar\tlink\turl\tdescription")
    for row in sorted(rows, key=lambda r: (r[0], r[1])):
        print("\t".join(row))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
