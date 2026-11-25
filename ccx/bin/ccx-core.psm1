# ccx-core.psm1 — IO 骨架：registry/state 读写（原子写、UTF8 无 BOM、损坏明错）
# 约定：所有读出的 JSON 一律深转换成 hashtable，后续任务只吃 hashtable
$script:CcxUtf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-CcxHome {
    # 测试缝：CCX_HOME 覆盖默认目录
    if ($env:CCX_HOME) { return $env:CCX_HOME }
    return (Join-Path $env:USERPROFILE '.claude\model-accounts')
}

function Convert-CcxToHashtable {
    param($Node)
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Node.PSObject.Properties) { $h[$p.Name] = Convert-CcxToHashtable $p.Value }
        return $h
    }
    if ($Node -is [System.Array]) {
        # 逗号包装防管道拆封：return @(...) 会把单元素数组解成元素本身、空数组解成 $null
        return , @($Node | ForEach-Object { Convert-CcxToHashtable $_ })
    }
    return $Node
}

function Read-CcxJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = [IO.File]::ReadAllText($Path)
        # 空文件视为"未初始化"（等同缺失），只有非空坏 JSON 才算损坏
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return Convert-CcxToHashtable (ConvertFrom-Json $raw)
    } catch {
        throw "CCX_E_REGISTRY_CORRUPT|$Path — JSON 解析失败: $($_.Exception.Message)"
    }
}

function Save-CcxJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][hashtable]$Data)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $json = ConvertTo-Json -InputObject $Data -Depth 10
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, $script:CcxUtf8NoBom)
    # .NET Framework 的 Move 不能覆盖已存在文件 → 存在则 Replace（原子换名），不存在才 Move
    # 注意：PS 把 $null 绑到 [string] 会变空串（合法路径报错），必须 [NullString]::Value
    if (Test-Path -LiteralPath $Path) {
        [IO.File]::Replace($tmp, $Path, [NullString]::Value)
    } else {
        [IO.File]::Move($tmp, $Path)
    }
}

function Read-CcxRegistry {
    return Read-CcxJson -Path (Join-Path (Get-CcxHome) 'registry.json')
}

function Read-CcxState {
    $s = Read-CcxJson -Path (Join-Path (Get-CcxHome) 'state.json')
    if ($null -eq $s) { $s = @{} }
    if (-not $s.Contains('schema')) { $s['schema'] = 1 }
    if (-not $s.Contains('accounts') -or $null -eq $s['accounts']) { $s['accounts'] = @{} }
    return $s
}

function Save-CcxState {
    param([Parameter(Mandatory = $true)][hashtable]$State)
    Save-CcxJson -Path (Join-Path (Get-CcxHome) 'state.json') -Data $State
}

function Get-CcxNextReset {
    # 账号下一次 reset_time 时刻（本地）；now 早于今日 reset → 今日，否则明日
    param([Parameter(Mandatory = $true)][string]$Id, [datetime]$Now = (Get-Date))
    $reset = '00:00'
    $reg = Read-CcxRegistry
    if ($null -ne $reg -and $reg['accounts']) {
        foreach ($a in $reg['accounts']) {
            if ($a['id'] -eq $Id -and $a['reset_time']) { $reset = $a['reset_time']; break }
        }
    }
    $parts = $reset.Split(':')
    $candidate = $Now.Date.AddHours([int]$parts[0]).AddMinutes([int]$parts[1])
    if ($candidate -le $Now) { $candidate = $candidate.AddDays(1) }
    return $candidate
}

function Get-CcxEffectiveStatus {
    # 惰性清冷却：r429/daily 且 until ≤ Now → 视为 ok 并回写传入 State
    param([Parameter(Mandatory = $true)][hashtable]$State, [Parameter(Mandatory = $true)][string]$Id, [datetime]$Now = (Get-Date))
    $acc = $State['accounts']
    if ($null -eq $acc -or -not $acc.Contains($Id) -or $null -eq $acc[$Id]) { return 'ok' }
    $st = $acc[$Id]
    $status = $st['status']
    if (-not $status) { return 'ok' }
    if ($status -eq 'ok' -or $status -eq 'blocked') { return $status }
    $until = $null
    if ($st.Contains('until') -and $st['until']) { $until = [datetime]$st['until'] }
    if ($null -ne $until -and $until -le $Now) {
        $st['status'] = 'ok'
        $st['updated_at'] = $Now.ToString('o')
        $st.Remove('until')
        return 'ok'
    }
    return $status
}

