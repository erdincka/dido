# Dido - PKM RAG Service

Dido is a full-stack, AI-powered Personal Knowledge Management (PKM) Retrieval-Augmented Generation (RAG) assistant. It allows you to index a local directory containing your documents and query them locally using language models.

Supported file formats include PDF, Word (.docx), PowerPoint (.pptx), Excel (.xlsx), Markdown, Text, HTML, and RTF files.

## Features

- **File Indexing:** Indexes documents from a target directory and chunks their content into vector embeddings using ChromaDB.
- **RAG via LLMs:** Built-in connection to Ollama/OpenAI-compatible language models to answer questions based strictly on your indexed documents.
- **Lazy Indexing:** Intelligently extracts metadata initially and waits to perform heavy text-chunking on demand when files are accessed.
- **VLM Support Context:** Context-aware endpoint capable of identifying Vision-Language Models for OCR or broader multimodal understanding.
- **Modern UI:** A sleek React frontend using Vite to manage configurations, explore your files, and chat with your PKM.
- **Metadata Editor:** Directly modify metadata attributes on indexed files to better sort your document sets.

## Architecture

The system consists of two main components:
1. **Frontend:** React + Vite, communicating with the backend API.
2. **Backend:** FastAPI (Python), utilizing ChromaDB as the underlying vector datastore.

## Requirements

Ensure the follow prerequisites are met:
- **macOS** or **Linux** based operation system recommended.
- **Python 3.10+**
- **uv:** The extremely fast Python package and project manager. To install it, you can use:
  ```bash
  curl -LsSf https://astral.sh/uv/install.sh | sh
  ```
- **Node.js (v18+)** and **npm**

## Getting Started

You can choose to run Dido locally in Development mode or Production mode without any container requirements.

### Production Run (Optimised)

This method prepares the static frontend bundle and serves the complete application gracefully through the FastAPI backend via a unified web service port.

```bash
./run_prod.sh /path/to/your/pkm/root
```

Once running, navigate to `http://127.0.0.1:8080` in your browser.

### Development Run

If you wish to work on the UI directly and need hot-reloading for the React application:

```bash
./run_local.sh /path/to/your/pkm/root
```

This will run to separate processes:
- The FastAPI Backend on `http://127.0.0.1:8080`.
- The Vite Frontend Server on `http://127.0.0.1:5173`.

Access the application via the local Vite port.

## Troubleshooting

- **No Output Extracted:** Double-check whether `.meta.json` exists incorrectly beside your files, or consider running a manual re-index within the frontend UI if the app thinks the file is already completed.
- **Read-Only Database Errors:** If you are migrating away from containers, make sure the local `./backend/chroma-data` directory has the necessary write permissions for your host's user.
- **404 Model generation Errors:** Verify that the API Endpoint configured within the Frontend's `Settings` matches your hosting solution (e.g. `http://localhost:11434` for a local Ollama daemon).

## License

MIT
