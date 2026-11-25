# Task 6 env 合并测试：settings ⊕ 账号 env 后写胜、ID/LABEL 注入、临时文件无 BOM、陈旧清理
. (Join-Path $PSScriptRoot 'assert.ps1')
Import-Module (Join-Path $PSScriptRoot '..\bin\ccx-core.psm1') -Force

$testHome = Join-Path ([IO.Path]::GetTempPath()) ('ccx-t6-' + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force $testHome | Out-Null
$env:CCX_HOME = $testHome
$realTemp = $env:TEMP
try {
    # ① settings fixture ⊕ 账号 env
    $fx = Join-Path $testHome 'settings.json'
    $fxData = @{ env = @{
        ANTHROPIC_BASE_URL    = 'https://old.example'
        ANTHROPIC_AUTH_TOKEN  = 'old-token'
        CLAUDE_CODE_EFFORT_LEVEL = 'max'
        ENABLE_TOOL_SEARCH    = '1'
    } }
    [IO.File]::WriteAllText($fx, (ConvertTo-Json -Depth 5 -InputObject $fxData), [Text.UTF8Encoding]::new($false))
    $env:CCX_SETTINGS_PATH = $fx

    $acc = @{ id = 'glm-1'; label = '智谱1'; env = @{
        ANTHROPIC_BASE_URL   = 'https://new.example'
        ANTHROPIC_AUTH_TOKEN = 'acc-token'
        ANTHROPIC_MODEL      = 'glm-5.3[1M]'
    } }
    $m = Merge-CcxEnv -Account $acc
    Assert-Equal 'max' $m['CLAUDE_CODE_EFFORT_LEVEL'] '非账号键存活 EFFORT_LEVEL'
    Assert-Equal '1' $m['ENABLE_TOOL_SEARCH'] '非账号键存活 TOOL_SEARCH'
    Assert-Equal 'https://new.example' $m['ANTHROPIC_BASE_URL'] '账号键覆盖 BASE_URL'
    Assert-Equal 'acc-token' $m['ANTHROPIC_AUTH_TOKEN'] '账号键覆盖 TOKEN'
    Assert-Equal 'glm-5.3[1M]' $m['ANTHROPIC_MODEL'] '账号 env 全量并入'
    Assert-Equal 'glm-1' $m['CCX_ACCOUNT_ID'] 'CCX_ACCOUNT_ID 注入'
    Assert-Equal '智谱1' $m['CCX_ACCOUNT_LABEL'] 'CCX_ACCOUNT_LABEL 注入'

    # 顶层 base_url/auth_token（spec §4 形态）必须注入 env 键——settings 旧值不得漏出
    $accBare = @{ id = 'glm-9'; label = '裸号'; base_url = 'https://bare.example'; auth_token = 'bare-token'; env = @{ ANTHROPIC_MODEL = 'glm-5.3[1M]' } }
    $m2 = Merge-CcxEnv -Account $accBare
    Assert-Equal 'https://bare.example' $m2['ANTHROPIC_BASE_URL'] '顶层 base_url 注入'
    Assert-Equal 'bare-token' $m2['ANTHROPIC_AUTH_TOKEN'] '顶层 auth_token 注入'

    # ②③ 临时文件：无 BOM、内容可回读、陈旧清理
    $env:TEMP = $testHome
    $stale = Join-Path $testHome 'ccx-settings-stale.json'
    [IO.File]::WriteAllText($stale, '{}', [Text.UTF8Encoding]::new($false))
    (Get-Item $stale).LastWriteTime = (Get-Date).AddHours(-2)

    $p = Write-CcxTempSettings -Env $m
    Assert-True ($p -like ('*ccx-settings-' + $PID + '.json')) '临时文件名含 pid'
    $b = [IO.File]::ReadAllBytes($p)
    Assert-True (-not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) '临时 settings 无 BOM'
    $back = Read-CcxJson -Path $p
    Assert-Equal 'acc-token' $back['env']['ANTHROPIC_AUTH_TOKEN'] '临时文件 env 可回读'
    Assert-Equal 'glm-1' $back['env']['CCX_ACCOUNT_ID'] '临时文件含 ID'
    Assert-True (-not (Test-Path $stale)) '陈旧(>1h)文件被清'
    Assert-True (Test-Path $p) '新文件留存'

    Remove-CcxTempSettings -Path $p
    Assert-True (-not (Test-Path $p)) 'Remove 删除临时文件'
} finally {
    $env:TEMP = $realTemp
    Remove-Item -Recurse -Force $testHome -ErrorAction SilentlyContinue
    Remove-Module ccx-core -ErrorAction SilentlyContinue
}
Write-Output 'test_envmerge OK'
