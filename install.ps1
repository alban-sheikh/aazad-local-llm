# Aazad Chat installer for Windows
#
#   irm https://raw.githubusercontent.com/alban-sheikh/aazad-local-llm/main/install.ps1 | iex
#
# Detects your hardware, asks about the AI engine (Ollama), models, storage and
# app settings, shows a summary, and changes nothing until you confirm.
# Run it again any time to update Aazad Chat or change settings.
#
# With options (for example a dry run):
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/alban-sheikh/aazad-local-llm/main/install.ps1))) -DryRun

[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$Uninstall,
    [ValidateSet('', 'keep', 'winget', 'download', 'skip')][string]$Ollama = '',
    [string]$Models = '',
    [string]$ModelsDir = '',
    [ValidateSet('', '5m', '30m', '1h', '-1')][string]$KeepAlive = '',
    [ValidateSet('', 'auto', '4096', '8192', '16384', '32768')][string]$Context = '',
    [string]$AppDir = '',
    [string]$DataDir = '',
    [int]$Port = 0,
    [ValidateSet('', 'yes', 'no')][string]$Autostart = '',
    [ValidateSet('', 'yes', 'no')][string]$Shortcut = '',
    [ValidateSet('', 'yes', 'no')][string]$Open = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # much faster downloads in Windows PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repo = 'alban-sheikh/aazad-local-llm'
$Branch = 'main'
$OllamaUrl = 'http://127.0.0.1:11434'
if ($env:AAZAD_YES -eq '1') { $Yes = $true }

# name | good for | capabilities | download size (GB, from the Ollama registry)
$Catalog = @(
    'gemma3:1b|General chat (tiny)|chat|0.8'
    'llama3.2:1b|General chat (tiny)|chat|1.3'
    'qwen3:1.7b|Reasoning (tiny)|chat, thinking|1.4'
    'qwen2.5-coder:3b|Coding (small)|code|1.9'
    'llama3.2:3b|General chat, fast|chat, tools|2.0'
    'qwen3:4b|Reasoning (small)|chat, thinking|2.5'
    'phi4-mini|General chat|chat, tools|2.5'
    'gemma3:4b|Chat + images|chat, vision|3.3'
    'qwen2.5-coder:7b|Coding|code|4.7'
    'llama3.1:8b|General chat|chat, tools|4.9'
    'qwen3:8b|Reasoning|chat, thinking|5.2'
    'deepseek-r1:8b|Step-by-step reasoning|thinking|5.2'
    'gemma3:12b|Chat + images|chat, vision|8.2'
    'qwen2.5-coder:14b|Coding|code|9.0'
    'deepseek-r1:14b|Step-by-step reasoning|thinking|9.0'
    'phi4:14b|General chat, reasoning|chat|9.1'
    'qwen3:14b|Reasoning|chat, thinking|9.3'
    'gemma3:27b|Chat + images|chat, vision|17.4'
    'qwen3:30b|Reasoning, fast (MoE)|chat, thinking|18.6'
    'qwen2.5-coder:32b|Coding|code|19.9'
    'deepseek-r1:32b|Step-by-step reasoning|thinking|19.9'
    'qwen3:32b|Reasoning|chat, thinking|20.2'
    'llama3.3:70b|General chat|chat, tools|42.5'
    'deepseek-r1:70b|Step-by-step reasoning|thinking|42.5'
    'qwen2.5:72b|General chat|chat, tools|47.4'
    'nomic-embed-text|Search / RAG (embeddings)|embedding|0.3'
) | ForEach-Object {
    $p = $_ -split '\|'
    [pscustomobject]@{ Name = $p[0]; GoodFor = $p[1]; Caps = $p[2]; SizeGB = [double]$p[3] }
}

# ---------------------------------------------------------------- output & prompts
function Say([string]$Text = '') { Write-Host $Text }
function Info([string]$Text) { Write-Host '> ' -ForegroundColor Cyan -NoNewline; Write-Host $Text }
function Ok([string]$Text) { Write-Host 'OK ' -ForegroundColor Green -NoNewline; Write-Host $Text }
function Warn([string]$Text) { Write-Host "! $Text" -ForegroundColor Yellow }
function Fail([string]$Text) { Write-Host "X $Text" -ForegroundColor Red; throw 'Installer stopped.' }
function Section([string]$Text) { Write-Host ''; Write-Host $Text -ForegroundColor White }

function Ask([string]$Question, [string]$Default) {
    if ($Yes) { return $Default }
    $reply = Read-Host "$Question [$Default]"
    if ([string]::IsNullOrWhiteSpace($reply)) { return $Default }
    return $reply.Trim()
}

function Confirm-Choice([string]$Question, [bool]$Default) {
    if ($Yes) { return $Default }
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $reply = Read-Host "$Question [$hint]"
        if ([string]::IsNullOrWhiteSpace($reply)) { return $Default }
        if ($reply -match '^[Yy]') { return $true }
        if ($reply -match '^[Nn]') { return $false }
    }
}

