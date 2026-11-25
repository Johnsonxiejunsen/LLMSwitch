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

function Invoke-CcxProbe {
    # 最小探针：POST <base_url>/v1/messages，max_tokens=1；-Probe 为测试注入口
    param([Parameter(Mandatory = $true)][hashtable]$Account, [scriptblock]$Probe)
    if ($Probe) { return (& $Probe -Account $Account) }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $uri = ([string]$Account['base_url']).TrimEnd('/') + '/v1/messages'
    $headers = @{
        'Authorization'       = 'Bearer ' + $Account['auth_token']
        'anthropic-version'   = '2023-06-01'
    }
    $model = $Account['env']['ANTHROPIC_MODEL']
    if (-not $model) { $model = 'claude-3-5-haiku-20241022' }
    $body = ConvertTo-Json -Depth 5 -InputObject @{
        model      = $model
        max_tokens = 1
        messages   = @(@{ role = 'user'; content = 'hi' })
    }
    try {
        $resp = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 10 -UseBasicParsing
        return @{ Status = [int]$resp.StatusCode; Body = [string]$resp.Content; NetworkError = $false }
    } catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $code = [int]$resp.StatusCode
            $bodyTxt = ''
            try {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $bodyTxt = $sr.ReadToEnd()
            } catch {}
            return @{ Status = $code; Body = $bodyTxt; NetworkError = $false }
        }
        return @{ Status = 0; Body = [string]$_.Exception.Message; NetworkError = $true }
    }
}

function Invoke-CcxPreflight {
    # 分类顺序（保守，不误杀）：401→blocked → Body 余额/欠费→daily → 429→r429 → 其余不标只警告
    param([Parameter(Mandatory = $true)][hashtable]$Account, [scriptblock]$Probe)
    $r = Invoke-CcxProbe -Account $Account -Probe:$Probe
    $status = [int]$r['Status']
    $body = [string]$r['Body']
    if ($body.Length -gt 120) { $body = $body.Substring(0, 120) + '…' }
    $ok = ($status -ge 200 -and $status -lt 300)
    if ($ok) { return @{ Ok = $true; Marked = $null; Detail = 'ok' } }
    if ($status -eq 401) {
        Set-CcxAccountStatus -Id $Account['id'] -Status 'blocked' -Note 'preflight 401'
        return @{ Ok = $false; Marked = 'blocked'; Detail = ('HTTP 401 ' + $body) }
    }
    if ($body -match '(?i)余额|欠费|insufficient|额度|exhaust') {
        Set-CcxAccountStatus -Id $Account['id'] -Status 'daily' -Note 'preflight 余额/欠费'
        return @{ Ok = $false; Marked = 'daily'; Detail = $body }
    }
    if ($status -eq 429) {
        Set-CcxAccountStatus -Id $Account['id'] -Status 'r429' -Note 'preflight 429'
        return @{ Ok = $false; Marked = 'r429'; Detail = ('HTTP 429 ' + $body) }
    }
    # 未知错误/网络错/5xx → 不标记（可能是本机网络问题，不能把号全杀）
    return @{ Ok = $false; Marked = $null; Detail = ('HTTP ' + $status + ' ' + $body) }
}

