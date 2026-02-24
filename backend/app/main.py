from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from typing import Optional, List, Dict, Any
import os
import logging
import warnings
from collections import deque
import urllib.request
import httpx
import mimetypes
import threading

from app.config import get_settings, update_settings
from app.indexer import index_pkm, lazy_index_file
from app.vector_store import vector_store
from app.llm import generate_answer

# Suppress noisy warnings from third-party libraries
warnings.filterwarnings("ignore", category=UserWarning)
warnings.filterwarnings("ignore", module="openpyxl")
warnings.filterwarnings("ignore", message=".*image cannot be loaded.*")

# Set noisy library loggers to CRITICAL only
for logger_name in [
    "docling",
    "docling_core",
    "docling_parse",
    "docxtpl",
    "openpyxl",
    "unstructured",
    "unstructured.trace",
    "pdfminer",
    "PIL",
]:
    logging.getLogger(logger_name).setLevel(logging.CRITICAL)

# Setup logging buffer
log_buffer = deque(maxlen=50)


class BufferHandler(logging.Handler):
    def emit(self, record):
        log_entry = self.format(record)
        log_buffer.append(log_entry)


logger = logging.getLogger("dido")
logger.setLevel(logging.INFO)
buf_handler = BufferHandler()
buf_handler.setFormatter(logging.Formatter("%(asctime)s - %(levelname)s - %(message)s"))
logger.addHandler(buf_handler)

stream_handler = logging.StreamHandler()
stream_handler.setFormatter(
    logging.Formatter("%(asctime)s - %(levelname)s - %(message)s")
)
logger.addHandler(stream_handler)


# Filter out status endpoints from uvicorn access logs
class StatusEndpointFilter(logging.Filter):
    def filter(self, record):
        msg = record.getMessage()
        return "/api/status" not in msg and "/api/index/status" not in msg


logging.getLogger("uvicorn.access").addFilter(StatusEndpointFilter())

app = FastAPI(title="Dido PKM RAG Service")


class ConfigUpdate(BaseModel):
    pkm_root: Optional[str] = None
    llm_base_url: Optional[str] = None
    llm_api_token: Optional[str] = None
    llm_model: Optional[str] = None
    vlm_base_url: Optional[str] = None
    system_prompt: Optional[str] = None
    chunk_size: Optional[int] = None
    chunk_overlap: Optional[int] = None
    top_k: Optional[int] = None


class IndexRequest(BaseModel):
    root_path: Optional[str] = None
    include_extensions: Optional[List[str]] = None


class FileRequest(BaseModel):
    path: str


class QueryRequest(BaseModel):
    query: str
    filters: Optional[Dict[str, Any]] = None
    top_k: Optional[int] = None


@app.get("/api/config")
def get_config():
    settings = get_settings()
    return settings.model_dump()


@app.get("/api/status")
def get_status():
    settings = get_settings()

    # check llm basic connectivity
    llm_status = "Unknown"
    try:
        urllib.request.urlopen(settings.llm_base_url, timeout=2)
        llm_status = "Connected"
    except Exception:
        llm_status = "Disconnected"

    # check chromadb
    try:
        vector_store._ensure_collection()
        count = vector_store.collection.count()
        vectordb_status = "Connected"
    except Exception:
        count = 0
        vectordb_status = "Disconnected"

    return {
        "llm": llm_status,
        "vectordb": vectordb_status,
        "chunks": count,
        "logs": list(log_buffer),
    }


@app.put("/api/config")
def update_config(config: ConfigUpdate):
    updated = update_settings(config.model_dump(exclude_unset=True))
    return updated.model_dump()


class ModelsRequest(BaseModel):
    url: str
    token: Optional[str] = None


@app.post("/api/models")
async def get_llm_models(req: ModelsRequest):
    url = req.url.rstrip("/")
    headers = {}
    if req.token:
        headers["Authorization"] = f"Bearer {req.token}"

    models_list = []

    async with httpx.AsyncClient(timeout=10.0, verify=False) as client:
        # Try Ollama /api/tags
        is_ollama = False
        try:
            base_url = url.replace("/v1", "")
            res = await client.get(f"{base_url}/api/tags", headers=headers)
            if res.status_code == 200:
                data = res.json()
                if "models" in data:
                    for m in data["models"]:
                        name = m.get("name")
                        details = m.get("details", {})
                        is_vlm = False
                        name_lower = name.lower()
                        if any(
                            x in name_lower
                            for x in ["vision", "vl", "minicpm-v", "llava", "pixtral"]
                        ):
                            is_vlm = True
                        if (
                            isinstance(details.get("families"), list)
                            and "vision" in details["families"]
                        ):
                            is_vlm = True
                        models_list.append({"name": name, "is_vlm": is_vlm})
                    is_ollama = True
        except Exception:
            pass

        if not is_ollama:
            try:
                test_url = (
                    f"{url}/models" if url.endswith("/v1") else f"{url}/v1/models"
                )
                res = await client.get(test_url, headers=headers)
                if res.status_code == 200:
                    data = res.json()
                    if "data" in data:
                        for m in data["data"]:
                            name = m.get("id")
                            is_vlm = False
                            name_lower = name.lower()
                            if any(
                                x in name_lower
                                for x in ["vision", "vl", "gpt-4o", "claude-3-5-sonnet"]
                            ):
                                is_vlm = True
                            models_list.append({"name": name, "is_vlm": is_vlm})
            except Exception:
                pass

    return models_list


