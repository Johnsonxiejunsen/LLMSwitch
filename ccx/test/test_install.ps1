# Task 10 install 测试：profile 注入、幂等、dot-source 后 ccx 可用
. (Join-Path $PSScriptRoot 'assert.ps1')

$testHome = Join-Path ([IO.Path]::GetTempPath()) ('ccx-t10-' + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force $testHome | Out-Null
$env:CCX_HOME = $testHome
$profileFx = Join-Path $testHome 'profile.ps1'
$env:CCX_PROFILE_PATH = $profileFx
$ccx = Join-Path $PSScriptRoot '..\bin\ccx.ps1'
try {
    # registry 供 ccx list 用
    Import-Module (Join-Path $PSScriptRoot '..\bin\ccx-core.psm1') -Force
    $reg = @{
        schema   = 1
        models   = @{ glm = @{ vendor = 'bigmodel'; label = '智谱 GLM' } }
        accounts = @(
            @{ id = 'glm-1'; label = '智谱1'; vendor = 'bigmodel'; priority = 1; enabled = $true; base_url = 'https://b.example'; auth_token = 't1'; env = @{} }
        )
    }
    Save-CcxJson -Path (Join-Path $testHome 'registry.json') -Data $reg
    Remove-Module ccx-core -ErrorAction SilentlyContinue

    # ① 首次 install → 文件含 function
    Assert-True (-not (Test-Path $profileFx)) '前置：profile 不存在'
    $out1 = Join-Path $testHome 'i1.out'
    $p1 = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ccx,'install') -Wait -PassThru -NoNewWindow -RedirectStandardOutput $out1 -RedirectStandardError (Join-Path $testHome 'i1.err')
    Assert-Equal 0 $p1.ExitCode '首次 install exit 0'
    Assert-True (Test-Path $profileFx) 'profile 已创建'
    $txt = [IO.File]::ReadAllText($profileFx)
    Assert-True ($txt -like '*function ccx*') '含 function ccx'
    Assert-True ($txt -like '*\ccx\bin\ccx.ps1*') '指向 ccx.ps1 绝对路径'

    # ② 再跑 → 幂等（字节不变）
    $bytes1 = [IO.File]::ReadAllBytes($profileFx)
    $p2 = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ccx,'install') -Wait -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $testHome 'i2.out') -RedirectStandardError (Join-Path $testHome 'i2.err')
    Assert-Equal 0 $p2.ExitCode '二次 install exit 0'
    $bytes2 = [IO.File]::ReadAllBytes($profileFx)
    Assert-True (@(Compare-Object $bytes1 $bytes2 -SyncWindow 0).Count -eq 0) '二次 install 字节不变'

    # ③ 新子进程 dot-source profile 后 ccx list 可执行
    $out3 = Join-Path $testHome 'i3.out'
    $p3 = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',('. "' + $profileFx + '"; ccx list')) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $out3 -RedirectStandardError (Join-Path $testHome 'i3.err')
    Assert-Equal 0 $p3.ExitCode 'dot-source 后 ccx list exit 0'
    Assert-True ((Get-Content $out3 -Raw -Encoding UTF8) -like '*glm-1*') 'ccx list 输出面板'
} finally {
    Remove-Item -Recurse -Force $testHome -ErrorAction SilentlyContinue
    Remove-Item Env:CCX_PROFILE_PATH -ErrorAction SilentlyContinue
}
Write-Output 'test_install OK'
