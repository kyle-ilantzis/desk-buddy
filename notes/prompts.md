Help me elaborate how to tackle ROADMAP.md and `## 1. Standalone app​`

open question:
`Work out what `/desk-buddy stop` means`
Decision: let is close the app as if the user decided to. its the same after all.

However in the standalone app, the buddy needs to change between different activities.
It should not be relaying on polling from claude sessions.

Claude sessions join the app.
This means the mod is the one with the polling logic on claude sessions.
It sends Reports to the running app.
What do you recommened for a claude typescript plugin (is it nodejs?) to send data to a running native OS app?