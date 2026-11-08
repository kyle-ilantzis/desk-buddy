import type { CoreEngineInterface as Engine, Register } from 'claude-code'
import { bridgeFor, type Command, type OSBridge } from './os-bridge.ts'

// The mod runs inside Claude Code and cannot draw outside its window, so it
// only reports. Each session posts a full snapshot of itself over a Unix socket,
// and the native overlay app (../native/<os>/) animates an avatar for each
// session at work, or stopped less than a minute ago by `idleSince`.
// What depends on the OS goes through ./os-bridge.ts.
// Only the project folder's name, tool names and the avatar's name are sent:
// never prompts, commands or file contents.

type Mood =
  | 'starting' | 'idle' | 'thinking' | 'reading' | 'editing'
  | 'running' | 'browsing' | 'delegating' | 'waiting' | 'done' | 'error' | 'ended'

const HEARTBEAT_MS = 15_000
const PROTOCOL = 1
const END_WAIT_MS = 500 // a session's last report gets this long before the session closes
const QUIT_WAIT_MS = 2_000 // a hung app gets this long to answer a quit
const EXIT_POLL_MS = 250 // how often an update checks that the app it quit is gone
const EXIT_TRIES = 20 // after this many checks, the app is killed
const STATUS_WAIT_MS = 1_000
const APP_CLOSED = 'The app is not running. Run `/desk-buddy start`, then try again.'
const FALLBACK = 'kyle' // the avatar worn when nothing else is picked
const RETIRED = 'builtin' // kyle's old name: a saved pick can still say it, and the app dresses it as kyle
const MAX_NAME = 32
const MAKER = 'avatar-maker'
const MAKER_DIR = 'tool-avatar-maker' // its prompt, spec and example sheets, under the plugin root
const MAKER_TYPE = `desk-buddy:${MAKER}`
const CREATE_USAGE = 'Usage: `/desk-buddy create <name> <image> [image...]`. Quote a name or a path with spaces in it.'
const HELP = [
  'Desk buddy commands:',
  '- `/desk-buddy start`: bring the desk buddies out',
  '- `/desk-buddy stop`: send them home',
  '- `/desk-buddy avatar`: list the avatars',
  '- `/desk-buddy avatar <name>`: pick this session\'s avatar, and the default for new sessions',
  '- `/desk-buddy create <name> <image> [image...]`: make a new avatar from pictures, in the background',
].join('\n')

// Session state, so a pick lasts through a /clear and a reload of this mod.
const avatarPick = { plugin: 'desk-buddy', key: 'avatar' } as const

const moodOf = (tool: string): Mood => {
  if (/^(Read|Grep|Glob|LS|NotebookRead)$/.test(tool)) return 'reading'
  if (/^(Edit|Write|MultiEdit|NotebookEdit)$/.test(tool)) return 'editing'
  if (/^(Bash|BashOutput|Monitor)$/.test(tool)) return 'running'
  if (/^(WebFetch|WebSearch)$/.test(tool) || tool.includes('Browser') || tool.includes('chrome')) return 'browsing'
  if (/^(Agent|Task)$/.test(tool)) return 'delegating'
  if (tool === 'AskUserQuestion') return 'waiting'
  return 'thinking'
}

let mood: Mood = 'starting'
let tool: string | undefined
let toolsInFlight = 0
let idleSince: number | undefined // when the last turn ended: unset during one, and before the first
let stopHeartbeat: (() => void) | undefined
type Place = { dataFolder: string, binary: string, resources: string, bundled?: string[], version?: string }

let place: Place | undefined // the app's last answer, for when it has since closed
let seq = 0
let lastSent: Promise<unknown> = Promise.resolve()
const makers = new Map<string, string>() // a running avatar maker's agent id, to the avatar it is making

