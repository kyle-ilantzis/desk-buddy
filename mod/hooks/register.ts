import type { CoreEngineInterface as Engine, Register } from 'claude-code'

// The mod runs inside Claude Code and cannot draw outside its window, so it
// only reports. Each session keeps one small JSON file up to date, and the
// native overlay app (../macos/DeskBuddy.swift) animates an avatar for each file
// whose session is at work, or stopped less than a minute ago by `idleSince`.
// Only the project folder's name, tool names and the avatar's name are written:
// never prompts, commands or file contents.

type Mood =
  | 'starting' | 'idle' | 'thinking' | 'reading' | 'editing'
  | 'running' | 'browsing' | 'delegating' | 'waiting' | 'done' | 'error' | 'ended'

const HEARTBEAT_MS = 15_000
const BUILT_IN = 'builtin' // no config names this, so the overlay wears the sheet it was built with
const MAKER = 'avatar-maker'
const MAKER_TYPE = `desk-buddy:${MAKER}`
const CREATE_USAGE = 'Usage: `/desk-buddy create <name> <image> [image...]`. Quote a path with spaces in it.'
const HELP = [
  'Desk buddy commands:',
  '- `/desk-buddy start`: bring the desk buddies out',
  '- `/desk-buddy stop`: send them home',
  '- `/desk-buddy avatar`: list the configured avatars',
  '- `/desk-buddy avatar <name>`: pick this session\'s avatar, and the default for new sessions',
  `- \`/desk-buddy avatar ${BUILT_IN}\`: go back to the built-in avatar`,
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
const makers = new Map<string, string>() // a running avatar maker's agent id, to the avatar it is making

async function report($: Engine, next: Mood, nextTool?: string, id?: string) {
  mood = next
  tool = nextTool
  try {
    const sessionId = id ?? (await $.session.id())
    const dir = `${await $.env.get('HOME')}/.claude/desk-buddy/sessions`
    const { value: avatar } = await $.state.get(avatarPick)
    // The app can move a session after it starts, from a spare folder to the real one.
    const project = (await $.session.root()).split('/').filter(Boolean).pop() ?? 'claude'
    const body = { id: sessionId, project, mood, tool, avatar: avatar ?? undefined, idleSince, updatedAt: await $.clock.now() }
    await $.fs.write(`${dir}/${sessionId}.json`, JSON.stringify(body))
  } catch (error) {
    $.ui.log(`desk-buddy: could not write its status: ${String(error)}`, { to: 'debug' })
  }
}

function launchOverlay($: Engine) {
  return $.process.run(['/bin/sh', `${$.plugin.root}/../macos/launch.sh`], { timeoutMs: 300_000 })
}

// The avatar names in ~/.claude/desk-buddy/avatars.json; none when there is no file.
async function configuredAvatars($: Engine): Promise<string[]> {
  const path = `${await $.env.get('HOME')}/.claude/desk-buddy/avatars.json`
  if (!(await $.fs.exists(path))) return []
  const config = JSON.parse(String(await $.fs.read(path))) as { avatars?: Record<string, unknown> }
  return Object.keys(config.avatars ?? {}).sort()
}

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

const buddyHome = async ($: Engine) => `${await $.env.get('HOME')}/.claude/desk-buddy`
const overlayBinary = (home: string) => `${home}/DeskBuddy.app/Contents/MacOS/DeskBuddy`

// Nobody answers a background agent's prompts, so each is settled here. The
// paths a maker writes stay in its jobs folder, and it runs only its own tools.
function makerDecision(tool: string, input: Record<string, unknown>, home: string) {
  const path = String(input.file_path ?? '')
  const command = String(input.command ?? '')
  const inJobs = path.startsWith(`${home}/jobs/`) && !path.split('/').includes('..')
  const binary = overlayBinary(home)
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
  if (!/^[a-z0-9][a-z0-9-]*$/.test(name) || name === BUILT_IN) {
    return `"${name}" can't be an avatar's name: use lowercase letters, digits and dashes, and not "${BUILT_IN}".`
  }
  let names: string[]
  try {
    names = await configuredAvatars($)
  } catch (error) {
    return `avatars.json could not be read: ${String(error).slice(0, 200)}`
  }
  if (names.includes(name)) return `There is already an avatar named "${name}".`
  if ([...makers.values()].includes(name)) return `"${name}" is already being made.`

  const userHome = await $.env.get('HOME')
  const home = await buddyHome($)
  const paths = images.map(path => (path.startsWith('~/') ? `${userHome}${path.slice(1)}` : path))
  for (const path of paths) {
    if (!(await $.fs.exists(path))) return `No image at ${path}.`
  }
  if (!(await $.fs.exists(overlayBinary(home)))) return 'The overlay is not built yet. Run `/desk-buddy start`, then try again.'

  // Copies, so a picture moved later can't stop the job and the agent keeps to one folder.
  const job = `${home}/jobs/${name}`
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
    description: `Make the ${name} avatar`,
    cwd: job,
    prompt: [
      `Avatar name: ${name}`,
      `Job folder: ${job}`,
      `Images:\n${copies.map(copy => `- ${copy}`).join('\n')}`,
      `Spec: ${$.plugin.root}/AVATAR-SHEETS.md`,
      `Example sheet: ${$.plugin.root}/../macos/assets/buddy.png, with buddy.json beside it`,
      `Check: ${overlayBinary(home)} --check-avatar ${job}/out ${job}/preview.png`,
      `Install: ${overlayBinary(home)} --install-avatar ${name} ${job}/out`,
    ].join('\n'),
  })
  if (spawned.deny !== undefined) return `Could not start the avatar maker: ${spawned.deny.slice(0, 200)}`
  if (spawned.agentId !== undefined) makers.set(spawned.agentId, name)
  return `Making "${name}" in the background from ${copies.length === 1 ? 'one image' : `${copies.length} images`}. You'll get a notification when it's done, and closing this session stops it.`
}

