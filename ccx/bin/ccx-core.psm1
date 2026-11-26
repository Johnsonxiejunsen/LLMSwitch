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

function Write-CcxTextAtomic {
    # 原子写文本：tmp 落盘 → 目标存在则 File.Replace（原子换名）否则 Move；无 BOM
    # Save-CcxJson 与 set-default 写 settings.json 共用（settings.json 是裸 claude 兜底层，写坏代价最高）
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, $Content, $script:CcxUtf8NoBom)
    # .NET Framework 的 Move 不能覆盖已存在文件 → 存在则 Replace（原子换名），不存在才 Move
    # 注意：PS 把 $null 绑到 [string] 会变空串（合法路径报错），必须 [NullString]::Value
    if (Test-Path -LiteralPath $Path) {
        [IO.File]::Replace($tmp, $Path, [NullString]::Value)
    } else {
        [IO.File]::Move($tmp, $Path)
    }
}

function Save-CcxJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][hashtable]$Data)
    Write-CcxTextAtomic -Path $Path -Content (ConvertTo-Json -InputObject $Data -Depth 10)
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

function ConvertTo-CcxVersionBase {
    # §13 归一化同基：小写 + 去尾 [..] 变体标签 + 去非字母数字（glm5.4[1M] ≡ glm-5.4 → glm54）
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Id)
    $s = $Id.ToLowerInvariant()
    $s = $s -replace '\[[^\]]*\]\s*$', ''
    return ($s -replace '[^a-z0-9]', '')
}

function Get-CcxVersionOptions {
    # §13 选项合并：C(手配 versions，序=真相序，default_version 标默认) ⊕ B(在线发现，
    # versions_include 过滤 + 同基去重后追加)。返回 @( @{Id; IsDefault; Source='local'|'remote'} )；$ModelNode 可 $null
    param([AllowNull()]$ModelNode, [string[]]$Fetched = @())
    $result = New-Object System.Collections.Generic.List[hashtable]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $default = $null
    if ($ModelNode -is [hashtable] -and $ModelNode['default_version']) { $default = [string]$ModelNode['default_version'] }
    if ($ModelNode -is [hashtable] -and $ModelNode['versions']) {
        foreach ($v in @($ModelNode['versions'])) {
            $id = $null
            if ($v -is [hashtable]) { $id = [string]$v['id'] } elseif ($v) { $id = [string]$v }
            if (-not $id) { continue }
            $base = ConvertTo-CcxVersionBase -Id $id
            if ($seen.Contains($base)) { continue }
            [void]$seen.Add($base)
            $result.Add(@{ Id = $id; IsDefault = ($id -eq $default); Source = 'local' })
        }
    }
    $include = $null
    if ($ModelNode -is [hashtable] -and $ModelNode['versions_include']) { $include = [string]$ModelNode['versions_include'] }
    foreach ($f in @($Fetched)) {
        $id = [string]$f
        if (-not $id) { continue }
        if ($include -and -not ($id -match $include)) { continue }
        $base = ConvertTo-CcxVersionBase -Id $id
        if ($seen.Contains($base)) { continue }
        [void]$seen.Add($base)
        $result.Add(@{ Id = $id; IsDefault = $false; Source = 'remote' })
    }
    return $result
}

function Resolve-CcxVersionInput {
    # §13 菜单输入解析：空→默认版；数字→编号映射；全名→须在选项内；否则 throw 无效版本
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Choice, [object]$Options)
    $opts = @($Options)
    $c = $Choice.Trim()
    if (-not $c) {
        $def = @($opts | Where-Object { $_['IsDefault'] })
        if ($def.Count -ge 1) { return [string]$def[0]['Id'] }
        throw '无效版本选择：该组未配 default_version，请输入编号或列表中的全名'
    }
    if ($c -match '^[1-9][0-9]*$') {
        $i = [int]$c - 1
        if ($i -ge 0 -and $i -lt $opts.Count) { return [string]$opts[$i]['Id'] }
        throw ('无效版本选择：编号 ' + $c + ' 超出范围（1-' + $opts.Count + '）')
    }
    foreach ($o in $opts) { if ([string]$o['Id'] -eq $c) { return $c } }
    throw ('无效版本选择：' + $c + '（输入编号或列表中的全名）')
}

