# Task 11 卫生门测试：ccx/ 全树零 token 泄漏 + 探针自证检测器活着 + 仓集成件存在
. (Join-Path $PSScriptRoot 'assert.ps1')

$ccxRoot = Join-Path $PSScriptRoot '..'
try {
    # 检测器自证：植入假 token 必须被命中（运行时拼接，源文件本身不含完整形态，防自扫描命中）
    $plant = Join-Path $PSScriptRoot '_hygiene_plant.txt'
    $fake = 'sk-' + 'abcdefghijklmnopqrstuvwxyz1234'
    [IO.File]::WriteAllText($plant, $fake, [Text.UTF8Encoding]::new($false))
    $plantHit = $false
    foreach ($f in @(Get-ChildItem $PSScriptRoot -Filter '_hygiene_plant.txt')) {
        $c = [IO.File]::ReadAllText($f.FullName)
        if ($c -match '(?i)(sk-[a-z0-9]{20,}|Bearer [A-Za-z0-9._-]{20,}|\b[0-9a-f]{32}\.[A-Za-z0-9]{16}\b)') { $plantHit = $true }
    }
    Remove-Item $plant -Force
    Assert-True $plantHit '检测器必须能命中植入的假 token'

    # 正门：ccx/ 全树扫描，零命中
    $hits = @()
    foreach ($f in @(Get-ChildItem $ccxRoot -Recurse -File)) {
        # 跳过二进制/超大文件（当前仓 ccx/ 全是文本，防御性跳过）
        if ($f.Length -gt 1MB) { continue }
        $c = $null
        try { $c = [IO.File]::ReadAllText($f.FullName) } catch { continue }
        if ($c -match '(?i)(sk-[a-z0-9]{20,}|Bearer [A-Za-z0-9._-]{20,}|\b[0-9a-f]{32}\.[A-Za-z0-9]{16}\b)') {
            $hits += $f.FullName
        }
    }
    Assert-Equal 0 $hits.Count ('token 卫生门被击穿: ' + ($hits -join ', '))

    # 仓集成件：marketplace 条目 + README
    $mp = Get-Content (Join-Path $ccxRoot '..\.claude-plugin\marketplace.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $entry = @($mp.plugins | Where-Object { $_.name -eq 'ccx' })
    Assert-Equal 1 $entry.Count 'marketplace 含 ccx 条目'
    Assert-Equal './ccx' $entry[0].source 'ccx 条目 source=./ccx'
    $readme = Join-Path $ccxRoot 'README.md'
    Assert-True (Test-Path $readme) 'README 存在'
    $rm = Get-Content $readme -Raw -Encoding UTF8
    Assert-True ($rm -like '*install*' -or $rm -like '*安装*') 'README 含安装步骤'
} finally {
    Remove-Item (Join-Path $PSScriptRoot '_hygiene_plant.txt') -Force -ErrorAction SilentlyContinue
}
Write-Output 'test_hygiene OK'
