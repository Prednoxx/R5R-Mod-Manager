param([switch]$Package)
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$automation = Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation\v4.0_3.0.0.0__31bf3856ad364e35\System.Management.Automation.dll'
& $compiler /nologo /target:winexe /platform:x64 /optimize+ /win32icon:"$PSScriptRoot\assets\app.ico" /reference:"$automation" /reference:System.Windows.Forms.dll /out:"$PSScriptRoot\R5R Mod Manager.exe" "$PSScriptRoot\src\Program.cs"
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
Write-Output 'Built R5R Mod Manager.exe'
if ($Package) {
    $dist = Join-Path $PSScriptRoot 'dist'
    $staging = Join-Path $dist ('package-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($staging)
    try {
        foreach ($name in @('R5R Mod Manager.exe','app.ps1','assets','catalog','lib','ui','docs','README.md','LICENSE')) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $staging -Recurse -Force
        }
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath (Join-Path $dist 'R5R-Mod-Manager-3.2.zip') -Force
        Write-Output 'Built dist/R5R-Mod-Manager-3.2.zip'
    } finally {
        $resolved = [IO.Path]::GetFullPath($staging)
        if ($resolved.StartsWith([IO.Path]::GetFullPath($dist).TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -like 'package-*') {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
