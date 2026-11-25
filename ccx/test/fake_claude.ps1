# fake_claude.ps1 - test fake for CCX_CLAUDE_CMD: records args + snapshots the --settings file.
# NOTE: no `exit` here - this script runs in-process via &, exit would kill the test host.
$lines = @($args | ForEach-Object { [string]$_ })
[System.IO.File]::WriteAllLines($env:CCX_FAKE_LOG, [string[]]$lines)
$settings = $null
for ($i = 0; $i -lt $lines.Count - 1; $i++) {
    if ($lines[$i] -eq '--settings') { $settings = $lines[$i + 1]; break }
}
if ($settings -and (Test-Path $settings)) { [System.IO.File]::Copy($settings, $env:CCX_FAKE_SNAPSHOT, $true) }
