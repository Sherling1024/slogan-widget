param([string]$Repo = 'D:\Users\22856\Desktop\DeepSeek-Harness\slogan-widget')
$ErrorActionPreference = 'Continue'

$lines = @(
'using System;',
'using System.Runtime.InteropServices;',
'public static class CredMgr {',
'    [DllImport("advapi32.dll", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)]',
'    public static extern bool CredRead(string target, int type, int flags, out IntPtr credential);',
'    [DllImport("advapi32.dll", EntryPoint="CredFree", SetLastError=true)]',
'    public static extern void CredFree(IntPtr cred);',
'    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]',
'    public struct CREDENTIAL {',
'        public int Flags;',
'        public int Type;',
'        public string TargetName;',
'        public string Comment;',
'        public long LastWritten;',
'        public int CredentialBlobSize;',
'        public IntPtr CredentialBlob;',
'        public int Persist;',
'        public int AttributeCount;',
'        public IntPtr Attributes;',
'        public string TargetAlias;',
'        public string UserName;',
'    }',
'    public static string[] Read(string target) {',
'        IntPtr p;',
'        if (!CredRead(target, 1, 0, out p)) return null;',
'        try {',
'            CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));',
'            string pw = Marshal.PtrToStringUni(c.CredentialBlob, c.CredentialBlobSize / 2);',
'            return new string[] { c.UserName, pw };',
'        } finally { CredFree(p); }',
'    }',
'}'
)
$src = $lines -join [Environment]::NewLine
if (-not ('CredMgr' -as [type])) { Add-Type -TypeDefinition $src }

$cred = [CredMgr]::Read('git:https://github.com')
if (-not $cred) { Write-Output 'NO CREDENTIAL'; exit 1 }
$user = $cred[0]
$token = $cred[1]
Write-Output ('cred user=' + $user + ' token-len=' + $token.Length)

$pair = [Text.Encoding]::ASCII.GetBytes($user + ':' + $token)
$basic = [Convert]::ToBase64String($pair)
$header = 'http.extraheader=AUTHORIZATION: basic ' + $basic

Push-Location $Repo
& git.exe -c $header -c 'http.proxy=' -c 'https.proxy=' push --tags origin main 2>&1 | ForEach-Object { Write-Output $_ }
$code = $LASTEXITCODE
Pop-Location
Write-Output ('push exit=' + $code)
