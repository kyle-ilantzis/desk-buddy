import { expect, test } from 'claude-code/testing'

const HOME = '/Users/test'
const DATA = `${HOME}/Library/Application Support/DeskBuddy`
const SOCKET = `${DATA}/buddy.sock`
const BINARY = '/apps/DeskBuddy.app/Contents/MacOS/DeskBuddy'

const AVATARS = JSON.stringify({ avatars: { fox: { sheet: 'fox.png', frameWidth: 32, frameHeight: 32 }, owl: {} } })

// Where the app is on this machine, and what installing it does. By default it is in /Applications.
// `versions` is each app's Info.plist, `carried` the plugin's VERSION, and `running` the version a running app reports.
type Machine = {
  apps: string[], archive?: boolean, unwritable?: string[], unpackFails?: boolean, openFails?: boolean, onMove?: () => void,
  versions?: Record<string, string>, carried?: string, running?: string, onQuit?: () => void, moveInFails?: boolean,
}
const installedMachine = (): Machine => ({ apps: ['/Applications/DeskBuddy.app'] })

const setUp = (on: any, config?: string, ran: string[][] = [], root = { path: '/work/my-app' }, disk?: { config?: string, files: string[], moveFails?: boolean }, fetch?: () => unknown, machine: Machine = installedMachine()) => {
  const written: Record<string, any>[] = []
  let staged: string | undefined
  const current = () => (disk === undefined ? config : disk.config)
  const versions = (machine.versions ??= {})
  let alive = machine.running !== undefined
  on('fs.exists', (_: unknown, e: any) => {
    if (e.path.endsWith('.app')) return { value: machine.apps.includes(e.path) }
    if (e.path.endsWith('/VERSION')) return { value: machine.carried !== undefined }
    if (e.path.endsWith('.zip')) return { value: machine.archive ?? true }
    return { value: disk?.files.includes(e.path) || (current() !== undefined && e.path.endsWith('avatars.json')) || (disk === undefined && config !== undefined) }
  })
  on('fs.read', (_: unknown, e: any) => ({ value: e.path.endsWith('/VERSION') ? `${machine.carried}\n` : current() }))
  on('env.get', () => ({ value: HOME }))
  on('session.id', () => ({ value: 's1' }))
  on('session.root', () => ({ value: root.path }))
  on('clock.now', () => ({ value: 1000 }))
  on('clock.every', () => ({ value: undefined }))
  on('command.register', () => ({ value: { command: 'desk-buddy' } }))
  on('agent.register', () => ({ value: { agent: 'desk-buddy:avatar-maker' } }))
  on('process.run', (_: unknown, e: any) => {
    ran.push([...e.argv])
    const fail = (stderr: string) => ({ value: { exitCode: 1, stdout: '', stderr } })
    if (e.argv[0] === '/bin/mkdir' && machine.unwritable?.some(folder => e.argv.at(-1).startsWith(`${folder}/`))) return fail('Permission denied')
    const ok = (stdout = '') => ({ value: { exitCode: 0, stdout, stderr: '' } })
    if (e.argv[0] === '/usr/bin/ditto') {
      if (machine.unpackFails) return fail('ditto: Couldn\'t read PKZip signature')
      const app = `${e.argv[4]}/DeskBuddy.app`
      machine.apps.push(app)
      if (machine.carried !== undefined) versions[app] = machine.carried
      return ok()
    }
    if (e.argv[0] === '/usr/bin/open' && machine.openFails) return fail('LSOpenURLsWithRole() failed')
    if (e.argv[0] === '/usr/bin/defaults') {
      const app = e.argv[2].slice(0, -'/Contents/Info'.length)
      return machine.apps.includes(app) && versions[app] !== undefined ? ok(`${versions[app]}\n`) : fail('does not exist')
    }
    if (e.argv[0] === '/usr/bin/pgrep') return alive ? ok('123\n') : fail('')
    if (e.argv[0] === '/usr/bin/pkill') alive = false
    if (e.argv[0] === '/bin/rm') machine.apps = machine.apps.filter(app => !app.startsWith(`${e.argv[2]}/`))
    // BSD mv -n into a folder: renames under the same name, and quietly skips a name that is taken.
    if (e.argv[0] === '/bin/mv' && e.argv[1] === '-n') {
      machine.onMove?.()
      const from = e.argv[2]
      const app = `${e.argv[3].slice(0, -1)}/DeskBuddy.app`
      if (machine.moveInFails && !app.includes('/.DeskBuddy.app-') && from.split('/').at(-2)!.startsWith('.DeskBuddy.app-')) return fail('Operation not permitted')
      if (!machine.apps.includes(app)) {
        machine.apps = machine.apps.filter(path => path !== from)
        machine.apps.push(app)
        if (versions[from] !== undefined) versions[app] = versions[from]!
      }
      return ok()
    }
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
      // The update tests say whether the app runs; the others take it as running, as before.
      if (machine.carried !== undefined && !alive) throw new Error('ECONNREFUSED')
      const version = alive ? machine.running : undefined
      return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ dataFolder: DATA, binary: BINARY, resources: '/apps/DeskBuddy.app/Contents/Resources', bundled: ['kyle', 'melody'], version, future: 1 }) } }
    }
    if (e.url === 'http://desk-buddy/quit') {
      ran.push(['POST /quit'])
      alive = false
      machine.onQuit?.()
    }
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