let bridge: OSBridge | undefined
const osBridge = async ($: Engine) => (bridge ??= bridgeFor(await $.env.get('OS')))
// A bridge only says what to run: the calls on `$` stay in this module.
const run = ($: Engine, { argv, timeoutMs }: Command) =>
  $.process.run(argv, timeoutMs === undefined ? undefined : { timeoutMs })

const socketPathOf = async ($: Engine) => (await osBridge($)).socketPath({ HOME: await $.env.get('HOME') })

async function report($: Engine, next: Mood, nextTool?: string, id?: string) {
  mood = next
  tool = nextTool
  try {
    const sessionId = id ?? (await $.session.id())
    const socketPath = await socketPathOf($)
    const { value: avatar } = await $.state.get(avatarPick)
    // The app can move a session after it starts, from a spare folder to the real one.
    const project = (await $.session.root()).split('/').filter(Boolean).pop() ?? 'claude'
    const updatedAt = await $.clock.now()
    // Starting from the clock keeps it rising through a reload, which resets `seq`.
    seq = Math.max(seq + 1, updatedAt)
    const body = { v: PROTOCOL, seq, id: sessionId, project, mood, tool, avatar: avatar ?? undefined, idleSince, updatedAt }
    // Not awaited: this runs inside tool.call, and a fetch has no timeout, so a
    // hung app would stall tools. The app drops any that arrive out of order by `seq`.
    lastSent = $.http.fetch('http://desk-buddy/report', {
      method: 'POST',
      socketPath,
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    }).catch((error: unknown) => $.ui.log(`desk-buddy: could not report: ${String(error)}`, { to: 'debug' }))
  } catch (error) {
    $.ui.log(`desk-buddy: could not report: ${String(error)}`, { to: 'debug' })
  }
}

// The running app's own answer, or nothing when it is closed or hung.
async function askStatus($: Engine): Promise<Place | undefined> {
  const status = $.http.fetch('http://desk-buddy/status', { socketPath: await socketPathOf($) })
    .then(reply => (reply.ok ? JSON.parse(reply.text) as Place : undefined))
  const timeout = $.clock.sleep(STATUS_WAIT_MS).then(() => undefined)
  const found = await Promise.race([status, timeout]).catch(() => undefined)
  if (found !== undefined) place = found
  return found
}

// Where the app keeps its data and its binary, which only it knows.
const locate = async ($: Engine): Promise<Place | undefined> => (await askStatus($)) ?? place

// The same quit as the menu item. Only a closed or hung app gets the pkill.
async function quitApp($: Engine) {
  const quit = $.http.fetch('http://desk-buddy/quit', { method: 'POST', socketPath: await socketPathOf($) })
  const timeout = $.clock.sleep(QUIT_WAIT_MS).then(() => false)
  const quitting = await Promise.race([quit.then(reply => reply.ok), timeout]).catch(() => false)
  if (!quitting) await run($, (await osBridge($)).killApp())
}

type Opened = { ok: boolean, note?: string }

const folderOf = (path: string) => path.slice(0, path.lastIndexOf('/'))
const nameOf = (path: string) => path.slice(path.lastIndexOf('/') + 1)
const archiveOf = ($: Engine, os: OSBridge) => `${$.plugin.root}/app/${os.appArchive()}`
// Unique to this try, so sessions starting together never share a staging folder.
const stampOf = async ($: Engine) => `${await $.session.id()}-${await $.clock.now()}`

// "1.2.10" as [1, 2, 10]. Anything else, like the "dev" of an app with no version, is undefined.
const partsOf = (version: string | undefined) =>
  version !== undefined && /^\d+(\.\d+)*$/.test(version) ? version.split('.').map(Number) : undefined

// Whether `carried` comes after `installed`. A version that can't be read is never replaced.
function isNewer(carried: string | undefined, installed: string | undefined): boolean {
  const a = partsOf(carried)
  const b = partsOf(installed)
  if (a === undefined || b === undefined) return false
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    const step = (a[i] ?? 0) - (b[i] ?? 0)
    if (step !== 0) return step > 0
  }
  return false
}

