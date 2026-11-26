# §13 版本选择测试：归一化/选项合并(C⊕B)/输入解析/fetch 降级/env 覆盖/启动接线
. (Join-Path $PSScriptRoot 'assert.ps1')
Import-Module (Join-Path $PSScriptRoot '..\bin\ccx-core.psm1') -Force

$testHome = Join-Path ([IO.Path]::GetTempPath()) ('ccx-tv-' + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force $testHome | Out-Null
$env:CCX_HOME = $testHome
try {
    # ① 归一化同基：小写+去尾[..]变体+去非字母数字
    Assert-Equal 'glm54' (ConvertTo-CcxVersionBase -Id 'glm5.4[1M]') 'glm5.4[1M] 归一'
    Assert-Equal 'glm54' (ConvertTo-CcxVersionBase -Id 'glm-5.4') 'glm-5.4 同基'
    Assert-Equal 'claudecode' (ConvertTo-CcxVersionBase -Id 'claude code') '空格剔除'
    Assert-Equal 'glm53flash' (ConvertTo-CcxVersionBase -Id 'glm-5.3-flash') '连字符剔除'
    Assert-Equal 'glm54' (ConvertTo-CcxVersionBase -Id 'GLM5.4[1m]') '大小写不敏感'

    # ② 合并去重（§13 验收场景：C 2 条 + 在线 4 条 → 4 项）
    $node = @{ versions = @('glm5.4[1M]', 'glm-5.3[1M]'); default_version = 'glm5.4[1M]' }
    $opts = Get-CcxVersionOptions -ModelNode $node -Fetched @('glm-5.4', 'glm-5.3', 'glm-5.2', 'glm-4.5')
    Assert-Equal 4 @($opts).Count '同基去重后 4 项'
    Assert-Equal 'glm5.4[1M]' $opts[0]['Id'] '第1项=本地配置序首'
    Assert-Equal $true $opts[0]['IsDefault'] '默认版标注'
    Assert-Equal 'local' $opts[0]['Source'] '来源=local'
    Assert-Equal 'glm-5.3[1M]' $opts[1]['Id'] '第2项=本地'
    Assert-Equal 'local' $opts[1]['Source'] '第2项来源'
    Assert-Equal $false $opts[1]['IsDefault'] '非默认'
    Assert-Equal 'glm-5.2' $opts[2]['Id'] '第3项=在线追加'
    Assert-Equal 'remote' $opts[2]['Source'] '第3项来源'
    Assert-Equal 'glm-4.5' $opts[3]['Id'] '第4项=在线追加'

    # ③ versions_include 过滤在线结果（本地不受过滤影响）
    $node2 = @{ versions = @('glm5.4[1M]'); default_version = 'glm5.4[1M]'; versions_include = 'glm-5' }
    $opts2 = Get-CcxVersionOptions -ModelNode $node2 -Fetched @('glm-5.2', 'glm-4.5')
    Assert-Equal 2 @($opts2).Count 'include 过滤后 2 项'
    Assert-Equal 'glm-5.2' $opts2[1]['Id'] 'glm-5.2 保留'

    # ④ ModelNode 为 null（组未配 versions）→ 全 remote、无默认
    $opts3 = Get-CcxVersionOptions -ModelNode $null -Fetched @('m-a', 'm-b')
    Assert-Equal 2 @($opts3).Count '无配置时在线 2 项'
    Assert-Equal 'remote' $opts3[0]['Source'] '无配置全 remote'
    Assert-Equal $false $opts3[0]['IsDefault'] '无配置无默认'

    # ⑤ 双空 → 0 项（上层跳过菜单）
    Assert-Equal 0 @(Get-CcxVersionOptions -ModelNode $null -Fetched @()).Count '双空 0 项'
    $opts5 = Get-CcxVersionOptions -ModelNode @{ versions = @('x1', 'x2') } -Fetched @()
    Assert-Equal 2 @($opts5).Count '仅本地 2 项'
    Assert-Equal $false $opts5[0]['IsDefault'] '未配 default_version 则无默认'

    # ⑥ versions 对象形式 @{id=..} 与字符串混排
    $nodeO = @{ versions = @(@{ id = 'glm5.4[1M]' }, 'glm-5.3[1M]'); default_version = 'glm-5.3[1M]' }
    $optsO = Get-CcxVersionOptions -ModelNode $nodeO -Fetched @()
    Assert-Equal 'glm5.4[1M]' $optsO[0]['Id'] '对象形式取 id'
    Assert-Equal $true $optsO[1]['IsDefault'] '默认版可为第2项'

    # ⑦ 输入解析：空→默认 / 数字→编号 / 全名原样 / 越界与未知→明错
    Assert-Equal 'glm5.4[1M]' (Resolve-CcxVersionInput -Choice '' -Options $opts) '空输入=默认版'
    Assert-Equal 'glm-5.2' (Resolve-CcxVersionInput -Choice '3' -Options $opts) '编号映射'
    Assert-Equal 'glm-5.3[1M]' (Resolve-CcxVersionInput -Choice 'glm-5.3[1M]' -Options $opts) '全名原样'
    Assert-Throws { Resolve-CcxVersionInput -Choice '9' -Options $opts } '越界编号明错' -Like '*无效版本*'
    Assert-Throws { Resolve-CcxVersionInput -Choice 'nope' -Options $opts } '未知版本明错' -Like '*无效版本*'

    # ⑧ fetch：-Fetcher 缝解析 OpenAI/Anthropic 风 data[].id；异常→空；127.0.0.1:1 真请求→空（秒拒）
    $fakeJson = '{"data":[{"id":"glm-5.4"},{"id":"glm-4.5"}]}'
    $acc = @{ id = 'a'; base_url = 'https://x.example'; auth_token = 't' }
    $viaSeam = Get-CcxRemoteVersions -Account $acc -Fetcher { param($Url, $Headers, $TimeoutSec) $fakeJson }
    Assert-Equal 'glm-5.4' $viaSeam[0] '缝路径解析 id'
    Assert-Equal 2 @($viaSeam).Count '缝路径 2 条'
    Assert-Equal 0 @(Get-CcxRemoteVersions -Account $acc -Fetcher { param($Url, $Headers, $TimeoutSec) throw 'boom' }).Count 'fetch 异常→空'
    $deadAcc = @{ id = 'd'; base_url = 'http://127.0.0.1:1/api'; auth_token = 't' }
    Assert-Equal 0 @(Get-CcxRemoteVersions -Account $deadAcc).Count '真请求秒拒→空'
    Assert-Equal 0 @(Get-CcxRemoteVersions -Account $acc -Fetcher { param($Url, $Headers, $TimeoutSec) 'not json' }).Count '非 JSON→空'

    # ⑨ Merge-CcxEnv -Version 覆盖（§13 规则）
    $fxPath = Join-Path $testHome 'settings.json'
    [IO.File]::WriteAllText($fxPath, '{"env":{"CLAUDE_CODE_EFFORT_LEVEL":"max","ANTHROPIC_BASE_URL":"https://old.example","ANTHROPIC_AUTH_TOKEN":"old"}}', [Text.UTF8Encoding]::new($false))
    $env:CCX_SETTINGS_PATH = $fxPath
    $accFull = @{
        id = 'glm-1'; label = '智谱1'; base_url = 'https://big.example/api'; auth_token = 'tok-1'
        env = @{
            ANTHROPIC_MODEL = 'glm-5.3[1M]'; ANTHROPIC_DEFAULT_SONNET_MODEL = 'glm-5.3[1M]'
            ANTHROPIC_DEFAULT_OPUS_MODEL_NAME = 'glm-5.3'
        }
    }
    $m = Merge-CcxEnv -Account $accFull -Version 'glm-5.4[1M]'
    Assert-Equal 'glm-5.4[1M]' $m['ANTHROPIC_MODEL'] '主键=版本串'
    Assert-Equal 'glm-5.4[1M]' $m['ANTHROPIC_DEFAULT_SONNET_MODEL'] 'DEFAULT 族=版本串'
    Assert-Equal 'glm-5.4' $m['ANTHROPIC_DEFAULT_OPUS_MODEL_NAME'] '_NAME=基名'
    Assert-Equal 'tok-1' $m['ANTHROPIC_AUTH_TOKEN'] 'token 不动'
    Assert-Equal 'https://big.example/api' $m['ANTHROPIC_BASE_URL'] 'base_url 不动'
    Assert-Equal 'max' $m['CLAUDE_CODE_EFFORT_LEVEL'] '非模型键不动'
    Assert-Equal 'glm-1' $m['CCX_ACCOUNT_ID'] 'CCX 标识在'

    # 最小 env 号：无任何 MODEL 键 → 至少写 ANTHROPIC_MODEL
    $accMin = @{ id = 'm-1'; label = '最小'; base_url = 'https://b.example'; auth_token = 't'; env = @{} }
    $m2 = Merge-CcxEnv -Account $accMin -Version 'glm-5.2'
    Assert-Equal 'glm-5.2' $m2['ANTHROPIC_MODEL'] '最小号也写主键'
    Assert-Equal 'glm-5.2' $m2['ANTHROPIC_DEFAULT_OPUS_MODEL_NAME'] '最小号 _NAME 键补齐'
    Assert-Equal 't' $m2['ANTHROPIC_AUTH_TOKEN'] '最小号 token 在'

    # 无 -Version 回归：与 A期行为逐键一致
    $m3 = Merge-CcxEnv -Account $accFull
    Assert-Equal 'glm-5.3[1M]' $m3['ANTHROPIC_MODEL'] '无版本不覆盖'
    Assert-Equal 'glm-5.3' $m3['ANTHROPIC_DEFAULT_OPUS_MODEL_NAME'] '无版本 _NAME 原样'

    # ⑩ Get-CcxModelNode：models 节按 vendor 命中 / 未配 null
    $reg = @{ models = @{ glm = @{ vendor = 'bigmodel'; versions = @('v1') }; kimi = @{ vendor = 'moonshot' } } }
    Assert-Equal 'v1' (Get-CcxModelNode -Registry $reg -Vendor 'bigmodel')['versions'][0] '命中 bigmodel 节'
    Assert-True ($null -eq (Get-CcxModelNode -Registry @{ models = @{} } -Vendor 'bigmodel')) '未配返回 null'
    Assert-True ($null -eq (Get-CcxModelNode -Registry @{ } -Vendor 'bigmodel')) '无 models 节返回 null'

    # ⑪ 启动接线（子进程）：单 vendor + versions 多项 + -NonInteractive → 版本菜单渲染、默认标注、退 1
    $env:CCX_FAKE_LOG = Join-Path $testHome 'fake-log.txt'
    $env:CCX_FAKE_SNAPSHOT = Join-Path $testHome 'fake-snapshot.json'
    $env:CCX_CLAUDE_CMD = Join-Path $PSScriptRoot 'fake_claude.ps1'
    $ccx = Join-Path $PSScriptRoot '..\bin\ccx.ps1'
    Save-CcxJson -Path (Join-Path $testHome 'registry.json') -Data @{
        schema   = 1
        models   = @{ glm = @{ vendor = 'bigmodel'; label = '智谱 GLM'; versions = @('glm-5.3[1M]', 'glm-5.4[1M]'); default_version = 'glm-5.3[1M]' } }
        accounts = @(
            @{ id = 'glm-1'; label = '智谱1'; vendor = 'bigmodel'; priority = 1; enabled = $true; base_url = 'http://127.0.0.1:1/api'; auth_token = 't1'; env = @{ ANTHROPIC_MODEL = 'glm-5.3[1M]'; ANTHROPIC_DEFAULT_OPUS_MODEL_NAME = 'glm-5.3' } }
        )
    }
    $outA = Join-Path $testHome 'a.out'; $errA = Join-Path $testHome 'a.err'
    $pA = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ccx) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outA -RedirectStandardError $errA
    $txtA = Get-Content $outA -Raw -Encoding UTF8
    Assert-True ($txtA -like '*选择版本*') '版本菜单渲染'
    Assert-True ($txtA.Contains('glm-5.3[1M]（默认）')) '默认版标注（字面含 [1M]，-like 会当字符类）'
    Assert-True ($txtA.Contains('glm-5.4[1M]')) '第二项在列'
    Assert-Equal 1 $pA.ExitCode 'NonInteractive Read-Host 抛错退 1'

    # ⑫ 唯一选项 → 静默直用（无菜单），快照=该版本
    Remove-Item $env:CCX_FAKE_LOG, $env:CCX_FAKE_SNAPSHOT -ErrorAction SilentlyContinue
    Save-CcxJson -Path (Join-Path $testHome 'registry.json') -Data @{
        schema   = 1
        models   = @{ glm = @{ vendor = 'bigmodel'; label = '智谱 GLM'; versions = @('glm-5.2') } }
        accounts = @(
            @{ id = 'glm-1'; label = '智谱1'; vendor = 'bigmodel'; priority = 1; enabled = $true; base_url = 'http://127.0.0.1:1/api'; auth_token = 't1'; env = @{ ANTHROPIC_MODEL = 'glm-5.3[1M]'; ANTHROPIC_DEFAULT_OPUS_MODEL_NAME = 'glm-5.3' } }
        )
    }
    $outB = Join-Path $testHome 'b.out'; $errB = Join-Path $testHome 'b.err'
    $pB = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ccx) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outB -RedirectStandardError $errB
    $txtB = Get-Content $outB -Raw -Encoding UTF8
    Assert-Equal 0 $pB.ExitCode '唯一选项静默启动'
    Assert-True ($txtB -notlike '*选择版本*') '唯一选项无菜单'
    Assert-True (Test-Path $env:CCX_FAKE_SNAPSHOT) 'fake 快照存在'
    $snapB = Read-CcxJson -Path $env:CCX_FAKE_SNAPSHOT
    Assert-Equal 'glm-5.2' $snapB['env']['ANTHROPIC_MODEL'] '唯一选项覆盖主键'
    Assert-Equal 'glm-5.2' $snapB['env']['ANTHROPIC_DEFAULT_OPUS_MODEL_NAME'] '唯一选项 _NAME=基名'

    # ⑬ 别名快路径：ccx glm → default_version 直用不问
    Remove-Item $env:CCX_FAKE_LOG, $env:CCX_FAKE_SNAPSHOT -ErrorAction SilentlyContinue
    Save-CcxJson -Path (Join-Path $testHome 'registry.json') -Data @{
        schema   = 1
        models   = @{ glm = @{ vendor = 'bigmodel'; label = '智谱 GLM'; versions = @('glm-5.3[1M]', 'glm-5.4[1M]'); default_version = 'glm-5.4[1M]' } }
        accounts = @(
            @{ id = 'glm-1'; label = '智谱1'; vendor = 'bigmodel'; priority = 1; enabled = $true; base_url = 'http://127.0.0.1:1/api'; auth_token = 't1'; env = @{ ANTHROPIC_MODEL = 'glm-5.3[1M]'; ANTHROPIC_DEFAULT_OPUS_MODEL_NAME = 'glm-5.3' } }
        )
    }
    $outC = Join-Path $testHome 'c.out'; $errC = Join-Path $testHome 'c.err'
    $pC = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ccx, 'glm') -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outC -RedirectStandardError $errC
    $txtC = Get-Content $outC -Raw -Encoding UTF8
    Assert-Equal 0 $pC.ExitCode '别名快路径启动'
    Assert-True ($txtC -notlike '*选择版本*') '快路径无菜单'
    $snapC = Read-CcxJson -Path $env:CCX_FAKE_SNAPSHOT
    Assert-Equal 'glm-5.4[1M]' $snapC['env']['ANTHROPIC_MODEL'] '快路径=默认版'
    Assert-Equal 'glm-5.4' $snapC['env']['ANTHROPIC_DEFAULT_OPUS_MODEL_NAME'] '快路径 _NAME=基名'

    # ⑭ 无 versions 组（fetch 秒拒空）→ 无菜单照启，快照=账号 env 原样（A期回归）
    Remove-Item $env:CCX_FAKE_LOG, $env:CCX_FAKE_SNAPSHOT -ErrorAction SilentlyContinue
    Save-CcxJson -Path (Join-Path $testHome 'registry.json') -Data @{
        schema   = 1
        models   = @{ glm = @{ vendor = 'bigmodel'; label = '智谱 GLM' } }
        accounts = @(
            @{ id = 'glm-1'; label = '智谱1'; vendor = 'bigmodel'; priority = 1; enabled = $true; base_url = 'http://127.0.0.1:1/api'; auth_token = 't1'; env = @{ ANTHROPIC_MODEL = 'glm-4.6' } }
        )
    }
    $outD = Join-Path $testHome 'd.out'; $errD = Join-Path $testHome 'd.err'
    $pD = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ccx) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outD -RedirectStandardError $errD
    $txtD = Get-Content $outD -Raw -Encoding UTF8
    Assert-Equal 0 $pD.ExitCode '无版本配置照启'
    Assert-True ($txtD -notlike '*选择版本*') '无配置无菜单'
    $snapD = Read-CcxJson -Path $env:CCX_FAKE_SNAPSHOT
    Assert-Equal 'glm-4.6' $snapD['env']['ANTHROPIC_MODEL'] '无配置不覆盖（A期原样）'

    # ⑮ add 向导：该厂商已配 versions → 打印编号列表，输入编号经 Resolve 解析（stdin 注入全向导）
    [IO.File]::WriteAllText($fxPath, '{"env":{"ANTHROPIC_BASE_URL":"https://old.example","ANTHROPIC_AUTH_TOKEN":"old","ANTHROPIC_MODEL":"x","ANTHROPIC_DEFAULT_OPUS_MODEL_NAME":"x","CLAUDE_CODE_EFFORT_LEVEL":"max"}}', [Text.UTF8Encoding]::new($false))
    Save-CcxJson -Path (Join-Path $testHome 'registry.json') -Data @{
        schema   = 1
        models   = @{ glm = @{ vendor = 'bigmodel'; label = '智谱 GLM'; versions = @('glm-5.3[1M]', 'glm-5.4[1M]'); default_version = 'glm-5.3[1M]' } }
        accounts = @()
    }
    $ansFile = Join-Path $testHome 'answers.txt'
    [IO.File]::WriteAllLines($ansFile, @('GLM-A', 'bigmodel', 'http://127.0.0.1:1/api', 'tk', '2'), [Text.UTF8Encoding]::new($false))
    $outE = Join-Path $testHome 'e.out'; $errE = Join-Path $testHome 'e.err'
    $pE = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ccx, 'add') -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outE -RedirectStandardError $errE -RedirectStandardInput $ansFile
    $txtE = Get-Content $outE -Raw -Encoding UTF8
    Assert-Equal 0 $pE.ExitCode 'add 向导跑完'
    Assert-True ($txtE.Contains('该组可选版本')) 'add 打印可选版本列表'
    Assert-True ($txtE.Contains('glm-5.3[1M]（默认）')) 'add 列表默认标注'
    $regE = Read-CcxJson -Path (Join-Path $testHome 'registry.json')
    $newAcc = @($regE['accounts'] | Where-Object { $_['id'] -eq 'bigmodel-1' })
    Assert-Equal 1 @($newAcc).Count '新号 bigmodel-1 落盘'
    Assert-Equal 'glm-5.4[1M]' $newAcc[0]['env']['ANTHROPIC_MODEL'] '编号 2 解析为 glm-5.4[1M]'
    Assert-Equal 'glm-5.4' $newAcc[0]['env']['ANTHROPIC_DEFAULT_OPUS_MODEL_NAME'] 'add _NAME=基名'
    Assert-Equal 'tk' $newAcc[0]['env']['ANTHROPIC_AUTH_TOKEN'] 'add token=输入值'

    # ⑯ usage 首行文案（Show-CcxUsage 当前无调用方=纯文案钉住，防回退）
    $usageTxt = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\bin\ccx.ps1'))
    Assert-True ($usageTxt.Contains('交互选模型+版本并启动')) 'usage 首行含版本'

    # ⑰ 同 vendor 双 models 节（旧裸别名 + versions 节并存，活 registry 实测形态）→ 命中带 versions 者；仅裸节点兜底返回
    $regDup = @{ models = @{ bigmodel = @{ vendor = 'bigmodel'; label = 'bigmodel' }; glm = @{ vendor = 'bigmodel'; label = '智谱 GLM'; versions = @('glm-5.3[1M]'); default_version = 'glm-5.3[1M]' } } }
    Assert-Equal 'glm-5.3[1M]' (Get-CcxModelNode -Registry $regDup -Vendor 'bigmodel')['default_version'] '双节点优先带 versions'
    $regBare = @{ models = @{ bigmodel = @{ vendor = 'bigmodel'; label = 'bigmodel' } } }
    Assert-Equal 'bigmodel' (Get-CcxModelNode -Registry $regBare -Vendor 'bigmodel')['label'] '仅裸节点兜底返回'
} finally {
    Remove-Item -Recurse -Force $testHome -ErrorAction SilentlyContinue
    Remove-Module ccx-core -ErrorAction SilentlyContinue
}
Write-Output 'test_version_menu OK'