function Get-CcxRemoteVersions {
    # §13 B 在线发现：GET <base_url>/v1/models（Bearer）；任何异常/畸形 → @() 静默（只当发现器，永不写回 registry）
    # -Fetcher 缝：param($Url,$Headers,$TimeoutSec) → 响应文本（默认真 Invoke-WebRequest，4s 超时）
    param(
        [Parameter(Mandatory = $true)][hashtable]$Account,
        [int]$TimeoutSec = 4,
        [scriptblock]$Fetcher
    )
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $url = ([string]$Account['base_url']).TrimEnd('/') + '/v1/models'
        $headers = @{ 'Authorization' = 'Bearer ' + $Account['auth_token'] }
        $txt = $null
        if ($Fetcher) { $txt = [string](& $Fetcher -Url $url -Headers $headers -TimeoutSec $TimeoutSec) }
        else {
            $resp = Invoke-WebRequest -Uri $url -Method Get -Headers $headers -TimeoutSec $TimeoutSec -UseBasicParsing
            $txt = [string]$resp.Content
        }
        $json = $txt | ConvertFrom-Json
        $ids = @()
        foreach ($d in @($json.data)) {
            if ($d -and $d.PSObject.Properties['id']) { $ids += [string]$d.id }
        }
        return $ids
    } catch {
        return @()
    }
}

