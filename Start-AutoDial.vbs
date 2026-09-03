' AutoDial hidden launcher: starts the PowerShell guard with no window at all.
' Keep this file ASCII-only (wscript reads ANSI).
Set fso = CreateObject("Scripting.FileSystemObject")
strDir = fso.GetParentFolderName(WScript.ScriptFullName)
strCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & strDir & "\AutoDial.ps1"" -Detached"
CreateObject("WScript.Shell").Run strCmd, 0, False