// The version of the app the plugin carries: scripts/dist.sh ships src/mod/VERSION at its root.
async function carriedVersion($: Engine): Promise<string | undefined> {
  const path = `${$.plugin.root}/VERSION`
  return (await $.fs.exists(path)) ? String(await $.fs.read(path)).trim() : undefined
}

async function versionAt($: Engine, os: OSBridge, path: string): Promise<string | undefined> {
  const ran = await run($, os.appVersionOf(path))
  return ran.exitCode === 0 ? ran.stdout.trim() : undefined
}

// A quit is answered before the app is gone. One still there after a while is killed.
async function waitForExit($: Engine, os: OSBridge) {
  for (let i = 0; i < 2 * EXIT_TRIES; i += 1) {
    if ((await run($, os.appRunning())).exitCode !== 0) return
    if (i === EXIT_TRIES) await run($, os.killApp())
    await $.clock.sleep(EXIT_POLL_MS)
  }
}

// Swaps the app at `path` for the one the plugin carries, and says why when it
// can't. The new copy is unpacked beside the old first, so the app is missing only
// between two renames, and the old one goes back if the new one doesn't land.
async function replaceApp($: Engine, os: OSBridge, archive: string, path: string, version: string): Promise<string> {
  const folder = folderOf(path)
  const name = nameOf(path)
  const staging = `${folder}/.${name}-${await stampOf($)}`
  const aside = `${staging}/old`
  if ((await run($, os.makeFolders([aside]))).exitCode !== 0) return `${folder} can't be written to`
  try {
    const unpacked = await run($, os.unpackApp(archive, staging))
    if (unpacked.exitCode !== 0) return `its archive could not be unpacked: ${unpacked.stderr.trim().slice(0, 200)}`
    // Either move may find another session's update got there first, which is as good.
    await run($, os.moveInto(path, aside))
    const moved = await run($, os.moveInto(`${staging}/${name}`, folder))
    if (!(await $.fs.exists(path))) await run($, os.moveInto(`${aside}/${name}`, folder))
    if (await versionAt($, os, path) === version) return ''
    return `it could not be moved into ${folder}${moved.exitCode === 0 ? '' : `: ${moved.stderr.trim().slice(0, 200)}`}`
  } finally {
    await run($, os.removeFolder(staging))
  }
}

type Updated = { note?: string, openByPath: boolean }

// Replaces an app older than the one the plugin carries. A running one is quit
// first and reopened after; other sessions rebuild their buddies on their next
// heartbeat. A newer app, such as one from `build.sh --install`, is left alone.
async function updateApp($: Engine, os: OSBridge, path: string): Promise<Updated> {
  const carried = await carriedVersion($)
  const archive = archiveOf($, os)
  if (carried === undefined || !(await $.fs.exists(archive))) return { openByPath: false }
  const running = await askStatus($)
  const current = running?.version ?? await versionAt($, os, path)
  if (!isNewer(carried, current)) return { openByPath: false }
  if (running !== undefined) {
    await quitApp($)
    await waitForExit($, os)
  }
  // A session starting at the same time may have updated it while this one waited.
  if (isNewer(carried, await versionAt($, os, path))) {
    const why = await replaceApp($, os, archive, path, carried)
    if (why !== '') return { note: `Could not update DeskBuddy to ${carried}: ${why}.`, openByPath: running !== undefined }
  }
  return { note: `Updated DeskBuddy from ${current} to ${carried}.`, openByPath: true }
}

