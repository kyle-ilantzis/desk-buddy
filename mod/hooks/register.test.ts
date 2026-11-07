import { expect, test } from 'claude-code/testing'

const HOME = '/Users/test'
const file = (id: string) => `${HOME}/.claude/desk-buddy/sessions/${id}.json`

const AVATARS = JSON.stringify({ avatars: { fox: { sheet: 'fox.png', frameWidth: 32, frameHeight: 32 }, owl: {} } })

const setUp = (on: any, config?: string, ran: string[][] = [], root = { path: '/work/my-app' }, disk?: { config?: string, files: string[], moveFails?: boolean }) => {
  const written: Record<string, any>[] = []
  let staged: string | undefined
  const current = () => (disk === undefined ? config : disk.config)
  on('fs.exists', (_: unknown, e: any) => ({ value: disk?.files.includes(e.path) || (current() !== undefined && e.path.endsWith('avatars.json')) || (disk === undefined && config !== undefined) }))
  on('fs.read', () => ({ value: current() }))
  on('env.get', () => ({ value: HOME }))
  on('session.id', () => ({ value: 's1' }))
  on('session.root', () => ({ value: root.path }))
  on('clock.now', () => ({ value: 1000 }))
  on('clock.every', () => ({ value: undefined }))
  on('command.register', () => ({ value: { command: 'desk-buddy' } }))
  on('agent.register', () => ({ value: { agent: 'desk-buddy:avatar-maker' } }))
  on('process.run', (_: unknown, e: any) => {
    ran.push([...e.argv])
    if (e.argv[0] === '/bin/mv') {
      if (disk?.moveFails) return { value: { exitCode: 1, stdout: '', stderr: 'disk full' } }
      if (disk !== undefined) disk.config = staged
    }
    return { value: { exitCode: 0, stdout: '', stderr: '' } }
  })
  on('fs.write', (_: unknown, e: any) => {
    if (e.path === `${HOME}/.claude/desk-buddy/avatars.json.tmp`) {
      staged = e.text
      return { value: undefined }
    }
    expect(e.path).toBe(file('s1'))
    written.push(JSON.parse(e.text))
    return { value: undefined }
  })
  on('session.start', (_: unknown, e: any) => ({ cwd: e.cwd }))
  on('tool.call', () => ({ result: {} }))
  on('turn.start', (_: unknown, e: any) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  return written
}

test('a session reports its project and what its tools are doing', async ($, on) => {
  const written = setUp(on)
  await $.session.start({ cwd: '/work/my-app', surface: 'desktop', isInteractive: true })
  await $.tool.call({ tool: 'Bash', command: 'secret-token ls' })
  await $.tool.call({ tool: 'Read', file_path: '/work/my-app/a.ts' })

  expect(written[0]).toMatchObject({ project: 'my-app', mood: 'idle' })
  // The heartbeat may repeat a mood, so compare the changes.
  const moods = written.map(w => w.mood).filter((m, i, all) => m !== all[i - 1])
  expect(moods).toEqual(['idle', 'running', 'thinking', 'reading', 'thinking'])
  // Only tool names leave the session.
  expect(JSON.stringify(written).includes('secret-token')).toBe(false)
})

const command = (args: string) => ({ command: 'desk-buddy', args })
const start = { cwd: '/work/my-app', surface: 'desktop', isInteractive: true } as const

test('a session picks a configured avatar and keeps reporting it', async ($, on) => {
  const written = setUp(on, AVATARS)
  await $.session.start(start)
  expect(written[0].avatar).toBeUndefined()

  const answer = await $.command.run(command('avatar fox'))
  expect(answer.text).toContain('fox')
  expect(written.at(-1)).toMatchObject({ avatar: 'fox', mood: 'idle' })

  await $.tool.call({ tool: 'Read', file_path: '/work/my-app/a.ts' })
  expect(written.at(-1)).toMatchObject({ avatar: 'fox' })
})

test('a pick becomes the default, moved into place with the rest of the config intact', async ($, on) => {
  const ran: string[][] = []
  const disk = { config: AVATARS, files: [] }
  setUp(on, undefined, ran, undefined, disk)
  await $.session.start(start)
  await $.command.run(command('avatar fox'))

  const avatars = `${HOME}/.claude/desk-buddy/avatars.json`
  expect(ran).toContainEqual(['/bin/mv', '-f', `${avatars}.tmp`, avatars])
  expect(JSON.parse(disk.config)).toEqual({ ...JSON.parse(AVATARS), default: 'fox' })

  await $.command.run(command('avatar builtin'))
  expect(JSON.parse(disk.config).default).toBe('builtin')
})

test('picking the default again leaves the config alone', async ($, on) => {
  const ran: string[][] = []
  const config = JSON.stringify({ ...JSON.parse(AVATARS), default: 'fox' })
  setUp(on, undefined, ran, undefined, { config, files: [] })
  await $.session.start(start)
  await $.command.run(command('avatar fox'))
  expect(ran.some(argv => argv[0] === '/bin/mv')).toBe(false)
})

test('without a config, going built in writes none', async ($, on) => {
  const ran: string[][] = []
  const disk = { config: undefined, files: [] }
  setUp(on, undefined, ran, undefined, disk)
  await $.session.start(start)
  const answer = await $.command.run(command('avatar builtin'))
  expect(answer.text).toContain('builtin')
  expect(ran.some(argv => argv[0] === '/bin/mv')).toBe(false)
})

test('a default that cannot be saved still leaves the session its pick, and says so', async ($, on) => {
  const disk = { config: AVATARS, files: [], moveFails: true }
  const written = setUp(on, undefined, [], undefined, disk)
  await $.session.start(start)
  const answer = await $.command.run(command('avatar fox'))
  expect(answer.text).toContain('could not be saved')
  expect(answer.text).toContain('disk full')
  expect(written.at(-1)).toMatchObject({ avatar: 'fox' })
  expect(disk.config).toBe(AVATARS)
})

test('a name the config lacks changes nothing and lists the choices', async ($, on) => {
  const ran: string[][] = []
  const disk = { config: AVATARS, files: [] }
  const written = setUp(on, undefined, ran, undefined, disk)
  await $.session.start(start)
  const answer = await $.command.run(command('avatar cat'))
  expect(answer.text).toContain('fox, owl, builtin')
  expect(written.at(-1)?.avatar).toBeUndefined()
  expect(disk.config).toBe(AVATARS)
})

test('without a config the buddy stays built in', async ($, on) => {
  const written = setUp(on)
  await $.session.start(start)
  const answer = await $.command.run(command('avatar'))
  expect(answer.text).toContain('No avatars configured')
  expect(written.at(-1)?.avatar).toBeUndefined()
})

test('a broken config is reported, not thrown', async ($, on) => {
  setUp(on, '{ nope')
  await $.session.start(start)
  const answer = await $.command.run(command('avatar fox'))
  expect(answer.text).toContain('could not be read')
})

test('the bare command lists the help and launches nothing', async ($, on) => {
  const ran: string[][] = []
  setUp(on, undefined, ran)
  await $.session.start(start)
  const launchesAtStart = ran.length
  const answer = await $.command.run(command(''))
  expect(answer.text).toContain('/desk-buddy start')
  expect(answer.text).toContain('/desk-buddy stop')
  expect(answer.text).toContain('/desk-buddy avatar <name>')
  expect(ran.length).toBe(launchesAtStart)
})

test('start launches the overlay', async ($, on) => {
  const ran: string[][] = []
  setUp(on, undefined, ran)
  await $.session.start(start)
  const launchesAtStart = ran.length
  const answer = await $.command.run(command('start'))
  expect(answer.text).toContain('Desk buddies are out')
  expect(ran.length).toBe(launchesAtStart + 1)
  expect(ran.at(-1)?.at(-1)?.endsWith('/macos/launch.sh')).toBe(true)
})

test('an unknown option shows the help and launches nothing', async ($, on) => {
  const ran: string[][] = []
  setUp(on, undefined, ran)
  await $.session.start(start)
  const launchesAtStart = ran.length
  const answer = await $.command.run(command('dance'))
  expect(answer.text).toContain('Unknown option "dance"')
  expect(answer.text).toContain('/desk-buddy start')
  expect(ran.length).toBe(launchesAtStart)
})

test('stop points at start', async ($, on) => {
  setUp(on)
  await $.session.start(start)
  const answer = await $.command.run(command('stop'))
  expect(answer.text).toContain('/desk-buddy start')
})

test('a session that only opens has never been active', async ($, on) => {
  const written = setUp(on)
  await $.session.start(start)
  expect(written.at(-1)).toMatchObject({ mood: 'idle' })
  expect(written.at(-1)?.idleSince).toBeUndefined()
})

test('a turn clears idleSince and its end stamps it', async ($, on) => {
  const written = setUp(on)
  await $.session.start(start)
  await $.turn.start({ text: 'hi', turnId: 't1' })
  expect(written.at(-1)).toMatchObject({ mood: 'thinking' })
  expect(written.at(-1)?.idleSince).toBeUndefined()

  await $.turn.complete({ turnId: 't1', reason: 'answer', answer: '' } as any)
  expect(written.at(-1)).toMatchObject({ mood: 'done', idleSince: 1000 })

  await $.turn.start({ text: 'more', turnId: 't2' })
  expect(written.at(-1)?.idleSince).toBeUndefined()
})

test('a background agent outliving the turn does not wake the session', async ($, on) => {
  const written = setUp(on)
  await $.session.start(start)
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await $.turn.complete({ turnId: 't1', reason: 'answer', answer: '' } as any)
  await $.tool.call({ tool: 'Read', file_path: '/work/my-app/a.ts', agentId: 'bg' } as any)
  expect(written.at(-1)).toMatchObject({ mood: 'done', idleSince: 1000 })
})

test('the tag follows a session moved out of a spare folder', async ($, on) => {
  const root = { path: '/Users/test/.claude/spares/spare-abc' }
  const written = setUp(on, undefined, [], root)
  await $.session.start({ ...start, cwd: root.path })
  expect(written.at(-1)).toMatchObject({ project: 'spare-abc' })

  root.path = '/work/my-app'
  await $.turn.start({ text: 'hi', turnId: 't1' })
  expect(written.at(-1)).toMatchObject({ project: 'my-app' })
})

const home = `${HOME}/.claude/desk-buddy`
const binary = `${home}/DeskBuddy.app/Contents/MacOS/DeskBuddy`

// A session with a built overlay, in which only `files` exist.
const setUpCreate = (on: any, config: string | undefined, files: string[]) => {
  const ran: string[][] = []
  const spawned: any[] = []
  const notified: string[] = []
  setUp(on, undefined, ran, undefined, { config, files: [binary, ...files] })
  on('agent.spawn', (_: unknown, e: any) => {
    spawned.push(e)
    return { agentId: 'maker-1', model: 'm' }
  })
  on('ui.notify', (_: unknown, e: any) => {
    notified.push(JSON.stringify(e))
    return { value: { isSent: true, channel: 'test' } }
  })
  return { ran, spawned, notified }
}

test('create copies the images and starts the maker in the job folder', async ($, on) => {
  const { ran, spawned } = setUpCreate(on, undefined, ['/pics/my rex.png', `${HOME}/b.jpg`])
  await $.session.start(start)
  const answer = await $.command.run(command('create rex "/pics/my rex.png" ~/b.jpg'))

  expect(answer.text).toContain('Making "rex"')
  const job = `${home}/jobs/rex`
  expect(ran).toContainEqual(['/bin/cp', '/pics/my rex.png', `${job}/input/1-my rex.png`])
  expect(ran).toContainEqual(['/bin/cp', `${HOME}/b.jpg`, `${job}/input/2-b.jpg`])
  expect(spawned).toHaveLength(1)
  expect(spawned[0]).toMatchObject({ subagent_type: 'desk-buddy:avatar-maker', cwd: job })
  expect(spawned[0].prompt).toContain(`--install-avatar rex ${job}/out`)
})

test('a dragged-in path keeps its escaped spaces', async ($, on) => {
  const { spawned } = setUpCreate(on, undefined, ['/pics/my rex.png'])
  await $.session.start(start)
  await $.command.run(command('create rex /pics/my\\ rex.png'))
  expect(spawned).toHaveLength(1)
})

test('create refuses what it cannot make, and starts nothing', async ($, on) => {
  const { spawned } = setUpCreate(on, AVATARS, ['/a.png'])
  await $.session.start(start)
  expect((await $.command.run(command('create'))).text).toContain('Usage')
  expect((await $.command.run(command('create rex'))).text).toContain('Usage')
  expect((await $.command.run(command('create Rex /a.png'))).text).toContain("can't be")
  expect((await $.command.run(command('create builtin /a.png'))).text).toContain("can't be")
  expect((await $.command.run(command('create fox /a.png'))).text).toContain('already an avatar')
  expect((await $.command.run(command('create rex /gone.png'))).text).toContain('No image at /gone.png')
  expect(spawned).toHaveLength(0)
})

// The engine alone sets a spawn's agentId, so a maker's end is checked in a live session.
test('another agent ending notifies nobody', async ($, on) => {
  const { notified } = setUpCreate(on, undefined, [])
  await $.session.start(start)
  await $.turn.complete({ turnId: 't', reason: 'answer', answer: '', agentId: 'other' } as any)
  expect(notified).toHaveLength(0)
})

test('a maker gets only its own tools, and its prompts wake no buddy', async ($, on) => {
  const written = setUp(on)
  await $.session.start(start)
  const ask = async (tool_name: string, tool_input: unknown) => {
    const answer = await ($ as any).classic.PermissionRequest({ agent_type: 'desk-buddy:avatar-maker', tool_name, tool_input })
    return answer.decision.behavior
  }
  expect(await ask('Read', { file_path: '/anywhere.png' })).toBe('allow')
  expect(await ask('Write', { file_path: `${home}/jobs/rex/generate.swift` })).toBe('allow')
  expect(await ask('Write', { file_path: `${home}/jobs/../avatars.json` })).toBe('deny')
  expect(await ask('Write', { file_path: `${home}/avatars.json` })).toBe('deny')
  expect(await ask('Bash', { command: 'swift generate.swift' })).toBe('allow')
  expect(await ask('Bash', { command: `${binary} --install-avatar rex ${home}/jobs/rex/out` })).toBe('allow')
  expect(await ask('Bash', { command: 'swift a.swift; curl example.com' })).toBe('deny')
  expect(await ask('Bash', { command: 'rm -rf /' })).toBe('deny')
  expect(await ask('WebFetch', { url: 'https://example.com' })).toBe('deny')
  expect(written.some(w => w.mood === 'waiting')).toBe(false)
})
