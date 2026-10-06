<#
.SYNOPSIS
    Compile and run SystemVerilog homework exercises with Icarus Verilog.

.DESCRIPTION
    A thin wrapper around iverilog + vvp that works on a single exercise
    instead of a whole homework folder. Artifacts (sim.out, log.txt, dump.vcd)
    land in the exercise directory and are already covered by .gitignore.

.EXAMPLE
    .\hw.ps1 1.1            # run exercise 01_01
.EXAMPLE
    .\hw.ps1 1              # run all of homework 01
.EXAMPLE
    .\hw.ps1 mux_case       # run whatever matches by name
.EXAMPLE
    .\hw.ps1 1.2 -Wave      # run and open the waveform in GTKWave
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Target,
    [switch]$Wave,
    [switch]$List,
    [switch]$Log,
    [switch]$Import,
    [switch]$Clean,
    [switch]$Help,
    [int]$MaxLines = 30
)

# 'Continue', not 'Stop': in Windows PowerShell 5.1 every stderr line from a
# native exe arrives as an ErrorRecord, and iverilog writes ordinary warnings
# there. Under 'Stop' a harmless warning would abort the run.
$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot

# Files this script generates. Nothing else is ever deleted by -Clean.
$GeneratedNames = @('sim.out', 'log.txt', 'lint.txt', 'dump.vcd')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Head($text) { Write-Host "`n>> $text" -ForegroundColor Cyan }

# Run a native command and return its combined output as plain text.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $raw = & $Exe @Arguments 2>&1
    $text = @($raw | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { $_ }
    }) -join "`n"
    return @{ Text = $text; ExitCode = $LASTEXITCODE }
}

function Show-Usage {
    Write-Host @"
Usage: .\hw.ps1 [target] [-Wave] [-List] [-Log] [-Clean] [-Import]

  target    1            whole homework 01
            1.1  01_01   a single exercise
            mux_case     any exercise whose name contains this
            (omitted)    the exercise or homework folder you are standing in

  -Wave     dump waveforms and open GTKWave (single exercise only)
  -List     list every exercise the script can find
  -Log      print the raw compile/simulate log instead of just PASS/FAIL
  -Clean    delete generated sim.out / log.txt / lint.txt / dump.vcd files
  -Import   fetch the openhwgroup/cvw sources needed by the float exercises
"@
}

function Test-IsExercise($path) {
    (Test-Path (Join-Path $path 'testbench.sv')) -or
    (Test-Path (Join-Path $path 'tb.sv')) -or
    (Test-Path (Join-Path $path 'testbenches'))
}

function Get-Exercises {
    $found = New-Object System.Collections.ArrayList
    $hwDirs = Get-ChildItem -LiteralPath $Root -Directory |
              Where-Object { $_.Name -match '^\d\d_' } | Sort-Object Name
    foreach ($hw in $hwDirs) {
        if (Test-IsExercise $hw.FullName) {
            [void]$found.Add($hw.FullName)
            continue
        }
        foreach ($ex in (Get-ChildItem -LiteralPath $hw.FullName -Directory | Sort-Object Name)) {
            if (Test-IsExercise $ex.FullName) { [void]$found.Add($ex.FullName) }
        }
    }
    return $found
}