function Select-AndPreflight {
    # 选号→预检→失败已标记者换下一号（上限=池大小）；StrongId 预检失败不接力（尊重强指）；
    # -NoCheck 跳过预检；未标记异常照常用该号启动；全不可用 → Account=$null + 全池面板
    param(
        [Parameter(Mandatory = $true)][hashtable]$Registry,
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][hashtable]$Group,
        [switch]$NoCheck,
        [string]$StrongId,
        [scriptblock]$Probe,
        [datetime]$Now = (Get-Date)
    )
    $warnings = @()
    if (-not $Group -or -not $Group['Accounts'] -or @($Group['Accounts']).Count -eq 0) {
        return @{ Account = $null; Warnings = $warnings; Panel = '  号池为空（ccx add 添加账号）' }
    }

    if ($StrongId) {
        $acc = @($Group['Accounts'] | Where-Object { $_['id'] -eq $StrongId } | Select-Object -First 1)
        if (-not $acc -or $acc.Count -eq 0) {
            return @{ Account = $null; Warnings = $warnings; Panel = ('  强指号不存在: ' + $StrongId) }
        }
        $acc = $acc[0]
        $eff = Get-CcxEffectiveStatus -State $State -Id $acc['id'] -Now $Now
        if ($eff -ne 'ok') { $warnings += ('{0} 当前状态 {1}（强指尊重选择）' -f $acc['id'], $eff) }
        Save-CcxState -State $State
        if (-not $NoCheck) {
            $pf = Invoke-CcxPreflight -Account $acc -Probe:$Probe
            if (-not $pf['Ok']) {
                $warnings += ('{0} 预检失败：{1}（强指不接力，仍用该号启动）' -f $acc['id'], $pf['Detail'])
            }
        }
        return @{ Account = $acc; Warnings = $warnings; Panel = ($warnings -join "`n") }
    }

    $pool = @($Group['Accounts'])
    for ($i = 0; $i -lt $pool.Count; $i++) {
        $sel = Select-CcxAccount -Registry $Registry -State $State -Group $Group -Now $Now
        if ($null -eq $sel['Account']) { return @{ Account = $null; Warnings = $warnings; Panel = $sel['Panel'] } }
        $acc = $sel['Account']
        Save-CcxState -State $State
        if ($NoCheck) { return @{ Account = $acc; Warnings = $warnings; Panel = $sel['Panel'] } }
        $pf = Invoke-CcxPreflight -Account $acc -Probe:$Probe
        if ($pf['Ok']) { return @{ Account = $acc; Warnings = $warnings; Panel = $sel['Panel'] } }
        if ($pf['Marked']) {
            $warnings += ('{0} 预检失败已标 {1}：{2}，换下一号' -f $acc['id'], $pf['Marked'], $pf['Detail'])
            $State = Read-CcxState   # 取回标记，防同号复读
            continue
        }
        $warnings += ('{0} 预检异常（未标记，可能本机网络问题）：{1}，仍用该号启动' -f $acc['id'], $pf['Detail'])
        return @{ Account = $acc; Warnings = $warnings; Panel = $sel['Panel'] }
    }
    # 上限耗尽（理论不可达：每轮要么返回要么标记）→ 兜底再选一次
    $sel = Select-CcxAccount -Registry $Registry -State $State -Group $Group -Now $Now
    return @{ Account = $sel['Account']; Warnings = $warnings; Panel = $sel['Panel'] }
}

function Invoke-CcxCheck {
    # 全池逐号预检 + 面板（ccx check 用）
    param([Parameter(Mandatory = $true)][hashtable]$Registry, [Parameter(Mandatory = $true)][hashtable]$State, [scriptblock]$Probe)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($a in @($Registry['accounts'])) {
        if ($a['enabled'] -eq $false) {
            $lines.Add(('  {0,-8} {1,-10} 已停用' -f $a['id'], $a['label']))
            continue
        }
        $pf = Invoke-CcxPreflight -Account $a -Probe:$Probe
        if ($pf['Ok']) { $txt = 'ok' }
        elseif ($pf['Marked']) { $txt = '失败→已标 ' + $pf['Marked'] }
        else { $txt = '异常(未标)' }
        $lines.Add(('  {0,-8} {1,-10} {2}  {3}' -f $a['id'], $a['label'], $txt, $pf['Detail']))
    }
    return ($lines -join "`n")
}

function Get-CcxSettingsPath {
    # 测试缝：CCX_SETTINGS_PATH 覆盖默认 settings.json
    if ($env:CCX_SETTINGS_PATH) { return $env:CCX_SETTINGS_PATH }
    return (Join-Path $env:USERPROFILE '.claude\settings.json')
}

function Merge-CcxEnv {
    # settings.json env ⊕ 账号 env ⊕ CCX_ACCOUNT_ID/LABEL（后写胜，按键合并非整块替换）
    param([Parameter(Mandatory = $true)][hashtable]$Account)
    $merged = @{}
    $settings = Read-CcxJson -Path (Get-CcxSettingsPath)
    if ($null -ne $settings -and $settings['env'] -is [hashtable]) {
        foreach ($k in @($settings['env'].Keys)) { $merged[$k] = $settings['env'][$k] }
    }
    if ($Account['env'] -is [hashtable]) {
        foreach ($k in @($Account['env'].Keys)) { $merged[$k] = $Account['env'][$k] }
    }
    $merged['CCX_ACCOUNT_ID'] = [string]$Account['id']
    $merged['CCX_ACCOUNT_LABEL'] = [string]$Account['label']
    return $merged
}

