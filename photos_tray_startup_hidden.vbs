' photos_tray_startup_hidden.vbs - scheduled-task launcher.
' Starts the tray host without creating a console window and waits for it,
' so Task Scheduler can observe a startup failure and retry it.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = scriptDir & "\photos_tray.ps1"
powershell = sh.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
command = Chr(34) & powershell & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & ps1 & Chr(34) & " -StartupDelaySeconds 25"
sh.Run command, 0, True
