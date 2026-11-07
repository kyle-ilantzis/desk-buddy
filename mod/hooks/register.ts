import type { CoreEngineInterface as Engine, Register } from 'claude-code'

// The mod runs inside Claude Code and cannot draw outside its window, so it
// only reports. Each session posts a full snapshot of itself over a Unix socket,
// and the native overlay app (../macos/DeskBuddy.swift) animates an avatar for each
// session at work, or stopped less than a minute ago by `idleSince`.
// Only the project folder's name, tool names and the avatar's name are sent:
// never prompts, commands or file contents.

type Mood =
  | 'starting' | 'idle' | 'thinking' | 'reading' | 'editing'
  | 'running' | 'browsing' | 'delegating' | 'waiting' | 'done' | 'error' | 'ended'

const HEARTBEAT_MS = 15_000
const BUNDLE_ID = 'kyleilantzis.desk-buddy.overlay'
const PROTOCOL = 1
const END_WAIT_MS = 500 // a session's last report gets this long before the session closes
const QUIT_WAIT_MS = 2_000 // a hung app gets this long to answer a quit
const STATUS_WAIT_MS = 1_000
const APP_CLOSED = 'The app is not running. Run `/desk-buddy start`, then try again.'
const FALLBACK = 'kyle' // the avatar worn when nothing else is picked
const RETIRED = 'builtin' // kyle's old name: a saved pick can still say it, and the app dresses it as kyle
const MAX_NAME = 32
const MAKER = 'avatar-maker'
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
type Place = { dataFolder: string, binary: string, resources: string, bundled?: string[] }

let place: Place | undefined // the app's last answer, for when it has since closed
let seq = 0
let lastSent: Promise<unknown> = Promise.resolve()
const makers = new Map<string, string>() // a running avatar maker's agent id, to the avatar it is making

const socketPathOf = async ($: Engine) => `${await $.env.get('HOME')}/Library/Application Support/DeskBuddy/buddy.sock`

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

// Where the app keeps its data and its binary, which only it knows.
async function locate($: Engine): Promise<Place | undefined> {
  const status = $.http.fetch('http://desk-buddy/status', { socketPath: await socketPathOf($) })
    .then(reply => (reply.ok ? JSON.parse(reply.text) as Place : undefined))
  const timeout = $.clock.sleep(STATUS_WAIT_MS).then(() => undefined)
  place = (await Promise.race([status, timeout]).catch(() => undefined)) ?? place
  return place
}

// The same quit as the menu item. Only a closed or hung app gets the pkill.
async function quitApp($: Engine) {
  const quit = $.http.fetch('http://desk-buddy/quit', { method: 'POST', socketPath: await socketPathOf($) })
  const timeout = $.clock.sleep(QUIT_WAIT_MS).then(() => false)
  const quitting = await Promise.race([quit.then(reply => reply.ok), timeout]).catch(() => false)
  if (!quitting) await $.process.run(['/usr/bin/pkill', '-x', 'DeskBuddy'])
}

function launchOverlay($: Engine) {
  return $.process.run(['/usr/bin/open', '-g', '-b', BUNDLE_ID], { timeoutMs: 10_000 })
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
function makerDecision(tool: string, input: Record<string, unknown>, { dataFolder, binary }: Place) {
  const path = String(input.file_path ?? '')
  const command = String(input.command ?? '')
  const inJobs = path.startsWith(`${dataFolder}/jobs/`) && !path.split('/').includes('..')
  const plain = !/[;&|`$<>\n]/.test(command)
  const allowed =
    /^(Read|Glob|Grep|LS)$/.test(tool) ||
    (/^(Write|Edit|MultiEdit)$/.test(tool) && inJobs) ||
    (tool === 'Bash' && plain && (/^(swift|swiftc|sips) /.test(command) ||
      command.startsWith(`${binary} --check-avatar `) || command.startsWith(`${binary} --install-avatar `)))
  return allowed
    ? { behavior: 'allow' as const }
    : { behavior: 'deny' as const, message: 'An avatar maker writes only in its job folder and runs only swift, swiftc, sips and DeskBuddy, one command at a time.' }
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
  const { dataFolder, binary, resources } = found
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
  await $.process.run(['/bin/rm', '-rf', job])
  await $.process.run(['/bin/mkdir', '-p', `${job}/input`, `${job}/out`])
  const copies: string[] = []
  for (const [i, path] of paths.entries()) {
    const copy = `${job}/input/${i + 1}-${path.split('/').pop()}`
    const ran = await $.process.run(['/bin/cp', path, copy])
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
      `Spec: ${$.plugin.root}/AVATAR-SHEETS.md`,
      `Example sheet: ${resources}/${FALLBACK}.png, with ${FALLBACK}.json beside it`,
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
  const moved = await $.process.run(['/bin/mv', '-f', `${path}.tmp`, path])
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
      prompt: String(await $.fs.read(`${$.plugin.root}/avatar-maker.md`)),
      tools: ['Read', 'Write', 'Edit', 'Bash'],
      omitClaudeMd: true,
    })
    idleSince = undefined
    await report($, 'idle')
    stopHeartbeat?.()
    const beat = $.clock.every(HEARTBEAT_MS, () => { void report($, mood, tool) })
    stopHeartbeat = () => beat.cancel()
    // Only here and in /desk-buddy start: a failed report must never reopen a quit app.
    void launchOverlay($).then(
      ran => { if (ran.exitCode !== 0) $.ui.log(`desk-buddy: ${ran.stderr.slice(0, 300)}`, { to: 'debug' }) },
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
      return { decision: makerDecision(e.tool_name, (e.tool_input ?? {}) as Record<string, unknown>, found) }
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
      const ran = await launchOverlay($)
      return { text: ran.exitCode === 0 ? 'Desk buddies are out.' : `Could not open the app. Is DeskBuddy in Applications? ${ran.stderr.slice(0, 300)}` }
    }
    if (verb === '' || verb === 'help') return { text: HELP }
    return { text: `Unknown option "${verb}".\n\n${HELP}` }
  })
}