function Get-CcxModelNode {
    # §13 models 别名节按 vendor 命中；同 vendor 多节点（旧裸别名+versions 节并存，活 registry 实测形态）
    # → 优先带 versions/default_version 者，裸节点兜底；未配/无 models 节 → $null
    param([AllowNull()]$Registry, [Parameter(Mandatory = $true)][string]$Vendor)
    if (-not $Registry -or -not $Registry['models']) { return $null }
    $fallback = $null
    foreach ($k in @($Registry['models'].Keys)) {
        $node = $Registry['models'][$k]
        if ($node -is [hashtable] -and [string]$node['vendor'] -eq $Vendor) {
            if ($node['versions'] -or $node['default_version']) { return $node }
            if (-not $fallback) { $fallback = $node }
        }
    }
    return $fallback
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

function Get-CcxProbeModel {
    # 探针模型名：env.ANTHROPIC_MODEL 剥尾 [..] 标签（与 Claude Code 客户端同构——
    # CC 发请求前会剥 [1M] 类标签，裸发带 [1M] 串实测必 400 [1211]，探针不同构会把好号误报死）；空 → 兜底最小模型
    param([Parameter(Mandatory = $true)][hashtable]$Account)
    $model = $null
    if ($Account['env'] -is [hashtable]) { $model = [string]$Account['env']['ANTHROPIC_MODEL'] }
    if (-not $model) { return 'claude-3-5-haiku-20241022' }
    return ($model -replace '\[[^\]]*\]\s*$', '')
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
    $model = Get-CcxProbeModel -Account $Account
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
    if ($body -match '(?i)模型不存在|model[\s_-]*not[\s_-]*(found|exist)|model_not_found|does[\s_-]+not[\s_-]+exist|no[\s_-]+such[\s_-]+model|unknown[\s_-]+model|invalid[\s_-]+model') {
        # 模型名配置错（非号的状态）：不标记（标记无意义）、由调用方明错不启动——2026-11-26 实跑 400 [1211] 定谳
        return @{ Ok = $false; Marked = $null; Fatal = $true; Detail = ('模型不存在 HTTP ' + $status + ' ' + $body) }
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
        # 终审#2：全停用组时上层会传 $null（Get-CcxVendorGroup 对 0 个可用号返回 null），
        # Mandatory 遇显式 $null 在真控制台会转交互提示（假挂）→ AllowNull + 下方空组护栏
        [Parameter(Mandatory = $true)][AllowNull()][hashtable]$Group,
        [switch]$NoCheck,
        [string]$StrongId,
        [scriptblock]$Probe,
        [datetime]$Now = (Get-Date)
    )
    $warnings = @()
    if (-not $Group -or -not $Group['Accounts'] -or @($Group['Accounts']).Count -eq 0) {
        return @{ Account = $null; Warnings = $warnings; Panel = '  该模型组没有可用账号（全部停用或未配置，ccx list 查看 / ccx add 添加）' }
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
            if ($pf['Fatal']) {
                throw ('ccx: {0} {1}（模型名配置错，不标记不启动——强指也起不来）— 修 registry 该号 env 的模型键，或 ccx rm/ccx add 重配' -f $acc['id'], $pf['Detail'])
            }
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
        if ($pf['Fatal']) {
            throw ('ccx: {0} {1}（模型名配置错，不标记不启动）— 修 registry 该号 env 的模型键，或 ccx rm/ccx add 重配' -f $acc['id'], $pf['Detail'])
        }
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
        elseif ($pf['Fatal']) { $txt = '模型不存在(配置错)' }
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
    # -Version（§13）：ANTHROPIC_* 含 MODEL 的键——*_NAME ← 基名(去尾[..])、其余 ← 版本串；
    #   并确保 ANTHROPIC_MODEL 与一条 *_NAME（缺则补 ANTHROPIC_DEFAULT_OPUS_MODEL_NAME）写入；其余键不动。无 -Version 与 A期逐字节一致
    param([Parameter(Mandatory = $true)][hashtable]$Account, [string]$Version)
    $merged = @{}
    $settings = Read-CcxJson -Path (Get-CcxSettingsPath)
    if ($null -ne $settings -and $settings['env'] -is [hashtable]) {
        foreach ($k in @($settings['env'].Keys)) { $merged[$k] = $settings['env'][$k] }
    }
    if ($Account['env'] -is [hashtable]) {
        foreach ($k in @($Account['env'].Keys)) { $merged[$k] = $Account['env'][$k] }
    }
    # spec §4：base_url/auth_token 是账号顶层字段，必须注入对应 env 键（P2/P3 实证 --settings 可覆盖）
    if ($Account['base_url']) { $merged['ANTHROPIC_BASE_URL'] = [string]$Account['base_url'] }
    if ($Account['auth_token']) { $merged['ANTHROPIC_AUTH_TOKEN'] = [string]$Account['auth_token'] }
    $merged['CCX_ACCOUNT_ID'] = [string]$Account['id']
    $merged['CCX_ACCOUNT_LABEL'] = [string]$Account['label']
    if ($Version) {
        $ver = [string]$Version
        $base = $ver -replace '\[[^\]]*\]\s*$', ''
        foreach ($k in @($merged.Keys)) {
            if ($k -like 'ANTHROPIC*MODEL*') {
                if ($k.EndsWith('_NAME')) { $merged[$k] = $base } else { $merged[$k] = $ver }
            }
        }
        if (-not $merged.Contains('ANTHROPIC_MODEL')) { $merged['ANTHROPIC_MODEL'] = $ver }
        $hasName = $false
        foreach ($k in @($merged.Keys)) { if ($k -like 'ANTHROPIC*MODEL*' -and $k.EndsWith('_NAME')) { $hasName = $true; break } }
        if (-not $hasName) { $merged['ANTHROPIC_DEFAULT_OPUS_MODEL_NAME'] = $base }
    }
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
        # §13：该厂商已配 versions → 打印编号列表可选（仍可自由输入全名；-Answers 注入路径零变化）
        $addOpts = @()
        if ($vendor) {
            $addNode = Get-CcxModelNode -Registry $reg -Vendor $vendor
            if ($addNode -and $addNode['versions']) { $addOpts = @(Get-CcxVersionOptions -ModelNode $addNode -Fetched @()) }
        }
        if ($addOpts.Count -gt 0) {
            Write-Output '该组可选版本:'
            for ($i = 0; $i -lt $addOpts.Count; $i++) {
                $mk = ''
                if ($addOpts[$i]['IsDefault']) { $mk = '（默认）' }
                Write-Output ('  ' + ($i + 1) + '. ' + $addOpts[$i]['Id'] + $mk)
            }
        }
        $model = Read-Host '模型全名（如 glm-5.3[1M]；可输上方编号）'
        if ($model -match '^[1-9][0-9]*$' -and $addOpts.Count -gt 0) {
            $model = Resolve-CcxVersionInput -Choice $model -Options $addOpts
        }
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
    Write-CcxTextAtomic -Path $sp -Content (ConvertTo-Json -Depth 32 -InputObject $settings)

    $reg['default_account'] = $Id
    Save-CcxJson -Path (Join-Path (Get-CcxHome) 'registry.json') -Data $reg
    Write-Output ('默认号已设为 ' + $Id + '，settings.json 已同步（备份: ' + (Split-Path $bak -Leaf) + '）')
}

function Get-CcxVendorGroup {
    # 按 vendor 直接建组（-p 非交互取 default 组 / 交互菜单用）
    param([Parameter(Mandatory = $true)][hashtable]$Registry, [Parameter(Mandatory = $true)][string]$Vendor)
    $accounts = @($Registry['accounts'] | Where-Object { $_ -and $_['enabled'] -ne $false -and $_['vendor'] -eq $Vendor })
    if ($accounts.Count -eq 0) { return $null }
    $label = $Vendor
    if ($Registry['models'] -is [hashtable]) {
        foreach ($k in @($Registry['models'].Keys)) {
            if ($Registry['models'][$k]['vendor'] -eq $Vendor) { $label = $Registry['models'][$k]['label']; break }
        }
    }
    return @{ Vendor = $Vendor; Label = $label; Accounts = $accounts }
}

function Invoke-CcxLaunch {
    # 启动路径：模型解析（-p 绝不 Read-Host）→ 选号+预检接力 → 临时 settings → claude 透传 → finally 清理
    # 失败模板：号池不可用(<原因>)。裸 claude 不受影响，仍可用 settings.json 快照号。
    param([string]$ModelSpec, [string[]]$Passthrough = @(), [switch]$NoCheck, [scriptblock]$Probe)

    $reg = $null
    try { $reg = Read-CcxRegistry } catch {
        throw ('号池不可用(registry.json 损坏: ' + $_.Exception.Message + ')。裸 claude 不受影响，仍可用 settings.json 快照号。')
    }
    if ($null -eq $reg) { throw '号池不可用(registry.json 不存在，先 ccx add)。裸 claude 不受影响，仍可用 settings.json 快照号。' }
    if (-not $reg['accounts'] -or @($reg['accounts']).Count -eq 0) { throw '号池不可用(号池为空，先 ccx add)。裸 claude 不受影响，仍可用 settings.json 快照号。' }

    $strongId = $null
    if ($ModelSpec.Contains('@')) { $strongId = ($ModelSpec -split '@')[1] }

    $grp = $null
    if ($ModelSpec) {
        $grp = Resolve-CcxModelGroup -ModelSpec $ModelSpec -Registry $reg
        if ($null -eq $grp) {
            if ($strongId -and @($reg['accounts'] | Where-Object { $_['id'] -eq $strongId }).Count -eq 0) {
                throw ('强指号不存在: ' + $strongId)
            }
            $aliases = ''
            if ($reg['models'] -is [hashtable]) { $aliases = (@($reg['models'].Keys) -join ', ') }
            throw ('未知模型: ' + $ModelSpec + '（可用: ' + $aliases + '）')
        }
    } else {
        $grp = Resolve-CcxModelGroup -ModelSpec '' -Registry $reg
        if ($null -eq $grp) {
            # 多 vendor：-p/--print 非交互 → default_account 组（无 default 取第一组），绝不 Read-Host
            $nonInteractive = (@($Passthrough) -contains '-p') -or (@($Passthrough) -contains '--print')
            if ($nonInteractive) {
                $vendor = $null
                if ($reg['default_account']) {
                    $def = @($reg['accounts'] | Where-Object { $_['id'] -eq $reg['default_account'] } | Select-Object -First 1)
                    if ($def.Count -gt 0) { $vendor = $def[0]['vendor'] }
                }
                if (-not $vendor) { $vendor = @($reg['accounts'])[0]['vendor'] }
                $grp = Get-CcxVendorGroup -Registry $reg -Vendor $vendor
            } else {
                $vendors = @($reg['accounts'] | ForEach-Object { $_['vendor'] } | Select-Object -Unique)
                Write-Output '选择模型组:'
                for ($i = 0; $i -lt $vendors.Count; $i++) {
                    $g = Get-CcxVendorGroup -Registry $reg -Vendor $vendors[$i]
                    $cnt = 0
                    if ($g) { $cnt = @($g['Accounts']).Count }
                    $lbl = $vendors[$i]
                    if ($reg['models'] -is [hashtable]) {
                        # 同 vendor 双节点同律：优先带 versions 者（与 Get-CcxModelNode 一致），label 空则保留 vendor 名
                        $lblNode = $null
                        foreach ($k in @($reg['models'].Keys)) {
                            $mn = $reg['models'][$k]
                            if ($mn -is [hashtable] -and [string]$mn['vendor'] -eq $vendors[$i]) {
                                if ($mn['versions'] -or $mn['default_version']) { $lblNode = $mn; break }
                                if (-not $lblNode) { $lblNode = $mn }
                            }
                        }
                        if ($lblNode -and $lblNode['label']) { $lbl = $lblNode['label'] }
                    }
                    Write-Output ('  ' + ($i + 1) + '. ' + $lbl + '（' + $vendors[$i] + '，' + $cnt + ' 个号）')
                }
                $choice = Read-Host '输入编号'
                $n = 0
                if (-not [int]::TryParse([string]$choice, [ref]$n) -or $n -lt 1 -or $n -gt $vendors.Count) { throw ('无效选择: ' + $choice) }
                $grp = Get-CcxVendorGroup -Registry $reg -Vendor $vendors[$n - 1]
            }
        }
    }

    $state = Read-CcxState
    $r = Select-AndPreflight -Registry $reg -State $state -Group $grp -NoCheck:$NoCheck -StrongId $strongId -Probe $Probe
    foreach ($w in @($r['Warnings'])) { Write-Output ('⚠ ' + $w) }
    if ($null -eq $r['Account']) {
        Write-Output $r['Panel']
        exit 1
    }
    $acc = $r['Account']

    # §13 版本选择：交互（无别名/强指且非 -p/--print）→ C⊕B 菜单（唯一选项静默直用；回车=默认版；
    # 未配默认又回车 → 不覆盖原样=兜底）；别名/强指/-p 快路径 → default_version 直用不问；
    # options 空 → 不覆盖（A期原样）。B 发现用选中号的 base_url/token，失败静默空、永不写回 registry
    $version = $null
    $interactive = (-not $ModelSpec) -and (-not (@($Passthrough) -contains '-p')) -and (-not (@($Passthrough) -contains '--print'))
    $modelNode = Get-CcxModelNode -Registry $reg -Vendor ([string]$acc['vendor'])
    if ($interactive) {
        $fetched = Get-CcxRemoteVersions -Account $acc
        $options = @(Get-CcxVersionOptions -ModelNode $modelNode -Fetched $fetched)
        if ($options.Count -eq 1) {
            $version = [string]$options[0]['Id']
        } elseif ($options.Count -gt 1) {
            Write-Output '选择版本:'
            for ($i = 0; $i -lt $options.Count; $i++) {
                $marks = ''
                if ($options[$i]['IsDefault']) { $marks += '（默认）' }
                if ($options[$i]['Source'] -eq 'remote') { $marks += ' ✚' }
                Write-Output ('  ' + ($i + 1) + '. ' + $options[$i]['Id'] + $marks)
            }
            $choice = [string](Read-Host '输入编号或全名（回车=默认）')
            $hasDefault = @($options | Where-Object { $_['IsDefault'] }).Count -gt 0
            if ([string]::IsNullOrWhiteSpace($choice) -and -not $hasDefault) {
                Write-Output 'ccx: 未配 default_version，回车=按账号 env 原样启动'
            } else {
                $version = Resolve-CcxVersionInput -Choice $choice -Options $options
            }
        }
    } elseif ($modelNode -and $modelNode['default_version']) {
        $version = [string]$modelNode['default_version']
    }

    $passthroughTxt = ''
    if (@($Passthrough).Count -gt 0) { $passthroughTxt = ' ' + (@($Passthrough) -join ' ') }
    $verTxt = ''
    if ($version) { $verTxt = ' @ ' + $version }
    Write-Output ('ccx: 启动 ' + $acc['label'] + '（' + $acc['id'] + '）' + $verTxt + $passthroughTxt)

    $env2 = Merge-CcxEnv -Account $acc -Version:$version
    $tmp = Write-CcxTempSettings -Env $env2
    $claudeCmd = 'claude'
    if ($env:CCX_CLAUDE_CMD) { $claudeCmd = $env:CCX_CLAUDE_CMD }
    $argList = @('--settings', $tmp) + @($Passthrough)
    $global:LASTEXITCODE = 0
    try {
        & $claudeCmd @argList
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } finally {
        Remove-CcxTempSettings -Path $tmp
    }
}