// session.start opens the app without waiting on it.
const settle = () => new Promise(resolve => setTimeout(resolve, 20))
const command = (args: string) => ({ command: 'desk-buddy', args })
const start = { cwd: '/work/my-app', surface: 'desktop', isInteractive: true } as const

test('a pick sets the default, and reports carry no avatar', async ($, on) => {
  const written = setUp(on, AVATARS)
  await $.session.start(start)
  const answer = await $.command.run(command('avatar fox'))
  expect(answer.text).toContain('The default buddy is now fox')
  await $.tool.call({ tool: 'Read', file_path: '/work/my-app/a.ts' })
  expect(written.every(body => body.avatar === undefined)).toBe(true)
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

  await $.command.run(command('avatar melody'))
  expect(JSON.parse(disk.config).default).toBe('melody')
})

test('the list says which buddy is the default, and builtin is kyle', async ($, on) => {
  setUp(on, JSON.stringify({ ...JSON.parse(AVATARS), default: 'builtin' }))
  await $.session.start(start)
  expect((await $.command.run(command('avatar'))).text).toContain('Default: kyle.')
})

test('builtin is retired: picking it wears kyle', async ($, on) => {
  const disk = { config: AVATARS, files: [] }
  setUp(on, undefined, [], undefined, disk)
  await $.session.start(start)
  const answer = await $.command.run(command('avatar builtin'))
  expect(answer.text).toContain('now kyle')
  expect(JSON.parse(disk.config).default).toBe('kyle')
})

test('picking the default again leaves the config alone', async ($, on) => {
  const ran: string[][] = []
  const config = JSON.stringify({ ...JSON.parse(AVATARS), default: 'fox' })
  setUp(on, undefined, ran, undefined, { config, files: [] })
  await $.session.start(start)
  await $.command.run(command('avatar fox'))
  expect(ran.some(argv => argv[0] === '/bin/mv')).toBe(false)
})

test('without a config, a pick of a bundled avatar makes one the app can read', async ($, on) => {
  const ran: string[][] = []
  const disk = { config: undefined as string | undefined, files: [] }
  setUp(on, undefined, ran, undefined, disk)
  await $.session.start(start)
  const answer = await $.command.run(command('avatar melody'))
  expect(answer.text).toContain('The default buddy is now melody')
  expect(JSON.parse(disk.config!)).toEqual({ avatars: {}, default: 'melody' })
})

