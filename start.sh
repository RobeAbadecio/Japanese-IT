#!/bin/zsh
# Starts the API server so the iPad app can reach it on the same Wi-Fi.
cd "${0:A:h}"
IP=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)
echo "Server address for the iPad app:  http://$IP:8000"
exec .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