// Puts the app the plugin carries in the first folder that takes it. Each try
// unpacks beside its target and moves the app in whole, so a session starting at
// the same time never opens half an app, and whichever move lands first wins.
async function installApp($: Engine, os: OSBridge, places: string[]): Promise<{ path?: string, reason: string }> {
  const archive = archiveOf($, os)
  if (!(await $.fs.exists(archive))) return { reason: `this copy of the mod carries no app for ${os.os}` }
  const stamp = await stampOf($)
  let reason = ''
  for (const path of places) {
    const folder = folderOf(path)
    const staging = `${folder}/.${nameOf(path)}-${stamp}`
    const made = await run($, os.makeFolders([staging]))
    if (made.exitCode !== 0) {
      reason = `${folder} can't be written to`
      continue
    }
    try {
      const unpacked = await run($, os.unpackApp(archive, staging))
      if (unpacked.exitCode !== 0) return { reason: `its archive could not be unpacked: ${unpacked.stderr.trim().slice(0, 200)}` }
      const moved = await run($, os.moveInto(`${staging}/${nameOf(path)}`, folder))
      if (moved.exitCode !== 0) {
        reason = `it could not be moved into ${folder}: ${moved.stderr.trim().slice(0, 200)}`
        continue
      }
    } finally {
      await run($, os.removeFolder(staging))
    }
    if (await $.fs.exists(path)) return { path, reason: '' }
  }
  return { reason }
}

// Opens the app, installing it first if it is in none of its places, or updating
// it if it is older than the plugin's. Only session.start and /desk-buddy start
// call this, so a quit app stays quit.
async function openApp($: Engine): Promise<Opened> {
  const os = await osBridge($)
  const places = os.installedApp({ HOME: await $.env.get('HOME') })
  const present = await Promise.all(places.map(path => $.fs.exists(path)))
  const installedAt = places[present.indexOf(true)]
  let openAt: string | undefined
  let note: string | undefined
  if (installedAt === undefined) {
    const installed = await installApp($, os, places)
    if (installed.path === undefined) return { ok: false, note: `Could not install DeskBuddy: ${installed.reason}.` }
    openAt = installed.path
    note = `Installed DeskBuddy in ${folderOf(installed.path)}.`
  } else {
    const updated = await updateApp($, os, installedAt)
    if (updated.openByPath) openAt = installedAt
    note = updated.note
  }
  // A fresh copy is opened by path: the OS may not know its id, or its new version, yet.
  const ran = await run($, openAt === undefined ? os.launchApp() : os.launchAppAt(openAt))
  if (ran.exitCode === 0) return { ok: true, note }
  const why = `Could not open DeskBuddy: ${ran.stderr.trim().slice(0, 300) || `exit code ${ran.exitCode}`}`
  return { ok: false, note: note === undefined ? why : `${note} ${why}` }
}

// The avatars in the app's avatars.json, each id to its display name if it has one;
// none when there is no file.
async function configuredAvatars($: Engine, dataFolder: string): Promise<Map<string, string | undefined>> {
  const path = `${dataFolder}/avatars.json`
  if (!(await $.fs.exists(path))) return new Map()
  const config = JSON.parse(String(await $.fs.read(path))) as { avatars?: Record<string, { name?: string }> }
  const avatars = config.avatars ?? {}
  return new Map(Object.keys(avatars).sort().map(id => [id, avatars[id]!.name]))
}

// Only the app knows which sheets it carries. One from before the list carries kyle's, as `builtin`.
const bundledAvatars = (found: Place) => found.bundled ?? [FALLBACK]

// "Mr Rex" is `mr-rex`: the id that picks and file names use.
const idOf = (name: string) => name.normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase()
  .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')

// The command's words: quotes group them, and a backslash keeps the next
// character, which is how a dragged-in path spells its spaces.
function words(text: string): string[] {
  const found: string[] = []
  let word: string | undefined
  let quote = ''
  for (let i = 0; i < text.length; i += 1) {
    const c = text[i]!
    if (c === '\\' && quote !== "'" && i + 1 < text.length) {
      i += 1
      word = (word ?? '') + text[i]
    } else if (quote !== '') {
      if (c === quote) quote = ''
      else word = (word ?? '') + c
    } else if (c === '"' || c === "'") {
      quote = c
      word = word ?? ''
    } else if (/\s/.test(c)) {
      if (word !== undefined) found.push(word)
      word = undefined
    } else {
      word = (word ?? '') + c
    }
  }
  if (word !== undefined) found.push(word)
  return found
}