function Set-CcxAccountStatus {
    # r429→until=Now+60s；daily→下一次 reset_time；blocked→无 until；均记 updated_at
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$Status, [string]$Note, [datetime]$Now = (Get-Date))
    $state = Read-CcxState
    if (-not $state['accounts'].Contains($Id)) { $state['accounts'][$Id] = @{} }
    $st = $state['accounts'][$Id]
    $st['status'] = $Status
    $st['updated_at'] = $Now.ToString('o')
    if ($Note) { $st['note'] = $Note } else { $st.Remove('note') }
    switch ($Status) {
        'r429'    { $st['until'] = $Now.AddSeconds(60).ToString('o') }
        'daily'   { $st['until'] = (Get-CcxNextReset -Id $Id -Now $Now).ToString('o') }
        default   { $st.Remove('until') }   # ok/blocked 不携带 until
    }
    Save-CcxState -State $state
}

function Unlock-CcxAccount {
    param([Parameter(Mandatory = $true)][string]$Id)
    Set-CcxAccountStatus -Id $Id -Status 'ok'
}

function New-CcxRegistrySample {
    # spec §4 样例；auth_token 为占位符，真实 token 永不入仓
    return @{
        schema   = 1
        models   = @{
            glm = @{ vendor = 'bigmodel'; label = '智谱 GLM' }
        }
        accounts = @(
            @{
                id         = 'glm-1'
                label      = '智谱主力'
                vendor     = 'bigmodel'
                base_url   = 'https://open.bigmodel.cn/api/anthropic'
                auth_token = '<把真实token粘贴到这里>'
                env        = @{
                    ANTHROPIC_MODEL                     = 'glm-5.3[1M]'
                    ANTHROPIC_DEFAULT_HAIKU_MODEL       = 'glm-5.3[1M]'
                    ANTHROPIC_DEFAULT_SONNET_MODEL      = 'glm-5.3[1M]'
                    ANTHROPIC_DEFAULT_OPUS_MODEL        = 'glm-5.3[1M]'
                    ANTHROPIC_DEFAULT_FABLE_MODEL       = 'glm-5.3[1M]'
                    ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME  = 'glm-5.3'
                    ANTHROPIC_DEFAULT_SONNET_MODEL_NAME = 'glm-5.3'
                    ANTHROPIC_DEFAULT_OPUS_MODEL_NAME   = 'glm-5.3'
                }
                priority   = 1
                reset_time = '00:00'
                enabled    = $true
            }
        )
    }
}

function Format-CcxUntil {
    param([Parameter(Mandatory = $true)][datetime]$Until, [datetime]$Now = (Get-Date))
    if ($Until.Date -eq $Now.Date) { return '今日 ' + $Until.ToString('HH:mm') }
    if ($Until.Date -eq $Now.Date.AddDays(1)) { return '明日 ' + $Until.ToString('HH:mm') }
    return $Until.ToString('MM-dd HH:mm')
}

