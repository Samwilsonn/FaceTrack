param(
    [Parameter(Mandatory = $true)][string]$Url,
    [ValidateRange(1, 120)][int]$DurationSeconds = 15
)

# Opens an additional video-only RTSP client. Does not change OBS or the phone.
# No URL, token, image, or packet payload is included in the JSON report.
$ErrorActionPreference = 'Stop'
$client = $null
$wire = $null

function Read-Bytes([int]$Count) {
    $bytes = New-Object byte[] $Count
    $offset = 0
    while ($offset -lt $Count) {
        $read = $wire.Read($bytes, $offset, $Count - $offset)
        if ($read -eq 0) { throw 'The stream closed before the measurement completed.' }
        $offset += $read
    }
    return ,$bytes
}

function Send-Request([string]$Method, [string]$Target, [string]$Extra = '') {
    $script:cseq++
    $request = "$Method $Target RTSP/1.0`r`nCSeq: $script:cseq`r`nUser-Agent: FacePull-Probe`r`n${Extra}`r`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($request)
    $wire.Write($bytes, 0, $bytes.Length)
    while ($true) {
        $first = Read-Bytes 1
        if ($first[0] -ne 36) { break }
        $interleaved = Read-Bytes 3
        $null = Read-Bytes ([int]$interleaved[1] * 256 + $interleaved[2])
    }
    $header = [Text.StringBuilder]::new()
    $null = $header.Append([char]$first[0])
    while (-not $header.ToString().EndsWith("`r`n`r`n")) {
        if ($header.Length -ge 16384) { throw 'Oversized RTSP response.' }
        $part = Read-Bytes 1
        $null = $header.Append([char]$part[0])
    }
    $text = $header.ToString()
    if ($text -notmatch '^RTSP/1\.0 200 ') { throw 'RTSP request failed. Check the current URL and start the phone stream.' }
    $body = ''
    if ($text -match '(?im)^Content-Length:\s*(\d+)') {
        $length = [int]$Matches[1]
        if ($length -gt 65536) { throw 'Oversized RTSP description.' }
        $body = [Text.Encoding]::UTF8.GetString((Read-Bytes $length))
    }
    return @{ Header = $text; Body = $body }
}

