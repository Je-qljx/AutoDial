' AutoDial GUI launcher - launches the management UI without a console window.
' IMPORTANT: keep this file ASCII-only (wscript reads ANSI).
Option Explicit
Dim fso, dir, shell, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\AutoDial-Setup.ps1"""
Set shell = CreateObject("WScript.Shell")
shell.Run cmd, 0, False
