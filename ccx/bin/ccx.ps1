# ccx.ps1 — ccx CLI 入口（Task 7：子命令；Task 8：启动路径）
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ccx-core.psm1') -Force

function Show-CcxUsage {
    Write-Output 'ccx — Claude Code 号池启动器'
    Write-Output '用法:'
    Write-Output '  ccx                       交互选模型并启动（尚未接入）'
    Write-Output '  ccx -c | ccx -r           续会话重新选号（尚未接入）'
    Write-Output '  ccx <model>[@<id>]        直启模型/强指号（尚未接入）'
    Write-Output '  ccx list                  池状态面板 + 快照漂移提示'
    Write-Output '  ccx mark <id> <r429|daily|blocked>   标记受限'
    Write-Output '  ccx unlock <id>           解锁 blocked'
    Write-Output '  ccx add | ccx rm <id>     号池维护'
    Write-Output '  ccx set-default <id>      默认号 + settings.json 同步'
    Write-Output '  ccx check                 全池逐号预检'
}

try {
    if ($args.Count -eq 0) { Show-CcxUsage; exit 1 }
    $cmd = [string]$args[0]
    switch ($cmd) {
        'list' { Invoke-CcxList | Write-Output }
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
        default {
            Write-Output ('未知命令: ' + $cmd)
            Show-CcxUsage
            exit 1
        }
    }
} catch {
    Write-Output ('ccx: ' + $_.Exception.Message)
    exit 1
}
