# ccx 测试断言原语 — 失败即 throw（子进程退出码非零）
# Stop 是 harness 契约：无它，command-not-found 只跳过当前语句，测试假绿 exit 0
$ErrorActionPreference = 'Stop'
$script:AssertCount = 0

function Assert-True {
    param($Condition, [string]$Message = 'Assert-True failed')
    $script:AssertCount++
    if (-not $Condition) { throw "[assert #$($script:AssertCount)] $Message" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = 'Assert-Equal failed')
    $script:AssertCount++
    if (-not ($Expected -eq $Actual)) {
        throw ("[assert #$($script:AssertCount)] $Message — expected: <$Expected> actual: <$Actual>")
    }
}

function Assert-Throws {
    param([scriptblock]$Script, [string]$Message = 'Assert-Throws failed', [string]$Like = $null)
    $script:AssertCount++
    try { & $Script | Out-Null } catch {
        if ($Like) {
            if ($_.Exception.Message -like $Like) { return }
            throw ("[assert #$($script:AssertCount)] $Message — 异常消息不匹配: <$($_.Exception.Message)> 期望 like <$Like>")
        }
        return
    }
    throw "[assert #$($script:AssertCount)] $Message — 未抛出异常"
}
