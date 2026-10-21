@echo off
setlocal
if not exist "%~dp0obj" mkdir "%~dp0obj"
"%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll /out:"%~dp0obj\R5RBuild.exe" "%~dp0tools\Build.cs"
if errorlevel 1 exit /b 1
"%~dp0obj\R5RBuild.exe" %*
exit /b %errorlevel%
