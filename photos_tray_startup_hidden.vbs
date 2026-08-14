' photos_tray_startup_hidden.vbs - scheduled-task launcher.
' Starts the tray host without a console window and waits for it.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = scriptDir & "\photos_tray.ps1"
If Not fso.FileExists(ps1) Then WScript.Quit 2

pwsh = ""
If WScript.Arguments.Count > 0 Then
    pwsh = WScript.Arguments(0)
Else
    resolver = scriptDir & "\resolve_latest_pwsh.vbs"
    If Not fso.FileExists(resolver) Then WScript.Quit 2
    ExecuteGlobal fso.OpenTextFile(resolver, 1).ReadAll
    pwsh = FindLatestPwsh(fso, sh)
End If
If pwsh = "" Or Not fso.FileExists(pwsh) Then WScript.Quit 2

command = Chr(34) & pwsh & Chr(34) & " -NoProfile -STA -WindowStyle Hidden -File " & Chr(34) & ps1 & Chr(34) & " -StartupDelaySeconds 25"
exitCode = sh.Run(command, 0, True)
WScript.Quit exitCode
