# Task 7 CLI 子命令测试：mark/list/set-default(备份+漂移)/add/rm/损坏防护/分发
. (Join-Path $PSScriptRoot 'assert.ps1')
Import-Module (Join-Path $PSScriptRoot '..\bin\ccx-core.psm1') -Force

$testHome = Join-Path ([IO.Path]::GetTempPath()) ('ccx-t7-' + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force $testHome | Out-Null
$env:CCX_HOME = $testHome
try {
    $reg = @{
        schema   = 1
        models   = @{ glm = @{ vendor = 'bigmodel'; label = '智谱 GLM' } }
        accounts = @(
            @{ id = 'glm-1'; label = '智谱1'; vendor = 'bigmodel'; priority = 1; enabled = $true; base_url = 'https://big.example/api/anthropic'; auth_token = 'tok-1'; env = @{ ANTHROPIC_MODEL = 'glm-5.3[1M]' } }
            @{ id = 'glm-2'; label = '智谱2'; vendor = 'bigmodel'; priority = 2; enabled = $true; base_url = 'https://big.example/api/anthropic'; auth_token = 'tok-2'; env = @{ ANTHROPIC_MODEL = 'glm-5.3[1M]' } }
        )
    }
    Save-CcxJson -Path (Join-Path $testHome 'registry.json') -Data $reg

    # settings fixture（含非 env 节）
    $fxPath = Join-Path $testHome 'settings.json'
    $fx = @{
        permissions   = @{ allow = @('Bash(git status:*)'); deny = @() }
        enabledPlugins = @{ 'llm-cost@claude-tools' = $true }
        env           = @{
            CLAUDE_CODE_EFFORT_LEVEL = 'max'
            ANTHROPIC_BASE_URL       = 'https://old.example'
            ANTHROPIC_AUTH_TOKEN     = 'old-token'
        }
    }
    [IO.File]::WriteAllText($fxPath, (ConvertTo-Json -Depth 10 -InputObject $fx), [Text.UTF8Encoding]::new($false))
    $env:CCX_SETTINGS_PATH = $fxPath

    # ① mark → state 生效 + list 可见
    Invoke-CcxMark -Id 'glm-1' -Status 'daily'
    Assert-Equal 'daily' (Read-CcxState)['accounts']['glm-1']['status'] 'mark 落 state'
    $listOut = Invoke-CcxList
    Assert-True ($listOut -like '*glm-1*daily*') 'list 面板可见 daily'
    Assert-True ($listOut -like '*glm-2*ok*') 'list 面板可见 ok'
    Assert-Throws { Invoke-CcxMark -Id 'glm-1' -Status 'bad' } '非法状态必须拒' -Like '*未知状态*'
    Assert-Throws { Invoke-CcxMark -Id 'zzz' -Status 'daily' } '未知号必须拒' -Like '*不存在*'

    # ② set-default：备份 + env 覆盖 + 非 env 节原样 + 默认号记录
    Invoke-CcxSetDefault -Id 'glm-2'
    Assert-True (@(Get-ChildItem $testHome -Filter 'settings.json.bak-ccx-*').Count -ge 1) '备份存在'
    $back = Read-CcxJson -Path $fxPath
    Assert-Equal 'tok-2' $back['env']['ANTHROPIC_AUTH_TOKEN'] 'token 已同步'
    Assert-Equal 'https://big.example/api/anthropic' $back['env']['ANTHROPIC_BASE_URL'] 'base_url 已同步'
    Assert-Equal 'glm-5.3[1M]' $back['env']['ANTHROPIC_MODEL'] '账号 env 键并入'
    Assert-Equal 'max' $back['env']['CLAUDE_CODE_EFFORT_LEVEL'] 'EFFORT_LEVEL 原值存活'
    Assert-Equal 'Bash(git status:*)' $back['permissions']['allow'][0] 'permissions 原样'
    Assert-Equal $true $back['enabledPlugins']['llm-cost@claude-tools'] 'enabledPlugins 原样'
    Assert-Equal 'glm-2' (Read-CcxRegistry)['default_account'] 'registry 记默认号'
    Assert-Equal 0 @(Get-ChildItem $testHome -Filter '*.tmp').Count 'set-default 原子写无 tmp 残留'

    # 同步后无漂移提示；手改 token 后出现漂移提示
    $listSync = Invoke-CcxList
    Assert-True (-not ($listSync -like '*快照*')) '同步后无漂移提示'
    $fx2 = Read-CcxJson -Path $fxPath
    $fx2['env']['ANTHROPIC_AUTH_TOKEN'] = 'drift-token'
    [IO.File]::WriteAllText($fxPath, (ConvertTo-Json -Depth 10 -InputObject $fx2), [Text.UTF8Encoding]::new($false))
    Assert-True ((Invoke-CcxList) -like '*快照*glm-2*') '漂移后出现提示'

    # ③ 损坏 settings → 不写、原文未动
    $corruptPath = Join-Path $testHome 'settings-bad.json'
    [IO.File]::WriteAllText($corruptPath, '{ not json', [Text.UTF8Encoding]::new($false))
    $bytesBefore = [IO.File]::ReadAllBytes($corruptPath)
    $env:CCX_SETTINGS_PATH = $corruptPath
    Assert-Throws { Invoke-CcxSetDefault -Id 'glm-1' } '损坏 settings 必须明错' -Like '*CCX_E_REGISTRY_CORRUPT*'
    Assert-True (@(Compare-Object ([IO.File]::ReadAllBytes($corruptPath)) $bytesBefore -SyncWindow 0).Count -eq 0) '损坏 settings 原文未动'
    $env:CCX_SETTINGS_PATH = $fxPath

    # ④ add：-Answers 注入 → schema 断言
    $answers = @{ label = '新号'; vendor = 'bigmodel'; base_url = 'https://new2.example/api/anthropic'; token = 'tok-new'; model = 'glm-5.3[1M]' }
    $newId = Invoke-CcxAdd -Answers $answers
    Assert-True ($newId -like 'bigmodel-*') '新 id 前缀 vendor'
    $reg2 = Read-CcxRegistry
    $newAcc = @($reg2['accounts'] | Where-Object { $_['id'] -eq $newId })[0]
    foreach ($k in @('id','label','vendor','base_url','auth_token','env','priority','reset_time','enabled')) {
        Assert-True ($newAcc.Contains($k)) ('add 产物缺字段: ' + $k)
    }
    Assert-Equal 'tok-new' $newAcc['auth_token'] 'add token 落 registry'
    Assert-Equal 'glm-5.3[1M]' $newAcc['env']['ANTHROPIC_MODEL'] 'MODEL 键=全名'
    Assert-Equal $true $newAcc['enabled'] 'add 默认 enabled'
    Assert-Equal '00:00' $newAcc['reset_time'] 'add 默认 reset_time'
    $hasNonAnthropic = @($newAcc['env'].Keys | Where-Object { $_ -notlike 'ANTHROPIC_*' }).Count -gt 0
    Assert-True (-not $hasNonAnthropic) 'env 只含 ANTHROPIC_*'

    # ⑤ rm：删号 + 清 state + 清默认
    Set-CcxAccountStatus -Id 'glm-1' -Status 'r429'
    $reg2['default_account'] = 'glm-1'
    Save-CcxJson -Path (Join-Path $testHome 'registry.json') -Data $reg2
    Invoke-CcxRm -Id 'glm-1'
    $reg3 = Read-CcxRegistry
    Assert-Equal 0 @($reg3['accounts'] | Where-Object { $_['id'] -eq 'glm-1' }).Count 'rm 后号消失'
    Assert-True (-not $reg3.Contains('default_account')) 'rm 默认号后清除'
    Assert-True (-not (Read-CcxState)['accounts'].Contains('glm-1')) 'rm 后 state 清理'

    # ⑥ 分发子进程：list exit 0；mark 未知号 exit 1
    $ccx = Join-Path $PSScriptRoot '..\bin\ccx.ps1'
    $outL = Join-Path $testHome 'outL.txt'; $errL = Join-Path $testHome 'errL.txt'
    $pL = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ccx,'list') -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outL -RedirectStandardError $errL
    Assert-Equal 0 $pL.ExitCode 'ccx list 退出码 0'
    Assert-True ((Get-Content $outL -Raw -Encoding UTF8) -like '*glm-2*') 'ccx list 输出含号'

    $outM = Join-Path $testHome 'outM.txt'; $errM = Join-Path $testHome 'errM.txt'
    $pM = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ccx,'mark','zzz','daily') -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outM -RedirectStandardError $errM
    Assert-Equal 1 $pM.ExitCode 'ccx mark 未知号退出码 1'
    Assert-True ((Get-Content $outM -Raw -Encoding UTF8) -like '*不存在*') 'ccx mark 报错可见'
} finally {
    Remove-Item -Recurse -Force $testHome -ErrorAction SilentlyContinue
    Remove-Module ccx-core -ErrorAction SilentlyContinue
}
Write-Output 'test_cli OK'