// A maker ended: installed means it is in the config, whatever the agent said.
async function makerEnded($: Engine, agentId: string) {
  const name = makers.get(agentId)
  if (name === undefined) return
  makers.delete(agentId)
  const installed = await configuredAvatars($).then(names => names.includes(name), () => false)
  await $.ui.notify(
    installed ? `Run /desk-buddy avatar ${name} to wear it.` : `It didn't finish. Its work is in ~/.claude/desk-buddy/jobs/${name}/.`,
    { title: installed ? `Your avatar ${name} is ready` : `Avatar ${name} failed` },
  )
}

// The latest pick becomes the config's default, which outlasts the overlay and
// every session. The overlay reads this file at any moment, so it is moved into
// place whole. With no file every buddy is built in already.
async function rememberDefault($: Engine, name: string) {
  const path = `${await buddyHome($)}/avatars.json`
  if (!(await $.fs.exists(path))) return
  const config = JSON.parse(String(await $.fs.read(path))) as { default?: string }
  if (config.default === name) return
  config.default = name
  await $.fs.write(`${path}.tmp`, JSON.stringify(config, null, 2))
  const moved = await $.process.run(['/bin/mv', '-f', `${path}.tmp`, path])
  if (moved.exitCode !== 0) throw new Error(moved.stderr)
}

async function pickAvatar($: Engine, wanted: string): Promise<string> {
  let names: string[]
  try {
    names = await configuredAvatars($)
  } catch (error) {
    return `avatars.json could not be read: ${String(error).slice(0, 200)}`
  }
  const choices = [...names, BUILT_IN].join(', ')
  if (wanted === '') {
    const { value: current } = await $.state.get(avatarPick)
    return names.length === 0
      ? 'No avatars configured, so this buddy uses the built-in one. Make one with `/desk-buddy create <name> <image>`.'
      : `This session: ${current ?? 'the default'}. Available: ${choices}.`
  }
  if (wanted !== BUILT_IN && !names.includes(wanted)) return `No avatar named "${wanted}". Available: ${choices}.`
  await $.state.set(avatarPick, wanted)
  await report($, mood, tool)
  try {
    await rememberDefault($, wanted)
  } catch (error) {
    return `This session's buddy is now ${wanted}, but it could not be saved as the default: ${String(error).slice(0, 200)}`
  }
  return `This session's buddy is now ${wanted}, and new sessions will start with it.`
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
    // The first start compiles the overlay, so it does not hold up the session.
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
      return { decision: makerDecision(e.tool_name, (e.tool_input ?? {}) as Record<string, unknown>, await buddyHome($)) }
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
    // A /clear goes on under a new id, so the heartbeat files a new buddy.
    if (e.reason !== 'clear') stopHeartbeat?.()
    return next(e)
  })

  on('command.run', { command: 'desk-buddy' }, async ($, e) => {
    const [verb = '', ...rest] = words(e.args)
    if (verb === 'avatar') return { text: await pickAvatar($, rest[0] ?? '') }
    if (verb === 'create') return { text: await createAvatar($, rest) }
    if (verb === 'stop') {
      await $.process.run(['/usr/bin/pkill', '-x', 'DeskBuddy'])
      return { text: 'Desk buddies sent home. Run /desk-buddy start to bring them back.' }
    }
    if (verb === 'start') {
      const ran = await launchOverlay($)
      return { text: ran.exitCode === 0 ? 'Desk buddies are out.' : `Could not start them: ${ran.stderr.slice(0, 300)}` }
    }
    if (verb === '' || verb === 'help') return { text: HELP }
    return { text: `Unknown option "${verb}".\n\n${HELP}` }
  })
}