test('a default that cannot be saved says so', async ($, on) => {
  const disk = { config: AVATARS, files: [], moveFails: true }
  setUp(on, undefined, [], undefined, disk)
  await $.session.start(start)
  const answer = await $.command.run(command('avatar fox'))
  expect(answer.text).toContain('could not be saved')
  expect(answer.text).toContain('disk full')
  expect(disk.config).toBe(AVATARS)
})

test('a name the config lacks changes nothing and lists the choices', async ($, on) => {
  const ran: string[][] = []
  const disk = { config: AVATARS, files: [] }
  const written = setUp(on, undefined, ran, undefined, disk)
  await $.session.start(start)
  await settle()
  const reported = written.length
  const answer = await $.command.run(command('avatar cat'))
  expect(answer.text).toContain('fox, owl, kyle, melody')
  expect(written.length).toBe(reported)
  expect(disk.config).toBe(AVATARS)
})

test('without a config the bundled avatars are still listed', async ($, on) => {
  setUp(on)
  await $.session.start(start)
  const answer = await $.command.run(command('avatar'))
  expect(answer.text).toContain('Default: kyle. Available: kyle, melody.')
})

test('an installed avatar named like a bundled one is listed once', async ($, on) => {
  setUp(on, JSON.stringify({ avatars: { melody: {} } }))
  await $.session.start(start)
  expect((await $.command.run(command('avatar'))).text).toContain('Available: melody, kyle.')
})

test('the list shows a display name beside its id, and a pick takes the id', async ($, on) => {
  setUp(on, JSON.stringify({ avatars: { 'mr-rex': { name: 'Mr Rex' }, owl: { name: 'owl' } } }))
  await $.session.start(start)
  expect((await $.command.run(command('avatar'))).text).toContain('Available: Mr Rex (mr-rex), owl, kyle, melody.')
  expect((await $.command.run(command('avatar mr-rex'))).text).toContain('now mr-rex')
})

test('an app from before the list still offers kyle', async ($, on) => {
  const status = { status: 200, ok: true, headers: {}, text: JSON.stringify({ dataFolder: DATA, binary: BINARY, resources: '/r' }) }
  setUp(on, undefined, [], undefined, undefined, () => ({ value: status }))
  await $.session.start(start)
  expect((await $.command.run(command('avatar'))).text).toContain('Available: kyle.')
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
  await settle()
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
  expect(spawned[0].prompt).toContain(`${BINARY} --install-avatar rex "${job}/out" "rex"`)
  expect(spawned[0].prompt).toMatch(/Spec: \S*\/tool-avatar-maker\/AVATAR-SHEETS\.md/)
  expect(spawned[0].prompt).toMatch(/Example sheet: \S*\/tool-avatar-maker\/assets\/kyle\.png/)
  expect(spawned[0].prompt).toContain(`${BINARY} --check-avatar "${job}/out" "${job}/preview.png"`)
})

test('a display name gets an id for its files, and travels to the install', async ($, on) => {
  const { ran, spawned } = setUpCreate(on, undefined, ['/a.png'])
  await $.session.start(start)
  const answer = await $.command.run(command(`create "Mr Rex" /a.png`))

  expect(answer.text).toContain('Making "Mr Rex"')
  const job = `${home}/jobs/mr-rex`
  expect(ran).toContainEqual(['/bin/cp', '/a.png', `${job}/input/1-a.png`])
  expect(spawned[0].prompt).toContain('Avatar name: Mr Rex')
  expect(spawned[0].prompt).toContain(`${BINARY} --install-avatar mr-rex "${job}/out" "Mr Rex"`)
})

