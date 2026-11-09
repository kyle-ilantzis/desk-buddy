// Everything the mod does that depends on the OS the native app runs on. The
// rest of the mod is the same everywhere, so a new OS is a new bridge, not a new
// branch in register.ts.
//
// A bridge only says what to run and where things are; register.ts makes the
// calls on `$`. The engine reads a module's calls off its source, so `$` can't be
// handed to a bridge's methods.

/** A program and its arguments, for `$.process.run`. */
export type Command = { argv: string[], timeoutMs?: number }

/** The environment variables a bridge needs, read by register.ts. */
export type OSEnv = { HOME?: string }

export interface OSBridge {
  readonly os: 'macos' | 'windows'
  /** Where the app listens for reports, status and quit. */
  socketPath(env: OSEnv): string
  /** Opens the app in the background, or brings a running one up. */
  launchApp(): Command
  /**
   * Where the app may be installed, the first choice first. An install goes to the
   * first folder that can be written to.
   */
  installedApp(env: OSEnv): string[]
  /** Unpacks the app's archive into the folder `into`, which then holds the app under its own name. */
  unpackApp(archive: string, into: string): Command
  /** Moves `from` into the folder `into` under its own name, and does nothing if one is there already. */
  moveInto(from: string, into: string): Command
  /** Opens the app at this path in the background: right after an install, the OS may not know it by id yet. */
  launchAppAt(path: string): Command
  /** Prints the version of the app at this path. */
  appVersionOf(path: string): Command
  /** The last resort for a closed or hung app, after a quit over the socket. */
  killApp(): Command
  /** Exits 0 while the app is still running. */
  appRunning(): Command
  /** Removes a folder and all it holds, if it is there. */
  removeFolder(path: string): Command
  /** Makes each folder, with any parents it lacks. */
  makeFolders(paths: string[]): Command
  copyFile(from: string, to: string): Command
  /** Moves `from` over `to` in one step, so a reader never sees half a file. */
  replaceFile(from: string, to: string): Command
  /** The programs an avatar maker may run besides the app's own binary. */
  makerCommands(): readonly string[]
  /** The app's archive in the plugin's `app/` folder, as scripts/dist.sh names it. */
  appArchive(): string
}

const BUNDLE_ID = 'kyleilantzis.desk-buddy.overlay'
const APP = 'DeskBuddy.app'

export const MacOsBridge: OSBridge = {
  os: 'macos',
  socketPath: ({ HOME }) => `${HOME}/Library/Application Support/DeskBuddy/buddy.sock`,
  launchApp: () => ({ argv: ['/usr/bin/open', '-g', '-b', BUNDLE_ID], timeoutMs: 10_000 }),
  // A standard account can't write to /Applications, so ~/Applications comes second.
  installedApp: ({ HOME }) => [`/Applications/${APP}`, `${HOME}/Applications/${APP}`],
  unpackApp: (archive, into) => ({ argv: ['/usr/bin/ditto', '-x', '-k', archive, into], timeoutMs: 60_000 }),
  // Into a folder, BSD mv renames to <folder>/<name>, and -n skips it if that is taken.
  moveInto: (from, into) => ({ argv: ['/bin/mv', '-n', from, `${into}/`] }),
  launchAppAt: path => ({ argv: ['/usr/bin/open', '-g', path], timeoutMs: 10_000 }),
  appVersionOf: path => ({ argv: ['/usr/bin/defaults', 'read', `${path}/Contents/Info`, 'CFBundleShortVersionString'] }),
  killApp: () => ({ argv: ['/usr/bin/pkill', '-x', 'DeskBuddy'] }),
  appRunning: () => ({ argv: ['/usr/bin/pgrep', '-x', 'DeskBuddy'] }),
  removeFolder: path => ({ argv: ['/bin/rm', '-rf', path] }),
  makeFolders: paths => ({ argv: ['/bin/mkdir', '-p', ...paths] }),
  copyFile: (from, to) => ({ argv: ['/bin/cp', from, to] }),
  replaceFile: (from, to) => ({ argv: ['/bin/mv', '-f', from, to] }),
  makerCommands: () => ['swift', 'swiftc', 'sips'],
  appArchive: () => 'DeskBuddy-macos.zip',
}

const notImplemented = (): never => { throw new Error('not implemented') }

// Section 5 of the roadmap fills this in.
export const WindowsBridge: OSBridge = {
  os: 'windows',
  socketPath: notImplemented,
  launchApp: notImplemented,
  installedApp: notImplemented,
  unpackApp: notImplemented,
  moveInto: notImplemented,
  launchAppAt: notImplemented,
  appVersionOf: notImplemented,
  killApp: notImplemented,
  appRunning: notImplemented,
  removeFolder: notImplemented,
  makeFolders: notImplemented,
  copyFile: notImplemented,
  replaceFile: notImplemented,
  makerCommands: notImplemented,
  appArchive: notImplemented,
}

/** The bridge for this machine, from the `OS` variable: Windows sets it, macOS doesn't. */
export const bridgeFor = (osVariable: string | undefined): OSBridge =>
  osVariable === 'Windows_NT' ? WindowsBridge : MacOsBridge
