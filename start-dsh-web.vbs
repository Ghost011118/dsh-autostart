' start-dsh-web.vbs
' Hidden autostart entry point: runs dsh-web-launcher.ps1 with a hidden window
' so `dsh web` is started and supervised with no console window.
'
' Placed in the Startup folder by install.cmd; running this file also works.
' Stop/resume/install: see install.cmd / readme.txt
'
' NOTE: intentionally ASCII-only for codepage safety.
Option Explicit

Dim ws, fso, src, ps, quotedScript, args
Set ws  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' folder that contains this vbs == the script folder
src = fso.GetParentFolderName(WScript.ScriptFullName)
ps  = src & "\dsh-web-launcher.ps1"

' launch powershell hidden (window mode 0), don't wait (background long-lived)
quotedScript = Chr(34) & ps & Chr(34)
args = "powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & quotedScript

ws.Run args, 0, False