test('a display name turns into a plain id', async ($, on) => {
  const { spawned } = setUpCreate(on, undefined, ['/a.png'])
  await $.session.start(start)
  await $.command.run(command(`create "Zoë's  Cat" /a.png`))
  expect(spawned[0].prompt).toContain(`--install-avatar zoe-s-cat "${home}/jobs/zoe-s-cat/out" "Zoë's  Cat"`)
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
  expect((await $.command.run(command('create "Mr;Rex" /a.png'))).text).toContain("can't be")
  expect((await $.command.run(command('create \\"Rex\\" /a.png'))).text).toContain("can't be")
  expect((await $.command.run(command(`create ${'x'.repeat(33)} /a.png`))).text).toContain("can't be")
  expect((await $.command.run(command('create builtin /a.png'))).text).toContain("can't be")
  expect((await $.command.run(command('create kyle /a.png'))).text).toContain("can't be")
  expect((await $.command.run(command('create Melody /a.png'))).text).toContain("can't be")
  expect((await $.command.run(command('create fox /a.png'))).text).toContain('already an avatar')
  expect((await $.command.run(command('create Fox /a.png'))).text).toContain('already an avatar')
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

const ROOT_APP = '/Applications/DeskBuddy.app'
const HOME_APP = `${HOME}/Applications/DeskBuddy.app`
const installSteps = (ran: string[][]) => ran.filter(argv => ['/bin/mkdir', '/usr/bin/ditto', '/bin/mv', '/bin/rm', '/usr/bin/open'].includes(argv[0]!))

test('start installs a missing app into /Applications, then opens it by path', async ($, on) => {
  const ran: string[][] = []
  const machine: Machine = { apps: [] }
  setUp(on, undefined, ran, undefined, undefined, undefined, machine)
  const answer = await $.command.run(command('start'))
  expect(answer.text).toBe('Installed DeskBuddy in /Applications. Desk buddies are out.')

  const steps = installSteps(ran)
  const staging = steps[0]!.at(-1)!
  expect(staging.startsWith('/Applications/.DeskBuddy.app-')).toBe(true)
  expect(steps).toEqual([
    ['/bin/mkdir', '-p', staging],
    ['/usr/bin/ditto', '-x', '-k', steps[1]![3], staging],
    ['/bin/mv', '-n', `${staging}/DeskBuddy.app`, '/Applications/'],
    ['/bin/rm', '-rf', staging],
    ['/usr/bin/open', '-g', ROOT_APP],
  ])
  expect(steps[1]![3]!.endsWith('/app/DeskBuddy-macos.zip')).toBe(true)
  expect(machine.apps).toEqual([ROOT_APP])
})

test('an app already installed is opened by id and not installed again', async ($, on) => {
  const ran: string[][] = []
  setUp(on, undefined, ran, undefined, undefined, undefined, { apps: [HOME_APP] })
  const answer = await $.command.run(command('start'))
  expect(answer.text).toBe('Desk buddies are out.')
  expect(installSteps(ran)).toEqual([['/usr/bin/open', '-g', '-b', 'kyleilantzis.desk-buddy.overlay']])
})

test('a standard account gets the app in ~/Applications', async ($, on) => {
  const ran: string[][] = []
  const machine: Machine = { apps: [], unwritable: ['/Applications'] }
  setUp(on, undefined, ran, undefined, undefined, undefined, machine)
  const answer = await $.command.run(command('start'))
  expect(answer.text).toBe(`Installed DeskBuddy in ${HOME}/Applications. Desk buddies are out.`)
  expect(machine.apps).toEqual([HOME_APP])
  expect(ran.at(-1)).toEqual(['/usr/bin/open', '-g', HOME_APP])
  // Nothing is left behind in either folder.
  const made = ran.filter(argv => argv[0] === '/bin/mkdir').map(argv => argv.at(-1))
  const removed = ran.filter(argv => argv[0] === '/bin/rm').map(argv => argv.at(-1))
  expect(removed).toEqual([made[1]])
})

test('a session that loses the race opens the app the other one installed', async ($, on) => {
  const ran: string[][] = []
  const machine: Machine = { apps: [], onMove: () => { if (!machine.apps.includes(ROOT_APP)) machine.apps.push(ROOT_APP) } }
  setUp(on, undefined, ran, undefined, undefined, undefined, machine)
  const answer = await $.command.run(command('start'))
  expect(answer.text).toContain('Desk buddies are out')
  expect(machine.apps).toEqual([ROOT_APP])
})

test('a mod without an archive says so and opens nothing', async ($, on) => {
  const ran: string[][] = []
  setUp(on, undefined, ran, undefined, undefined, undefined, { apps: [], archive: false })
  const answer = await $.command.run(command('start'))
  expect(answer.text).toBe('Could not install DeskBuddy: this copy of the mod carries no app for macos.')
  expect(installSteps(ran)).toEqual([])
})

test('a broken archive says why, cleans up and opens nothing', async ($, on) => {
  const ran: string[][] = []
  setUp(on, undefined, ran, undefined, undefined, undefined, { apps: [], unpackFails: true })
  const answer = await $.command.run(command('start'))
  expect(answer.text).toContain('Could not install DeskBuddy: its archive could not be unpacked: ditto:')
  const steps = installSteps(ran)
  expect(steps.at(-1)![0]).toBe('/bin/rm')
  expect(steps.some(argv => argv[0] === '/usr/bin/open')).toBe(false)
})

test('with no folder to write to, start says so', async ($, on) => {
  setUp(on, undefined, [], undefined, undefined, undefined, { apps: [], unwritable: ['/Applications', `${HOME}/Applications`] })
  const answer = await $.command.run(command('start'))
  expect(answer.text).toBe(`Could not install DeskBuddy: ${HOME}/Applications can't be written to.`)
})

test('an app that will not open says why', async ($, on) => {
  setUp(on, undefined, [], undefined, undefined, undefined, { apps: [ROOT_APP], openFails: true })
  const answer = await $.command.run(command('start'))
  expect(answer.text).toBe('Could not open DeskBuddy: LSOpenURLsWithRole() failed')
})

test('a session start installs a missing app and notes it in the transcript', async ($, on) => {
  const ran: string[][] = []
  const logged: string[] = []
  const machine: Machine = { apps: [] }
  setUp(on, undefined, ran, undefined, undefined, undefined, machine)
  on('ui.log', (_: unknown, e: any) => {
    if (e.to !== 'debug') logged.push(e.text)
    return { value: undefined }
  })
  await $.session.start(start)
  await settle()
  expect(machine.apps).toEqual([ROOT_APP])
  expect(logged).toEqual(['desk-buddy: Installed DeskBuddy in /Applications.'])
})

test('a session start with the app in place adds nothing to the transcript', async ($, on) => {
  const logged: string[] = []
  setUp(on)
  on('ui.log', (_: unknown, e: any) => {
    if (e.to !== 'debug') logged.push(e.text)
    return { value: undefined }
  })
  await $.session.start(start)
  await settle()
  expect(logged).toEqual([])
})

const updateSteps = (ran: string[][]) => ran.filter(argv => argv[0] === 'POST /quit' || ['/bin/mkdir', '/usr/bin/ditto', '/bin/mv', '/bin/rm', '/usr/bin/open', '/usr/bin/pkill'].includes(argv[0]!))

test('a closed app older than the mod is replaced in place, then opened by path', async ($, on) => {
  const ran: string[][] = []
  const machine: Machine = { apps: [ROOT_APP], versions: { [ROOT_APP]: '0.1.0' }, carried: '0.2.0' }
  setUp(on, undefined, ran, undefined, undefined, undefined, machine)
  const answer = await $.command.run(command('start'))
  expect(answer.text).toBe('Updated DeskBuddy from 0.1.0 to 0.2.0. Desk buddies are out.')

  const steps = updateSteps(ran)
  const staging = steps[0]!.at(-1)!.slice(0, -'/old'.length)
  expect(staging.startsWith('/Applications/.DeskBuddy.app-')).toBe(true)
  expect(steps).toEqual([
    ['/bin/mkdir', '-p', `${staging}/old`],
    ['/usr/bin/ditto', '-x', '-k', steps[1]![3], staging],
    ['/bin/mv', '-n', ROOT_APP, `${staging}/old/`],
    ['/bin/mv', '-n', `${staging}/DeskBuddy.app`, '/Applications/'],
    ['/bin/rm', '-rf', staging],
    ['/usr/bin/open', '-g', ROOT_APP],
  ])
  expect(machine.apps).toEqual([ROOT_APP])
  expect(machine.versions![ROOT_APP]).toBe('0.2.0')
})

test('a running app older than the mod is quit before it is replaced, then reopened', async ($, on) => {
  const ran: string[][] = []
  const machine: Machine = { apps: [ROOT_APP], versions: { [ROOT_APP]: '0.1.0' }, carried: '0.2.0', running: '0.1.0' }
  setUp(on, undefined, ran, undefined, undefined, undefined, machine)
  const answer = await $.command.run(command('start'))
  expect(answer.text).toBe('Updated DeskBuddy from 0.1.0 to 0.2.0. Desk buddies are out.')
  const steps = updateSteps(ran)
  expect(steps[0]).toEqual(['POST /quit'])
  expect(steps.some(argv => argv[0] === '/usr/bin/pkill')).toBe(false)
  expect(steps.at(-1)).toEqual(['/usr/bin/open', '-g', ROOT_APP])
  expect(machine.versions![ROOT_APP]).toBe('0.2.0')
})

test('the running app\'s own version decides, over the copy on disk', async ($, on) => {
  const ran: string[][] = []
  // Its Info.plist was already replaced by hand, but the old one is still running.
  const machine: Machine = { apps: [ROOT_APP], versions: { [ROOT_APP]: '0.2.0' }, carried: '0.2.0', running: '0.1.0' }
  setUp(on, undefined, ran, undefined, undefined, undefined, machine)
  const answer = await $.command.run(command('start'))
  expect(answer.text).toBe('Updated DeskBuddy from 0.1.0 to 0.2.0. Desk buddies are out.')
  // Only the restart: the copy on disk is current.
  expect(updateSteps(ran)).toEqual([['POST /quit'], ['/usr/bin/open', '-g', ROOT_APP]])
})

test('versions compare by number, not by text', async ($, on) => {
  const machine: Machine = { apps: [ROOT_APP], versions: { [ROOT_APP]: '0.9.0' }, carried: '0.10.0' }
  setUp(on, undefined, [], undefined, undefined, undefined, machine)
  const answer = await $.command.run(command('start'))
  expect(answer.text).toBe('Updated DeskBuddy from 0.9.0 to 0.10.0. Desk buddies are out.')
})

for (const [installed, why] of [['0.3.0', 'a newer app, from build.sh --install'], ['0.2.0', 'the same version'], ['dev', 'an app with no version']] as const) {
  test(`${why} is left alone and opened by id`, async ($, on) => {
    const ran: string[][] = []
    const machine: Machine = { apps: [ROOT_APP], versions: { [ROOT_APP]: installed }, carried: '0.2.0', running: installed }
    setUp(on, undefined, ran, undefined, undefined, undefined, machine)
    const answer = await $.command.run(command('start'))
    expect(answer.text).toBe('Desk buddies are out.')
    expect(updateSteps(ran)).toEqual([['/usr/bin/open', '-g', '-b', 'kyleilantzis.desk-buddy.overlay']])
  })
}

for (const [machine, why] of [
  [{ apps: [ROOT_APP], versions: { [ROOT_APP]: '0.1.0' }, carried: '0.2.0', archive: false }, 'no app'],
  [{ apps: [ROOT_APP], versions: { [ROOT_APP]: '0.1.0' } }, 'no VERSION'],
] as [Machine, string][]) {
  test(`a mod with ${why} updates nothing`, async ($, on) => {
    setUp(on, undefined, [], undefined, undefined, undefined, machine)
    const answer = await $.command.run(command('start'))
    expect(answer.text).toBe('Desk buddies are out.')
    expect(machine.versions![ROOT_APP]).toBe('0.1.0')
  })
}

test('a session that updated first leaves this one only the reopening', async ($, on) => {
  const ran: string[][] = []
  const machine: Machine = { apps: [ROOT_APP], versions: { [ROOT_APP]: '0.1.0' }, carried: '0.2.0', running: '0.1.0' }
  machine.onQuit = () => { machine.versions![ROOT_APP] = '0.2.0' }
  setUp(on, undefined, ran, undefined, undefined, undefined, machine)
  const answer = await $.command.run(command('start'))
  expect(answer.text).toBe('Updated DeskBuddy from 0.1.0 to 0.2.0. Desk buddies are out.')
  expect(ran.some(argv => argv[0] === '/usr/bin/ditto')).toBe(false)
})

test('an app in a folder that can\'t be written to stays, and still opens', async ($, on) => {
  const ran: string[][] = []
  const machine: Machine = { apps: [ROOT_APP], versions: { [ROOT_APP]: '0.1.0' }, carried: '0.2.0', unwritable: ['/Applications'] }
  setUp(on, undefined, ran, undefined, undefined, undefined, machine)
  const answer = await $.command.run(command('start'))
  expect(answer.text).toBe('Could not update DeskBuddy to 0.2.0: /Applications can\'t be written to. Desk buddies are out.')
  expect(ran.at(-1)).toEqual(['/usr/bin/open', '-g', '-b', 'kyleilantzis.desk-buddy.overlay'])
  expect(machine.versions![ROOT_APP]).toBe('0.1.0')
})

test('a new copy that can\'t be moved in puts the old one back', async ($, on) => {
  const ran: string[][] = []
  const machine: Machine = { apps: [ROOT_APP], versions: { [ROOT_APP]: '0.1.0' }, carried: '0.2.0', running: '0.1.0', moveInFails: true }
  setUp(on, undefined, ran, undefined, undefined, undefined, machine)
  const answer = await $.command.run(command('start'))
  expect(answer.text).toBe('Could not update DeskBuddy to 0.2.0: it could not be moved into /Applications: Operation not permitted. Desk buddies are out.')
  expect(machine.apps).toEqual([ROOT_APP])
  expect(machine.versions![ROOT_APP]).toBe('0.1.0')
  // It was quit for the update, so it is opened again.
  expect(ran.at(-1)).toEqual(['/usr/bin/open', '-g', ROOT_APP])
})

test('a broken archive leaves the old app as it was', async ($, on) => {
  const machine: Machine = { apps: [ROOT_APP], versions: { [ROOT_APP]: '0.1.0' }, carried: '0.2.0', unpackFails: true }
  setUp(on, undefined, [], undefined, undefined, undefined, machine)
  const answer = await $.command.run(command('start'))
  expect(answer.text).toContain('Could not update DeskBuddy to 0.2.0: its archive could not be unpacked: ditto:')
  expect(machine.apps).toEqual([ROOT_APP])
})

test('a session start notes an update in the transcript', async ($, on) => {
  const logged: string[] = []
  const machine: Machine = { apps: [HOME_APP], versions: { [HOME_APP]: '0.1.0' }, carried: '0.2.0' }
  setUp(on, undefined, [], undefined, undefined, undefined, machine)
  on('ui.log', (_: unknown, e: any) => {
    if (e.to !== 'debug') logged.push(e.text)
    return { value: undefined }
  })
  await $.session.start(start)
  await settle()
  expect(logged).toEqual(['desk-buddy: Updated DeskBuddy from 0.1.0 to 0.2.0.'])
  expect(machine.versions![HOME_APP]).toBe('0.2.0')
})
