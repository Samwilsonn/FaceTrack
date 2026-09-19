[CmdletBinding()]
param([switch]$NoAutoStart)
$ErrorActionPreference = 'Stop'
$install = Join-Path $env:LOCALAPPDATA 'FacePull\USB'
New-Item -ItemType Directory -Force -Path $install | Out-Null
foreach ($name in @('FacePullBridge.cs','Run-Bridge.ps1','Start-USB.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $install $name) -Force
}
$service = Get-Service -Name 'Apple Mobile Device Service' -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Warning 'Apple Mobile Device Service is not installed; bridge listeners can still start offline.'
} elseif ($service.Status -ne 'Running') {
    Write-Warning "Apple Mobile Device Service is $($service.Status); bridge listeners will recover when the service/device becomes available."
}
if (-not $NoAutoStart) {
    $startup = [Environment]::GetFolderPath('Startup')
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut((Join-Path $startup 'FacePull USB.lnk'))
    $link.TargetPath = (Get-Command powershell.exe).Source
    $link.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $install 'Start-USB.ps1')`""
    $link.WindowStyle = 7
    $link.Save()
}
& (Join-Path $install 'Start-USB.ps1')
Write-Host 'Setup complete. Bridge listeners are ready; phone connectivity may become available later.'
Write-Host 'Copy the USB URL from FacePull Settings > Connect into OBS once.'