function Get-RelId($path) {
    return $path.Substring($Root.Length).TrimStart('\').TrimStart('/').Replace('\', '/')
}

# Turn "1.1", "1-1", "01 01" into "01_01"; "7" into "07".
function Get-NormalizedTarget($text) {
    $n = $text.ToLower() -replace '[\.\-\s/\\]', '_'
    $n = $n.Trim('_')
    if ($n -match '^(\d{1,2})_(\d{1,2})$') {
        return ('{0:d2}_{1:d2}' -f [int]$Matches[1], [int]$Matches[2])
    }
    if ($n -match '^\d{1,2}$') { return ('{0:d2}' -f [int]$n) }
    return $n
}

function Resolve-Targets($text) {
    $all = Get-Exercises

    # No target: use the directory we are standing in.
    if ([string]::IsNullOrWhiteSpace($text)) {
        $cwd = (Get-Location).Path.TrimEnd('\')
        $hits = @($all | Where-Object { $_ -eq $cwd -or $_.StartsWith($cwd + '\') })
        if ($hits.Count -gt 0) { return $hits }
        Write-Host "No exercise found here. Pass a target, e.g. .\hw.ps1 1.1" -ForegroundColor Yellow
        return @()
    }

    $n = Get-NormalizedTarget $text

    # A bare homework number runs the whole homework folder.
    if ($n -match '^\d{2}$') {
        $prefix = $n + '_'
        $hits = @($all | Where-Object { (Get-RelId $_).StartsWith($prefix) })
        if ($hits.Count -gt 0) { return $hits }
    }

    # Prefer a leaf name that *starts with* the target, so "1.4" picks
    # 01_04_mux_index and not 06_01_04_sqrt_formula_pipe, which merely
    # contains "01_04". Fall back to substring matching for name searches.
    $hits = @($all | Where-Object { (Split-Path $_ -Leaf).ToLower().StartsWith($n) })
    if ($hits.Count -eq 0) {
        $hits = @($all | Where-Object { (Split-Path $_ -Leaf).ToLower().Contains($n) })
    }
    if ($hits.Count -eq 0) {
        $hits = @($all | Where-Object { (Get-RelId $_).ToLower().Contains($n) })
    }
    return $hits
}

# ---------------------------------------------------------------------------
# Building the iverilog command line for one exercise
# ---------------------------------------------------------------------------

# Everything is passed to iverilog relative to the exercise directory and with
# forward slashes. Both matter: Verilog string literals eat backslashes, so an
# absolute Windows path turns `__FILE__` into garbage in the PASS/FAIL lines.
function Get-CompileArgs($dir) {
    $depth = (Get-RelId $dir).Split('/').Count
    $up = ('../' * $depth)
    $common = $up + 'common'

    if (Test-Path (Join-Path $dir 'testbenches')) {
        # isqrt-style exercise: testbenches live in a subdirectory
        return @(
            '-I', $common,
            '-I', '.',
            '-I', 'testbenches',
            'testbenches/*.sv',
            "$common/isqrt/*.sv",
            '*.sv'
        )
    }

    $tb = Join-Path $dir 'testbench.sv'
    if ((Test-Path $tb) -and (Select-String -LiteralPath $tb -Pattern 'realtobits' -Quiet)) {
        # Exercise built on the Wally (cvw) FPU blocks
        if (-not (Test-Path (Join-Path $Root 'import\preprocessed\cvw'))) {
            throw "This exercise needs the openhwgroup/cvw sources. Run '.\hw.ps1 -Import' once."
        }
        $import = $up + 'import/preprocessed/cvw'
        $a = @(
            '-I', $import,
            '-I', $common,
            "$import/config.vh",
            "$import/*.sv",
            "$common/wally_fpu/*.sv",
            '*.sv'
        )
        if (Test-Path (Join-Path $dir 'solution_submodules')) {
            $a += @('-I', 'solution_submodules', 'solution_submodules/*.sv')
        }
        return $a
    }

    # Ordinary exercise
    return @('-I', $common, '*.sv')
}

# $dumpvars is commented out in the testbenches on purpose. Rather than editing
# them, elaborate an extra root module that dumps the whole design. It lives
# outside the exercise directory so the `*.sv` glob does not pick it up twice.
function New-DumpModule {
    $path = Join-Path $env:TEMP 'hw_wave_dump.sv'
    $body = @'
// Generated by hw.ps1 -Wave. Safe to delete.
module _hw_wave_dump;
  initial
  begin
    $dumpfile("dump.vcd");
    $dumpvars;
  end
endmodule
'@
    Set-Content -LiteralPath $path -Value $body -Encoding ascii
    return $path
}

function Invoke-Exercise($dir, [bool]$withWave) {
    $id = Get-RelId $dir
    Write-Head $id

    $logPath = Join-Path $dir 'log.txt'
    foreach ($name in $GeneratedNames) {
        $stale = Join-Path $dir $name
        if (Test-Path $stale) { Remove-Item -LiteralPath $stale -Force }
    }

    $compileArgs = @(Get-CompileArgs $dir)
    $dumpFile = $null
    if ($withWave) {
        $dumpFile = New-DumpModule
        $compileArgs += $dumpFile.Replace('\', '/')
    }

    Push-Location $dir
    try {
        $r = Invoke-Native 'iverilog' (@('-g2012', '-o', 'sim.out') + $compileArgs)
        $out = $r.Text
        $compiled = ($r.ExitCode -eq 0)
        if ($compiled) {
            $out = $out + "`n" + (Invoke-Native 'vvp' @('sim.out')).Text
        }
    }
    finally {
        Pop-Location
        if ($dumpFile -and (Test-Path $dumpFile)) { Remove-Item -LiteralPath $dumpFile -Force }
    }

    # Match the upstream scripts: drop noise the student cannot act on.
    $lines = $out -split "`r?`n" | Where-Object {
        $_ -notmatch 'sorry: constant selects' -and $_ -notmatch 'finish called'
    }
    $out = $lines -join "`n"
    Set-Content -LiteralPath $logPath -Value $out -Encoding ascii

    if (-not $compiled) {
        Write-Host $out
        Write-Host "COMPILE ERROR" -ForegroundColor Red
        return $false
    }

    if ($Log) {
        Write-Host $out
    }
    else {
        # A broken design can emit tens of thousands of assertion lines; show
        # enough to debug from and leave the rest in log.txt.
        $interesting = @($lines | Where-Object { $_ -match 'PASS|FAIL|[Ee]rror|Timeout|^\+\+' })
        foreach ($line in ($interesting | Select-Object -First $MaxLines)) {
            if ($line -match 'PASS')                      { Write-Host $line -ForegroundColor Green }
            elseif ($line -match 'FAIL|[Ee]rror|Timeout') { Write-Host $line -ForegroundColor Red }
            else                                          { Write-Host $line -ForegroundColor DarkGray }
        }
        if ($interesting.Count -gt $MaxLines) {
            $rest = $interesting.Count - $MaxLines
            Write-Host "... $rest more line(s) - full output in $id/log.txt" -ForegroundColor DarkYellow
        }
    }

    if ($out -match 'FAIL|[Ee]rror|Timeout') { return $false }
    if ($out -notmatch 'PASS') {
        Write-Host "(no PASS/FAIL in output - see $id/log.txt)" -ForegroundColor Yellow
        return $false
    }
    return $true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ($Help) { Show-Usage; return }

if ($Clean) {
    # Match on the exact file name. Do NOT use Get-ChildItem -Include here:
    # with a -Path that has no wildcard, -Include is silently ignored and the
    # pipeline returns every file in the tree.
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
               Where-Object { $GeneratedNames -contains $_.Name -and $_.FullName -notmatch '\\\.git\\' })
    foreach ($f in $files) { Remove-Item -LiteralPath $f.FullName -Force }
    Write-Host "Removed $($files.Count) generated file(s)." -ForegroundColor Green
    return
}

if (-not (Get-Command iverilog -ErrorAction SilentlyContinue)) {
    Write-Host "iverilog is not on PATH. Install Icarus Verilog or add C:\iverilog\bin to PATH." -ForegroundColor Red
    return
}

if ($Import) {
    # The upstream sh script already knows how to fetch and preprocess cvw.
    $gitBash = 'C:\Program Files\Git\bin\bash.exe'
    if (-not (Test-Path $gitBash)) {
        Write-Host "Git Bash not found at $gitBash - cannot run the import script." -ForegroundColor Red
        return
    }
    Write-Host "Fetching openhwgroup/cvw (answer 'y' when prompted)..." -ForegroundColor Cyan
    Push-Location (Join-Path $Root '03_combinational_arithmetic')
    try { & $gitBash -lc './run_linux_mac.sh' }
    finally { Pop-Location }
    return
}

if ($List) {
    foreach ($e in Get-Exercises) { Write-Host (Get-RelId $e) }
    return
}

$targets = @(Resolve-Targets $Target)

if ($targets.Count -eq 0) {
    if ($Target) { Write-Host "Nothing matched '$Target'. Try .\hw.ps1 -List" -ForegroundColor Yellow }
    return
}

if ($targets.Count -gt 1 -and $Wave) {
    Write-Host "-Wave needs a single exercise; '$Target' matched $($targets.Count):" -ForegroundColor Yellow
    foreach ($t in $targets) { Write-Host "  $(Get-RelId $t)" }
    return
}

$pass = 0
$fail = 0
$skip = 0
foreach ($t in $targets) {
    try {
        if (Invoke-Exercise $t ([bool]$Wave)) { $pass++ } else { $fail++ }
    }
    catch {
        # A missing prerequisite should skip one exercise, not abort the batch.
        Write-Host "SKIPPED - $($_.Exception.Message)" -ForegroundColor Yellow
        $skip++
    }
}

Write-Host ""
$summary = "$pass passed, $fail failed"
if ($skip -gt 0) { $summary = "$summary, $skip skipped" }
if ($fail -eq 0) { Write-Host $summary -ForegroundColor Green }
else             { Write-Host $summary -ForegroundColor Red }

if ($Wave -and $targets.Count -eq 1) {
    $vcd = Join-Path $targets[0] 'dump.vcd'
    if (Test-Path $vcd) {
        $tcl = Join-Path $targets[0] 'gtkwave.tcl'
        Write-Host "Opening GTKWave..." -ForegroundColor Cyan
        if (Test-Path $tcl) { Start-Process gtkwave -ArgumentList $vcd, '--script', $tcl }
        else                { Start-Process gtkwave -ArgumentList $vcd }
    }
    else {
        Write-Host "No dump.vcd was produced." -ForegroundColor Yellow
    }
}

# vvp exits non-zero on $finish(1), which every failing testbench uses. Don't
# let that leak out and colour the shell prompt red.
$global:LASTEXITCODE = 0
