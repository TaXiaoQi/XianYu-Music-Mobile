@echo off
setlocal
title XianYu Music Mobile - Cache Clean

echo ============================================
echo   XianYu Music Mobile - Cache Clean
echo ============================================
echo.

:: Set PATH (Cargo)
set "PATH=%USERPROFILE%\.cargo\bin;%PATH%"

:: [1/5] Clean Flutter build output (build)
if exist "%~dp0build" (
    echo [1/5] Cleaning Flutter build output...
    rmdir /s /q "%~dp0build"
) else (
    echo [1/5] No build folder, skip
)
echo.

:: [2/5] Clean Dart tool cache (.dart_tool)
if exist "%~dp0.dart_tool" (
    echo [2/5] Cleaning Dart tool cache...
    rmdir /s /q "%~dp0.dart_tool"
) else (
    echo [2/5] No .dart_tool cache, skip
)
echo.

:: [3/5] Clean Rust build cache (rust\target)
if exist "%~dp0rust\target" (
    echo [3/5] Cleaning Rust build cache...
    cd /d "%~dp0rust"
    cargo clean
    cd /d "%~dp0"
) else (
    echo [3/5] No rust\target, skip
)
echo.

:: [4/5] Clean Gradle cache (android\.gradle)
if exist "%~dp0android\.gradle" (
    echo [4/5] Cleaning Gradle cache...
    rmdir /s /q "%~dp0android\.gradle"
) else (
    echo [4/5] No android\.gradle cache, skip
)
echo.

:: [5/5] Clean logs
if exist "%~dp0logs" (
    echo [5/5] Cleaning logs...
    rmdir /s /q "%~dp0logs"
) else (
    echo [5/5] No logs, skip
)
echo.

echo ============================================
echo   Cache cleaned! Run "flutter run" or "flutter build apk" to rebuild.
echo   (Rust is compiled automatically via android gradle-rust-hook.ps1)
echo ============================================
echo.
pause
