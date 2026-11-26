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
} finally {
    Remove-Item -Recurse -Force $testHome -ErrorAction SilentlyContinue
    Remove-Module ccx-core -ErrorAction SilentlyContinue
}
Write-Output 'test_version_menu OK'
