# Task 2 IO 层测试：往返深相等、无 BOM、无 tmp 残留、损坏明错、state 空壳补全
. (Join-Path $PSScriptRoot 'assert.ps1')
Import-Module (Join-Path $PSScriptRoot '..\bin\ccx-core.psm1') -Force

function Assert-CcxDeepEqual {
    param($A, $B, [string]$Path)
    Assert-True (($null -eq $A) -eq ($null -eq $B)) ("null 失配 @" + $Path)
    if ($null -eq $A) { return }
    if ($A -is [System.Array]) {
        Assert-True ($B -is [System.Array]) ("应为数组 @" + $Path)
        Assert-Equal $A.Count $B.Count ("长度失配 @" + $Path)
        for ($i = 0; $i -lt $A.Count; $i++) { Assert-CcxDeepEqual $A[$i] $B[$i] ($Path + '[' + $i + ']') }
        return
    }
    if ($A -is [hashtable]) {
        Assert-True ($B -is [hashtable]) ("应为 hashtable @" + $Path)
        Assert-Equal $A.Count $B.Count ("键数失配 @" + $Path)
        foreach ($k in @($A.Keys)) {
            Assert-True ($B.Contains($k)) ("缺键 " + $k + " @" + $Path)
            Assert-CcxDeepEqual $A[$k] $B[$k] ($Path + '.' + $k)
        }
        return
    }
    Assert-Equal $A $B ("值失配 @" + $Path)
}

$testHome = Join-Path ([IO.Path]::GetTempPath()) ('ccx-t2-' + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force $testHome | Out-Null
$env:CCX_HOME = $testHome
try {
    Assert-Equal $testHome (Get-CcxHome) 'Get-CcxHome 尊重 CCX_HOME'

    $sample = New-CcxRegistrySample
    Assert-Equal 1 $sample['schema'] '样例 schema=1'
    Assert-Equal 'bigmodel' $sample['models']['glm']['vendor'] '样例 models.glm.vendor'
    Assert-True ($sample['accounts'].Count -ge 1) '样例至少 1 个账号'
    foreach ($k in @('id','label','vendor','base_url','auth_token','env','priority','reset_time','enabled')) {
        Assert-True ($sample['accounts'][0].Contains($k)) ('样例账号缺字段: ' + $k)
    }

    # ① 往返深相等
    $p1 = Join-Path $testHome 'rt1.json'
    Save-CcxJson -Path $p1 -Data $sample
    $back = Read-CcxJson -Path $p1
    Assert-True ($back -is [hashtable]) 'Read 返回 hashtable'
    Assert-True ($back['accounts'][0]['env'] -is [hashtable]) '嵌套 env 是 hashtable'
    Assert-CcxDeepEqual $sample $back 'root'

    # 目录不存在自动建
    $deep = Join-Path $testHome 'sub\dir\f.json'
    Save-CcxJson -Path $deep -Data @{ schema = 1 }
    Assert-True (Test-Path $deep) '父目录自动创建'

    # ② 无 BOM
    $b1 = [IO.File]::ReadAllBytes($p1)
    Assert-True (-not ($b1[0] -eq 0xEF -and $b1[1] -eq 0xBB -and $b1[2] -eq 0xBF)) 'JSON 无 BOM'

    # ③ 无 .tmp 残留
    Assert-Equal 0 @(Get-ChildItem $testHome -Filter '*.tmp' -Recurse).Count '无 tmp 残留'

    # ④ 损坏 JSON 明错
    $bad = Join-Path $testHome 'bad.json'
    [IO.File]::WriteAllText($bad, '{ not json', [Text.UTF8Encoding]::new($false))
    Assert-Throws { Read-CcxJson -Path $bad } '损坏 JSON 必须明错' -Like '*CCX_E_REGISTRY_CORRUPT*'

    # 不存在 → null
    Assert-True ($null -eq (Read-CcxJson -Path (Join-Path $testHome 'nope.json'))) '不存在返回 null'

    # ⑤ state 缺失 → 空壳补全
    $st = Read-CcxState
    Assert-True ($st -is [hashtable]) 'state 是 hashtable'
    Assert-Equal 1 $st['schema'] 'state 空壳 schema=1'
    Assert-True ($st['accounts'] -is [hashtable]) 'state.accounts 是 hashtable'
    Assert-Equal 0 $st['accounts'].Count 'state 空壳 accounts 空'

    # state.json 存在但缺 accounts 字段 → 也补全
    [IO.File]::WriteAllText((Join-Path $testHome 'state.json'), '{"schema":1}', [Text.UTF8Encoding]::new($false))
    $st2 = Read-CcxState
    Assert-True ($st2['accounts'] -is [hashtable]) '缺 accounts 字段补空壳'

    # Save-CcxState 落盘往返
    $st2['accounts']['x1'] = @{ status = 'ok' }
    Save-CcxState -State $st2
    Assert-Equal 'ok' (Read-CcxState)['accounts']['x1']['status'] 'state 保存往返'

    # registry 路由到 CCX_HOME\registry.json
    Save-CcxJson -Path (Join-Path $testHome 'registry.json') -Data $sample
    Assert-Equal 'bigmodel' (Read-CcxRegistry)['models']['glm']['vendor'] 'Read-CcxRegistry 读 CCX_HOME'
} finally {
    Remove-Item -Recurse -Force $testHome -ErrorAction SilentlyContinue
    Remove-Module ccx-core -ErrorAction SilentlyContinue
}
Write-Output 'test_io OK'
