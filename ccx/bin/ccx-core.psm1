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
