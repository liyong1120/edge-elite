@echo off
setlocal
chcp 936 >nul

REM ==========================================================
REM  棱锋精英 一键打包脚本
REM  改完代码后双击本文件，即可重新生成发布包
REM  产物：build\EdgeElite_win64.zip
REM ==========================================================

REM ---------- 配置（换机器时改这里） ----------
set "GODOT=C:\Users\liyong\AppData\Local\Godot\Godot_v4.7.1-stable_win64_console.exe"
set "TEMPLATES_HOME=%TEMP%\godot_export_home"
set "PRESET=Windows Desktop"
set "APPNAME=EdgeElite"
REM -------------------------------------------

set "PROJ=%~dp0"
if "%PROJ:~-1%"=="\" set "PROJ=%PROJ:~0,-1%"
set "BUILD=%PROJ%\build"
set "PKGDIR=%BUILD%\%APPNAME%"
set "ZIP=%BUILD%\%APPNAME%_win64.zip"
set "EXTRA=%PROJ%\packaging"

echo ==========================================
echo   棱锋精英 一键打包
echo ==========================================
echo   项目目录: %PROJ%
echo.

if not exist "%GODOT%" (
    echo [错误] 找不到 Godot 可执行文件：
    echo        %GODOT%
    echo        请修改本脚本顶部的 GODOT 变量。
    goto :fail
)

if not exist "%TEMPLATES_HOME%\Godot\export_templates\4.7.1.stable\windows_release_x86_64.exe" (
    echo [错误] 找不到导出模板：
    echo        %TEMPLATES_HOME%\Godot\export_templates\4.7.1.stable\
    echo        请先安装 Godot 4.7.1 的导出模板。
    goto :fail
)

if not exist "%BUILD%" mkdir "%BUILD%" 2>nul

echo [1/4] 导出项目（release）...
set "APPDATA=%TEMPLATES_HOME%"
"%GODOT%" --headless --path "%PROJ%" --export-release "%PRESET%" "%BUILD%\%APPNAME%.exe"
if errorlevel 1 (
    echo.
    echo [错误] 导出失败，请看上面的 Godot 输出。
    goto :fail
)

echo.
echo [2/4] 整理发布目录...
rd /s /q "%PKGDIR%" 2>nul
mkdir "%PKGDIR%" 2>nul
copy /y "%BUILD%\%APPNAME%.exe" "%PKGDIR%\" >nul
copy /y "%BUILD%\%APPNAME%.pck" "%PKGDIR%\" >nul
if exist "%EXTRA%\" (
    xcopy /y /e /i /q "%EXTRA%\*" "%PKGDIR%\" >nul
) else (
    echo [提示] 没有 packaging 目录，跳过附加文件。
)

echo.
echo [3/4] 压缩为 zip...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.IO.Compression.FileSystem; $z = '%ZIP%'; if (Test-Path $z) { Remove-Item $z -Force }; [System.IO.Compression.ZipFile]::CreateFromDirectory('%PKGDIR%', $z, [System.IO.Compression.CompressionLevel]::Optimal, $true, [System.Text.Encoding]::UTF8)"
if errorlevel 1 (
    echo.
    echo [错误] 压缩失败。
    goto :fail
)

echo.
echo [4/4] 完成！
for %%F in ("%ZIP%") do set "ZIPSIZE=%%~zF"
set /a ZIPSIZE_MB=%ZIPSIZE%/1048576
echo   发布目录: %PKGDIR%
echo   压缩包  : %ZIP%
echo   包大小  : %ZIPSIZE_MB% MB
echo.
echo 可以关闭本窗口了。
pause
exit /b 0

:fail
echo.
echo 打包失败。
pause
exit /b 1
