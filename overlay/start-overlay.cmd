@echo off
rem Starts the plan usage overlay with no console window. Running it again
rem while the overlay is open does nothing. To close it, right-click the card.
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0overlay.ps1"
