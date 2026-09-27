@echo off
title Terabyte Network Manager - APK Builder
echo ===================================================
echo Building Terabyte Network Manager APK...
echo ===================================================

where java >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Java (JDK 17) is not installed or not in PATH!
    echo Please install JDK 17 (e.g. from https://adoptium.net) or
    echo open this folder in Android Studio to build automatically.
    pause
    exit /b 1
)

if exist gradlew.bat (
    call gradlew.bat assembleDebug
) else (
    echo [INFO] Running gradle assembleDebug...
    call gradle assembleDebug
)

if %errorlevel% equ 0 (
    echo.
    echo ===================================================
    echo SUCCESS! APK Generated at:
    echo app\build\outputs\apk\debug\app-debug.apk
    echo ===================================================
) else (
    echo.
    echo [ERROR] Build failed. Please check logs above.
)
pause
