' photos_tray_startup_hidden.vbs - compatibility startup launcher.
' Starts the tray host with the newest installed pwsh and waits for it.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = scriptDir & "\photos_tray.ps1"
resolver = scriptDir & "\resolve_latest_pwsh.vbs"
If Not fso.FileExists(resolver) Then WScript.Quit 2
ExecuteGlobal fso.OpenTextFile(resolver, 1).ReadAll
pwsh = FindLatestPwsh(fso, sh)
If pwsh = "" Then WScript.Quit 2
command = Chr(34) & pwsh & Chr(34) & " -NoProfile -STA -WindowStyle Hidden -File " & Chr(34) & ps1 & Chr(34) & " -StartupDelaySeconds 25"
sh.Run command, 0, True
