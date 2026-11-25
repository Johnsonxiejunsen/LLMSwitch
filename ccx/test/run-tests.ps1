# ccx 测试入口 — 每个测试文件独立子进程运行，汇总 PASS/FAIL；任一失败退出码 1
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$testDir = $PSScriptRoot
$tests = @(Get-ChildItem -Path $testDir -Filter 'test_*.ps1' | Sort-Object Name)
if ($tests.Count -eq 0) { Write-Output 'no tests found'; exit 1 }

$failed = 0
foreach ($t in $tests) {
    $outFile = Join-Path $env:TEMP ($t.BaseName + '.ccxtest.out')
    $errFile = Join-Path $env:TEMP ($t.BaseName + '.ccxtest.err')
    $p = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $t.FullName) `
        -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $ok = ($p.ExitCode -eq 0)
    if (-not $ok) {
        $failed++
        Write-Output ("FAIL  {0}  (exit {1})" -f $t.Name, $p.ExitCode)
        foreach ($f in @($errFile, $outFile)) {
            if ((Test-Path $f) -and ((Get-Item $f).Length -gt 0)) {
                Write-Output ("  --- {0} (tail) ---" -f (Split-Path $f -Leaf))
                Get-Content $f -Tail 12 -Encoding UTF8 | ForEach-Object { Write-Output ("  " + $_) }
            }
        }
    } else {
        Write-Output ("PASS  {0}" -f $t.Name)
    }
}

Write-Output ("total: {0}, failed: {1}" -f $tests.Count, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
