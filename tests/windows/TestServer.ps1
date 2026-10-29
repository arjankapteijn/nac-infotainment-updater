<#
    Tiny HTTP server for the download tests, on a raw TcpListener so it needs
    no admin rights or URL reservation.

    Serves files from -Root. With -NoRange it ignores Range headers and always
    answers 200 with the whole file, like majestic-web.mpsa.com sometimes does.
#>
param([string]$Root, [int]$Port, [switch]$NoRange)

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()

while ($true) {
    # Poll instead of blocking in AcceptTcpClient(): Stop-Job can't interrupt a
    # blocking .NET call, which made the cleanup hang for minutes.
    while (-not $listener.Pending()) { Start-Sleep -Milliseconds 50 }
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 4096, $true)
        $requestLine = $reader.ReadLine()
        $range = $null
        while (($line = $reader.ReadLine()) -ne $null -and $line -ne '') {
            if ($line -match '^Range:\s*bytes=(\d+)-') { $range = [long]$Matches[1] }
        }

        $name = [System.IO.Path]::GetFileName(($requestLine -split ' ')[1].Split('?')[0])
        $path = Join-Path $Root $name
        $writer = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::ASCII, 4096, $true)
        $writer.NewLine = "`r`n"

        if (-not (Test-Path $path -PathType Leaf)) {
            $writer.WriteLine('HTTP/1.1 404 Not Found'); $writer.WriteLine('Content-Length: 0'); $writer.WriteLine('Connection: close'); $writer.WriteLine(); $writer.Flush()
            continue
        }

        $size = (Get-Item $path).Length
        $start = 0
        if ($range -ne $null -and -not $NoRange) {
            $start = $range
            $writer.WriteLine('HTTP/1.1 206 Partial Content')
            $writer.WriteLine("Content-Range: bytes $start-$($size - 1)/$size")
        } else {
            $writer.WriteLine('HTTP/1.1 200 OK')
        }
        $writer.WriteLine('Accept-Ranges: bytes')
        $writer.WriteLine("Content-Length: $($size - $start)")
        $writer.WriteLine('Connection: close')
        $writer.WriteLine()
        $writer.Flush()

        $file = [System.IO.File]::OpenRead($path)
        try {
            [void]$file.Seek($start, 'Begin')
            $file.CopyTo($stream)
        } finally {
            $file.Close()
        }
    } catch {
        # Client gave up mid-transfer; nothing to do.
    } finally {
        $client.Close()
    }
}