is_currently_indexing = False
last_index_status = ""


class IndexResponse(BaseModel):
    status: str
    detail: str


@app.post("/api/index", response_model=IndexResponse)
def trigger_index(req: IndexRequest, background_tasks: BackgroundTasks):
    global is_currently_indexing, last_index_status
    if is_currently_indexing:
        raise HTTPException(status_code=400, detail="Indexing is already in progress.")

    is_currently_indexing = True
    last_index_status = "Indexing started..."

    def background_indexer():
        global is_currently_indexing, last_index_status

        def update_status(msg: str):
            global last_index_status
            last_index_status = msg

        try:
            index_pkm(
                req.root_path, req.include_extensions, progress_callback=update_status
            )
        except Exception as e:
            logger.error(f"Background indexing failed: {str(e)}")
            last_index_status = f"Error: {str(e)}"
        finally:
            is_currently_indexing = False

    thread = threading.Thread(target=background_indexer, daemon=True)
    thread.start()
    return {"status": "started", "detail": "Indexing started in the background."}


@app.post("/api/query")
async def run_query(req: QueryRequest):
    try:
        path = req.filters.get("path") if req.filters else None

        chunks = []
        is_text_based = False
        is_non_text_based = False

        if path:
            path_lower = str(path).lower()
            ext = "." + path_lower.rsplit(".", 1)[-1] if "." in path_lower else ""
            text_exts = {
                ".yaml",
                ".yml",
                ".txt",
                ".md",
                ".html",
                ".xml",
                ".json",
                ".csv",
            }
            non_text_exts = {".pdf", ".xlsx", ".pptx", ".docx"}

            settings = get_settings()
            full_path = os.path.join(settings.pkm_root, path)

            if ext in text_exts:
                is_text_based = True
            elif ext in non_text_exts:
                is_non_text_based = True

            is_dir = os.path.isdir(full_path)

            if is_dir:
                try:
                    folder_contents = []
                    entries = sorted(
                        os.scandir(full_path), key=lambda e: (not e.is_dir(), e.name)
                    )
                    for entry in entries:
                        if entry.name.startswith("."):
                            continue

                        entry_info = f"[{'Directory' if entry.is_dir() else 'File'}] {entry.name}"
                        meta_path = entry.path + ".meta.json"
                        meta_str = ""
                        if os.path.exists(meta_path):
                            try:
                                import json

                                with open(meta_path, "r", encoding="utf-8") as mf:
                                    meta_data = json.load(mf)
                                    if meta_data:
                                        meta_parts = []
                                        for k, v in meta_data.items():
                                            if v and k != "path":
                                                meta_parts.append(f"{k}: {v}")
                                        if meta_parts:
                                            meta_str = (
                                                " (Metadata: "
                                                + ", ".join(meta_parts)
                                                + ")"
                                            )
                            except Exception:
                                pass

                        folder_contents.append(entry_info + meta_str)

                    if folder_contents:
                        context_str = (
                            f"The user is asking about the folder '{path}'. Here are its direct contents (files and subfolders) along with their metadata:\n\n"
                            + "\n".join(folder_contents)
                        )
                        chunks.append(
                            {
                                "snippet": context_str,
                                "metadata": {"path": path, "type": "folder_listing"},
                            }
                        )
                except Exception as e:
                    logger.error(f"Failed to read folder contents for {full_path}: {e}")
            else:
                # Lazy index if it's text based
                if is_text_based:
                    lazy_index_file(path)

                # Fetch chunks for this path
                try:
                    all_chunks = vector_store.collection.get(
                        where={"path": {"$eq": path}}
                    )
                    if all_chunks and all_chunks.get("documents"):
                        for i, doc in enumerate(all_chunks["documents"]):
                            chunks.append(
                                {
                                    "snippet": doc,
                                    "metadata": (
                                        all_chunks["metadatas"][i]
                                        if all_chunks.get("metadatas")
                                        else {}
                                    ),
                                }
                            )
                except Exception as e:
                    logger.error(f"Failed to get chunks for {path}: {e}")

                # If it's binary, it will be handled in generate_answer via the file_path parameter.

        if not is_text_based and not is_non_text_based:
            # Fallback to standard top_k query
            settings = get_settings()
            k = req.top_k if req.top_k is not None else settings.top_k
            results = vector_store.query(req.query, req.filters, k)
            if results and results.get("documents") and len(results["documents"]) > 0:
                for doc_list, meta_list in zip(
                    results["documents"], results["metadatas"]
                ):
                    for doc, meta in zip(doc_list, meta_list):
                        chunks.append({"snippet": doc, "metadata": meta})

        # Generate Answer
        answer = await generate_answer(
            req.query, chunks, file_path=path if is_non_text_based else None
        )

        return {"answer": answer, "sources": chunks}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/metadata/values")
