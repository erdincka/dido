#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

if [ -z "$1" ]; then
    echo "Error: PKM_ROOT argument is required."
    echo "Usage: $0 <path_to_pkm_root>"
    exit 1
fi
export PKM_ROOT="$1"

echo "Starting Dido in Production Mode... with PKM_ROOT=$PKM_ROOT"

# ==========================================
# 1. Build the Frontend
# ==========================================
echo "=> [Frontend] Building static assets..."
cd frontend
npm install
npm run build
cd ..

# ==========================================
# 2. Run the Backend (using uv)
# ==========================================
echo "=> [Backend] Setting up via uv..."
cd backend

if [ ! -d ".venv" ]; then
    echo "=> [Backend] Creating new venv with uv..."
    uv venv
fi

source .venv/bin/activate

echo "=> [Backend] Installing requirements..."
uv pip install -r requirements.txt

export CHROMA_DB_DIR="$PWD/chroma-data"

echo ""
echo "========================================================"
echo "✨ Dido is running at http://127.0.0.1:8080 ✨"
echo "Press Ctrl+C to stop."
echo "========================================================"
echo ""

uvicorn app.main:app --host 0.0.0.0 --port 8080
