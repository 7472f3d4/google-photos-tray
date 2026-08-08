' photos_tray_hidden.vbs - launch photos_tray.ps1 without a console window.
' (Use this .vbs for startup registration and manual double-click launch.)
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = scriptDir & "\photos_tray.ps1"
powershell = sh.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
command = Chr(34) & powershell & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & ps1 & Chr(34) & " -OpenNow"
sh.Run command, 0, False