function Resolve-CcxModelGroup {
    # 'glm' 走 models 节；'glm@g1' 强指 id；'' 唯一 vendor 直取（多组 null=上层出菜单）；models 缺失按 vendor 兜底
    param([string]$ModelSpec, [Parameter(Mandatory = $true)][hashtable]$Registry)
    $accounts = @($Registry['accounts'] | Where-Object { $_ -and $_['enabled'] -ne $false })
    if ($accounts.Count -eq 0) { return $null }

    $alias = [string]$ModelSpec
    $strongId = $null
    if ($alias.Contains('@')) {
        $parts = $alias -split '@'
        $alias = $parts[0]
        $strongId = $parts[1]
    }

    $vendor = $null; $label = $null
    $models = $Registry['models']
    if ($alias) {
        if ($models -is [hashtable] -and $models.Contains($alias)) {
            $vendor = $models[$alias]['vendor']
            $label = $models[$alias]['label']
        } elseif ($strongId) {
            # models 节缺失但强指了 id → 按该账号自身 vendor 兜底
            $hit = @($accounts | Where-Object { $_['id'] -eq $strongId })
            if ($hit.Count -gt 0) { $vendor = $hit[0]['vendor']; $label = $vendor }
        }
        if (-not $vendor) { return $null }
    } else {
        $vendors = @($accounts | ForEach-Object { $_['vendor'] } | Select-Object -Unique)
        if ($vendors.Count -ne 1) { return $null }
        $vendor = $vendors[0]
        if ($models -is [hashtable]) {
            foreach ($k in @($models.Keys)) { if ($models[$k]['vendor'] -eq $vendor) { $label = $models[$k]['label']; break } }
        }
        if (-not $label) { $label = $vendor }
    }

    $groupAccounts = @($accounts | Where-Object { $_['vendor'] -eq $vendor })
    if ($strongId) { $groupAccounts = @($groupAccounts | Where-Object { $_['id'] -eq $strongId }) }
    if ($groupAccounts.Count -eq 0) { return $null }
    return @{ Vendor = $vendor; Label = $label; Accounts = $groupAccounts }
}

function Find-EarliestRecovery {
    # 有 until（r429/daily）的号里取最早恢复者；全 blocked/无 until → null
    param([Parameter(Mandatory = $true)][hashtable]$State, [Parameter(Mandatory = $true)]$Accounts)
    $best = $null
    foreach ($a in @($Accounts)) {
        $st = $State['accounts'][$a['id']]
        if ($null -eq $st -or -not $st['until']) { continue }
        $u = [datetime]$st['until']
        if ($null -eq $best -or $u -lt $best['Until']) { $best = @{ Id = $a['id']; Until = $u } }
    }
    return $best
}

function Select-CcxAccount {
    # 调用方契约：State 为读写对象（惰性清冷却 + last_used_at 回写在此），调用后由上层 Save-CcxState
    # priority 升序、并列取 last_used_at 最旧（缺省最旧）；全不可用 → Account=null + 全池面板
    param([Parameter(Mandatory = $true)][hashtable]$Registry, [Parameter(Mandatory = $true)][hashtable]$State, [Parameter(Mandatory = $true)][hashtable]$Group, [datetime]$Now = (Get-Date))
    $lines = New-Object System.Collections.Generic.List[string]
    $okAccounts = @()
    foreach ($a in @($Group['Accounts'])) {
        $eff = Get-CcxEffectiveStatus -State $State -Id $a['id'] -Now $Now
        $st = $State['accounts'][$a['id']]
        $untilTxt = ''
        if ($eff -ne 'ok' -and $null -ne $st -and $st['until']) {
            $untilTxt = '（恢复 ' + (Format-CcxUntil -Until ([datetime]$st['until']) -Now $Now) + '）'
        }
        $lines.Add(('  {0,-8} {1,-10} {2}{3}' -f $a['id'], $a['label'], $eff, $untilTxt))
        if ($eff -eq 'ok') { $okAccounts += ,$a }
    }
    if ($okAccounts.Count -eq 0) {
        $er = Find-EarliestRecovery -State $State -Accounts $Group['Accounts']
        $tail = '  全池不可用，最早恢复 '
        if ($er) { $tail += $er['Id'] + ' ' + (Format-CcxUntil -Until $er['Until'] -Now $Now) }
        else { $tail += '—（blocked 需 ccx unlock 手动解锁）' }
        $lines.Add($tail)
        return @{ Account = $null; Panel = ($lines -join "`n") }
    }
    $sortProps = @(
        @{ Expression = { if ($_['priority']) { [int]$_['priority'] } else { 999 } } }
        @{ Expression = { $rec = $State['accounts'][$_['id']]; if ($rec -and $rec['last_used_at']) { [datetime]$rec['last_used_at'] } else { [datetime]::MinValue } } }
    )
    $chosen = @($okAccounts | Sort-Object -Property $sortProps)[0]
    if (-not $State['accounts'].Contains($chosen['id'])) { $State['accounts'][$chosen['id']] = @{} }
    $State['accounts'][$chosen['id']]['last_used_at'] = $Now.ToString('o')
    return @{ Account = $chosen; Panel = ($lines -join "`n") }
}
