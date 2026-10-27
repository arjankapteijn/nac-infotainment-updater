<#
.SYNOPSIS
    Tests for the Windows scripts. Run from the repository root:

        powershell -ExecutionPolicy Bypass -File tests\windows\Run-Tests.ps1

    Nothing is downloaded from the internet and no real disk is touched. The
    format test runs only as Administrator, on a throwaway 1 GB VHD.
#>
# Not 'Stop': in Windows PowerShell 5.1 that turns any stderr line from a
# child process into a terminating error.
$ErrorActionPreference = 'Continue'

$repo  = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$ps    = (Get-Process -Id $PID).Path
$work  = Join-Path ([System.IO.Path]::GetTempPath()) ("nac-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$scripts = @(
    (Join-Path $repo 'windows\Prepare-NacFirmwareUpdate.ps1'),
    (Join-Path $repo 'windows\Prepare-NacMapUpdate.ps1')
)

$script:passed = 0
$script:failed = 0
$script:skipped = 0
function Report($name, $ok, $detail) {
    if ($ok) { Write-Host "ok   - $name"; $script:passed++ }
    else { Write-Host "FAIL - $name" -ForegroundColor Red; $detail -split "`r?`n" | Select-Object -Last 15 | ForEach-Object { Write-Host "       $_" }; $script:failed++ }
}

# -- Fixtures ----------------------------------------------------------------
New-Item -ItemType Directory "$work\data\SWL\pkg", "$work\other\OTHER", "$work\srv" -Force | Out-Null
# Enough entries that a pipeline cut short after a few lines would break tar
1..3000 | ForEach-Object { [System.IO.File]::WriteAllText("$work\data\SWL\pkg\file$_.bin", "$_") }
$random = New-Object byte[] 2000000
[System.Random]::new(1).NextBytes($random)
[System.IO.File]::WriteAllBytes("$work\data\SWL\big.bin", $random)
'readme' | Out-File "$work\other\OTHER\readme.txt"
& tar.exe -cf "$work\good.tar" -C "$work\data" SWL/pkg SWL/big.bin
& tar.exe -cf "$work\noswl.tar" -C "$work\other" OTHER
# Cut inside the big last member, like a dropped download
$good = [System.IO.File]::ReadAllBytes("$work\good.tar")
$cut = New-Object byte[] ($good.Length - 1000000)
[Array]::Copy($good, $cut, $cut.Length)
[System.IO.File]::WriteAllBytes("$work\truncated.tar", $cut)

$payload = New-Object byte[] 8388608
[System.Random]::new(2).NextBytes($payload)
[System.IO.File]::WriteAllBytes("$work\srv\payload.bin", $payload)

$portRange = Get-Random -Minimum 20000 -Maximum 40000
$portNoRange = $portRange + 1
$servers = @(
    (Start-Job -ScriptBlock { param($s, $r, $p) & $s -Root $r -Port $p } -ArgumentList "$PSScriptRoot\TestServer.ps1", "$work\srv", $portRange),
    (Start-Job -ScriptBlock { param($s, $r, $p) & $s -Root $r -Port $p -NoRange } -ArgumentList "$PSScriptRoot\TestServer.ps1", "$work\srv", $portNoRange)
)
$urlRange = "http://127.0.0.1:$portRange"
$urlNoRange = "http://127.0.0.1:$portNoRange"
foreach ($port in $portRange, $portNoRange) {
    $up = $false
    for ($i = 0; $i -lt 50 -and -not $up; $i++) {
        try { $c = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $port); $c.Close(); $up = $true } catch { Start-Sleep -Milliseconds 200 }
    }
    if (-not $up) { throw "Test server on port $port did not start" }
}

# -- Cases: name, expected exit code, text the RESULT line must contain ------
$cases = @(
    @{ Case = 'select-one';       Exit = 0; Expect = 'selected=2';            Name = 'auto-selects a single USB drive' },
    @{ Case = 'select-two';       Exit = 0; Expect = 'selected=3';            Name = 'selects drive 2 of 2' },
    @{ Case = 'select-one-large'; Exit = 0; Expect = 'selected=4';            Name = 'auto-selects a single large USB drive' },
    @{ Case = 'tar-good';         Exit = 0; Expect = 'passed';                Name = 'accepts a valid archive' },
    @{ Case = 'tar-truncated';    Exit = 1; Expect = 'corrupted';             Name = 'rejects a truncated archive' },
    @{ Case = 'tar-noswl';        Exit = 1; Expect = 'No SWL';                Name = 'rejects an archive without SWL/' },
    @{ Case = 'extract';          Exit = 0; Expect = 'files=3001 expected=3001'; Name = 'extracts every file' },
    @{ Case = 'download-fresh';   Exit = 0; Expect = 'ok=True identical=True'; Name = 'fresh download is complete' },
    @{ Case = 'download-resume';  Exit = 0; Expect = 'ok=True identical=True'; Name = 'resumes a partial download' },
    @{ Case = 'download-norange'; Exit = 0; Expect = 'ok=True identical=True'; Name = 'restarts when the server ignores Range'; Also = 'Server rejected resume' },
    @{ Case = 'format-vhd';       Exit = 0; Expect = 'style=MBR fs=FAT32 active=True'; Name = 'formats an initialized GPT disk as MBR + FAT32'; Admin = $true }
)

try {
    # -- Parse check (with the BOM Windows PowerShell 5.1 needs for non-ASCII)
    foreach ($s in $scripts) {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($s, [ref]$null, [ref]$errs) | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($s)
        $bom = $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        Report "$(Split-Path $s -Leaf): parses" ($errs.Count -eq 0) ($errs | Out-String)
        Report "$(Split-Path $s -Leaf): saved as UTF-8 with BOM" $bom ''
    }

    foreach ($s in $scripts) {
        $leaf = Split-Path $s -Leaf
        foreach ($c in $cases) {
            $name = "${leaf}: $($c.Name)"
            if ($c.Admin -and -not $isAdmin) { Write-Host "skip - $name (needs Administrator)"; $script:skipped++; continue }

            if ($c.Case -eq 'format-vhd') {
                # Fresh VHD, initialized as GPT with a partition, like a used stick
                $vhd = "$work\test.vhdx"
                "create vdisk file=`"$vhd`" maximum=1024 type=expandable`nselect vdisk file=`"$vhd`"`nattach vdisk`nconvert gpt`ncreate partition primary" | diskpart.exe | Out-Null
                Start-Sleep -Seconds 2
            }

            $log = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PSScriptRoot\Cases.ps1" `
                -Script $s -Case $c.Case -Work $work -UrlRange $urlRange -UrlNoRange $urlNoRange 2>&1 | Out-String
            $code = $LASTEXITCODE

            if ($c.Case -eq 'format-vhd') {
                "select vdisk file=`"$vhd`"`ndetach vdisk" | diskpart.exe | Out-Null
                Remove-Item $vhd -Force -ErrorAction SilentlyContinue
            }

            $ok = ($code -eq $c.Exit) -and ($log -match [regex]::Escape($c.Expect))
            if ($c.Also) { $ok = $ok -and ($log -match [regex]::Escape($c.Also)) }
            Report $name $ok "exit $code`n$log"
        }
    }
} finally {
    $servers | Stop-Job -PassThru | Remove-Job -Force
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$($script:passed) passed, $($script:failed) failed, $($script:skipped) skipped"
if ($script:failed -gt 0) { exit 1 }
