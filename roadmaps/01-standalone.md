# 1. Standalone app

How to tackle [section 1 of the roadmap](../ROADMAP.md#1-standalone-app): desk buddy runs without any Claude Code session, and sessions join the running app.

## Decisions

- **`/desk-buddy stop` closes the app as if the person had quit it.** It is the same thing, so it takes the same path as the menu item.
- **The buddy's activity comes from the app.** It changes between activities on its own and doesn't depend on any session.
- **Sessions join the app.** The mod owns everything about Claude sessions and sends reports to the running app.
- **Reports travel as HTTP over a Unix socket.** See [Transport](#transport).

## What the code does today

- **The mod doesn't poll.** It already pushes from hooks, plus a 15-second heartbeat. The polling is the app reading `sessions/*.json` every second in `Stage.poll()`, so the mod only changes where it sends reports.
- **A buddy with no session nearly works.** `cast()` already creates a resting buddy, and `poll()` copes with a missing folder.
- **Napping is the real gap.** After 90 seconds idle the buddy sleeps and never wakes, because `moodSince` only resets when the mood changes.

## Transport

A mod isn't Node. It runs in its own environment with no Node and no DOM, so `node:net` isn't available and everything goes through `$`. `$.http.fetch` has a `socketPath` option for this:

```ts
void $.http.fetch('http://desk-buddy/report', {
  method: 'POST',
  socketPath: `${home}/Library/Application Support/DeskBuddy/buddy.sock`,
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify(report),
})
```

| Option | Verdict |
|---|---|
| **HTTP over a Unix socket** | **Use this.** It needs no port or token, and file permissions limit it to the person's user. |
| HTTP on `127.0.0.1` | Keep as the Windows fallback. It needs a port file and a token, because any local process or web page can reach it. |
| Helper process via `$.process.spawn` | Not needed, and it adds a binary to ship. |
| Status files (today) | This is the polling being removed. |
| URL scheme or XPC | A URL scheme opens a process for every report, and XPC can't be reached from `$`. |

### Endpoints

| Endpoint | Purpose |
|---|---|
| `POST /report` | Full session snapshot, including `seq` and a protocol version |
| `GET /status` | App version, data folder, binary path |
| `POST /quit` | Same as quitting from the menu |

### What has been tested

A small Swift `NWListener` prototype, called with curl:

- It handled 50 POSTs at about 7 ms each, including curl's startup time.
- Connections fail cleanly when the app is down.
- It relaunches fine over a stale socket file left by a crash.

Not tested yet:

- A call from a real mod through `$.http.fetch`.
- Whether an organization's web-fetch policy blocks socket requests.
- Whether `socketPath` works on Windows.

## Steps

### 1. Prove the connection

- [ ] Send one POST from a real mod to a prototype listener. Everything else depends on this.

### 2. Make the app independent

- [ ] Remove `quitAfterEmpty`.
- [ ] Add an idle routine that cycles between wandering, napping and waking, so activity comes from the app itself.

### 3. Replace the files with the socket, in one change

- [ ] Add the endpoints and keep reports in memory.
- [ ] Run `cast()` as soon as a report arrives, so moods update right away instead of up to a second later.
- [ ] Remove the `unread` handling for half-written files.
- [ ] Keep a light 1-second timer for `staleAfter`, `idleGrace` and `avatars.refresh()`.
- [ ] Update `mod/hooks/register.test.ts`, which currently stubs `fs.write`.

### 4. Handle stop and start

- [ ] Have `/desk-buddy stop` call `POST /quit`, which runs the same `NSApp.terminate` as the menu item. Keep `pkill` only as a fallback.

### 5. Move the data

- [ ] Move it to `~/Library/Application Support/DeskBuddy/`, with a one-time migration of `avatars.json`, `sprites/` and `jobs/`.
- [ ] Have `GET /status` return the data folder and binary path, so the mod stops hardcoding them.

### 6. Ship the app

- [ ] Replace `launch.sh` with a build script and a signed, notarized release.
- [ ] Have the mod open the app with `open -g -b <bundle id>`.

## Things to watch for

- **Quit could undo itself.** If a failed report reopened the app, the next heartbeat would bring it straight back after a quit. Only `session.start` and `/desk-buddy start` should open it.
- **A hung app could stall tool calls.** `HttpInit` has no timeout, and `report()` runs inside the `tool.call` hook, so don't await it. Unawaited POSTs can arrive out of order, so add a per-session `seq` and have the app drop older ones.
- **Keep reports as full snapshots.** A relaunched app then rebuilds itself within one 15-second heartbeat. A crashed session still expires through `staleAfter`.
- **Socket path length.** With a path over the 104-byte limit, `NWListener` reported `ready` but created no socket. The planned path is about 60 bytes, but the app should check the length and log an error.
- **Stale socket file.** A crash leaves the file behind, so the app should try connecting at launch. If something answers, exit. Otherwise delete the file and bind.
- **The mod and app can drift apart.** They used to build from the same source, but will now update separately. Version the protocol, ignore unknown fields, and keep treating unknown moods as idle.
- **Hardcoded paths will break.** `overlayBinary()`, the `makerDecision` allow-list and the `../macos/...` paths in `createAvatar` and `launchOverlay` all assume the current layout.

## Open question

**Does a quit outlast the next session?** The working assumption is that a quit lasts until the next new session starts, which reopens the app as it does today. A plugin reload also runs `session.start`, so that would reopen it too. If a quit should stick until the person reopens the app, the mod needs an auto-open setting.
