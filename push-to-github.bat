@echo off
title Push Terabyte Network Manager to GitHub
echo ===================================================
echo Pushing Project to GitHub (Tera-Bytespk/TeraByte-ONT)...
echo ===================================================

cd /d "C:\Users\ry2\.gemini\antigravity\scratch\terabyte-network-manager"

"C:\Users\ry2\MinGit\cmd\git.exe" branch -M main
"C:\Users\ry2\MinGit\cmd\git.exe" push -u origin main --force

if %errorlevel% equ 0 (
    echo.
    echo ===================================================
    echo SUCCESS! All files uploaded to GitHub.
    echo Now open https://github.com/Tera-Bytespk/TeraByte-ONT/actions
    echo to download your APK!
    echo ===================================================
) else (
    echo.
    echo [ERROR] Push failed. If it asked for login, please enter your GitHub credentials or Personal Access Token.
)
pause
