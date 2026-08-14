' Resolve the newest installed PowerShell (pwsh.exe) by file version.
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

Sub ConsiderPwsh(fso, candidate, ByRef bestPath, ByRef bestVersion)
    If Not fso.FileExists(candidate) Then Exit Sub
    version = fso.GetFileVersion(candidate)
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
            ConsiderPwsh fso, fso.BuildPath(root, "pwsh.exe"), bestPath, bestVersion
            For Each child In fso.GetFolder(root).SubFolders
                ConsiderPwsh fso, fso.BuildPath(child.Path, "pwsh.exe"), bestPath, bestVersion
            Next
        End If
    Next

    On Error Resume Next
    Set whereProcess = sh.Exec("where.exe pwsh.exe")
    If Err.Number = 0 Then
        Do Until whereProcess.StdOut.AtEndOfStream
            candidate = Trim(whereProcess.StdOut.ReadLine())
            If candidate <> "" Then ConsiderPwsh fso, candidate, bestPath, bestVersion
        Loop
    End If
    Err.Clear
    On Error GoTo 0

    FindLatestPwsh = bestPath
End Function
