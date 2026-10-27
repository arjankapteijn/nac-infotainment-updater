<#
    Runs one test case against one script. Run-Tests.ps1 starts this in its
    own PowerShell process per case, because the scripts call `exit` on errors.

    Only the function definitions are loaded from the script, so its main body
    (admin check, prompts, downloads) never runs. Prompts and disks are faked
    where needed; the format case works on a throwaway VHD.
#>
param([string]$Script, [string]$Case, [string]$Work, [string]$UrlRange, [string]$UrlNoRange)

$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

# Settings the functions read from the script scope
$ExpectedSize    = 0
$MaxRetries      = 3
$RetryDelayBase  = 0
$RetryDelayCap   = 0
$MinDownloadSize = 0
$FirmwareVersion = 'test'
$MapVersion      = 'test'
$ProgressPreference = 'SilentlyContinue'

# Fake Read-Host answers, consumed in order
$global:Answers = [System.Collections.Queue]::new()
function Read-Host { param($Prompt) $a = $global:Answers.Dequeue(); Write-Host "$Prompt> $a"; $a }

function New-FakeDisk($Number, $Name, $SizeGb, $Media = 'Removable') {
    [pscustomobject]@{ Number = $Number; FriendlyName = $Name; Size = [int64]$SizeGb * 1GB; BusType = 'USB'; MediaType = $Media }
}

function Test-ArchiveFile($Path) {
    if (Get-Command Test-Firmware -ErrorAction SilentlyContinue) { Test-Firmware -Path $Path } else { Test-MapFile -Path $Path }
}

function Get-Sha($Path) { (Get-FileHash $Path -Algorithm SHA256).Hash }

if ($Case -like 'select-*') { function Get-Partition { $null } }

switch ($Case) {
    'select-one' {
        function Get-Disk { New-FakeDisk 2 'Fake Stick' 32 }
        $global:Answers.Enqueue('YES')
        $d = Select-UsbDrive
        Write-Host "RESULT selected=$($d.Number)"
    }
    'select-two' {
        function Get-Disk { New-FakeDisk 2 'Stick A' 16; New-FakeDisk 3 'Stick B' 32 }
        $global:Answers.Enqueue('2'); $global:Answers.Enqueue('YES')
        $d = Select-UsbDrive
        Write-Host "RESULT selected=$($d.Number)"
    }
    'select-one-large' {
        function Get-Disk { New-FakeDisk 4 'Big USB SSD' 512 'Fixed' }
        $global:Answers.Enqueue('YES')
        $d = Select-UsbDrive
        Write-Host "RESULT selected=$($d.Number)"
    }
    'tar-good'      { Test-ArchiveFile "$Work\good.tar";      Write-Host 'RESULT passed' }
    'tar-truncated' { Test-ArchiveFile "$Work\truncated.tar"; Write-Host 'RESULT passed' }
    'tar-noswl'     { Test-ArchiveFile "$Work\noswl.tar";     Write-Host 'RESULT passed' }
    'extract' {
        $dest = Join-Path $Work ("usb-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory $dest | Out-Null
        Expand-ToUsb -TarPath "$Work\good.tar" -UsbRoot $dest
        $n = @(Get-ChildItem "$dest\SWL" -Recurse -File).Count
        $expected = @(& tar.exe tf "$Work\good.tar" | Where-Object { $_ -notmatch '/$' }).Count
        Write-Host "RESULT files=$n expected=$expected"
    }
    { $_ -like 'download-*' } {
        $dest = Join-Path $Work ("dl-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.bin')
        $payload = "$Work\srv\payload.bin"
        $url = if ($Case -eq 'download-norange') { "$UrlNoRange/payload.bin" } else { "$UrlRange/payload.bin" }
        if ($Case -ne 'download-fresh') {
            # Start from a partial file holding the first 3,000,000 bytes
            $buffer = New-Object byte[] 3000000
            $in = [System.IO.File]::OpenRead($payload)
            [void]$in.Read($buffer, 0, $buffer.Length)
            $in.Close()
            [System.IO.File]::WriteAllBytes($dest, $buffer)
        }
        $ok = Download-WithResume -Url $url -Dest $dest -ExpSize (Get-Item $payload).Length
        $same = (Test-Path $dest) -and ((Get-Sha $dest) -eq (Get-Sha $payload))
        Write-Host "RESULT ok=$ok identical=$same"
    }
    'format-vhd' {
        $vhd = "$Work\test.vhdx"
        $disk = Get-Disk | Where-Object { $_.Location -eq $vhd }
        if (-not $disk -or $disk.BusType -ne 'File Backed Virtual') { Write-Host 'RESULT aborted: test VHD not found'; exit 2 }
        $letter = Format-UsbDrive -Disk $disk
        $after = Get-Disk -Number $disk.Number
        $vol = Get-Volume -DriveLetter $letter.TrimEnd(':')
        $part = Get-Partition -DiskNumber $disk.Number | Select-Object -First 1
        Write-Host "RESULT style=$($after.PartitionStyle) fs=$($vol.FileSystem) active=$($part.IsActive)"
    }
    default { Write-Host "RESULT unknown case $Case"; exit 3 }
}
