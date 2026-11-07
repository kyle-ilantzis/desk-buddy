import { expect, test } from 'claude-code/testing'

const HOME = '/Users/test'
const DATA = `${HOME}/Library/Application Support/DeskBuddy`
const SOCKET = `${DATA}/buddy.sock`
const BINARY = '/apps/DeskBuddy.app/Contents/MacOS/DeskBuddy'

const AVATARS = JSON.stringify({ avatars: { fox: { sheet: 'fox.png', frameWidth: 32, frameHeight: 32 }, owl: {} } })

const setUp = (on: any, config?: string, ran: string[][] = [], root = { path: '/work/my-app' }, disk?: { config?: string, files: string[], moveFails?: boolean }, fetch?: () => unknown) => {
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
    if (e.path === `${DATA}/avatars.json.tmp`) {
      staged = e.text
      return { value: undefined }
    }
    return { value: undefined }
  })
  // Waits run out only where a test stands in for the app.
  on('clock.sleep', () => (fetch === undefined ? new Promise(() => {}) : { value: undefined }))
  on('http.fetch', (_: unknown, e: any) => {
    if (fetch !== undefined) return fetch()
    expect(e.init.socketPath).toBe(SOCKET)
    if (e.url === 'http://desk-buddy/status') {
      return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ dataFolder: DATA, binary: BINARY, resources: '/apps/DeskBuddy.app/Contents/Resources', future: 1 }) } }
    }
    if (e.url === 'http://desk-buddy/quit') ran.push(['POST /quit'])
    else {
      expect(e.url).toBe('http://desk-buddy/report')
      written.push(JSON.parse(e.init.body))
    }
    return { value: { status: 200, ok: true, headers: {}, text: '{"ok":true}' } }
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

test('reports are numbered in order and carry the protocol version', async ($, on) => {
  const written = setUp(on)
  await $.session.start({ cwd: '/work/my-app', surface: 'desktop', isInteractive: true })
  await $.tool.call({ tool: 'Read', file_path: '/work/my-app/a.ts' })

  expect(written.every(w => w.v === 1)).toBe(true)
  const seqs = written.map(w => w.seq)
  expect(seqs.every((seq, i) => i === 0 || seq > seqs[i - 1])).toBe(true)
  // A reload starts the module over, so the count starts from the clock, not from zero.
  expect(seqs[0]).toBeGreaterThanOrEqual(1000)
})

test('a closed app costs a session nothing', async ($, on) => {
  setUp(on, undefined, [], undefined, undefined, () => { throw new Error('ENOENT') })
  await $.session.start({ cwd: '/work/my-app', surface: 'desktop', isInteractive: true })
  const result = await $.tool.call({ tool: 'Read', file_path: '/work/my-app/a.ts' })
  expect(result).toEqual({ result: {} })
})

test('a hung app holds up no tool call', async ($, on) => {
  setUp(on, undefined, [], undefined, undefined, () => new Promise(() => {}))
  await $.session.start({ cwd: '/work/my-app', surface: 'desktop', isInteractive: true })
  const result = await $.tool.call({ tool: 'Read', file_path: '/work/my-app/a.ts' })
  expect(result).toEqual({ result: {} })
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

  const avatars = `${DATA}/avatars.json`
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
  expect(ran.at(-1)).toEqual(['/usr/bin/open', '-g', '-b', 'kyleilantzis.desk-buddy.overlay'])
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

const PKILL = ['/usr/bin/pkill', '-x', 'DeskBuddy']

test('stop quits the app over the socket, as the menu item does', async ($, on) => {
  const ran: string[][] = []
  setUp(on, undefined, ran)
  await $.command.run(command('stop'))
  expect(ran).toEqual([['POST /quit']])
})

test('stop falls back to pkill when the app is closed', async ($, on) => {
  const ran: string[][] = []
  setUp(on, undefined, ran, undefined, undefined, () => { throw new Error('ENOENT') })
  await $.command.run(command('stop'))
  expect(ran).toEqual([PKILL])
})

test('stop falls back to pkill when the app is hung', async ($, on) => {
  const ran: string[][] = []
  setUp(on, undefined, ran, undefined, undefined, () => new Promise(() => {}))
  await $.command.run(command('stop'))
  expect(ran).toEqual([PKILL])
})

test('stop falls back to pkill when the app refuses', async ($, on) => {
  const ran: string[][] = []
  setUp(on, undefined, ran, undefined, undefined, () => ({ value: { status: 503, ok: false, headers: {}, text: '' } }))
  await $.command.run(command('stop'))
  expect(ran).toEqual([PKILL])
})

test('with the app closed, avatar commands say how to start it and change nothing', async ($, on) => {
  const ran: string[][] = []
  setUp(on, AVATARS, ran, undefined, undefined, () => { throw new Error('ENOENT') })
  expect((await $.command.run(command('avatar fox'))).text).toContain('/desk-buddy start')
  expect((await $.command.run(command('create rex /a.png'))).text).toContain('/desk-buddy start')
  expect(ran).toEqual([])
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

const home = DATA
const binary = BINARY

// A session with a built overlay, in which only `files` exist.
const setUpCreate = (on: any, config: string | undefined, files: string[]) => {
  const ran: string[][] = []
  const spawned: any[] = []
  const notified: string[] = []
  setUp(on, undefined, ran, undefined, { config, files })
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
  // The data folder has a space in it, so the maker's commands quote their paths.
  expect(spawned[0].prompt).toContain(`${BINARY} --install-avatar rex "${job}/out"`)
  expect(spawned[0].prompt).toContain('Example sheet: /apps/DeskBuddy.app/Contents/Resources/buddy.png')
  expect(spawned[0].prompt).toContain(`${BINARY} --check-avatar "${job}/out" "${job}/preview.png"`)
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
