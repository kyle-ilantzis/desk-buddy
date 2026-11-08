We need a strategy to better prepare src/mod for cross platform work.

Right now it will run the native app expecting mac os.
It will install the app expecting mac os as well in roadmaps/03-mod-install.md in the plan

So there should be an interface object with methods, OSBridge MacOsBridge and WindowsBridge
WindowsBridge will throw Error("not implemented"). And move the macOS commands into the MacOsBridge.

Analyze the code to find the methods OSBridge should have. Then impement them.

===

I need a strategy to better distribute the mod as I iterate on it.
In the future we are working towards distributing the mod.
ROADMAP.md and roadmaps/03-mod-install.md need better structure for future distribution.

I want some kind of structure

src/mod <the claude mod that will run on both mac and windows>
src/native/ <the os code for macos and windows along with the core for both oses>
build/ <the intermediate folder for builds and packaging>
dist/ <the final folder to distribute the plugin>

I want when ever the src is modified, we redistribute it
And we point ClaudeCode desktop app somehow to the dist

===

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