function Select-Option([string]$Question, [int]$Default, [string[]]$Options) {
    if ($Yes) { return $Default }
    Say $Question
    for ($i = 0; $i -lt $Options.Count; $i++) { Say ("  {0}) {1}" -f ($i + 1), $Options[$i]) }
    while ($true) {
        $reply = Read-Host "Choose 1-$($Options.Count) [$Default]"
        if ([string]::IsNullOrWhiteSpace($reply)) { return $Default }
        $n = 0
        if ([int]::TryParse($reply, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) { return $n }
        Warn "Please type a number from 1 to $($Options.Count)."
    }
}

function Resolve-YesNo([string]$Preset, [string]$Question, [bool]$Default) {
    if ($Preset -eq 'yes') { return $true }
    if ($Preset -eq 'no') { return $false }
    return (Confirm-Choice $Question $Default)
}

function Invoke-Step([string]$Description, [scriptblock]$Action) {
    if ($DryRun) { Write-Host "  [dry-run] $Description" -ForegroundColor DarkGray; return }
    & $Action
}

function Expand-UserPath([string]$Path) {
    $p = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ($p.StartsWith('~')) { $p = Join-Path $env:USERPROFILE $p.Substring(1).TrimStart('\', '/') }
    return [IO.Path]::GetFullPath($p).TrimEnd('\')
}

function Get-FreeGB([string]$Path) {
    $root = [IO.Path]::GetPathRoot((Expand-UserPath $Path))
    $drive = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $root.TrimEnd('\'))
    if ($drive) { return [math]::Round($drive.FreeSpace / 1GB, 1) }
    return 0
}

function Test-Http([string]$Url) {
    try { Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3 | Out-Null; return $true } catch { return $false }
}

function Wait-Http([string]$Url, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Http $Url) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

# ---------------------------------------------------------------- detection
function Get-Hardware {
    $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    $gpuName = 'none (CPU only)'
    $gpuGB = 0.0

    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        $lines = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
        foreach ($line in @($lines)) {
            $parts = $line -split ','
            if ($parts.Count -ge 2) {
                $gb = [math]::Round([double]$parts[-1].Trim() / 1024, 1)
                if ($gb -gt $gpuGB) { $gpuGB = $gb; $gpuName = ($parts[0..($parts.Count - 2)] -join ',').Trim() }
            }
        }
    }
    if ($gpuGB -eq 0) {
        # Dedicated video memory from the display driver (works for AMD, Intel Arc and NVIDIA without nvidia-smi)
        $class = 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*'
        foreach ($key in @(Get-ItemProperty -Path $class -ErrorAction SilentlyContinue)) {
            $prop = $key.PSObject.Properties['HardwareInformation.qwMemorySize']
            if (-not $prop) { continue }
            $value = $prop.Value
            if ($value -is [byte[]]) { $value = [BitConverter]::ToUInt64($value, 0) }
            $gb = [math]::Round([double]$value / 1GB, 1)
            if ($gb -ge 2 -and $gb -gt $gpuGB) {
                $gpuGB = $gb
                $desc = $key.PSObject.Properties['DriverDesc']
                $gpuName = if ($desc) { $desc.Value } else { 'GPU' }
            }
        }
    }
    [pscustomobject]@{ RamGB = $ramGB; GpuName = $gpuName; GpuGB = $gpuGB }
}

function Find-Ollama {
    $cmd = Get-Command ollama -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $path = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (Test-Path $path) { return $path }
    return $null
}

function Get-OllamaVersion {
    try { return (Invoke-RestMethod -Uri "$OllamaUrl/api/version" -TimeoutSec 3).version } catch { return $null }
}

function Get-InstalledModels([string]$OllamaExe) {
    if (-not $OllamaExe -or -not (Get-OllamaVersion)) { return @() }
    try {
        return @((Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec 5).models | ForEach-Object { $_.name })
    } catch { return @() }
}

function Test-ModelInstalled([string]$Name, [string[]]$Installed) {
    return ($Installed -contains $Name) -or ($Installed -contains "$Name`:latest")
}

function Find-Python {
    $candidates = @(@{ Exe = 'py'; Args = @('-3') }, @{ Exe = 'python'; Args = @() }, @{ Exe = 'python3'; Args = @() })
    foreach ($c in $candidates) {
        $cmd = Get-Command $c.Exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd) { continue }
        # Skip the Microsoft Store placeholder (a 0-byte alias that opens the Store)
        if ($cmd.Source -like '*\WindowsApps\*' -and (Get-Item $cmd.Source -ErrorAction SilentlyContinue).Length -eq 0) { continue }
        try {
            # sqlite3 holds the chats; it's part of every python.org and winget Python
            $out = & $cmd.Source @($c.Args) -c 'import sys, sqlite3; print(sys.executable) if sys.version_info >= (3, 9) else sys.exit(1)' 2>$null
            if ($LASTEXITCODE -eq 0 -and $out) { return ([string]$out).Trim() }
        } catch { continue }
    }
    return $null
}

function Get-FitLabel([double]$Size, $Hw) {
    if ($Hw.GpuGB -gt 0 -and $Hw.GpuGB -ge ($Size + 1.5)) { return @('fast (GPU)', 'Green') }
    if ($Hw.GpuGB -gt 0 -and ($Hw.GpuGB + $Hw.RamGB * 0.5) -ge ($Size + 2)) { return @('partly GPU, slower', 'Yellow') }
    if (($Hw.RamGB * 0.75) -ge ($Size + 2)) { return @('CPU, slow', 'Yellow') }
    return @('too big', 'Red')
}

function Get-RecommendedModels($Hw) {
    if ($Hw.GpuGB -ge 40) { return @('llama3.3:70b', 'qwen2.5-coder:32b') }
    if ($Hw.GpuGB -ge 21.5) { return @('gemma3:27b', 'qwen2.5-coder:32b') }
    if ($Hw.GpuGB -ge 10.5) { return @('gemma3:12b', 'qwen2.5-coder:14b') }
    if ($Hw.GpuGB -ge 6.5) { return @('gemma3:4b', 'qwen2.5-coder:7b') }
    if ($Hw.GpuGB -ge 3.5) { return @('gemma3:4b', 'qwen2.5-coder:3b') }
    if ($Hw.RamGB -ge 14) { return @('llama3.2:3b') }
    return @('gemma3:1b')
}

function Get-UserEnv([string]$Name) { return [Environment]::GetEnvironmentVariable($Name, 'User') }

function Get-AazadProcesses([string]$Dir) {
    if (-not $Dir) { return @() }
    $pattern = [regex]::Escape((Join-Path $Dir 'server.py'))
    return @(Get-CimInstance Win32_Process -Filter "Name LIKE 'python%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match $pattern })
}

# ---------------------------------------------------------------- install steps
function Stop-OllamaApp {
    Get-Process -Name 'ollama app', 'ollama' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Start-OllamaApp {
    $app = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
    if (Test-Path $app) { Start-Process -FilePath $app | Out-Null }
    elseif ($script:OllamaExe) { Start-Process -FilePath $script:OllamaExe -ArgumentList 'serve' -WindowStyle Hidden | Out-Null }
    if (-not (Wait-Http "$OllamaUrl/api/version" 60)) { Warn "Ollama isn't answering yet at $OllamaUrl." }
}

function Install-AazadFiles([string]$Dir) {
    if (Test-Path (Join-Path $Dir '.git')) {
        Info 'Updating Aazad Chat (git pull)...'
        Invoke-Step "git -C `"$Dir`" pull --ff-only" { & git -C $Dir pull --ff-only }
        return
    }
    Info 'Downloading Aazad Chat...'
    Invoke-Step "download https://codeload.github.com/$Repo/zip/refs/heads/$Branch and unpack into $Dir" {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("aazad-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $zip = Join-Path $tmp 'app.zip'
            Invoke-WebRequest -Uri "https://codeload.github.com/$Repo/zip/refs/heads/$Branch" -OutFile $zip -UseBasicParsing
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            $src = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
            if (-not $src -or -not (Test-Path (Join-Path $src.FullName 'server.py'))) { Fail "The download didn't contain Aazad Chat. Please try again." }
            if (Test-Path $Dir) { Remove-Item -Recurse -Force $Dir }
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            Copy-Item -Path (Join-Path $src.FullName '*') -Destination $Dir -Recurse -Force
        } finally {
            Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        }
    }
    Ok "Aazad Chat files are in $Dir"
}

function New-Shortcut([string]$Path, [string]$Target, [string]$Arguments, [string]$WorkDir) {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath = $Target
    $lnk.Arguments = $Arguments
    $lnk.WorkingDirectory = $WorkDir
    $lnk.WindowStyle = 7
    $lnk.Description = 'Aazad Chat server'
    $lnk.Save()
}

# ---------------------------------------------------------------- uninstall
function Invoke-Uninstall($Conf) {
    Section 'Uninstall Aazad Chat'
    $app = if ($Conf) { $Conf.AppDir } else { Join-Path $env:LOCALAPPDATA 'AazadChat\app' }
    $data = if ($Conf) { $Conf.DataDir } else { Join-Path $env:LOCALAPPDATA 'AazadChat' }
    Say "  App folder:   $app"
    Say "  Chats database: $data\aazad-chat.db"
    Say '  Ollama and your models are not touched.'
    if (-not (Confirm-Choice 'Remove Aazad Chat?' $false)) { Say 'Nothing was changed.'; return }

    Invoke-Step 'stop the Aazad Chat server' { Get-AazadProcesses $app | ForEach-Object { Stop-Process -Id $_.ProcessId -Force } }
    $startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'Aazad Chat.lnk'
    $menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Aazad Chat.url'
    Invoke-Step "remove $startup and $menu" { Remove-Item -Force $startup, $menu -ErrorAction SilentlyContinue }
    if ((Test-Path (Join-Path $app 'server.py'))) {
        $delete = $true
        if (Test-Path (Join-Path $app '.git')) { $delete = Confirm-Choice "$app is a git checkout (maybe your own copy). Delete it too?" $false }
        if ($delete) { Invoke-Step "delete $app" { Remove-Item -Recurse -Force $app } }
    }
    if (Test-Path $data) {
        if (Confirm-Choice "Also delete your saved chats in $data?" $false) {
            Invoke-Step "delete $data" { Remove-Item -Recurse -Force $data }
        } else {
            Invoke-Step "delete $data\install.json" { Remove-Item -Force (Join-Path $data 'install.json') -ErrorAction SilentlyContinue }
        }
    }
    foreach ($name in 'AAZAD_CHAT_PORT', 'AAZAD_CHAT_DATA') {
        Invoke-Step "remove user variable $name" { [Environment]::SetEnvironmentVariable($name, $null, 'User') }
    }
    Ok 'Aazad Chat removed.'
}

# ---------------------------------------------------------------- main
function Main {
    Say 'Aazad Chat installer: free, private AI on your own computer'
    if ($DryRun) { Warn 'Dry run: nothing will be changed.' }

    $defaultData = Join-Path $env:LOCALAPPDATA 'AazadChat'
    $confPath = Join-Path $(if (Get-UserEnv 'AAZAD_CHAT_DATA') { Get-UserEnv 'AAZAD_CHAT_DATA' } else { $defaultData }) 'install.json'
    $conf = $null
    if (Test-Path $confPath) { try { $conf = Get-Content -Raw $confPath | ConvertFrom-Json } catch { $conf = $null } }

    if ($Uninstall) { Invoke-Uninstall $conf; return }

    # ---- your computer
    $hw = Get-Hardware
    Section 'Your computer'
    Say ("  System:  Windows {0}" -f [Environment]::OSVersion.Version)
    Say "  Memory:  $($hw.RamGB) GB RAM"
    if ($hw.GpuGB -gt 0) { Say "  GPU:     $($hw.GpuName), $($hw.GpuGB) GB" } else { Say '  GPU:     none found, models will run on the CPU' }

    $python = Find-Python
    if (-not $python) {
        Warn 'Python 3.9 or newer is required to run Aazad Chat, and it was not found.'
        if ((Get-Command winget -ErrorAction SilentlyContinue) -and (Confirm-Choice 'Install Python 3.12 now with winget?' $true)) {
            Invoke-Step 'winget install -e --id Python.Python.3.12' {
                & winget install -e --id Python.Python.3.12 --scope user --accept-source-agreements --accept-package-agreements
                Update-SessionPath
            }
            if (-not $DryRun) { $python = Find-Python }
        }
        if (-not $python -and -not $DryRun) { Fail 'Install Python from https://www.python.org/downloads/ (tick "Add python.exe to PATH"), then run the installer again.' }
        if (-not $python) { $python = 'python.exe' }
    }
    $pythonw = Join-Path (Split-Path $python) 'pythonw.exe'
    if (-not (Test-Path $pythonw)) { $pythonw = $python }
    Say "  Python:  $python"

    # ---- 1. Ollama
    Section '1. AI engine (Ollama)'
    $script:OllamaExe = Find-Ollama
    $ollamaVersion = Get-OllamaVersion
    $ollamaAction = $Ollama
    if (-not $ollamaAction) {
        if ($script:OllamaExe -or $ollamaVersion) {
            $ollamaAction = 'keep'
        } else {
            $hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
            $options = @()
            if ($hasWinget) { $options += 'winget: winget install Ollama.Ollama (recommended)' }
            $options += 'Download OllamaSetup.exe from ollama.com and run it'
            $options += "Skip: I'll install Ollama myself"
            $n = Select-Option 'Ollama is not installed. How should it be installed?' 1 $options
            $choices = @(); if ($hasWinget) { $choices += 'winget' }; $choices += 'download', 'skip'
            $ollamaAction = $choices[$n - 1]
        }
    }
    switch ($ollamaAction) {
        'keep' { if ($ollamaVersion) { Ok "Using the Ollama already on this computer (version $ollamaVersion)" } else { Warn 'Ollama is installed but not running. The installer will start it.' } }
        'skip' { Warn "Skipping Ollama. Models can't be downloaded until it's installed and running." }
    }
    $installed = Get-InstalledModels $script:OllamaExe

    # ---- 2. Models
    Section '2. Models'
    $recommended = Get-RecommendedModels $hw
    Write-Host ("  {0,-3} {1,-18} {2,-26} {3,-15} {4,8}  {5}" -f '#', 'Model', 'Good for', 'Capabilities', 'Download', 'On this computer') -ForegroundColor DarkGray
    for ($i = 0; $i -lt $Catalog.Count; $i++) {
        $m = $Catalog[$i]
        $fit = Get-FitLabel $m.SizeGB $hw
        Write-Host ("  {0,-3} {1,-18} {2,-26} {3,-15} {4,5} GB  " -f ($i + 1), $m.Name, $m.GoodFor, $m.Caps, $m.SizeGB) -NoNewline
        Write-Host $fit[0] -ForegroundColor $fit[1] -NoNewline
        if ($recommended -contains $m.Name) { Write-Host ' * recommended' -NoNewline }
        if (Test-ModelInstalled $m.Name $installed) { Write-Host ' (installed)' -ForegroundColor Green -NoNewline }
        Write-Host ''
    }
    $defaultPick = if (@($recommended | Where-Object { -not (Test-ModelInstalled $_ $installed) }).Count -gt 0) { 'r' } else { 'n' }
    if ($ollamaAction -eq 'skip' -and -not $ollamaVersion) { $defaultPick = 'n' }
    $reply = $Models
    if (-not $reply) {
        if (-not $Yes) {
            Say ''
            Say '  Type numbers or names separated by spaces (e.g. 8 9), r = recommended *, n = none.'
            Say '  You can download more later from the Models button in the app.'
        }
        $reply = Ask 'Models to download' $defaultPick
    }
    $selected = New-Object System.Collections.Generic.List[string]
    foreach ($token in ($reply -split '[,\s]+' | Where-Object { $_ })) {
        $names = @()
        if ($token -match '^[rR]$') { $names = $recommended }
        elseif ($token -match '^(n|N|none)$') { $names = @() }
        elseif ($token -match '^\d+$') {
            $idx = [int]$token
            if ($idx -ge 1 -and $idx -le $Catalog.Count) { $names = @($Catalog[$idx - 1].Name) } else { Warn "There is no model number $token, skipped." }
        } else {
            if (-not ($Catalog | Where-Object { $_.Name -eq $token })) { Info "$token isn't in the list above; it will be downloaded if the Ollama library has it." }
            $names = @($token)
        }
        foreach ($name in $names) {
            if (Test-ModelInstalled $name $installed) { Info "$name is already installed, skipping its download."; continue }
            if (-not $selected.Contains($name)) { $selected.Add($name) }
        }
    }
    $totalGB = 0.0
    foreach ($name in $selected) {
        $entry = $Catalog | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($entry) {
            $totalGB += $entry.SizeGB
            if ((Get-FitLabel $entry.SizeGB $hw)[0] -eq 'too big') { Warn "$name ($($entry.SizeGB) GB) is too big for this computer's memory and may not run." }
        }
    }
    if ($selected.Count) { Ok ("Will download: {0} (about {1} GB)" -f ($selected -join ' '), [math]::Round($totalGB, 1)) } else { Info 'No models will be downloaded.' }

    # ---- 3. Storage
    Section '3. Model storage'
    $defaultModelsDefault = Join-Path $env:USERPROFILE '.ollama\models'
    $currentModelsDir = if (Get-UserEnv 'OLLAMA_MODELS') { Get-UserEnv 'OLLAMA_MODELS' } elseif ([Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'Machine')) { [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'Machine') } else { $defaultModelsDefault }
    Say '  Pick a drive with enough space that is always connected. Models can be large.'
    $modelsDirChoice = if ($ModelsDir) { $ModelsDir } else { Ask 'Folder for models' $currentModelsDir }
    $modelsDirChoice = Expand-UserPath $modelsDirChoice
    $moveModels = $false
    if ($modelsDirChoice -ne (Expand-UserPath $currentModelsDir)) {
        $blobs = Join-Path $currentModelsDir 'blobs'
        if ((Test-Path $blobs) -and (Get-ChildItem $blobs -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            $moveModels = Confirm-Choice "Move the models already in $currentModelsDir to the new folder?" $true
        }
    }
    $free = Get-FreeGB $modelsDirChoice
    if (($totalGB + 2) -gt $free) {
        Warn "Only $free GB free there, but the selected models need about $([math]::Round($totalGB, 1)) GB."
        if (-not (Confirm-Choice 'Continue anyway?' $false)) { Fail 'Stopped. Choose fewer models or another folder.' }
    } else { Ok "$free GB free on $([IO.Path]::GetPathRoot($modelsDirChoice))" }

    # ---- 4. Model settings
    Section '4. Model settings'
    $currentKeep = if (Get-UserEnv 'OLLAMA_KEEP_ALIVE') { Get-UserEnv 'OLLAMA_KEEP_ALIVE' } else { '5m' }
    $keep = $KeepAlive
    if (-not $keep) {
        $def = switch ($currentKeep) { '5m' { if ($ollamaAction -eq 'keep') { 1 } else { 2 } } '1h' { 3 } '-1' { 4 } default { 2 } }
        $n = Select-Option 'How long should a model stay loaded after you use it?' $def @(
            "5 minutes (Ollama's default, frees memory quickly)",
            '30 minutes (recommended)',
            '1 hour',
            'Always, until unloaded (fastest replies, keeps memory busy)')
        $keep = @('5m', '30m', '1h', '-1')[$n - 1]
    }
    $currentCtx = if (Get-UserEnv 'OLLAMA_CONTEXT_LENGTH') { Get-UserEnv 'OLLAMA_CONTEXT_LENGTH' } else { 'auto' }
    $ctx = $Context
    if (-not $ctx) {
        $cdef = switch ($currentCtx) { '4096' { 2 } '8192' { 3 } '16384' { 4 } '32768' { 5 } default { 1 } }
        $n = Select-Option 'Default context length (how much of a conversation a model remembers; more uses more memory)' $cdef @(
            'Automatic (Ollama picks from your GPU memory; recommended)', '4K tokens', '8K tokens', '16K tokens', '32K tokens')
        $ctx = @('auto', '4096', '8192', '16384', '32768')[$n - 1]
    }

    # ---- 5. Aazad Chat
    Section '5. Aazad Chat'
    $defaultApp = if ($conf -and $conf.AppDir) { $conf.AppDir } else { Join-Path $defaultData 'app' }
    $appDirChoice = Expand-UserPath $(if ($AppDir) { $AppDir } else { Ask 'Install folder' $defaultApp })
    if ((Test-Path $appDirChoice) -and (Get-ChildItem $appDirChoice -Force | Select-Object -First 1) -and -not (Test-Path (Join-Path $appDirChoice 'server.py'))) {
        Fail "$appDirChoice already contains other files. Choose an empty or new folder."
    }
    $defaultDataDir = if ($conf -and $conf.DataDir) { $conf.DataDir } else { $defaultData }
    $dataDirChoice = Expand-UserPath $(if ($DataDir) { $DataDir } else { Ask 'Folder for saved chats' $defaultDataDir })

    $defaultPort = if ($conf -and $conf.Port) { [int]$conf.Port } else { 3210 }
    $portChoice = $Port
    while ($true) {
        if (-not $portChoice) {
            $answer = Ask 'Port for the web app' ([string]$defaultPort)
            if (-not [int]::TryParse($answer, [ref]$portChoice)) { Warn 'The port must be a number.'; $portChoice = 0; continue }
        }
        $busy = Get-NetTCPConnection -LocalPort $portChoice -State Listen -ErrorAction SilentlyContinue
        $ours = $false
        if ($busy) { try { $ours = (Invoke-WebRequest "http://127.0.0.1:$portChoice/" -UseBasicParsing -TimeoutSec 2).Content -match '<title>Aazad Chat' } catch { $ours = $false } }
        if ($busy -and -not $ours) {
            Warn "Port $portChoice is used by another program."
            if ($Yes) { Fail "Port $portChoice is busy. Use -Port to pick another." }
            $defaultPort = $portChoice + 1
            $portChoice = 0
            continue
        }
        break
    }

    $autostartChoice = Resolve-YesNo $Autostart 'Start Aazad Chat automatically when you sign in?' $(if ($conf) { [bool]$conf.Autostart } else { $true })
    $shortcutChoice = Resolve-YesNo $Shortcut 'Add Aazad Chat to the Start menu?' $(if ($conf) { [bool]$conf.Shortcut } else { $true })
    $openChoice = Resolve-YesNo $Open 'Open Aazad Chat in your browser when done?' $true

    # ---- summary
    Section 'Summary'
    $engineText = @{ keep = 'use the existing Ollama'; winget = 'install with winget'; download = 'download and run OllamaSetup.exe'; skip = 'skip' }[$ollamaAction]
    Say "  AI engine:        $engineText"
    Say ("  Models:           {0}" -f $(if ($selected.Count) { "$($selected -join ' ') (about $([math]::Round($totalGB, 1)) GB)" } else { 'none' }))
    Say ("  Model folder:     {0}{1}" -f $modelsDirChoice, $(if ($moveModels) { "  (move existing models from $currentModelsDir)" } else { '' }))
    Say "  Keep loaded:      $keep"
    Say "  Context length:   $ctx"
    Say "  App folder:       $appDirChoice"
    Say "  Chats database:   $dataDirChoice\aazad-chat.db"
    Say "  Address:          http://127.0.0.1:$portChoice"
    Say ("  Start at sign-in: {0}" -f $(if ($autostartChoice) { 'yes' } else { 'no' }))
    Say ("  Start menu:       {0}" -f $(if ($shortcutChoice) { 'yes' } else { 'no' }))
    Say ''
    if (-not (Confirm-Choice 'Go ahead?' $true)) { Say 'Nothing was changed.'; return }

    # ---- install
    Section 'Installing'
    switch ($ollamaAction) {
        'winget' {
            Invoke-Step 'winget install -e --id Ollama.Ollama' {
                & winget install -e --id Ollama.Ollama --accept-source-agreements --accept-package-agreements
                Update-SessionPath
            }
        }
        'download' {
            Invoke-Step 'download https://ollama.com/download/OllamaSetup.exe and run it' {
                $setup = Join-Path ([IO.Path]::GetTempPath()) 'OllamaSetup.exe'
                Invoke-WebRequest -Uri 'https://ollama.com/download/OllamaSetup.exe' -OutFile $setup -UseBasicParsing
                Start-Process -FilePath $setup -Wait
                Remove-Item -Force $setup -ErrorAction SilentlyContinue
                Update-SessionPath
            }
        }
    }
    if (-not $DryRun) { $script:OllamaExe = Find-Ollama }

    # Ollama settings live in user environment variables; Ollama reads them when it starts
    $wanted = [ordered]@{
        OLLAMA_KEEP_ALIVE     = $(if ($keep -ne '5m') { $keep } else { $null })
        OLLAMA_CONTEXT_LENGTH = $(if ($ctx -ne 'auto') { $ctx } else { $null })
        OLLAMA_MODELS         = $(if ($modelsDirChoice -ne (Expand-UserPath $defaultModelsDefault)) { $modelsDirChoice } else { $null })
    }
    $changed = $false
    foreach ($k in $wanted.Keys) { if ((Get-UserEnv $k) -ne $wanted[$k]) { $changed = $true } }
    if ($ollamaAction -ne 'skip') {
        if ($changed -or $moveModels) {
            Invoke-Step 'stop Ollama to apply settings' { Stop-OllamaApp }
            if ($moveModels) {
                Invoke-Step "move models from $currentModelsDir to $modelsDirChoice" {
                    New-Item -ItemType Directory -Path $modelsDirChoice -Force | Out-Null
                    if (Get-ChildItem $modelsDirChoice -Force | Select-Object -First 1) { Warn "$modelsDirChoice is not empty, so existing models were not moved." }
                    else { Get-ChildItem $currentModelsDir -Force | Move-Item -Destination $modelsDirChoice }
                }
            }
            foreach ($k in $wanted.Keys) {
                $v = $wanted[$k]
                Invoke-Step "set user variable $k=$v" {
                    [Environment]::SetEnvironmentVariable($k, $v, 'User')
                    Set-Item -Path "Env:$k" -Value $v -ErrorAction SilentlyContinue
                    if ($null -eq $v) { Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue }
                }
            }
            Invoke-Step 'start Ollama' { Start-OllamaApp }
            Ok 'Ollama settings saved'
        } else {
            if (-not $DryRun -and -not (Get-OllamaVersion)) { Start-OllamaApp }
            Ok 'Ollama settings unchanged'
        }
    }

    if ($selected.Count) {
        if (-not $DryRun -and -not (Get-OllamaVersion)) {
            Warn "Ollama isn't running, so models weren't downloaded. Later, run: ollama pull <model>"
        } else {
            foreach ($name in $selected) {
                Info "Downloading $name..."
                Invoke-Step "ollama pull $name" {
                    & $script:OllamaExe pull $name
                    if ($LASTEXITCODE -ne 0) { Warn "$name didn't download. Try again later with: ollama pull $name" }
                }
            }
        }
    }

    Install-AazadFiles $appDirChoice

    Invoke-Step "save AAZAD_CHAT_PORT=$portChoice and AAZAD_CHAT_DATA=$dataDirChoice as user variables" {
        New-Item -ItemType Directory -Path $dataDirChoice -Force | Out-Null
        [Environment]::SetEnvironmentVariable('AAZAD_CHAT_PORT', [string]$portChoice, 'User')
        [Environment]::SetEnvironmentVariable('AAZAD_CHAT_DATA', $dataDirChoice, 'User')
        $env:AAZAD_CHAT_PORT = [string]$portChoice
        $env:AAZAD_CHAT_DATA = $dataDirChoice
    }

    $startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Aazad Chat.lnk'
    if ($autostartChoice) {
        Invoke-Step "create $startupLink" { New-Shortcut $startupLink $pythonw "`"$(Join-Path $appDirChoice 'server.py')`"" $appDirChoice }
    } else {
        Invoke-Step "remove $startupLink" { Remove-Item -Force $startupLink -ErrorAction SilentlyContinue }
    }

    Invoke-Step 'restart the Aazad Chat server' {
        Get-AazadProcesses $appDirChoice | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Process -FilePath $pythonw -ArgumentList "`"$(Join-Path $appDirChoice 'server.py')`"" -WorkingDirectory $appDirChoice -WindowStyle Hidden | Out-Null
        if (Wait-Http "http://127.0.0.1:$portChoice/" 20) { Ok "Aazad Chat is running at http://127.0.0.1:$portChoice" }
        else { Warn "Aazad Chat didn't answer on port $portChoice yet." }
    }

    $menuLink = Join-Path ([Environment]::GetFolderPath('Programs')) 'Aazad Chat.url'
    if ($shortcutChoice) {
        Invoke-Step "create $menuLink" { Set-Content -Path $menuLink -Value "[InternetShortcut]`r`nURL=http://127.0.0.1:$portChoice`r`n" -Encoding ASCII }
    } else {
        Invoke-Step "remove $menuLink" { Remove-Item -Force $menuLink -ErrorAction SilentlyContinue }
    }

    Invoke-Step "save settings to $dataDirChoice\install.json" {
        [pscustomobject]@{
            AppDir = $appDirChoice; DataDir = $dataDirChoice; Port = $portChoice
            Autostart = $autostartChoice; Shortcut = $shortcutChoice
            KeepAlive = $keep; Context = $ctx; ModelsDir = $modelsDirChoice
        } | ConvertTo-Json | Set-Content -Path (Join-Path $dataDirChoice 'install.json') -Encoding UTF8
    }

    Section 'Done'
    if ($DryRun) { Say '  Dry run finished. Run again without -DryRun to install.'; return }
    Say "  Aazad Chat: http://127.0.0.1:$portChoice"
    Say "  Chats:      $dataDirChoice\aazad-chat.db"
    Say '  Update or change settings: run this installer again'
    Say '  Remove:     run this installer with -Uninstall'
    if ($openChoice) { Start-Process "http://127.0.0.1:$portChoice" }
}

try {
    Main
} catch {
    if ($_.Exception.Message -ne 'Installer stopped.') { Write-Host "X $($_.Exception.Message)" -ForegroundColor Red }
    exit 1
}
