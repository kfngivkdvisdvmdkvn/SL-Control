# ============================================================================
#  SL Control Agent — ตัวติดตั้ง/อัพเดทออนไลน์ (รันบรรทัดเดียว, ขอสิทธิ์แอดมินเอง)
#
#  วิธีใช้ที่เครื่องลูก (PowerShell โหมดปกติ ไม่ต้อง Run as admin):
#     [Net.ServicePointManager]::SecurityProtocol='Tls12'; iex ((irm <ลิงก์>/install_online.ps1).TrimStart([char]0xFEFF))
#
#  หลักการสำคัญ (แก้ 2026-09-06):
#     "โหลดให้เสร็จและตรวจไฟล์ให้ผ่านก่อน ค่อยแตะของเดิม"
#     ของเดิมหยุด agent + เขียนทับ agent.exe ตั้งแต่ยังไม่ได้โหลด -> ถ้าเน็ตสะดุด
#     (ยิงพร้อมกัน 500 เครื่อง ต้นทางจำกัดความเร็ว) เครื่องนั้นจะเหลือไฟล์พัง = เหมือนโดนถอนโปรแกรม
#     ตอนนี้: โหลดลงที่พักก่อน -> ตรวจว่าเป็น .exe จริงและครบไฟล์ -> ค่อยสลับ ->
#     สลับแล้วเปิดไม่ขึ้นก็ย้อนกลับตัวเดิมให้อัตโนมัติ
#
#  *** แก้ 2 ลิงก์ + IP ด้านล่างก่อนอัปโหลด ***
# ============================================================================
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'      # ปิดแถบความคืบหน้า = โหลดไฟล์ใหญ่เร็วขึ้นมาก

# ====== ตั้งค่า — แก้ตรงนี้ก่อนเอาขึ้นออนไลน์ ======
$AgentUrl = 'https://www.dropbox.com/scl/fi/mivxi8iavjg517kkzpdwa/agent.exe?rlkey=88rlh5iw93jl57yp6xet9nqky&dl=1'
$SelfUrl  = 'https://github.com/kfngivkdvisdvmdkvn/SL-Control/raw/refs/heads/main/install_online.ps1'
$ServerIp = ''                               # IP เครื่องคุม (เว้นว่าง = ให้หาเจอเองในวง LAN)
$Password = 'SL'                             # รหัสเชื่อมต่อ (ต้องตรงกับเครื่องคุม)
$MinSizeMB = 5                               # ไฟล์ที่โหลดมาต้องไม่เล็กกว่านี้ ไม่งั้นถือว่าโหลดไม่ครบ
$Tries     = 4                               # โหลดไม่สำเร็จ ลองใหม่กี่ครั้ง
$StaggerMax = 8                              # สุ่มรอ 0-N วินาทีก่อนโหลด (กันยิงพร้อมกันทีละหลายร้อยเครื่อง)
# =================================================

# --- ยกสิทธิ์แอดมินอัตโนมัติ: ถ้ายังไม่ใช่แอดมิน -> เด้ง UAC แล้วรันสคริปต์เดิมซ้ำแบบแอดมิน ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'กำลังขอสิทธิ์แอดมิน (กด ใช่ ที่หน้าต่าง UAC)...' -ForegroundColor Yellow
    $cmd = "[Net.ServicePointManager]::SecurityProtocol='Tls12'; iex ((irm '$SelfUrl').TrimStart([char]0xFEFF))"
    Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd
    return
}

# ================= จากนี้เป็นสิทธิ์แอดมิน =================
$dir = 'C:\SLControl'; $exe = "$dir\agent.exe"; $tn = 'SLControlAgent'; $grp = 'SL Control Agent'
$stage = Join-Path $env:TEMP 'SLControl_update'
$new = Join-Path $stage 'agent.new.exe'
$bak = "$dir\agent.bak.exe"
$hadOld = Test-Path $exe

Write-Host ''
Write-Host '=== SL Control Agent — ติดตั้ง/อัพเดท ===' -ForegroundColor Cyan

# ---------------------------------------------------------------- ตัวช่วย
function Test-PyInstallerTail([IO.FileStream]$fs) {
    # agent.exe เป็น PyInstaller onefile = ตัวโปรแกรม + "คลังไฟล์" ต่อท้ายไว้ตอนท้ายสุด
    # ถ้าไฟล์ขาดท้าย (โหลด/คัดลอกไม่ครบ) เครื่องหมายนี้จะหายไป แล้วเปิดโปรแกรมจะขึ้น
    # "Could not load PyInstaller's embedded PKG archive" — เจอจริงหน้างาน 2026-09-12
    $tail = [Math]::Min(8192, $fs.Length)
    $fs.Seek(-$tail, 'End') | Out-Null
    $t = New-Object byte[] $tail
    $fs.Read($t, 0, $tail) | Out-Null
    $magic = [byte[]](0x4D, 0x45, 0x49, 0x0C, 0x0B, 0x0A, 0x0B, 0x0E)      # 'MEI' + รหัส
    for ($i = 0; $i -le ($t.Length - $magic.Length); $i++) {
        $ok = $true
        for ($j = 0; $j -lt $magic.Length; $j++) {
            if ($t[$i + $j] -ne $magic[$j]) { $ok = $false; break }
        }
        if ($ok) { return $true }
    }
    return $false
}

