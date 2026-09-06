# ============================================================================
#  SL Control Agent — อัพเดทจาก "ไฟล์ที่ส่งมาจากคอนโซล" (ไม่ต้องโหลดจากเน็ต)
#
#  ใช้ตอนอัพเดทหลายร้อยเครื่องพร้อมกัน — ดีกว่าให้ทุกเครื่องไปโหลดลิงก์เดียวกัน
#  เพราะไฟล์วิ่งในวง LAN ของเราเอง (คอนโซลคุมความเร็ว/ทีละกี่เครื่องได้)
#
#  ขั้นตอนที่คอนโซล:
#    1) เมนู "ส่งไฟล์" -> เลือก agent.exe -> ปลายทาง  C:\SLControl\update
#       (รอให้ส่งครบทุกเครื่องก่อน! ดูรายงานให้ครบ 100%)
#    2) เมนู "รันคำสั่ง" -> PowerShell -> ติ๊ก "เปิดแล้วปล่อย (ไม่รอผล)" -> วางบรรทัดนี้:
#         powershell -NoProfile -ExecutionPolicy Bypass -File C:\SLControl\update\update_from_console.ps1
#       (ส่งไฟล์นี้ไปพร้อม agent.exe ด้วย)
#
#  หลักการเดียวกับตัวติดตั้งออนไลน์: ตรวจไฟล์ให้ผ่านก่อน ค่อยแตะของเดิม
#  ถ้าไฟล์ที่ส่งมาไม่ครบ/ไม่ใช่โปรแกรม -> ไม่ทำอะไรเลย เครื่องนั้นยังใช้ตัวเก่าได้
# ============================================================================
$ErrorActionPreference = 'Stop'

$dir = 'C:\SLControl'
$exe = "$dir\agent.exe"
$new = "$dir\update\agent.exe"
$bak = "$dir\agent.bak.exe"
$tn  = 'SLControlAgent'
$log = "$dir\update\update_log.txt"

function Say([string]$m) {
    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m)
    Write-Host $line
    try { Add-Content -Path $log -Value $line -Encoding UTF8 } catch { }
}

function Test-AgentFile([string]$p) {
    if (-not (Test-Path $p)) { return $false }
    if ((Get-Item $p).Length -lt 5MB) { return $false }
    try {
        $fs = [IO.File]::OpenRead($p); $b = New-Object byte[] 2
        $n = $fs.Read($b, 0, 2); $fs.Close()
    } catch { return $false }
    return ($n -eq 2 -and $b[0] -eq 0x4D -and $b[1] -eq 0x5A)
}

function Start-Agent() {
    Start-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 12; $i++) {
        if (Get-Process -Name agent -ErrorAction SilentlyContinue) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return [bool](Get-Process -Name agent -ErrorAction SilentlyContinue)
}

function Copy-WithRetry([string]$s, [string]$d) {
    for ($i = 0; $i -lt 20; $i++) {
        try { Copy-Item $s $d -Force; return $true } catch { Start-Sleep -Milliseconds 500 }
    }
    return $false
}

# ---- 1) ไฟล์ที่คอนโซลส่งมาต้องครบและใช้ได้จริงก่อน ----
if (-not (Test-AgentFile $new)) {
    Say 'ไฟล์ใหม่ยังมาไม่ครบ/ไม่ใช่ไฟล์โปรแกรม -> ไม่แตะของเดิม'
    if (Test-Path $exe) { Start-Agent | Out-Null }
    exit 1
}
if ((Test-Path $exe) -and (Get-FileHash $new -Algorithm SHA256).Hash -eq (Get-FileHash $exe -Algorithm SHA256).Hash) {
    Say 'เป็นตัวเดียวกับที่ใช้อยู่แล้ว -> ไม่ต้องอัพเดท'
    if (-not (Get-Process -Name agent -ErrorAction SilentlyContinue)) { Start-Agent | Out-Null }
    Remove-Item $new -Force -ErrorAction SilentlyContinue
    exit 0
}

# ---- 2) ถึงตอนนี้ค่อยสลับ ----
Say 'ไฟล์ใหม่พร้อม -> ปิดตัวเก่าแล้วสลับ'
Stop-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
Stop-Process -Name agent -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Remove-Item $bak -Force -ErrorAction SilentlyContinue
if (Test-Path $exe) { Copy-Item $exe $bak -Force -ErrorAction SilentlyContinue }

if (-not (Copy-WithRetry $new $exe)) {
    Say 'เขียนทับไม่ได้ (ไฟล์ถูกใช้อยู่) -> คืนตัวเดิม'
    if ((Test-Path $bak) -and -not (Test-AgentFile $exe)) { Copy-Item $bak $exe -Force -ErrorAction SilentlyContinue }
    Start-Agent | Out-Null
    exit 1
}

# ---- 3) เปิดใช้งาน + ย้อนกลับถ้าเปิดไม่ขึ้น ----
if (Start-Agent) {
    Say 'อัพเดทสำเร็จ agent ทำงานแล้ว'
    Remove-Item $new -Force -ErrorAction SilentlyContinue
    Remove-Item $bak -Force -ErrorAction SilentlyContinue
    exit 0
}
if (Test-Path $bak) {
    Say 'ตัวใหม่เปิดไม่ขึ้น -> ย้อนกลับตัวเดิม'
    Copy-WithRetry $bak $exe | Out-Null
    Start-Agent | Out-Null
    exit 1
}
Say 'อัพเดทแล้วแต่ยังไม่เริ่มทำงาน (ลองรีสตาร์ตเครื่อง)'
exit 1
