# ============================================================================
#  SL Control Agent — ถอนการติดตั้งออนไลน์ (รันบรรทัดเดียว, ขอสิทธิ์แอดมินเอง)
#
#  วิธีใช้ที่เครื่องลูก (PowerShell โหมดปกติ):
#     [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm <ลิงก์>/uninstall_online.ps1 | iex
#
#  *** แก้ลิงก์ $SelfUrl ให้ตรงกับที่อัปโหลดก่อน ***
# ============================================================================
$ErrorActionPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SelfUrl = 'https://github.com/kfngivkdvisdvmdkvn/SL-Control/raw/refs/heads/main/uninstall_online.ps1'

# --- ยกสิทธิ์แอดมินอัตโนมัติ ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'กำลังขอสิทธิ์แอดมิน (กด ใช่ ที่หน้าต่าง UAC)...' -ForegroundColor Yellow
    $cmd = "[Net.ServicePointManager]::SecurityProtocol='Tls12'; iex ((irm '$SelfUrl').TrimStart([char]0xFEFF))"
    Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd
    return
}

# ================= จากนี้เป็นสิทธิ์แอดมิน =================
$dir = 'C:\SLControl'; $tn = 'SLControlAgent'; $grp = 'SL Control Agent'
Write-Host ''
Write-Host '=== SL Control Agent — กำลังถอนการติดตั้ง ===' -ForegroundColor Cyan

# หยุด + ลบ Task
Stop-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
Stop-Process -Name agent -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Stop-ScheduledTask -TaskName $tn
Unregister-ScheduledTask -TaskName $tn -Confirm:$false
Unregister-ScheduledTask -TaskName 'NetClassAgent' -Confirm:$false

# ลบกฎ Firewall
Remove-NetFirewallRule -Group $grp

# ลบโฟลเดอร์ (retry เพราะ exe อาจเพิ่งปล่อยไฟล์)
for ($i = 0; $i -lt 8; $i++) {
    Remove-Item $dir -Recurse -Force
    if (-not (Test-Path $dir)) { break }
    Start-Sleep -Milliseconds 600
}

Write-Host ''
if (Test-Path $dir) { Write-Host "ถอนแล้วบางส่วน (ลบ $dir ไม่หมด — อาจมีไฟล์ค้าง)" -ForegroundColor Yellow }
else { Write-Host 'ถอนการติดตั้งเรียบร้อย' -ForegroundColor Green }
Start-Sleep -Seconds 4
