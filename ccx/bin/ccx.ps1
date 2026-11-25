# ccx.ps1 — ccx CLI 入口（Task 7：子命令；Task 8：启动路径）
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ccx-core.psm1') -Force

function Show-CcxUsage {
    Write-Output 'ccx — Claude Code 号池启动器'
    Write-Output '用法:'
    Write-Output '  ccx                       交互选模型并启动'
    Write-Output '  ccx -c | ccx -r           续会话，重新自动选号'
    Write-Output '  ccx <model>[@<id>]        直启模型 / 强指号'
    Write-Output '  ccx <model> ... --no-check            跳过启动预检'
    Write-Output '  ccx list                  池状态面板 + 快照漂移提示'
    Write-Output '  ccx mark <id> <r429|daily|blocked>   标记受限'
    Write-Output '  ccx unlock <id>           解锁 blocked'
    Write-Output '  ccx add | ccx rm <id>     号池维护'
    Write-Output '  ccx set-default <id>      默认号 + settings.json 同步'
    Write-Output '  ccx check                 全池逐号预检'
    Write-Output '  ccx install               把 ccx 命令装进 PowerShell profile'
}

function Invoke-CcxInstall {
    # profile 注入 function ccx（幂等：标记已存在则跳过）。块内容纯 ASCII，规避 PS 5.1 无 BOM 中文坑
    $p = $env:CCX_PROFILE_PATH
    if (-not $p) { $p = $PROFILE.CurrentUserAllHosts }
    $marker = '# >>> ccx launcher >>>'
    if (Test-Path -LiteralPath $p) {
        $existing = [IO.File]::ReadAllText($p)
        if ($existing.Contains($marker)) {
            Write-Output ('ccx 已安装过（' + $p + '），跳过')
            return
        }
    }
    $dir = Split-Path -Parent $p
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $target = Join-Path $PSScriptRoot 'ccx.ps1'
    $block = "`r`n" + $marker + "`r`n" +
        ("function ccx { & '" + $target + "' @args }") + "`r`n" +
        '# <<< ccx launcher <<<' + "`r`n"
    [IO.File]::AppendAllText($p, $block, [System.Text.ASCIIEncoding]::ASCII)
    Write-Output ('已安装 ccx → ' + $p + '（新开 PowerShell 窗口生效）')
}

try {
    if ($args.Count -eq 0) { Show-CcxUsage; exit 1 }
    $cmd = [string]$args[0]
    switch ($cmd) {        'list' { Invoke-CcxList | Write-Output }
        'mark' {
            if ($args.Count -lt 3) { throw '用法: ccx mark <id> <r429|daily|blocked>' }
            Invoke-CcxMark -Id ([string]$args[1]) -Status ([string]$args[2])
        }
        'unlock' {
            if ($args.Count -lt 2) { throw '用法: ccx unlock <id>' }
            Invoke-CcxUnlock -Id ([string]$args[1])
        }
        'add' {
            $id = Invoke-CcxAdd
            Write-Output ('已添加 ' + $id)
        }
        'rm' {
            if ($args.Count -lt 2) { throw '用法: ccx rm <id>' }
            Invoke-CcxRm -Id ([string]$args[1])
        }
        'set-default' {
            if ($args.Count -lt 2) { throw '用法: ccx set-default <id>' }
            Invoke-CcxSetDefault -Id ([string]$args[1])
        }
        'check' {
            $reg = Read-CcxRegistry
            if ($null -eq $reg -or -not $reg['accounts'] -or @($reg['accounts']).Count -eq 0) {
                Write-Output '  号池为空（ccx add 添加账号）'
            } else {
                Invoke-CcxCheck -Registry $reg -State (Read-CcxState) | Write-Output
            }
        }
        'install' { Invoke-CcxInstall }
        default {
            # 启动路径：首个非 - 开头参数=模型别名(可 @id 强指)，其余透传 claude；--no-check 剥离
            $modelSpec = ''
            $noCheck = $false
            $passthrough = @()
            foreach ($a in $args) {
                $s = [string]$a
                if ($s -eq '--no-check') { $noCheck = $true; continue }
                if (-not $modelSpec -and $s -notlike '-*') { $modelSpec = $s; continue }
                $passthrough += $s
            }
            Invoke-CcxLaunch -ModelSpec $modelSpec -Passthrough $passthrough -NoCheck:$noCheck
        }
    }
} catch {
    Write-Output ('ccx: ' + $_.Exception.Message)
    exit 1
}
