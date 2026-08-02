# ============================================================================
#  SL Control Agent — ตัวติดตั้งออนไลน์ (รันบรรทัดเดียว, ขอสิทธิ์แอดมินเอง)
#
#  วิธีใช้ที่เครื่องลูก (PowerShell โหมดปกติ ไม่ต้อง Run as admin):
#     [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm <ลิงก์>/install_online.ps1 | iex
#
#  *** แก้ 2 ลิงก์ + IP ด้านล่างก่อนอัปโหลด ***
# ============================================================================
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ====== ตั้งค่า — แก้ตรงนี้ก่อนเอาขึ้นออนไลน์ ======
$AgentUrl = 'https://github.com/kfngivkdvisdvmdkvn/SL-Control/raw/refs/heads/main/agent.exe'
$SelfUrl  = 'https://github.com/kfngivkdvisdvmdkvn/SL-Control/raw/refs/heads/main/install_online.ps1'
$ServerIp = ''                               # IP เครื่องคุม (เว้นว่าง = ให้หาเจอเองในวง LAN)
$Password = 'SL'                             # รหัสเชื่อมต่อ (ต้องตรงกับเครื่องคุม)
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
Write-Host ''
Write-Host '=== SL Control Agent — กำลังติดตั้ง/อัพเดท ===' -ForegroundColor Cyan

# 1) หยุด agent เดิม (กันไฟล์ถูกล็อกตอนเขียนทับ) + ล้างของเก่า
Stop-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
Stop-Process -Name agent -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Unregister-ScheduledTask -TaskName 'NetClassAgent' -Confirm:$false -ErrorAction SilentlyContinue

# 2) ดาวน์โหลด agent.exe
New-Item -ItemType Directory -Force $dir | Out-Null
Write-Host 'ดาวน์โหลด agent.exe ...'
Invoke-WebRequest -Uri $AgentUrl -OutFile $exe -UseBasicParsing
if (-not (Test-Path $exe) -or (Get-Item $exe).Length -lt 1MB) {
    throw "ดาวน์โหลด agent.exe ไม่สำเร็จ (ลิงก์ผิด/ไม่ใช่ลิงก์ดาวน์โหลดตรง?) — ได้ไฟล์เล็กผิดปกติ"
}

# 3) เขียน config.json (ถ้ามีของเดิมอยู่แล้วเก็บไว้ ไม่ทับ)
if (-not (Test-Path "$dir\config.json")) {
    $cfg = [ordered]@{ password = $Password; discovery_port = 45454; control_port = 45455;
        server_ip = $ServerIp; status_interval = 5; group = '' }
    ($cfg | ConvertTo-Json) | Set-Content "$dir\config.json" -Encoding UTF8
}

# 4) Scheduled Task — รันตอนล็อกอิน สิทธิ์สูงสุด เบื้องหลัง ตายแล้วรันใหม่เอง
Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
$a = New-ScheduledTaskAction -Execute $exe -WorkingDirectory $dir
$t = New-ScheduledTaskTrigger -AtLogOn
$p = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Highest
$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden
Register-ScheduledTask -TaskName $tn -Action $a -Trigger $t -Principal $p -Settings $s -Force | Out-Null

# 5) Firewall — อนุญาต agent.exe ทุกโปรไฟล์ (ส่วนตัว+สาธารณะ) -> ไม่มีหน้าต่างถามเด้ง
Remove-NetFirewallRule -Group $grp -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'SL Control Agent (In)'  -Group $grp -Direction Inbound  -Program $exe -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'SL Control Agent (Out)' -Group $grp -Direction Outbound -Program $exe -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'SL Control Agent Discovery UDP' -Group $grp -Direction Inbound -Protocol UDP -LocalPort 45454 -Action Allow -Profile Any | Out-Null

# 6) เริ่มทำงาน
Start-ScheduledTask -TaskName $tn
Write-Host ''
Write-Host 'ติดตั้งเสร็จเรียบร้อย! เครื่องนี้ควรโผล่ในตาราง Console ภายใน 2-15 วินาที' -ForegroundColor Green
Start-Sleep -Seconds 4
