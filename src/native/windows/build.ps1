# Builds DeskBuddy for Windows, and a zip of it, in build\windows at the repo root:
#
#   build\windows\DeskBuddy\DeskBuddy.exe      the app
#   build\windows\DeskBuddy\*.dll              the Swift runtime and Foundation, which ship with it
#   build\windows\DeskBuddy\Resources\         the bundled avatars, and VERSION
#   build\windows\DeskBuddy.zip                all of that, for scripts/dist.sh
#
# The version comes from src\mod\VERSION. It needs the Swift toolchain for Windows from
# swift.org, with the Visual Studio Build Tools and the Windows SDK. It isn't signed.
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$native = Split-Path $here
$root = (Resolve-Path (Join-Path $here '..\..\..')).Path
$out = Join-Path $root 'build\windows'
$app = Join-Path $out 'DeskBuddy'
$version = (Get-Content (Join-Path $root 'src\mod\VERSION') -Raw).Trim()

if (-not (Get-Command swift -ErrorAction SilentlyContinue)) { throw 'swift not found: install the toolchain from swift.org' }

$build = @('--package-path', $native, '--scratch-path', (Join-Path $root 'build\swiftpm'), '-c', 'release', '--product', 'DeskBuddy')
swift build @build
if ($LASTEXITCODE) { exit $LASTEXITCODE }
$bin = (swift build @build --show-bin-path).Trim()

if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory (Join-Path $app 'Resources') | Out-Null
Copy-Item (Join-Path $bin 'DeskBuddy.exe') $app

# The runtime's DLLs are on PATH once Swift is installed; they go beside the exe.
$core = (where.exe swiftCore.dll 2>$null | Select-Object -First 1)
if (-not $core) { throw 'swiftCore.dll is not on PATH: is the Swift runtime installed?' }
Copy-Item (Join-Path (Split-Path $core) '*.dll') $app

Copy-Item (Join-Path $native 'core\assets\*.png'), (Join-Path $native 'core\assets\*.json') (Join-Path $app 'Resources')
Set-Content (Join-Path $app 'Resources\VERSION') $version -NoNewline -Encoding ascii

Compress-Archive -Path $app -DestinationPath (Join-Path $out 'DeskBuddy.zip')
Write-Output "Built $out\DeskBuddy.zip ($version)"
