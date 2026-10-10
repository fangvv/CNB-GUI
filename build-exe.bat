@echo off
setlocal enabledelayedexpansion
rem ==========================================================================
rem  Build CNB-GUI.exe (single-file launcher) with the built-in .NET csc.exe.
rem  No third-party tools required. Output: CNB-GUI.exe
rem ==========================================================================

set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" (
    echo [ERROR] csc.exe not found. This needs .NET Framework 4.x.
    exit /b 1
)

"%CSC%" /nologo /target:winexe /out:CNB-GUI.exe /resource:cnb-gui.ps1 launcher.cs
if errorlevel 1 (
    echo [ERROR] Compilation failed.
    exit /b 1
)

echo.
echo Done: CNB-GUI.exe
echo Double-click CNB-GUI.exe to run. It embeds cnb-gui.ps1.
endlocal
