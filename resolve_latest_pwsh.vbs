' Resolve the newest installed stable PowerShell (pwsh.exe) by file version.
Function VersionPart(versionText, index)
    parts = Split(versionText, ".")
    value = 0
    If index <= UBound(parts) Then
        On Error Resume Next
        value = CLng(parts(index))
        If Err.Number <> 0 Then value = 0
        Err.Clear
        On Error GoTo 0
    End If
    VersionPart = value
End Function

Function CompareVersions(leftVersion, rightVersion)
    CompareVersions = 0
    For index = 0 To 3
        leftPart = VersionPart(leftVersion, index)
        rightPart = VersionPart(rightVersion, index)
        If leftPart > rightPart Then
            CompareVersions = 1
            Exit Function
        End If
        If leftPart < rightPart Then
            CompareVersions = -1
            Exit Function
        End If
    Next
End Function

Function GetCandidateVersion(fso, sh, candidate)
    version = fso.GetFileVersion(candidate)
    If version = "" Or InStr(1, candidate, "\WindowsApps\", vbTextCompare) > 0 Then
        On Error Resume Next
        command = Chr(34) & candidate & Chr(34) & " -NoProfile -Command " & Chr(34) & "$PSVersionTable.PSVersion.ToString()" & Chr(34)
        Set process = sh.Exec(command)
        If Err.Number = 0 Then
            output = Trim(process.StdOut.ReadAll())
            If process.ExitCode = 0 And output <> "" Then version = output
        End If
        Err.Clear
        On Error GoTo 0
    End If
    GetCandidateVersion = Trim(version)
End Function

Function IsPreviewPath(candidate)
    lower = LCase(candidate)
    IsPreviewPath = InStr(lower, "\preview\") > 0 Or _
                    InStr(lower, "\pre-release\") > 0 Or _
                    InStr(lower, "\nightly\") > 0
End Function

Sub ConsiderPwsh(fso, sh, candidate, ByRef bestPath, ByRef bestVersion)
    If Not fso.FileExists(candidate) Then Exit Sub
    If IsPreviewPath(candidate) Then Exit Sub
    version = GetCandidateVersion(fso, sh, candidate)
    If CompareVersions(version, "7.0.0.0") < 0 Then Exit Sub
    If bestPath = "" Or CompareVersions(version, bestVersion) > 0 Then
        bestPath = candidate
        bestVersion = version
    End If
End Sub

Function FindLatestPwsh(fso, sh)
    bestPath = ""
    bestVersion = "0.0.0.0"
    roots = Array( _
        sh.ExpandEnvironmentStrings("%ProgramFiles%\PowerShell"), _
        sh.ExpandEnvironmentStrings("%LOCALAPPDATA%\Programs\PowerShell") _
    )
    For Each root In roots
        If fso.FolderExists(root) Then
            ConsiderPwsh fso, sh, fso.BuildPath(root, "pwsh.exe"), bestPath, bestVersion
            For Each child In fso.GetFolder(root).SubFolders
                ConsiderPwsh fso, sh, fso.BuildPath(child.Path, "pwsh.exe"), bestPath, bestVersion
            Next
        End If
    Next

    ' The MSIX package exposes a stable per-user alias kept current by Store updates.
    ConsiderPwsh fso, sh, sh.ExpandEnvironmentStrings("%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"), bestPath, bestVersion

    On Error Resume Next
    Set whereProcess = sh.Exec("where.exe pwsh.exe")
    If Err.Number = 0 Then
        Do Until whereProcess.StdOut.AtEndOfStream
            candidate = Trim(whereProcess.StdOut.ReadLine())
            If candidate <> "" Then ConsiderPwsh fso, sh, candidate, bestPath, bestVersion
        Loop
    End If
    Err.Clear
    On Error GoTo 0

    FindLatestPwsh = bestPath
End Function