function Test-AgentFile([string]$path) {
    # ไฟล์ที่ใช้ได้ต้อง: มีอยู่จริง · ใหญ่พอ · ขึ้นต้นด้วย 'MZ' · **มีคลังไฟล์ต่อท้ายครบ**
    # กันเคสต้นทางตอบหน้าเว็บ error / ไฟล์โหลดมาไม่ครบ แล้วเราเอาไปทับของดี
    if (-not (Test-Path $path)) { return $false }
    $len = (Get-Item $path).Length
    if ($len -lt ($MinSizeMB * 1MB)) { return $false }
    try {
        $fs = [IO.File]::OpenRead($path)
        $b = New-Object byte[] 2
        $n = $fs.Read($b, 0, 2)
        if ($n -ne 2 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) { $fs.Close(); return $false }
        $tailOk = Test-PyInstallerTail $fs
        $fs.Close()
    } catch { return $false }
    return $tailOk
}

function Get-Sha([string]$path) {
    if (-not (Test-Path $path)) { return '' }
    return (Get-FileHash -Path $path -Algorithm SHA256).Hash
}

function Start-Agent() {
    Start-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    for ($i = 0; $i -lt 12; $i++) {
        if (Get-Process -Name agent -ErrorAction SilentlyContinue) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return [bool](Get-Process -Name agent -ErrorAction SilentlyContinue)
}

function Copy-WithRetry([string]$src, [string]$dst) {
    # ไฟล์อาจยังถูกล็อกอยู่แป๊บนึงหลังปิดโปรเซส -> ลองซ้ำสัก 10 วินาที
    for ($i = 0; $i -lt 20; $i++) {
        try {
            Copy-Item $src $dst -Force
            return $true
        } catch { Start-Sleep -Milliseconds 500 }
    }
    return $false
}

# ---------------------------------------------------- 1) โหลดตัวใหม่ลงที่พักก่อน
New-Item -ItemType Directory -Force $stage | Out-Null
Remove-Item $new -Force -ErrorAction SilentlyContinue
if ($StaggerMax -gt 0) {
    $wait = Get-Random -Minimum 0 -Maximum ($StaggerMax + 1)
    if ($wait -gt 0) {
        Write-Host ("รอ $wait วินาทีก่อนโหลด (กระจายคิว ไม่ให้ทุกเครื่องยิงพร้อมกัน)...")
        Start-Sleep -Seconds $wait
    }
}

$ok = $false
for ($try = 1; $try -le $Tries; $try++) {
    try {
        Write-Host ("ดาวน์โหลด agent.exe ... (ครั้งที่ $try/$Tries)")
        Remove-Item $new -Force -ErrorAction SilentlyContinue
        Invoke-WebRequest -Uri $AgentUrl -OutFile $new -UseBasicParsing -TimeoutSec 600
    } catch {
        Write-Host ("   โหลดไม่สำเร็จ: " + $_.Exception.Message) -ForegroundColor DarkYellow
    }
    if (Test-AgentFile $new) { $ok = $true; break }
    Write-Host '   ไฟล์ที่ได้ไม่สมบูรณ์ (ไม่ใช่ไฟล์โปรแกรม/โหลดไม่ครบ)' -ForegroundColor DarkYellow
    if ($try -lt $Tries) {
        $sleep = (@(4, 12, 30)[$try - 1]) + (Get-Random -Minimum 0 -Maximum 6)
        Write-Host ("   รอ $sleep วินาทีแล้วลองใหม่...")
        Start-Sleep -Seconds $sleep
    }
}

if (-not $ok) {
    Remove-Item $new -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host 'โหลดไฟล์ใหม่ไม่สำเร็จ — ไม่ได้แตะของเดิมเลย เครื่องนี้ยังใช้ตัวเก่าได้ตามปกติ' -ForegroundColor Yellow
    if ($hadOld) {
        if (Start-Agent) { Write-Host 'ตัวเก่ายังทำงานอยู่' -ForegroundColor Green }
    } else {
        Write-Host 'เครื่องนี้ยังไม่เคยติดตั้ง — ลองรันคำสั่งนี้ใหม่อีกครั้งภายหลัง' -ForegroundColor Yellow
    }
    Start-Sleep -Seconds 5
    return
}
Write-Host ('   โหลดครบแล้ว: {0:N1} MB' -f ((Get-Item $new).Length / 1MB)) -ForegroundColor Green

# ---------------------------------------------------- 2) เหมือนเดิมอยู่แล้วก็ไม่ต้องสลับ
if ($hadOld -and (Get-Sha $new) -eq (Get-Sha $exe)) {
    Write-Host 'เป็นเวอร์ชันล่าสุดอยู่แล้ว — ไม่ต้องติดตั้งทับ' -ForegroundColor Green
    Remove-Item $new -Force -ErrorAction SilentlyContinue
    if (-not (Get-Process -Name agent -ErrorAction SilentlyContinue)) {
        Write-Host 'แต่ agent ไม่ได้รันอยู่ — สั่งเปิดให้ใหม่'
        Start-Agent | Out-Null
    }
    Start-Sleep -Seconds 3
    return
}

# ---------------------------------------------------- 3) สลับตัวใหม่ (ถึงตอนนี้ค่อยแตะของเดิม)
Write-Host 'ปิดตัวเก่าแล้วติดตั้งตัวใหม่...'
New-Item -ItemType Directory -Force $dir | Out-Null
Stop-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
Stop-Process -Name agent -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Unregister-ScheduledTask -TaskName 'NetClassAgent' -Confirm:$false -ErrorAction SilentlyContinue   # ชื่อเก่าสมัยก่อน

Remove-Item $bak -Force -ErrorAction SilentlyContinue
if ($hadOld) { Copy-Item $exe $bak -Force -ErrorAction SilentlyContinue }     # เก็บตัวเก่าไว้ย้อนกลับ

if (-not (Copy-WithRetry $new $exe)) {
    Write-Host 'เขียนไฟล์ทับไม่ได้ (ไฟล์ถูกใช้งานอยู่?) — คืนค่าตัวเดิมให้แล้ว' -ForegroundColor Red
    if ((Test-Path $bak) -and -not (Test-AgentFile $exe)) { Copy-Item $bak $exe -Force -ErrorAction SilentlyContinue }
    Start-Agent | Out-Null
    Start-Sleep -Seconds 5
    return
}

# ---------------------------------------------------- 4) config.json (ของเดิมเก็บค่าไว้ แค่ตัด BOM)
$cfgPath = "$dir\config.json"
if (Test-Path $cfgPath) {
    $cfgJson = [IO.File]::ReadAllText($cfgPath)
} else {
    $cfg = [ordered]@{ password = $Password; discovery_port = 45454; control_port = 45455; server_ip = $ServerIp; status_interval = 5; group = '' }
    $cfgJson = $cfg | ConvertTo-Json
}
[IO.File]::WriteAllText($cfgPath, $cfgJson, (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------- 5) Scheduled Task + Firewall
Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
$a = New-ScheduledTaskAction -Execute $exe -WorkingDirectory $dir
$t = New-ScheduledTaskTrigger -AtLogOn
$p = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Highest
$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden
Register-ScheduledTask -TaskName $tn -Action $a -Trigger $t -Principal $p -Settings $s -Force | Out-Null

Remove-NetFirewallRule -Group $grp -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'SL Control Agent (In)'  -Group $grp -Direction Inbound  -Program $exe -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'SL Control Agent (Out)' -Group $grp -Direction Outbound -Program $exe -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'SL Control Agent Discovery UDP' -Group $grp -Direction Inbound -Protocol UDP -LocalPort 45454 -Action Allow -Profile Any | Out-Null

# ---------------------------------------------------- 6) เปิดใช้งาน + ถ้าไม่ขึ้นให้ย้อนกลับตัวเดิม
if (Start-Agent) {
    Remove-Item $new -Force -ErrorAction SilentlyContinue
    Remove-Item $bak -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host 'ติดตั้งเสร็จเรียบร้อย! เครื่องนี้ควรโผล่ในตาราง Console ภายใน 2-15 วินาที' -ForegroundColor Green
} elseif (Test-Path $bak) {
    Write-Host 'ตัวใหม่เปิดไม่ขึ้น — ย้อนกลับไปใช้ตัวเดิมให้แล้ว' -ForegroundColor Red
    Copy-WithRetry $bak $exe | Out-Null
    Start-Agent | Out-Null
} else {
    Write-Host 'ติดตั้งแล้วแต่ agent ยังไม่เริ่มทำงาน — ลองรีสตาร์ตเครื่อง หรือรันคำสั่งนี้ใหม่' -ForegroundColor Yellow
}
Start-Sleep -Seconds 4
