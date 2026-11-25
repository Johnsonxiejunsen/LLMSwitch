# Task 4 选号测试：spec §6 数值预演原样代入 + Resolve 分组 + 轮转 + 面板
. (Join-Path $PSScriptRoot 'assert.ps1')
Import-Module (Join-Path $PSScriptRoot '..\bin\ccx-core.psm1') -Force

$testHome = Join-Path ([IO.Path]::GetTempPath()) ('ccx-t4-' + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force $testHome | Out-Null
$env:CCX_HOME = $testHome
try {
    $tomorrow = (Get-Date).Date.AddDays(1)   # 明日 00:00
    $reg = @{
        schema   = 1
        models   = @{ glm = @{ vendor = 'bigmodel'; label = '智谱 GLM' } }
        accounts = @(
            @{ id = 'glm-1'; label = '智谱1'; vendor = 'bigmodel'; priority = 1; enabled = $true }
            @{ id = 'glm-2'; label = '智谱2'; vendor = 'bigmodel'; priority = 1; enabled = $true }
            @{ id = 'glm-3'; label = '智谱3'; vendor = 'bigmodel'; priority = 3; enabled = $true }
        )
    }
    $state = @{ schema = 1; accounts = @{
        'glm-1' = @{ status = 'daily'; until = $tomorrow.ToString('o') }
    } }

    $grp = Resolve-CcxModelGroup -ModelSpec 'glm' -Registry $reg
    Assert-Equal 'bigmodel' $grp['Vendor'] 'Resolve glm → bigmodel 组'
    Assert-Equal 3 $grp['Accounts'].Count '组内 3 号'

    # 预演①：glm-1 daily → 选 glm-2
    $sel = Select-CcxAccount -Registry $reg -State $state -Group $grp
    Assert-Equal 'glm-2' $sel['Account']['id'] '预演① 选 glm-2'
    Assert-True ($state['accounts']['glm-2']['last_used_at']) '选中写 last_used_at'

    # 预演②：mark glm-2 daily → 选 glm-3
    $state['accounts']['glm-2'] = @{ status = 'daily'; until = $tomorrow.AddHours(8).ToString('o') }
    $sel2 = Select-CcxAccount -Registry $reg -State $state -Group $grp
    Assert-Equal 'glm-3' $sel2['Account']['id'] '预演② 选 glm-3'

    # 预演③：全 mark → Account=null + 面板
    $state['accounts']['glm-3'] = @{ status = 'daily'; until = $tomorrow.AddHours(8).ToString('o') }
    $sel3 = Select-CcxAccount -Registry $reg -State $state -Group $grp
    Assert-True ($null -eq $sel3['Account']) '预演③ 全不可用 Account=null'
    Assert-True ($sel3['Panel'] -like '*全池不可用*') '面板含全池不可用'
    Assert-True ($sel3['Panel'] -like '*最早恢复 glm-1*') '面板含最早恢复 glm-1'

    # priority 并列取 last_used_at 最旧
    $regT = @{
        schema   = 1
        models   = @{ glm = @{ vendor = 'bigmodel'; label = 'GLM' } }
        accounts = @(
            @{ id = 'ta'; label = 'A'; vendor = 'bigmodel'; priority = 1; enabled = $true }
            @{ id = 'tb'; label = 'B'; vendor = 'bigmodel'; priority = 1; enabled = $true }
        )
    }
    $now = Get-Date
    $stateT = @{ schema = 1; accounts = @{
        'ta' = @{ status = 'ok'; last_used_at = $now.AddHours(-1).ToString('o') }
        'tb' = @{ status = 'ok'; last_used_at = $now.ToString('o') }
    } }
    $grpT = Resolve-CcxModelGroup -ModelSpec 'glm' -Registry $regT
    $selT = Select-CcxAccount -Registry $regT -State $stateT -Group $grpT
    Assert-Equal 'ta' $selT['Account']['id'] '并列取 last_used 旧者'

    # disabled 不入组
    $regT['accounts'][1]['enabled'] = $false
    $grpT2 = Resolve-CcxModelGroup -ModelSpec 'glm' -Registry $regT
    Assert-Equal 1 $grpT2['Accounts'].Count 'disabled 不入组'

    # 空 spec 唯一 vendor 直取
    $grpE = Resolve-CcxModelGroup -ModelSpec '' -Registry $regT
    Assert-Equal 'bigmodel' $grpE['Vendor'] '空 spec 唯一 vendor 直取'

    # 空 spec 多 vendor → null
    $regM = @{
        schema   = 1
        models   = @{ glm = @{ vendor = 'bigmodel'; label = 'G' }; kimi = @{ vendor = 'moonshot'; label = 'K' } }
        accounts = @(
            @{ id = 'g1'; label = 'G1'; vendor = 'bigmodel'; enabled = $true }
            @{ id = 'k1'; label = 'K1'; vendor = 'moonshot'; enabled = $true }
        )
    }
    Assert-True ($null -eq (Resolve-CcxModelGroup -ModelSpec '' -Registry $regM)) '多 vendor 空 spec → null'

    # 强指 model@id
    $regG = @{
        schema   = 1
        models   = @{ glm = @{ vendor = 'bigmodel'; label = 'GLM' } }
        accounts = @(
            @{ id = 'g1'; label = 'G1'; vendor = 'bigmodel'; enabled = $true }
            @{ id = 'g2'; label = 'G2'; vendor = 'bigmodel'; enabled = $true }
        )
    }
    $grpG = Resolve-CcxModelGroup -ModelSpec 'glm@g2' -Registry $regG
    Assert-Equal 1 $grpG['Accounts'].Count '强指后组内 1 号'
    Assert-Equal 'g2' $grpG['Accounts'][0]['id'] '强指命中 g2'

    # models 节缺失 → 按 vendor 分组兜底
    $regN = @{ schema = 1; accounts = @(
        @{ id = 'n1'; label = 'N1'; vendor = 'bigmodel'; enabled = $true }
        @{ id = 'n2'; label = 'N2'; vendor = 'bigmodel'; enabled = $true }
    ) }
    $grpN = Resolve-CcxModelGroup -ModelSpec '' -Registry $regN
    Assert-Equal 'bigmodel' $grpN['Vendor'] '无 models 节按 vendor 兜底'
    Assert-Equal 2 $grpN['Accounts'].Count '兜底组 2 号'

    # 未知别名 → null
    Assert-True ($null -eq (Resolve-CcxModelGroup -ModelSpec 'nope' -Registry $reg)) '未知别名 null'

    # Find-EarliestRecovery
    $er = Find-EarliestRecovery -State $state -Accounts $reg['accounts']
    Assert-Equal 'glm-1' $er['Id'] '最早恢复 glm-1'
    $stateB = @{ schema = 1; accounts = @{ 'glm-1' = @{ status = 'blocked' }; 'glm-2' = @{ status = 'blocked' }; 'glm-3' = @{ status = 'blocked' } } }
    Assert-True ($null -eq (Find-EarliestRecovery -State $stateB -Accounts $reg['accounts'])) '全 blocked 无恢复点 → null'
} finally {
    Remove-Item -Recurse -Force $testHome -ErrorAction SilentlyContinue
    Remove-Module ccx-core -ErrorAction SilentlyContinue
}
Write-Output 'test_selection OK'
