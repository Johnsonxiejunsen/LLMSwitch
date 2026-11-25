# harness 自检：断言原语本身可用
. (Join-Path $PSScriptRoot 'assert.ps1')

Assert-Equal 1 1 'Assert-Equal 基本相等'
Assert-True ($true) 'Assert-True 接受真值'

$threw = $false
try { Assert-Equal 1 2 '应当失败' } catch { $threw = $true }
Assert-True $threw 'Assert-Equal 失败路径必须 throw'

Assert-Throws { throw 'boom' } 'Assert-Throws 捕获异常' -Like '*boom*'

$noThrow = $false
try { Assert-Throws { Write-Output 'nope' } '未抛异常必须判失败' } catch { $noThrow = $true }
Assert-True $noThrow 'Assert-Throws 对无异常必须 throw'

Write-Output 'harness self-check OK'
