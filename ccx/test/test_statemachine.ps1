# Task 3 状态机测试：惰性清冷却、daily/r429/blocked 语义、until 计算
. (Join-Path $PSScriptRoot 'assert.ps1')
Import-Module (Join-Path $PSScriptRoot '..\bin\ccx-core.psm1') -Force

$testHome = Join-Path ([IO.Path]::GetTempPath()) ('ccx-t3-' + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force $testHome | Out-Null
$env:CCX_HOME = $testHome
try {
    # registry：glm-1 reset_time=00:50（用于 until 计算）
    $reg = New-CcxRegistrySample
    $reg['accounts'][0]['reset_time'] = '00:50'
    Save-CcxJson -Path (Join-Path $testHome 'registry.json') -Data $reg

    $now = Get-Date

    # ① daily 已过期 → ok 且回写传入 State
    $state = @{ schema = 1; accounts = @{ a1 = @{ status = 'daily'; until = $now.AddSeconds(-1).ToString('o') } } }
    Assert-Equal 'ok' (Get-CcxEffectiveStatus -State $state -Id 'a1' -Now $now) '过期 daily 惰性清为 ok'
    Assert-Equal 'ok' $state['accounts']['a1']['status'] '惰性清冷却回写 state'

    # ② daily 未过期 → daily 不回写
    $state2 = @{ schema = 1; accounts = @{ a1 = @{ status = 'daily'; until = $now.AddHours(1).ToString('o') } } }
    Assert-Equal 'daily' (Get-CcxEffectiveStatus -State $state2 -Id 'a1' -Now $now) '未过期 daily 保持'
    Assert-Equal 'daily' $state2['accounts']['a1']['status'] '未过期不回写'

    # ④ blocked 永不自动恢复
    $state3 = @{ schema = 1; accounts = @{ a1 = @{ status = 'blocked'; until = $now.AddHours(-1).ToString('o') } } }
    Assert-Equal 'blocked' (Get-CcxEffectiveStatus -State $state3 -Id 'a1' -Now $now) 'blocked until 过去仍 blocked'

    # r429 未过期 → r429；过期 → ok
    $state4 = @{ schema = 1; accounts = @{ a1 = @{ status = 'r429'; until = $now.AddSeconds(30).ToString('o') } } }
    Assert-Equal 'r429' (Get-CcxEffectiveStatus -State $state4 -Id 'a1' -Now $now) 'r429 未过期保持'
    $state5 = @{ schema = 1; accounts = @{ a1 = @{ status = 'r429'; until = $now.AddSeconds(-1).ToString('o') } } }
    Assert-Equal 'ok' (Get-CcxEffectiveStatus -State $state5 -Id 'a1' -Now $now) 'r429 过期清为 ok'

    # ⑥ 无记录 → ok
    $state6 = @{ schema = 1; accounts = @{} }
    Assert-Equal 'ok' (Get-CcxEffectiveStatus -State $state6 -Id 'nobody' -Now $now) '无记录视为 ok'

    # ③ daily until 计算：reset_time=00:50
    $base = $now.Date
    Set-CcxAccountStatus -Id 'glm-1' -Status 'daily' -Now $base.AddMinutes(49)
    $u1 = [datetime](Read-CcxState)['accounts']['glm-1']['until']
    Assert-Equal ($base.AddMinutes(50)) $u1 '00:49 标记 → 今日 00:50'

    Set-CcxAccountStatus -Id 'glm-1' -Status 'daily' -Now $base.AddMinutes(51)
    $u2 = [datetime](Read-CcxState)['accounts']['glm-1']['until']
    Assert-Equal ($base.AddDays(1).AddMinutes(50)) $u2 '00:51 标记 → 明日 00:50'

    # 00:50 整点（不早于 reset）→ 明日
    Set-CcxAccountStatus -Id 'glm-1' -Status 'daily' -Now $base.AddMinutes(50)
    $u3 = [datetime](Read-CcxState)['accounts']['glm-1']['until']
    Assert-Equal ($base.AddDays(1).AddMinutes(50)) $u3 '00:50 整点标记 → 明日 00:50'

    # ⑤ r429 → until ≈ Now+60s
    $t0 = Get-Date
    Set-CcxAccountStatus -Id 'glm-1' -Status 'r429' -Now $t0
    $u4 = [datetime](Read-CcxState)['accounts']['glm-1']['until']
    $drift = [Math]::Abs(($u4 - $t0.AddSeconds(60)).TotalSeconds)
    Assert-True ($drift -lt 2) ('r429 until≈Now+60s，实际漂移=' + $drift)

    # updated_at / note 记录
    $st = (Read-CcxState)['accounts']['glm-1']
    Assert-True ($st.Contains('updated_at')) '记录 updated_at'
    Set-CcxAccountStatus -Id 'glm-1' -Status 'daily' -Note '手动标记' -Now $t0
    Assert-Equal '手动标记' (Read-CcxState)['accounts']['glm-1']['note'] 'note 落盘'

    # Unlock → ok 且清 until
    Set-CcxAccountStatus -Id 'glm-1' -Status 'blocked' -Now $t0
    Unlock-CcxAccount -Id 'glm-1'
    $st2 = (Read-CcxState)['accounts']['glm-1']
    Assert-Equal 'ok' $st2['status'] 'unlock 后 ok'
    Assert-True (-not $st2.Contains('until')) 'unlock 清 until'
} finally {
    Remove-Item -Recurse -Force $testHome -ErrorAction SilentlyContinue
    Remove-Module ccx-core -ErrorAction SilentlyContinue
}
Write-Output 'test_statemachine OK'
