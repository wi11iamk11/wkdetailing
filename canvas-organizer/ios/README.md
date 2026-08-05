# 📚 Canvas Organizer for iPhone

Everything due across your Canvas courses, grouped by urgency, on your phone —
no computer and no server involved. Tap any assignment to open it in Canvas.

```
Overdue (1)
  Lab Report 3           BIO 101 · Was due 2 days ago · 50 pts · MISSING
Due today (1)
  📝 Cell Structure Quiz  BIO 101 · Today at 11:59 PM · 20 pts
Next 7 days (2)
  Essay on Rome          HIST 210 · Monday at 11:59 PM · 100 pts
  Problem Set 5          MATH 240 · Tuesday at 9:00 AM · 30 pts
```

Work you've already turned in is hidden automatically, so the list is only what
you still owe.

## Setup (about 5 minutes)

**1. Install Scriptable** — it's free on the App Store. It runs JavaScript on
your phone, which is what lets this work without a server.

**2. Get a Canvas access token.** Easiest on a computer, but Safari works if you
request the desktop site:

- Canvas → **Account** → **Settings**
- Scroll to **Approved Integrations** → **+ New Access Token**
- Purpose: "Canvas Organizer", leave the expiry blank → **Generate Token**
- Copy it. Canvas only shows it once.

**3. Add the script.** Open [`CanvasOrganizer.js`](CanvasOrganizer.js) on your
phone, copy the whole file, then in Scriptable tap **+** and paste it. Rename it
to `Canvas Organizer` using the settings icon at the bottom of the editor.

**4. Run it.** Tap the play button. It asks for your Canvas address
(`myschool.instructure.com`) and the token, then shows your list. Both are saved
to the iOS Keychain, so you only enter them once.

## Home screen widget

Long-press your home screen → **+** → search **Scriptable** → pick a size →
**Add Widget**. Then tap the new widget, set **Script** to `Canvas Organizer`,
and set **When Interacting** to **Run Script**.

The small size shows the next 3 things due, medium and large show 5. Overdue
items are red, due-today amber. iOS decides how often widgets refresh, so treat
it as a glance, not a live feed — open the script for the current list.

## Siri and Shortcuts

In Shortcuts: **+** → **Scripting** → **Run Script** (Scriptable) → choose
`Canvas Organizer`. Name the shortcut something like "What's due" and you can
ask Siri for it.

## Notes

- Your token is stored in the iOS Keychain and only ever sent to your own
  Canvas server. Nothing goes anywhere else.
- The last successful load is cached, so the widget and list still show
  something if you're offline or on bad campus Wi-Fi — it'll say so.
- If a single course fails to load, the rest still show and a warning row names
  the course that failed.
- **Sign out** is the last row in the list; it clears the saved address and token.

## Troubleshooting

**"Canvas rejected your token"** — the token was deleted or expired. Generate a
new one, sign out in the script, and run it again.

**"Could not reach Canvas"** — usually the wrong address. It should be the bare
domain (`myschool.instructure.com`), not a link to a course page.

**A course is missing** — only currently active, published courses are pulled.

**Nothing shows but you know work is due** — assignments with no due date land
in a "No due date" group at the bottom; unpublished ones are skipped entirely.

## Development

The Canvas and date logic is plain JavaScript with no iOS dependencies, so it
can be tested off-device:

```bash
node ios/test.js
```

That covers paging, grouping, sorting, and the due-date wording against a stub
Canvas server. The Scriptable-specific parts (the table, the widget, Keychain)
can only be verified on a real device.