try {
    $address = [Uri]$Url
    if ($address.Scheme -ne 'rtsp' -or [string]::IsNullOrWhiteSpace($address.Host)) {
        throw 'Provide the full RTSP URL copied from FacePull Connect.'
    }
    $port = if ($address.Port -gt 0) { $address.Port } else { 554 }
    $client = [Net.Sockets.TcpClient]::new()
    $client.NoDelay = $true
    $connect = $client.ConnectAsync($address.Host, $port)
    if (-not $connect.Wait(5000)) { throw 'Connection timed out. Check Wi-Fi or the USB bridge.' }
    $wire = $client.GetStream()
    $wire.ReadTimeout = 5000
    $wire.WriteTimeout = 5000
    $script:cseq = 0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $null = Send-Request 'OPTIONS' $Url
    $description = Send-Request 'DESCRIBE' $Url "Accept: application/sdp`r`n"
    $tracks = @($description.Body -split "`r`n" | Where-Object { $_ -like 'm=*' })
    if ($tracks.Count -ne 1 -or $tracks[0] -notlike 'm=video *') {
        throw 'Expected the current video-only FacePull stream.'
    }
    $control = @($description.Body -split "`r`n" | Where-Object { $_ -like 'a=control:rtsp://*' })
    if ($control.Count -ne 1) { throw 'Missing video track URL.' }
    $setup = Send-Request 'SETUP' $control[0].Substring(10) "Transport: RTP/AVP/TCP;unicast;interleaved=0-1`r`n"
    if ($setup.Header -notmatch '(?im)^Session:\s*([^;\r\n]+)') { throw 'Missing RTSP session.' }
    $session = $Matches[1].Trim()
    $null = Send-Request 'PLAY' $Url "Session: $session`r`n"
    $firstArrival = $null
    $lastStamp = $null
    $sourceElapsed = 0.0
    $minOffset = 0.0
    $maxGrowth = 0.0
    $lastGrowth = 0.0
    $frames = 0
    $bytesReceived = 0L
    $keyframes = 0
    $isKeyframe = $false
    $previousSequence = $null
    $sequenceGaps = 0
    while ($null -eq $firstArrival -or $clock.Elapsed.TotalSeconds - $firstArrival -lt $DurationSeconds) {
        $prefix = Read-Bytes 4
        if ($prefix[0] -ne 36) { throw 'Unexpected data in interleaved RTSP stream.' }
        $length = [int]$prefix[2] * 256 + $prefix[3]
        $packet = Read-Bytes $length
        $bytesReceived += $length + 4
        if ($prefix[1] -ne 0 -or $length -lt 13) { continue }
        if (($packet[0] -band 192) -ne 128) { throw 'Invalid RTP version.' }
        $sequence = [int]$packet[2] * 256 + $packet[3]
        if ($null -ne $previousSequence -and $sequence -ne (($previousSequence + 1) % 65536)) { $sequenceGaps++ }
        $previousSequence = $sequence
        $payload = 12 + 4 * ($packet[0] -band 15)
        if (($packet[0] -band 16) -ne 0) {
            if ($length -lt $payload + 4) { throw 'Invalid RTP extension.' }
            $payload += 4 + 4 * ([int]$packet[$payload + 2] * 256 + $packet[$payload + 3])
        }
        if ($payload -ge $length) { throw 'Empty RTP payload.' }
        $kind = $packet[$payload] -band 31
        if ($kind -eq 5 -or ($kind -eq 28 -and $payload + 1 -lt $length -and ($packet[$payload + 1] -band 31) -eq 5)) { $isKeyframe = $true }
        if (($packet[1] -band 128) -eq 0) { continue }
        $stamp = [long]$packet[4] * 16777216 + [long]$packet[5] * 65536 + [long]$packet[6] * 256 + $packet[7]
        $now = $clock.Elapsed.TotalSeconds
        if ($null -eq $firstArrival) { $firstArrival = $now }
        if ($null -ne $lastStamp) {
            $delta = ($stamp - $lastStamp + 4294967296L) % 4294967296L
            if ($delta -ge 2147483648L) { throw 'RTP timestamps moved backwards.' }
            $sourceElapsed += $delta / 90000.0
        }
        $lastStamp = $stamp
        $offset = $now - $firstArrival - $sourceElapsed
        $minOffset = [Math]::Min($minOffset, $offset)
        $lastGrowth = [Math]::Max(0.0, $offset - $minOffset)
        $maxGrowth = [Math]::Max($maxGrowth, $lastGrowth)
        Write-Verbose ('RTP timestamp={0} sourceSeconds={1:F3} arrivalSeconds={2:F3} addedDelaySeconds={3:F3}' -f $stamp, $sourceElapsed, ($now - $firstArrival), $lastGrowth)
        $frames++
        if ($isKeyframe) { $keyframes++ }
        $isKeyframe = $false
    }
    $elapsed = $clock.Elapsed.TotalSeconds - $firstArrival
    [ordered]@{
        observationSeconds = [Math]::Round($elapsed, 2)
        frames = $frames
        receivedFPS = [Math]::Round(($frames - 1) / [Math]::Max($elapsed, 0.001), 2)
        startupToFirstFrameMs = [Math]::Round($firstArrival * 1000, 1)
        additionalArrivalDelayMs = [Math]::Round($lastGrowth * 1000, 1)
        peakAdditionalArrivalDelayMs = [Math]::Round($maxGrowth * 1000, 1)
        receivedMbps = [Math]::Round($bytesReceived * 8 / [Math]::Max($elapsed, 0.001) / 1000000, 2)
        keyframes = $keyframes
        rtpSequenceDiscontinuities = $sequenceGaps
        headersInSDP = $description.Body.Contains('sprop-parameter-sets=')
        limitation = 'Relative arrival drift only; does not measure constant network delay, decoding, or OBS display latency. This probe adds one viewer.'
    } | ConvertTo-Json
} catch {
    # Do not print the supplied token-bearing URL in exception details.
    Write-Error 'Stream measurement failed. Verify the current FacePull URL, running stream, network access, and available viewer slots.'
    exit 1
} finally {
    if ($null -ne $wire) { $wire.Dispose() }
    if ($null -ne $client) { $client.Dispose() }
}