// Nobody answers a background agent's prompts, so each is settled here. The
// paths a maker writes stay in its jobs folder, and it runs only its own tools.
function makerDecision(tool: string, input: Record<string, unknown>, { dataFolder, binary }: Place, makerCommands: readonly string[]) {
  const path = String(input.file_path ?? '')
  const command = String(input.command ?? '')
  const inJobs = path.startsWith(`${dataFolder}/jobs/`) && !path.split('/').includes('..')
  const plain = !/[;&|`$<>\n]/.test(command)
  const allowed =
    /^(Read|Glob|Grep|LS)$/.test(tool) ||
    (/^(Write|Edit|MultiEdit)$/.test(tool) && inJobs) ||
    (tool === 'Bash' && plain && (makerCommands.some(name => command.startsWith(`${name} `)) ||
      command.startsWith(`${binary} --check-avatar `) || command.startsWith(`${binary} --install-avatar `)))
  return allowed
    ? { behavior: 'allow' as const }
    : { behavior: 'deny' as const, message: `An avatar maker writes only in its job folder and runs only ${makerCommands.join(', ')} and DeskBuddy, one command at a time.` }
}

async function createAvatar($: Engine, [name = '', ...images]: string[]): Promise<string> {
  if (name === '' || images.length === 0) return CREATE_USAGE
  const id = idOf(name)
  // These characters are all safe inside the double quotes of the maker's install command.
  if (id === '' || name.length > MAX_NAME || !/^[\p{L}\p{N}][\p{L}\p{N} .'_-]*$/u.test(name)) {
    return `"${name}" can't be an avatar's name: use letters, digits, spaces and dashes, at most ${MAX_NAME} of them.`
  }
  const found = await locate($)
  if (found === undefined) return APP_CLOSED
  const { dataFolder, binary } = found
  if ([...bundledAvatars(found), RETIRED].includes(id)) return `"${id}" can't be an avatar's name: the app keeps it for its own.`
  let names: Map<string, string | undefined>
  try {
    names = await configuredAvatars($, dataFolder)
  } catch (error) {
    return `avatars.json could not be read: ${String(error).slice(0, 200)}`
  }
  if (names.has(id)) return `There is already an avatar named "${id}".`
  if ([...makers.values()].includes(id)) return `"${id}" is already being made.`

  const userHome = await $.env.get('HOME')
  const paths = images.map(path => (path.startsWith('~/') ? `${userHome}${path.slice(1)}` : path))
  for (const path of paths) {
    if (!(await $.fs.exists(path))) return `No image at ${path}.`
  }

  // Copies, so a picture moved later can't stop the job and the agent keeps to one folder.
  const job = `${dataFolder}/jobs/${id}`
  const os = await osBridge($)
  await run($, os.removeFolder(job))
  await run($, os.makeFolders([`${job}/input`, `${job}/out`]))
  const copies: string[] = []
  for (const [i, path] of paths.entries()) {
    const copy = `${job}/input/${i + 1}-${path.split('/').pop()}`
    const ran = await run($, os.copyFile(path, copy))
    if (ran.exitCode !== 0) return `Could not copy ${path}: ${ran.stderr.slice(0, 200)}`
    copies.push(copy)
  }

  const spawned = await $.agent.spawn({
    subagentType: MAKER_TYPE,
    description: `Make the ${id} avatar`,
    cwd: job,
    prompt: [
      `Avatar name: ${name}`,
      `Job folder: ${job}`,
      `Images:\n${copies.map(copy => `- ${copy}`).join('\n')}`,
      `Spec: ${$.plugin.root}/${MAKER_DIR}/AVATAR-SHEETS.md`,
      `Example sheet: ${$.plugin.root}/${MAKER_DIR}/assets/${FALLBACK}.png, with ${FALLBACK}.json beside it. The other bundled avatars in that folder are examples too.`,
      `Check: ${binary} --check-avatar "${job}/out" "${job}/preview.png"`,
      `Install: ${binary} --install-avatar ${id} "${job}/out" "${name}"`,
    ].join('\n'),
  })
  if (spawned.deny !== undefined) return `Could not start the avatar maker: ${spawned.deny.slice(0, 200)}`
  if (spawned.agentId !== undefined) makers.set(spawned.agentId, id)
  return `Making "${name}" in the background from ${copies.length === 1 ? 'one image' : `${copies.length} images`}. You'll get a notification when it's done, and closing this session stops it.`
}

// A maker ended: installed means it is in the config, whatever the agent said.
async function makerEnded($: Engine, agentId: string) {
  const id = makers.get(agentId)
  if (id === undefined) return
  makers.delete(agentId)
  const found = await locate($)
  const names = found === undefined ? new Map<string, string | undefined>() : await configuredAvatars($, found.dataFolder).catch(() => new Map<string, string | undefined>())
  const shown = names.get(id) ?? id
  await $.ui.notify(
    names.has(id) ? `Run /desk-buddy avatar ${id} to wear it.` : `It didn't finish. Its work is in ${found?.dataFolder ?? 'the app\'s data folder'}/jobs/${id}/.`,
    { title: names.has(id) ? `Your avatar ${shown} is ready` : `Avatar ${shown} failed` },
  )
}

// The latest pick becomes the config's default, which outlasts the overlay and
// every session. The overlay reads this file at any moment, so it is moved into
// place whole. With no file yet, this makes one: `avatars` is the one key the app needs.
async function rememberDefault($: Engine, dataFolder: string, name: string) {
  const path = `${dataFolder}/avatars.json`
  const config = (await $.fs.exists(path) ? JSON.parse(String(await $.fs.read(path))) : { avatars: {} }) as { default?: string }
  if (config.default === name) return
  config.default = name
  await $.fs.write(`${path}.tmp`, JSON.stringify(config, null, 2))
  const moved = await run($, (await osBridge($)).replaceFile(`${path}.tmp`, path))
  if (moved.exitCode !== 0) throw new Error(moved.stderr)
}

async function pickAvatar($: Engine, wanted: string): Promise<string> {
  const found = await locate($)
  if (found === undefined) return APP_CLOSED
  let names: Map<string, string | undefined>
  try {
    names = await configuredAvatars($, found.dataFolder)
  } catch (error) {
    return `avatars.json could not be read: ${String(error).slice(0, 200)}`
  }
  const bundled = bundledAvatars(found)
  const ids = [...names.keys(), ...bundled.filter(id => !names.has(id))]
  const choices = ids.map(id => (names.get(id) ?? id) === id ? id : `${names.get(id)} (${id})`).join(', ')
  if (wanted === '') {
    const { value: current } = await $.state.get(avatarPick)
    return `This session: ${current === RETIRED ? FALLBACK : current ?? 'the default'}. Available: ${choices}.`
  }
  const id = wanted === RETIRED ? FALLBACK : wanted
  if (!ids.includes(id)) return `No avatar named "${wanted}". Available: ${choices}.`
  await $.state.set(avatarPick, id)
  await report($, mood, tool)
  try {
    await rememberDefault($, found.dataFolder, id)
  } catch (error) {
    return `This session's buddy is now ${id}, but it could not be saved as the default: ${String(error).slice(0, 200)}`
  }
  return `This session's buddy is now ${id}, and new sessions will start with it.`
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await $.command.register({
      name: 'desk-buddy',
      description: 'List the desk buddy commands, bring the buddies out with "start", send them home with "stop", pick this session\'s sprite with "avatar <name>", or make a new one from pictures with "create <name> <image...>".',
      argumentHint: '[start | stop | avatar [name] | create <name> <image...>]',
    })
    await $.agent.register({
      name: MAKER,
      description: 'Turns reference images into a desk buddy sprite sheet. Started only by /desk-buddy create.',
      prompt: String(await $.fs.read(`${$.plugin.root}/${MAKER_DIR}/avatar-maker.md`)),
      tools: ['Read', 'Write', 'Edit', 'Bash'],
      omitClaudeMd: true,
    })
    idleSince = undefined
    await report($, 'idle')
    stopHeartbeat?.()
    const beat = $.clock.every(HEARTBEAT_MS, () => { void report($, mood, tool) })
    stopHeartbeat = () => beat.cancel()
    // Only here and in /desk-buddy start: a failed report must never reopen a quit app.
    // An install or a failure is worth a line; opening as usual is not.
    void openApp($).then(
      ({ note }) => { if (note !== undefined) $.ui.log(`desk-buddy: ${note}`) },
      error => $.ui.log(`desk-buddy: ${String(error)}`, { to: 'debug' }),
    )
    return started
  })

  // Only /desk-buddy create starts one, so it isn't offered to the model.
  on('agent.offer', { agent: MAKER_TYPE }, () => ({ isOffered: false }))

  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) {
      idleSince = undefined
      await report($, 'thinking')
    }
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    // A background agent outliving the turn would keep the session's buddy out for good.
    if (e.agentId !== undefined && idleSince !== undefined) return next(e)
    toolsInFlight += 1
    await report($, moodOf(e.tool), e.tool)
    try {
      return await next(e)
    } finally {
      toolsInFlight -= 1
      if (toolsInFlight === 0 && mood !== 'idle' && mood !== 'done') await report($, 'thinking')
    }
  })

  // A permission prompt: the buddy waves until the person answers it.
  on('classic.PermissionRequest', async ($, e, next) => {
    if (e.agent_type === MAKER_TYPE) {
      const found = await locate($)
      if (found === undefined) return { decision: { behavior: 'deny' as const, message: APP_CLOSED } }
      const makerCommands = (await osBridge($)).makerCommands()
      return { decision: makerDecision(e.tool_name, (e.tool_input ?? {}) as Record<string, unknown>, found, makerCommands) }
    }
    await report($, 'waiting', tool)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      toolsInFlight = 0
      idleSince = await $.clock.now()
      await report($, e.reason === 'answer' ? 'done' : e.reason === 'aborted' ? 'idle' : 'error')
    } else {
      await makerEnded($, e.agentId)
    }
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    await report($, 'ended', undefined, e.sessionId)
    await Promise.race([lastSent, $.clock.sleep(END_WAIT_MS)])
    // A /clear goes on under a new id, so the heartbeat files a new buddy.
    if (e.reason !== 'clear') stopHeartbeat?.()
    return next(e)
  })

  on('command.run', { command: 'desk-buddy' }, async ($, e) => {
    const [verb = '', ...rest] = words(e.args)
    if (verb === 'avatar') return { text: await pickAvatar($, rest[0] ?? '') }
    if (verb === 'create') return { text: await createAvatar($, rest) }
    if (verb === 'stop') {
      await quitApp($)
      return { text: 'Desk buddies sent home. Run /desk-buddy start to bring them back.' }
    }
    if (verb === 'start') {
      const opened = await openApp($).catch((error: unknown): Opened => ({ ok: false, note: `Could not open DeskBuddy: ${String(error).slice(0, 300)}` }))
      return { text: [opened.note, opened.ok ? 'Desk buddies are out.' : undefined].filter(Boolean).join(' ') }
    }
    if (verb === '' || verb === 'help') return { text: HELP }
    return { text: `Unknown option "${verb}".\n\n${HELP}` }
  })
}
