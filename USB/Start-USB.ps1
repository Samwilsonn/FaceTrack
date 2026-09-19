[CmdletBinding()]
param([string]$DeviceID = '')
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'Run-Bridge.ps1'
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
$started = @()

function Test-LocalPort {
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $pending = $client.ConnectAsync('127.0.0.1', $Port)
        return $pending.Wait(250) -and $client.Connected
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Test-ExistingFacePullBridge {
    param([int]$LocalPort)
    if (-not (Test-LocalPort $LocalPort)) { return $false }
    $name = "Local\FacePullBridge-$LocalPort"
    try {
        $mutex = [System.Threading.Mutex]::OpenExisting($name)
    } catch [System.Threading.WaitHandleCannotBeOpenedException] {
        return $false
    } catch {
        return $false
    }
    try {
        try {
            if ($mutex.WaitOne(0)) {
                $mutex.ReleaseMutex()
                return $false
            }
            return $true
        } catch [System.Threading.AbandonedMutexException] {
            # WaitOne acquired an abandoned mutex; no live bridge owns it.
            $mutex.ReleaseMutex()
            return $false
        }
    } finally {
        $mutex.Dispose()
    }
}

function Start-ValidatedBridge {
    param([int]$LocalPort, [int]$DevicePort)
    if (Test-LocalPort $LocalPort) {
        if (Test-ExistingFacePullBridge $LocalPort) { return }
        throw "127.0.0.1:$LocalPort is already in use by another process."
    }
    $bridgeArguments = "$arguments -LocalPort $LocalPort -DevicePort $DevicePort"
    $process = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList $bridgeArguments
    $script:started += $process
    $deadline = (Get-Date).AddSeconds(8)
    do {
        if (Test-LocalPort $LocalPort) {
            if (-not $process.HasExited -or (Test-ExistingFacePullBridge $LocalPort)) { return }
        }
        if ($process.HasExited) {
            if (Test-ExistingFacePullBridge $LocalPort) { return }
            throw "FacePull USB bridge for 127.0.0.1:$LocalPort exited with code $($process.ExitCode)."
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw "FacePull USB bridge did not open 127.0.0.1:$LocalPort within 8 seconds."
}

try {
    $service = Get-Service -Name 'Apple Mobile Device Service' -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Warning 'Apple Mobile Device Service is not installed; bridge listeners will start offline.'
    } elseif ($service.Status -ne 'Running') {
        Write-Warning "Apple Mobile Device Service is $($service.Status); bridge listeners will start and recover when the service/device becomes available."
    }
    if ($DeviceID) {
        if ($DeviceID -notmatch '^[A-Za-z0-9-]+$') { throw 'Invalid device ID' }
        $arguments += " -DeviceID $DeviceID"
    }
    Start-ValidatedBridge -LocalPort 18080 -DevicePort 8080
    Start-ValidatedBridge -LocalPort 18554 -DevicePort 8554
} catch {
    foreach ($process in $started) {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
    throw
}
Write-Host 'FacePull USB bridge listeners are ready at 127.0.0.1:18080 and 127.0.0.1:18554.'
Write-Host 'Phone connectivity is lazy: connect/trust the iPhone and start streaming in FacePull when ready.'

