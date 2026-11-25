# Task 8 启动路径测试：接力全链→透传 --settings、-p 无 Read-Host、全死面板、损坏模板、临时文件清理
. (Join-Path $PSScriptRoot 'assert.ps1')
Import-Module (Join-Path $PSScriptRoot '..\bin\ccx-core.psm1') -Force

$testHome = Join-Path ([IO.Path]::GetTempPath()) ('ccx-t8-' + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force $testHome | Out-Null
$env:CCX_HOME = $testHome
$env:CCX_FAKE_LOG = Join-Path $testHome 'fake-log.txt'
$env:CCX_FAKE_SNAPSHOT = Join-Path $testHome 'fake-snapshot.json'
$env:CCX_CLAUDE_CMD = Join-Path $PSScriptRoot 'fake_claude.ps1'
try {
    # settings fixture（Merge-CcxEnv 基底）
    $fxPath = Join-Path $testHome 'settings.json'
    [IO.File]::WriteAllText($fxPath, '{"env":{"CLAUDE_CODE_EFFORT_LEVEL":"max","ANTHROPIC_BASE_URL":"https://old.example","ANTHROPIC_AUTH_TOKEN":"old"}}', [Text.UTF8Encoding]::new($false))
    $env:CCX_SETTINGS_PATH = $fxPath

    # ① 预检接力全链：glm-1 死 token(401) → glm-2
    $reg1 = @{
        schema   = 1
        models   = @{ glm = @{ vendor = 'bigmodel'; label = '智谱 GLM' } }
        accounts = @(
            @{ id = 'glm-1'; label = '智谱1'; vendor = 'bigmodel'; priority = 1; enabled = $true; base_url = 'https://big.example/api/anthropic'; auth_token = 'dead-token'; env = @{ ANTHROPIC_MODEL = 'glm-5.3[1M]' } }
            @{ id = 'glm-2'; label = '智谱2'; vendor = 'bigmodel'; priority = 2; enabled = $true; base_url = 'https://big.example/api/anthropic'; auth_token = 'ok-token'; env = @{ ANTHROPIC_MODEL = 'glm-5.3[1M]' } }
        )
    }
    Save-CcxJson -Path (Join-Path $testHome 'registry.json') -Data $reg1
    $probe1 = { param($Account) if ($Account['id'] -eq 'glm-1') { @{ Status = 401; Body = 'unauth'; NetworkError = $false } } else { @{ Status = 200; Body = 'ok'; NetworkError = $false } } }
    Invoke-CcxLaunch -ModelSpec 'glm' -Passthrough @() -Probe $probe1
    Assert-True (Test-Path $env:CCX_FAKE_LOG) 'fake 收到调用'
    $logLines = Get-Content $env:CCX_FAKE_LOG -Encoding UTF8
    Assert-True (@($logLines | Where-Object { $_ -eq '--settings' }).Count -eq 1) '透传 --settings'
    Assert-Equal 'blocked' (Read-CcxState)['accounts']['glm-1']['status'] '接力中 glm-1 已标 blocked'
    Assert-True (Test-Path $env:CCX_FAKE_SNAPSHOT) 'fake 快照了 settings'
    $snap = Read-CcxJson -Path $env:CCX_FAKE_SNAPSHOT
    Assert-Equal 'ok-token' $snap['env']['ANTHROPIC_AUTH_TOKEN'] '临时 settings token=ok 号'
    Assert-Equal 'glm-2' $snap['env']['CCX_ACCOUNT_ID'] '临时 settings 含正确 ID'
    Assert-Equal 'max' $snap['env']['CLAUDE_CODE_EFFORT_LEVEL'] '非账号键经合并存活'
    $tmpArgIdx = [array]::IndexOf($logLines, '--settings')
    $tmpPath = $logLines[$tmpArgIdx + 1]
    Assert-True (-not (Test-Path $tmpPath)) '④ fake 返回后临时文件已删'

    # ② -p + 无 ModelSpec + 双 vendor → 不 Read-Host、落 default 组
    $reg2 = @{
        schema   = 1
        models   = @{ glm = @{ vendor = 'bigmodel'; label = '智谱 GLM' }; kimi = @{ vendor = 'moonshot'; label = 'Kimi' } }
        accounts = @(
            @{ id = 'glm-1'; label = '智谱1'; vendor = 'bigmodel'; priority = 1; enabled = $true; base_url = 'https://b.example'; auth_token = 'g1'; env = @{} }
            @{ id = 'glm-2'; label = '智谱2'; vendor = 'bigmodel'; priority = 2; enabled = $true; base_url = 'https://b.example'; auth_token = 'g2'; env = @{} }
            @{ id = 'kimi-1'; label = 'K1'; vendor = 'moonshot'; priority = 1; enabled = $true; base_url = 'https://m.example'; auth_token = 'k1'; env = @{} }
        )
        default_account = 'glm-2'
    }
    Save-CcxJson -Path (Join-Path $testHome 'registry.json') -Data $reg2
    $probe2 = { param($Account) @{ Status = 200; Body = 'ok'; NetworkError = $false } }
    Invoke-CcxLaunch -ModelSpec '' -Passthrough @('-p', 'hi') -Probe $probe2
    $log2 = Get-Content $env:CCX_FAKE_LOG -Encoding UTF8
    Assert-True (@($log2 | Where-Object { $_ -eq '-p' }).Count -eq 1) '-p 原样透传'
    $snap2 = Read-CcxJson -Path $env:CCX_FAKE_SNAPSHOT
    Assert-True ($snap2['env']['CCX_ACCOUNT_ID'] -like 'glm-*') '-p 落 default 组(bigmodel)'
    Assert-True ($snap2['env']['CCX_ACCOUNT_ID'] -ne 'kimi-1') '未落 moonshot'

    # 未知模型 → 明错（函数层）
    Assert-Throws { Invoke-CcxLaunch -ModelSpec 'nope' -Passthrough @() -Probe $probe2 } '未知模型必须明错' -Like '*未知模型*'

    # ③ 全死 → 子进程 exit 1 + 面板（无预检：Select 先返回 null）
    $stateAll = @{ schema = 1; accounts = @{
        'glm-1' = @{ status = 'daily'; until = (Get-Date).AddHours(5).ToString('o') }
        'glm-2' = @{ status = 'daily'; until = (Get-Date).AddHours(6).ToString('o') }
    } }
    Save-CcxJson -Path (Join-Path $testHome 'state.json') -Data $stateAll
    Remove-Item $env:CCX_FAKE_LOG -ErrorAction SilentlyContinue
    $ccx = Join-Path $PSScriptRoot '..\bin\ccx.ps1'
    $outA = Join-Path $testHome 'a.out'; $errA = Join-Path $testHome 'a.err'
    $pA = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ccx,'glm') -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outA -RedirectStandardError $errA
    Assert-Equal 1 $pA.ExitCode '全死退出码 1'
    Assert-True ((Get-Content $outA -Raw -Encoding UTF8) -like '*全池不可用*') '全死打印面板'
    Assert-True (-not (Test-Path $env:CCX_FAKE_LOG)) '全死未启动 claude'

    # ⑤ 损坏 registry → 模板文案 + 非零退出
    [IO.File]::WriteAllText((Join-Path $testHome 'registry.json'), '{ bad', [Text.UTF8Encoding]::new($false))
    $outB = Join-Path $testHome 'b.out'; $errB = Join-Path $testHome 'b.err'
    $pB = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ccx,'glm') -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outB -RedirectStandardError $errB
    Assert-Equal 1 $pB.ExitCode '损坏退出码 1'
    $txtB = Get-Content $outB -Raw -Encoding UTF8
    Assert-True ($txtB -like '*号池不可用*') '模板含号池不可用'
    Assert-True ($txtB -like '*裸 claude 不受影响*') '模板含兜底提示'

    # ⑥ 裸 ccx（无参数）→ 直接进启动路径而非 usage（终审#1 回归；probe 指向 127.0.0.1:1 秒拒=网络错不标照启）
    Save-CcxJson -Path (Join-Path $testHome 'registry.json') -Data @{
        schema   = 1
        models   = @{ glm = @{ vendor = 'bigmodel'; label = '智谱 GLM' } }
        accounts = @(
            @{ id = 'glm-1'; label = '智谱1'; vendor = 'bigmodel'; priority = 1; enabled = $true; base_url = 'http://127.0.0.1:1/api'; auth_token = 't1'; env = @{} }
            @{ id = 'glm-2'; label = '智谱2'; vendor = 'bigmodel'; priority = 2; enabled = $true; base_url = 'http://127.0.0.1:1/api'; auth_token = 't2'; env = @{} }
        )
    }
    Remove-Item (Join-Path $testHome 'state.json') -ErrorAction SilentlyContinue
    Remove-Item $env:CCX_FAKE_LOG -ErrorAction SilentlyContinue
    $outC = Join-Path $testHome 'c.out'; $errC = Join-Path $testHome 'c.err'
    $pC = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ccx) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outC -RedirectStandardError $errC
    $txtC = Get-Content $outC -Raw -Encoding UTF8
    Assert-Equal 0 $pC.ExitCode '裸 ccx 退出码 0（启动而非 usage）'
    Assert-True ($txtC -notlike '*用法*') '裸 ccx 不打印 usage'
    Assert-True (Test-Path $env:CCX_FAKE_LOG) '裸 ccx 启动了 claude'
    Assert-True (@((Get-Content $env:CCX_FAKE_LOG -Encoding UTF8) | Where-Object { $_ -eq '--settings' }).Count -eq 1) '裸 ccx 透传 --settings'

    # ⑦ 全停用组 + 裸 -p → 友好面板退出 1，不得参数绑定异常（终审#2）
    Save-CcxJson -Path (Join-Path $testHome 'registry.json') -Data @{
        schema = 1; default_account = 'glm-1'
        models = @{ glm = @{ vendor = 'bigmodel'; label = '智谱 GLM' } }
        accounts = @(
            @{ id = 'glm-1'; label = '智谱1'; vendor = 'bigmodel'; priority = 1; enabled = $false; base_url = 'http://127.0.0.1:1/api'; auth_token = 't1'; env = @{} }
        )
    }
    $outD = Join-Path $testHome 'd.out'; $errD = Join-Path $testHome 'd.err'
    $pD = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ccx, '-p') -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outD -RedirectStandardError $errD
    $txtD = Get-Content $outD -Raw -Encoding UTF8
    Assert-Equal 1 $pD.ExitCode '全停用退出码 1'
    Assert-True ($txtD -like '*没有可用账号*') '全停用打印友好面板'
    Assert-True ($txtD -notlike '*Cannot bind*') '不得出现参数绑定异常'

    # ⑧ 裸 ccx 多 vendor（≥2 个可用）→ 交互菜单渲染（含 0 号组护栏，终审#2 姊妹）；-NonInteractive 使 Read-Host 确定性抛错
    Save-CcxJson -Path (Join-Path $testHome 'registry.json') -Data @{
        schema   = 1
        models   = @{ glm = @{ vendor = 'bigmodel'; label = '智谱 GLM' }; kimi = @{ vendor = 'moonshot'; label = 'Kimi' }; qw = @{ vendor = 'qwen'; label = '通义' } }
        accounts = @(
            @{ id = 'glm-1'; label = '智谱1'; vendor = 'bigmodel'; priority = 1; enabled = $false; base_url = 'http://127.0.0.1:1/api'; auth_token = 't1'; env = @{} }
            @{ id = 'kimi-1'; label = 'K1'; vendor = 'moonshot'; priority = 1; enabled = $true; base_url = 'http://127.0.0.1:1/api'; auth_token = 'k2'; env = @{} }
            @{ id = 'qw-1'; label = 'Q1'; vendor = 'qwen'; priority = 1; enabled = $true; base_url = 'http://127.0.0.1:1/api'; auth_token = 'q3'; env = @{} }
        )
    }
    $outE = Join-Path $testHome 'e.out'; $errE = Join-Path $testHome 'e.err'
    $pE = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ccx) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outE -RedirectStandardError $errE
    $txtE = Get-Content $outE -Raw -Encoding UTF8
    Assert-True ($txtE -like '*选择模型组*') '裸 ccx 多 vendor 出菜单'
    Assert-True ($txtE -like '*0 个号*') '0 号组渲染不炸'
    Assert-Equal 1 $pE.ExitCode 'Read-Host 非交互抛错 → 无效选择退 1'
} finally {
    Remove-Item -Recurse -Force $testHome -ErrorAction SilentlyContinue
    Remove-Module ccx-core -ErrorAction SilentlyContinue
}
Write-Output 'test_launch OK'
