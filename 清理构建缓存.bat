@echo off
setlocal
title XianYu Music Mobile - Cache Clean

echo ============================================
echo   XianYu Music Mobile - Cache Clean
echo ============================================
echo.

:: Set PATH (Cargo)
set "PATH=%USERPROFILE%\.cargo\bin;%PATH%"

:: [1/6] Clean Flutter build output (build)
if exist "%~dp0build" (
    echo [1/6] Cleaning Flutter build output...
    rmdir /s /q "%~dp0build"
) else (
    echo [1/6] No build folder, skip
)
echo.

:: [2/6] Clean Dart tool cache (.dart_tool)
if exist "%~dp0.dart_tool" (
    echo [2/6] Cleaning Dart tool cache...
    rmdir /s /q "%~dp0.dart_tool"
) else (
    echo [2/6] No .dart_tool cache, skip
)
echo.

:: [3/6] Clean Rust build cache (rust\target)
if exist "%~dp0rust\target" (
    echo [3/6] Cleaning Rust build cache...
    cd /d "%~dp0rust"
    cargo clean
    cd /d "%~dp0"
) else (
    echo [3/6] No rust\target, skip
)
echo.

:: [4/6] Clean Gradle cache (android\.gradle)
if exist "%~dp0android\.gradle" (
    echo [4/6] Cleaning Gradle cache...
    rmdir /s /q "%~dp0android\.gradle"
) else (
    echo [4/6] No android\.gradle cache, skip
)
echo.

:: [5/6] Clean logs
if exist "%~dp0logs" (
    echo [5/6] Cleaning logs...
    rmdir /s /q "%~dp0logs"
) else (
    echo [5/6] No logs, skip
)
echo.

:: [6/6] Clean external ASCII build dir (build-release.ps1 cache D:\build\XianYuMusicSrc)
if exist "D:\build\XianYuMusicSrc" (
    echo [6/6] Cleaning external build dir [D:\build\XianYuMusicSrc]...
    rmdir /s /q "D:\build\XianYuMusicSrc"
) else (
    echo [6/6] No external build dir, skip
)
echo.

echo ============================================
echo   Cache cleaned! Run scripts\build-release.ps1 to rebuild.
echo ============================================
echo.
pause