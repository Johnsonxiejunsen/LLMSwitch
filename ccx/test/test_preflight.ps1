# Task 5 预检测试：失败分类顺序、接力、强指不接力、未标记不误杀、全池 check
. (Join-Path $PSScriptRoot 'assert.ps1')
Import-Module (Join-Path $PSScriptRoot '..\bin\ccx-core.psm1') -Force

$testHome = Join-Path ([IO.Path]::GetTempPath()) ('ccx-t5-' + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force $testHome | Out-Null
$env:CCX_HOME = $testHome
try {
    $reg = @{
        schema   = 1
        models   = @{ glm = @{ vendor = 'bigmodel'; label = '智谱 GLM' } }
        accounts = @(
            @{ id = 'glm-1'; label = '智谱1'; vendor = 'bigmodel'; priority = 1; enabled = $true; base_url = 'https://x.example/api/anthropic'; auth_token = 't1'; env = @{ ANTHROPIC_MODEL = 'm' } }
            @{ id = 'glm-2'; label = '智谱2'; vendor = 'bigmodel'; priority = 1; enabled = $true; base_url = 'https://x.example/api/anthropic'; auth_token = 't2'; env = @{ ANTHROPIC_MODEL = 'm' } }
            @{ id = 'glm-3'; label = '智谱3'; vendor = 'bigmodel'; priority = 3; enabled = $true; base_url = 'https://x.example/api/anthropic'; auth_token = 't3'; env = @{ ANTHROPIC_MODEL = 'm' } }
        )
    }
    Save-CcxJson -Path (Join-Path $testHome 'registry.json') -Data $reg
    $tomorrow = (Get-Date).Date.AddDays(1)
    $acc2 = $reg['accounts'][1]

    # ok 探针
    $probeOk = { param($Account) @{ Status = 200; Body = 'ok'; NetworkError = $false } }

    # ① 401 → blocked
    $probe401 = { param($Account) @{ Status = 401; Body = 'unauthorized'; NetworkError = $false } }
    $r1 = Invoke-CcxPreflight -Account $acc2 -Probe $probe401
    Assert-Equal $false $r1['Ok'] '401 → Ok=false'
    Assert-Equal 'blocked' $r1['Marked'] '401 → Marked=blocked'
    Assert-Equal 'blocked' (Read-CcxState)['accounts']['glm-2']['status'] '401 标记落盘'

    # ② Body 含「余额不足」→ daily（非 401/429 状态码）
    $probeBal = { param($Account) @{ Status = 402; Body = '{"error":{"message":"余额不足，请充值"}}'; NetworkError = $false } }
    $r2 = Invoke-CcxPreflight -Account $acc2 -Probe $probeBal
    Assert-Equal 'daily' $r2['Marked'] '余额报文 → daily'

    # ③ 429 → r429
    $probe429 = { param($Account) @{ Status = 429; Body = 'rate limit'; NetworkError = $false } }
    $r3 = Invoke-CcxPreflight -Account $acc2 -Probe $probe429
    Assert-Equal 'r429' $r3['Marked'] '429 → r429'

    # ④ 网络错/超时 → 不标记
    $probeNet = { param($Account) @{ Status = 0; Body = '连接超时'; NetworkError = $true } }
    $r4 = Invoke-CcxPreflight -Account $acc2 -Probe $probeNet
    Assert-Equal $false $r4['Ok'] '网络错 → Ok=false'
    Assert-True ($null -eq $r4['Marked']) '网络错不标记'

    # 200 → Ok
    $r5 = Invoke-CcxPreflight -Account $acc2 -Probe $probeOk
    Assert-Equal $true $r5['Ok'] '200 → Ok=true'
    Assert-True ($null -eq $r5['Marked']) '200 不标记'

    # ⑤ 接力：glm-2 预检 401、其余 ok → 返回 glm-3 且 glm-2 已标 blocked
    $state = @{ schema = 1; accounts = @{ 'glm-1' = @{ status = 'daily'; until = $tomorrow.ToString('o') } } }
    Save-CcxState -State $state
    $grp = Resolve-CcxModelGroup -ModelSpec 'glm' -Registry $reg
    $probeRelay = { param($Account) if ($Account['id'] -eq 'glm-2') { @{ Status = 401; Body = 'unauth'; NetworkError = $false } } else { @{ Status = 200; Body = 'ok'; NetworkError = $false } } }
    $r6 = Select-AndPreflight -Registry $reg -State (Read-CcxState) -Group $grp -Probe $probeRelay
    Assert-Equal 'glm-3' $r6['Account']['id'] '接力后选 glm-3'
    Assert-Equal 'blocked' (Read-CcxState)['accounts']['glm-2']['status'] '接力中 glm-2 已标 blocked'

    # ⑥ StrongId + 死号 → 仍返回该号 + 警告
    $stateB = @{ schema = 1; accounts = @{} }
    Save-CcxState -State $stateB
    $grpG2 = Resolve-CcxModelGroup -ModelSpec 'glm@glm-2' -Registry $reg
    $r7 = Select-AndPreflight -Registry $reg -State (Read-CcxState) -Group $grpG2 -StrongId 'glm-2' -Probe $probe401
    Assert-Equal 'glm-2' $r7['Account']['id'] '强指死号仍返回该号'
    Assert-True ($r7['Warnings'].Count -ge 1) '强指死号有警告'

    # ⑦ 全死 → Account=null + 面板
    $stateC = @{ schema = 1; accounts = @{ 'glm-1' = @{ status = 'daily'; until = $tomorrow.ToString('o') } } }
    Save-CcxState -State $stateC
    $r8 = Select-AndPreflight -Registry $reg -State (Read-CcxState) -Group $grp -Probe $probe401
    Assert-True ($null -eq $r8['Account']) '全死 → Account=null'
    Assert-True ($r8['Panel'] -like '*全池不可用*') '全死面板含全池不可用'

    # ④' 网络错（未标记）→ 照常用该号启动，不接力
    $stateD = @{ schema = 1; accounts = @{ 'glm-1' = @{ status = 'daily'; until = $tomorrow.ToString('o') } } }
    Save-CcxState -State $stateD
    $r9 = Select-AndPreflight -Registry $reg -State (Read-CcxState) -Group $grp -Probe $probeNet
    Assert-Equal 'glm-2' $r9['Account']['id'] '未标记异常照常用该号'
    Assert-True (@($r9['Warnings'] | Where-Object { $_ -like '*预检异常*' }).Count -ge 1) '未标记异常有警告'

    # -NoCheck → 不发预检（探针注入抛错证明未被调用）
    $probeBomb = { param($Account) throw '不应被调用' }
    $stateE = @{ schema = 1; accounts = @{} }
    Save-CcxState -State $stateE
    $r10 = Select-AndPreflight -Registry $reg -State (Read-CcxState) -Group $grp -NoCheck -Probe $probeBomb
    Assert-Equal 'glm-2' $r10['Account']['id'] 'NoCheck 直接选号'

    # Invoke-CcxCheck：全池逐号预检 + 面板
    $stateF = @{ schema = 1; accounts = @{} }
    Save-CcxState -State $stateF
    $reg2 = @{
        schema   = 1
        accounts = @(
            @{ id = 'c1'; label = 'C1'; vendor = 'bigmodel'; enabled = $true; auth_token = 't'; env = @{} }
            @{ id = 'c2'; label = 'C2'; vendor = 'bigmodel'; enabled = $false; auth_token = 't'; env = @{} }
        )
    }
    $probeCheck = { param($Account) if ($Account['id'] -eq 'c1') { @{ Status = 200; Body = 'ok'; NetworkError = $false } } else { @{ Status = 401; Body = 'x'; NetworkError = $false } } }
    $panel = Invoke-CcxCheck -Registry $reg2 -State (Read-CcxState) -Probe $probeCheck
    Assert-True ($panel -like '*c1*ok*') 'check 面板含 c1 ok'
    Assert-True ($panel -like '*c2*已停用*') 'check 面板含 c2 已停用'

    # ⑧ Get-CcxProbeModel：剥尾 [..] 标签（与 CC 客户端同构——裸发 [1M] 串实测必 400 [1211]，探针不同构误报好号）
    Assert-Equal 'glm-5.4' (Get-CcxProbeModel -Account @{ env = @{ ANTHROPIC_MODEL = 'glm-5.4[1M]' } }) '剥尾 [1M]'
    Assert-Equal 'glm-5.3' (Get-CcxProbeModel -Account @{ env = @{ ANTHROPIC_MODEL = 'glm-5.3' } }) '无标签原样'
    Assert-Equal 'claude-3-5-haiku-20241022' (Get-CcxProbeModel -Account @{ env = @{} }) '空 env → 兜底模型'

    # ⑨ 400+模型不存在 → Fatal（分类层不 throw 不标记，策略归调用方）
    $probeNoModel = { param($Account) @{ Status = 400; Body = '{"error":{"message":"[1211][模型不存在，请检查模型代码。]"}}'; NetworkError = $false } }
    $r11 = Invoke-CcxPreflight -Account $acc2 -Probe $probeNoModel
    Assert-Equal $false $r11['Ok'] '模型不存在 → Ok=false'
    Assert-Equal $true $r11['Fatal'] '模型不存在 → Fatal=true'
    Assert-True ($null -eq $r11['Marked']) '模型不存在不标记'
    Assert-True ($null -eq (Read-CcxState)['accounts']['glm-2']) '模型不存在状态零落盘'

    # ⑨' 英文报文同判（model not found / does not exist）
    $probeNoModelEn = { param($Account) @{ Status = 404; Body = '{"error":{"type":"not_found_error","message":"model not found: glm5.4"}}'; NetworkError = $false } }
    Assert-Equal $true (Invoke-CcxPreflight -Account $acc2 -Probe $probeNoModelEn)['Fatal'] 'model not found → Fatal'

    # ⑨'' 无关键词的 400 → 仍走未知不标（兜底铁律回归：不能把未知错全杀）
    $probe400Unknown = { param($Account) @{ Status = 400; Body = 'bad request something else'; NetworkError = $false } }
    $r12 = Invoke-CcxPreflight -Account $acc2 -Probe $probe400Unknown
    Assert-True ($null -eq $r12['Fatal']) '未知400 无 Fatal'
    Assert-True ($null -eq $r12['Marked']) '未知400 不标记'

    # ⑩ 轮转路径遇 Fatal → throw 明错不启动（不再"仍用该号启动"卖必死会话）
    $stateG = @{ schema = 1; accounts = @{} }
    Save-CcxState -State $stateG
    Assert-Throws { Select-AndPreflight -Registry $reg -State (Read-CcxState) -Group $grp -Probe $probeNoModel } '轮转遇模型不存在明错' -Like '*模型不存在*'

    # ⑩' 强指路径同判（配置错非"尊重选择"范畴：强指的号也起不来）
    Assert-Throws { Select-AndPreflight -Registry $reg -State (Read-CcxState) -Group $grpG2 -StrongId 'glm-2' -Probe $probeNoModel } '强指遇模型不存在明错' -Like '*模型不存在*'

    # ⑪ ccx check：Fatal 渲染配置错行，不中断全池遍历
    $reg3 = @{ schema = 1; accounts = @(
        @{ id = 'c3'; label = 'C3'; vendor = 'bigmodel'; enabled = $true; auth_token = 't'; env = @{} }
        @{ id = 'c4'; label = 'C4'; vendor = 'bigmodel'; enabled = $true; auth_token = 't'; env = @{} }
    ) }
    $panel3 = Invoke-CcxCheck -Registry $reg3 -State (Read-CcxState) -Probe $probeNoModel
    Assert-True ($panel3 -like '*c3*模型不存在*') 'check 面板 c3 配置错'
    Assert-True ($panel3 -like '*c4*模型不存在*') 'check 面板 c4 配置错且未中断'

    # ⑫ 终审#1 Fatal 正则收紧：非模型类 does-not-exist / invalid model parameter 不得误伤
    $probeEndpoint = { param($Account) @{ Status = 404; Body = 'endpoint does not exist'; NetworkError = $false } }
    Assert-True ($null -eq (Invoke-CcxPreflight -Account $acc2 -Probe $probeEndpoint)['Fatal']) 'endpoint does not exist 不误伤'
    $probeUser404 = { param($Account) @{ Status = 404; Body = 'user does not exist'; NetworkError = $false } }
    Assert-True ($null -eq (Invoke-CcxPreflight -Account $acc2 -Probe $probeUser404)['Fatal']) 'user does not exist 不误伤'
    $probeInvalidParam = { param($Account) @{ Status = 400; Body = 'invalid model parameter: temperature'; NetworkError = $false } }
    $r13 = Invoke-CcxPreflight -Account $acc2 -Probe $probeInvalidParam
    Assert-True ($null -eq $r13['Fatal']) 'invalid model parameter 不误伤'
    Assert-True ($null -eq $r13['Marked']) '误伤面不误标'

    # ⑫' 真阳性仍命中：OpenAI 风 "The model 'x' does not exist" / invalid model id
    $probeOai = { param($Account) @{ Status = 404; Body = "The model 'gpt-x' does not exist or you do not have access to it."; NetworkError = $false } }
    Assert-Equal $true (Invoke-CcxPreflight -Account $acc2 -Probe $probeOai)['Fatal'] "model 'x' does not exist → Fatal"
    $probeInvalidId = { param($Account) @{ Status = 400; Body = 'invalid model id provided'; NetworkError = $false } }
    Assert-Equal $true (Invoke-CcxPreflight -Account $acc2 -Probe $probeInvalidId)['Fatal'] 'invalid model id → Fatal'
} finally {
    Remove-Item -Recurse -Force $testHome -ErrorAction SilentlyContinue
    Remove-Module ccx-core -ErrorAction SilentlyContinue
}
Write-Output 'test_preflight OK'
