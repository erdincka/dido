#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

if [ -z "$1" ]; then
    echo "Error: PKM_ROOT argument is required."
    echo "Usage: $0 <path_to_pkm_root>"
    exit 1
fi
export PKM_ROOT="$1"

echo "Starting Dido (Frontend + Backend) on localhost... with PKM_ROOT=$PKM_ROOT"

# Trap Ctrl+C (SIGINT) and kill all background processes started by this script
trap 'echo "Stopping Dido..."; kill 0; exit 0' SIGINT SIGTERM EXIT

# ==========================================
# 1. Start the Backend (using uv)
# ==========================================
echo "=> [Backend] Setting up via uv..."
cd backend

# Create uv venv if it doesn't already exist
if [ ! -d ".venv" ]; then
    echo "=> [Backend] Creating new venv with uv..."
    uv venv
fi

# Activate venv
source .venv/bin/activate

# Install dependencies quickly with uv pip
echo "=> [Backend] Installing requirements..."
uv pip install -r requirements.txt

# Start uvicorn in the background
echo "=> [Backend] Starting server..."
export CHROMA_DB_DIR="$PWD/chroma-data"
uvicorn app.main:app --host 127.0.0.1 --port 8080 --reload &
cd ..

echo "=> [Backend] Waiting for server to start responding on port 8080..."
while ! nc -z 127.0.0.1 8080; do
  sleep 1
done
echo "=> [Backend] Server is up!"


# ==========================================
# 2. Start the Frontend (npm / vite)
# ==========================================
echo "=> [Frontend] Setting up via npm..."
cd frontend

# Install exact dependencies
npm install

# Start Vite in the background and point target proxy locally
echo "=> [Frontend] Starting server..."
export BACKEND_URL="http://127.0.0.1:8080"
npm run dev &
cd ..


# ==========================================
# 3. Wait gracefully
# ==========================================
echo ""
echo "========================================================"
echo "✨ Dido is running locally! ✨"
echo "- Backend: http://127.0.0.1:8080"
echo "- Frontend: View your Vite console for the Local URL (typically http://localhost:5173/)"
echo "Press Ctrl+C to gracefully stop both servers."
echo "========================================================"
echo ""

# Wait on all background jobs
wait
