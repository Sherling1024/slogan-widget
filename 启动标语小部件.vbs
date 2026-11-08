' 桌面标语小部件 - 静默启动器（不闪黑框）
Option Explicit
Dim fso, sh, dir, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = sh.ExpandEnvironmentStrings("%TEMP%")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\SloganWidget.ps1"""
sh.Run cmd, 0, False
