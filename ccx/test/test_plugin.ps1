# Task 9 插件件测试：session-info 三场景恒 exit 0 + 首行文案
. (Join-Path $PSScriptRoot 'assert.ps1')

$testHome = Join-Path ([IO.Path]::GetTempPath()) ('ccx-t9-' + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force $testHome | Out-Null
$env:CCX_HOME = $testHome
$sessionInfo = Join-Path $PSScriptRoot '..\scripts\session-info.ps1'
try {
    Import-Module (Join-Path $PSScriptRoot '..\bin\ccx-core.psm1') -Force
    $reg = @{
        schema   = 1
        models   = @{ glm = @{ vendor = 'bigmodel'; label = '智谱 GLM' } }
        accounts = @(
            @{ id = 'glm-1'; label = '智谱1'; vendor = 'bigmodel'; priority = 1; enabled = $true; base_url = 'https://b.example'; auth_token = 't1'; env = @{} }
            @{ id = 'glm-2'; label = '智谱2'; vendor = 'bigmodel'; priority = 2; enabled = $true; base_url = 'https://b.example'; auth_token = 't2'; env = @{} }
        )
    }
    Save-CcxJson -Path (Join-Path $testHome 'registry.json') -Data $reg
    Set-CcxAccountStatus -Id 'glm-2' -Status 'daily'
    Remove-Module ccx-core -ErrorAction SilentlyContinue

    function Invoke-SessionInfo {
        param([string[]]$CmdEnv = @())
        $out = Join-Path $testHome 'si.out'
        $err = Join-Path $testHome 'si.err'
        Remove-Item $out, $err -ErrorAction SilentlyContinue
        $p = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $sessionInfo) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
        return @{ Code = $p.ExitCode; Out = (Get-Content $out -Raw -Encoding UTF8); Err = (Get-Content $err -Raw -Encoding UTF8) }
    }

    # ①a 有 CCX_ACCOUNT_ID → 首行当前账号 + 面板，exit 0
    $env:CCX_ACCOUNT_ID = 'glm-1'
    $env:CCX_ACCOUNT_LABEL = '智谱1'
    $r1 = Invoke-SessionInfo
    Assert-Equal 0 $r1['Code'] '有号场景 exit 0'
    Assert-True ($r1['Out'] -like '*当前窗口账号: 智谱1(glm-1)*') '首行当前账号'
    Assert-True ($r1['Out'] -like '*glm-2*daily*') '附池面板'

    # ①b 无 CCX_ACCOUNT_ID → 未由 ccx 启动，exit 0
    Remove-Item Env:CCX_ACCOUNT_ID -ErrorAction SilentlyContinue
    Remove-Item Env:CCX_ACCOUNT_LABEL -ErrorAction SilentlyContinue
    $r2 = Invoke-SessionInfo
    Assert-Equal 0 $r2['Code'] '无号场景 exit 0'
    Assert-True ($r2['Out'] -like '*本窗口未由 ccx 启动*') '首行未由 ccx 启动'

    # ② 损坏 registry → 仍 exit 0，首行 + 一句提示
    $env:CCX_ACCOUNT_ID = 'glm-1'
    $env:CCX_ACCOUNT_LABEL = '智谱1'
    [IO.File]::WriteAllText((Join-Path $testHome 'registry.json'), '{ bad', [Text.UTF8Encoding]::new($false))
    $r3 = Invoke-SessionInfo
    Assert-Equal 0 $r3['Code'] '损坏场景 exit 0'
    Assert-True ($r3['Out'] -like '*当前窗口账号: 智谱1(glm-1)*') '损坏场景首行仍在'
    Assert-True ($r3['Out'] -like '*池面板不可用*') '损坏场景一句提示'

    # 插件件存在性 + JSON 合法（无 BOM）
    $pluginJson = Join-Path $PSScriptRoot '..\.claude-plugin\plugin.json'
    $hooksJson = Join-Path $PSScriptRoot '..\hooks\hooks.json'
    Assert-True (Test-Path $pluginJson) 'plugin.json 存在'
    Assert-True (Test-Path $hooksJson) 'hooks.json 存在'
    Assert-True (Test-Path (Join-Path $PSScriptRoot '..\commands\modelx.md')) 'modelx.md 存在'
    $pj = Get-Content $pluginJson -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'ccx' $pj.name 'plugin name=ccx'
    $hj = Get-Content $hooksJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $cmd = $hj.hooks.SessionStart[0].hooks[0].command
    Assert-True ($cmd -like '*session-info.ps1*') 'hooks 指向 session-info'
    Assert-True ($cmd -like '*${CLAUDE_PLUGIN_ROOT}*') 'hooks 用 CLAUDE_PLUGIN_ROOT 变量'
    foreach ($jf in @($pluginJson, $hooksJson)) {
        $b = [IO.File]::ReadAllBytes($jf)
        Assert-True (-not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) 'JSON 无 BOM'
    }
} finally {
    Remove-Item -Recurse -Force $testHome -ErrorAction SilentlyContinue
    Remove-Item Env:CCX_ACCOUNT_ID -ErrorAction SilentlyContinue
    Remove-Item Env:CCX_ACCOUNT_LABEL -ErrorAction SilentlyContinue
}
Write-Output 'test_plugin OK'