def get_metadata_values():
    return vector_store.get_metadata_values()


class MetadataUpdateRequest(BaseModel):
    path: str
    metadata: Dict[str, Any]


@app.put("/api/metadata")
def update_file_metadata(req: MetadataUpdateRequest):
    settings = get_settings()
    root = settings.pkm_root
    target_path = os.path.normpath(os.path.join(root, req.path))
    if not target_path.startswith(os.path.normpath(root)):
        raise HTTPException(status_code=403, detail="Forbidden path")

    if not os.path.exists(target_path) or os.path.isdir(target_path):
        raise HTTPException(status_code=404, detail="File not found")

    # Apply to vectorstore
    success = vector_store.update_metadata(req.path, req.metadata)
    if not success:
        raise HTTPException(
            status_code=400,
            detail="Document not found in vector store it might not be indexed yet.",
        )

    # Save to disk as an override
    import json

    meta_path = target_path + ".meta.json"
    try:
        with open(meta_path, "w", encoding="utf-8") as f:
            json.dump(req.metadata, f, indent=2)
    except Exception as e:
        raise HTTPException(
            status_code=500, detail=f"Failed to save metadata to disk: {e}"
        )

    return {"status": "success", "metadata": req.metadata}


@app.get("/api/index/status")
def get_index_status():
    global is_currently_indexing, last_index_status
    return {"is_indexing": is_currently_indexing, "detail": last_index_status}


@app.get("/api/files")
def get_files():
    settings = get_settings()
    root = settings.pkm_root
    if not os.path.exists(root):
        return []

    def build_tree(current_path, relative_path=""):
        tree = []
        try:
            entries = sorted(
                os.scandir(current_path), key=lambda e: (not e.is_dir(), e.name)
            )
        except PermissionError:
            return tree

        for entry in entries:
            if entry.name.startswith("."):
                continue
            entry_rel_path = (
                os.path.join(relative_path, entry.name) if relative_path else entry.name
            )
            if entry.is_dir():
                tree.append(
                    {
                        "name": entry.name,
                        "type": "folder",
                        "path": entry_rel_path,
                        "children": build_tree(entry.path, entry_rel_path),
                    }
                )
            elif entry.is_file():
                tree.append(
                    {"name": entry.name, "type": "file", "path": entry_rel_path}
                )
        return tree

    return build_tree(root)


@app.post("/api/file/content")
def get_file_content(req: FileRequest):
    settings = get_settings()
    root = settings.pkm_root
    # Security: ensure path doesn't break out of root
    target_path = os.path.normpath(os.path.join(root, req.path))
    if not target_path.startswith(os.path.normpath(root)):
        raise HTTPException(status_code=403, detail="Forbidden path")

    if not os.path.exists(target_path):
        raise HTTPException(status_code=404, detail="File not found")

    if os.path.isdir(target_path):
        raise HTTPException(status_code=400, detail="Cannot read a directory")

    try:
        with open(target_path, "r", encoding="utf-8") as f:
            content = f.read()
        return {"content": content}
    except UnicodeDecodeError:
        return {"content": "[Binary or non-UTF-8 file content]"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/file/raw")
def get_file_raw(path: str):
    settings = get_settings()
    root = settings.pkm_root
    target_path = os.path.normpath(os.path.join(root, path))
    if not target_path.startswith(os.path.normpath(root)):
        raise HTTPException(status_code=403, detail="Forbidden path")

    if not os.path.exists(target_path) or os.path.isdir(target_path):
        raise HTTPException(status_code=404, detail="File not found")

    mime_type, _ = mimetypes.guess_type(target_path)
    return FileResponse(
        target_path,
        media_type=mime_type or "application/octet-stream",
        filename=os.path.basename(target_path),
        content_disposition_type="inline",
    )


# Serve frontend static files if they exist (for prod deployment)
frontend_dist = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "frontend", "dist"
)
if os.path.isdir(frontend_dist):
    app.mount("/", StaticFiles(directory=frontend_dist, html=True), name="frontend")
