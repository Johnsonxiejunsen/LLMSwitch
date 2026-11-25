# session-info.ps1 — SessionStart 钩子：输出当前窗口账号 + 池面板（任何失败不干扰启动，恒 exit 0）
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Stop'
try {
    $corePath = Join-Path $PSScriptRoot '..\bin\ccx-core.psm1'
    if (Test-Path $corePath) { Import-Module $corePath -Force }

    if ($env:CCX_ACCOUNT_ID) {
        $label = $env:CCX_ACCOUNT_LABEL
        if (-not $label) { $label = $env:CCX_ACCOUNT_ID }
        Write-Output ('[ccx] 当前窗口账号: ' + $label + '(' + $env:CCX_ACCOUNT_ID + ')')
    } else {
        Write-Output '[ccx] 本窗口未由 ccx 启动（settings.json 快照号）'
    }
    try {
        $panel = Invoke-CcxList
        Write-Output $panel
    } catch {
        Write-Output ('[ccx] 池面板不可用: ' + $_.Exception.Message)
    }
} catch {
    Write-Output ('[ccx] ' + $_.Exception.Message)
}
exit 0