function Write-CcxTempSettings {
    # %TEMP%\ccx-settings-<pid>.json（UTF8 无 BOM）；顺带清 >1h 陈旧件（claude 只在启动读一次，清了无害）
    param([Parameter(Mandatory = $true)][hashtable]$Env)
    $dir = $env:TEMP
    if (-not $dir) { $dir = [IO.Path]::GetTempPath() }
    try {
        Get-ChildItem -Path $dir -Filter 'ccx-settings-*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}
    $path = Join-Path $dir ('ccx-settings-' + $PID + '.json')
    $json = ConvertTo-Json -Depth 10 -InputObject @{ env = $Env }
    [IO.File]::WriteAllText($path, $json, $script:CcxUtf8NoBom)
    return $path
}

function Remove-CcxTempSettings {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

function Get-CcxSnapshotDrift {
    # settings.json 快照的 BASE_URL/TOKEN ≠ registry 默认号 → 漂移提示（无默认号/无 settings → 不提示）
    param([Parameter(Mandatory = $true)][hashtable]$Registry)
    $defId = $Registry['default_account']
    if (-not $defId) { return $null }
    $acc = @($Registry['accounts'] | Where-Object { $_['id'] -eq $defId } | Select-Object -First 1)
    if ($acc.Count -eq 0) { return $null }
    $acc = $acc[0]
    $settings = Read-CcxJson -Path (Get-CcxSettingsPath)
    if ($null -eq $settings -or -not ($settings['env'] -is [hashtable])) { return $null }
    if (($settings['env']['ANTHROPIC_BASE_URL'] -ne $acc['base_url']) -or ($settings['env']['ANTHROPIC_AUTH_TOKEN'] -ne $acc['auth_token'])) {
        return ('settings.json 快照 ≠ 默认号 ' + $defId + '，ccx set-default 可同步')
    }
    return $null
}

function Invoke-CcxList {
    # 全池面板（按 vendor 分节）+ 快照漂移提示
    $reg = Read-CcxRegistry
    if ($null -eq $reg -or -not $reg['accounts'] -or @($reg['accounts']).Count -eq 0) {
        return '  号池为空（ccx add 添加账号）'
    }
    $state = Read-CcxState
    $now = Get-Date
    $lines = New-Object System.Collections.Generic.List[string]
    $lastVendor = $null
    foreach ($a in @($reg['accounts'])) {
        if ($a['vendor'] -ne $lastVendor) {
            $lines.Add('')
            $lines.Add('[' + $a['vendor'] + ']')
            $lastVendor = $a['vendor']
        }
        $eff = Get-CcxEffectiveStatus -State $state -Id $a['id'] -Now $now
        $st = $state['accounts'][$a['id']]
        $txt = [string]$eff
        if ($eff -ne 'ok' -and $null -ne $st -and $st['until']) {
            $txt += '（恢复 ' + (Format-CcxUntil -Until ([datetime]$st['until']) -Now $now) + '）'
        }
        if ($a['enabled'] -eq $false) { $txt += ' 已停用' }
        if ($reg['default_account'] -eq $a['id']) { $txt += ' *默认' }
        $lines.Add(('  {0,-8} {1,-10} {2}' -f $a['id'], $a['label'], $txt))
    }
    Save-CcxState -State $state   # 持久化惰性清冷却
    $hint = Get-CcxSnapshotDrift -Registry $reg
    if ($hint) { $lines.Add(''); $lines.Add('  ⚠ ' + $hint) }
    return ($lines -join "`n")
}

function Invoke-CcxMark {
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$Status)
    if (@('r429', 'daily', 'blocked') -notcontains $Status) {
        throw ('未知状态: ' + $Status + '（可用 r429|daily|blocked）')
    }
    $reg = Read-CcxRegistry
    if ($null -eq $reg -or @($reg['accounts'] | Where-Object { $_['id'] -eq $Id }).Count -eq 0) {
        throw ('号不存在: ' + $Id)
    }
    Set-CcxAccountStatus -Id $Id -Status $Status -Note '手动标记'
    Write-Output ('已标记 ' + $Id + ' → ' + $Status)
}

function Invoke-CcxUnlock {
    param([Parameter(Mandatory = $true)][string]$Id)
    $reg = Read-CcxRegistry
    if ($null -eq $reg -or @($reg['accounts'] | Where-Object { $_['id'] -eq $Id }).Count -eq 0) {
        throw ('号不存在: ' + $Id)
    }
    Unlock-CcxAccount -Id $Id
    Write-Output ('已解锁 ' + $Id)
}

function Invoke-CcxAdd {
    # 向导式加号；-Answers 为非交互注入（测试/脚本用）。env 模板 = settings.json 的 ANTHROPIC_* 键改值
    param([hashtable]$Answers)
    $reg = Read-CcxRegistry
    if ($null -eq $reg) { $reg = @{ schema = 1; models = @{}; accounts = @() } }
    if (-not $reg['models']) { $reg['models'] = @{} }
    if (-not $reg['accounts']) { $reg['accounts'] = @() }

    if ($Answers) {
        $label = $Answers['label']; $vendor = $Answers['vendor']; $baseUrl = $Answers['base_url']
        $token = $Answers['token']; $model = $Answers['model']
    } else {
        $label = Read-Host '标签（如 智谱主力）'
        $vendor = Read-Host '厂商（如 bigmodel）'
        $baseUrl = Read-Host 'base_url（如 https://open.bigmodel.cn/api/anthropic）'
        $token = Read-Host 'auth_token'
        $model = Read-Host '模型全名（如 glm-5.3[1M]）'
    }
    foreach ($pair in @(@('label', $label), @('vendor', $vendor), @('base_url', $baseUrl), @('auth_token', $token), @('model', $model))) {
        if (-not $pair[1]) { throw ('缺少必填项: ' + $pair[0]) }
    }
    $shortModel = $model -replace '\[.*\]$'

    $env = @{}
    $settings = Read-CcxJson -Path (Get-CcxSettingsPath)
    if ($null -ne $settings -and $settings['env'] -is [hashtable]) {
        foreach ($k in @($settings['env'].Keys)) {
            if ($k -like 'ANTHROPIC_*') { $env[$k] = $settings['env'][$k] }
        }
    }
    $env['ANTHROPIC_BASE_URL'] = $baseUrl
    $env['ANTHROPIC_AUTH_TOKEN'] = $token
    foreach ($k in @($env.Keys)) {
        if ($k -like '*MODEL*') {
            if ($k -like '*_NAME') { $env[$k] = $shortModel } else { $env[$k] = $model }
        }
    }

    $n = 1
    while (@($reg['accounts'] | Where-Object { $_['id'] -eq ($vendor + '-' + $n) }).Count -gt 0) { $n++ }
    $id = $vendor + '-' + $n
    $maxP = 0
    foreach ($a in @($reg['accounts'])) { if ($a['priority']) { $p = [int]$a['priority']; if ($p -gt $maxP) { $maxP = $p } } }

    $reg['accounts'] += , @{ id = $id; label = $label; vendor = $vendor; base_url = $baseUrl; auth_token = $token; env = $env; priority = ($maxP + 1); reset_time = '00:00'; enabled = $true }
    $hasVendorAlias = $false
    foreach ($k in @($reg['models'].Keys)) { if ($reg['models'][$k]['vendor'] -eq $vendor) { $hasVendorAlias = $true; break } }
    if (-not $hasVendorAlias) { $reg['models'][$vendor] = @{ vendor = $vendor; label = $vendor } }
    Save-CcxJson -Path (Join-Path (Get-CcxHome) 'registry.json') -Data $reg
    return $id
}

function Invoke-CcxRm {
    param([Parameter(Mandatory = $true)][string]$Id)
    $reg = Read-CcxRegistry
    if ($null -eq $reg) { throw 'registry 不存在' }
    $before = @($reg['accounts']).Count
    $rest = @($reg['accounts'] | Where-Object { $_['id'] -ne $Id })
    if ($rest.Count -eq $before) { throw ('号不存在: ' + $Id) }
    $reg['accounts'] = $rest
    if ($reg['default_account'] -eq $Id) { $reg.Remove('default_account') }
    Save-CcxJson -Path (Join-Path (Get-CcxHome) 'registry.json') -Data $reg
    $state = Read-CcxState
    if ($state['accounts'].Contains($Id)) { $state['accounts'].Remove($Id); Save-CcxState -State $state }
    Write-Output ('已删除 ' + $Id)
}

function Invoke-CcxSetDefault {
    # registry 记 default_account + settings.json 同步（唯一写 settings.json 的入口）
    # 顺序：解析(失败即抛，未写) → 备份 → 只覆盖 env 指定键 → 无 BOM 写回
    param([Parameter(Mandatory = $true)][string]$Id)
    $reg = Read-CcxRegistry
    if ($null -eq $reg) { throw 'registry 不存在' }
    $acc = @($reg['accounts'] | Where-Object { $_['id'] -eq $Id } | Select-Object -First 1)
    if ($acc.Count -eq 0) { throw ('号不存在: ' + $Id) }
    $acc = $acc[0]

    $sp = Get-CcxSettingsPath
    if (-not (Test-Path -LiteralPath $sp)) { throw ('settings 不存在: ' + $sp) }
    $settings = Read-CcxJson -Path $sp
    if ($null -eq $settings) { throw ('settings.json 为空，无法同步: ' + $sp) }
    if (-not ($settings['env'] -is [hashtable])) { $settings['env'] = @{} }

    $bak = $sp + '.bak-ccx-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    [IO.File]::Copy($sp, $bak, $true)

    $settings['env']['ANTHROPIC_BASE_URL'] = $acc['base_url']
    $settings['env']['ANTHROPIC_AUTH_TOKEN'] = $acc['auth_token']
    if ($acc['env'] -is [hashtable]) {
        foreach ($k in @($acc['env'].Keys)) { $settings['env'][$k] = $acc['env'][$k] }
    }
    $json = ConvertTo-Json -Depth 32 -InputObject $settings
    [IO.File]::WriteAllText($sp, $json, $script:CcxUtf8NoBom)

    $reg['default_account'] = $Id
    Save-CcxJson -Path (Join-Path (Get-CcxHome) 'registry.json') -Data $reg
    Write-Output ('默认号已设为 ' + $Id + '，settings.json 已同步（备份: ' + (Split-Path $bak -Leaf) + '）')
}
