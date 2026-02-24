import os
import logging
import json

from app.config import get_settings
from app.metadata_parser import extract_metadata_from_path
from app.vector_store import vector_store

logger = logging.getLogger("dido")


def process_image_assets(metadata: dict, image_path: str):
    """
    STUB: For future VLM (Vision-Language Model) integration.
    This function should take an extracted image or diagram path,
    pass it to an external VLM endpoint (e.g., LLaVA or GPT-4o),
    and return an enriched description or chunk to be added to Chroma.
    """
    pass


def chunk_text(text: str, chunk_size: int = None, overlap: int = None) -> list[str]:
    settings = get_settings()
    chunk_sz = chunk_size if chunk_size is not None else settings.chunk_size
    ovrlp = overlap if overlap is not None else settings.chunk_overlap
    chunks = []
    if not text:
        return chunks

    # Safety guard to prevent infinite loop
    if chunk_sz <= ovrlp:
        chunk_sz = ovrlp + 1

    start = 0
    while start < len(text):
        chunks.append(text[start : start + chunk_sz])
        start += chunk_sz - ovrlp
    return chunks


def index_pkm(
    root_path: str = None, include_extensions: list[str] = None, progress_callback=None
):
    settings = get_settings()
    target_root = root_path or settings.pkm_root

    if not include_extensions:
        include_extensions = ["docx", "pptx", "xlsx", "rtf", "pdf", "html", "txt", "md"]

    # Gather files
    files_to_process = []
    for root, _, files in os.walk(target_root):
        for file in files:
            if file.startswith("."):
                continue
            ext = file.rsplit(".", 1)[-1].lower() if "." in file else ""
            if ext in include_extensions:
                files_to_process.append((root, file))

    total = len(files_to_process)

    msg = f"Starting lazy index of {target_root}. Found {total} files."
    logger.info(msg)
    if progress_callback:
        progress_callback(msg)

    processed_files = 0
    errors = []

    for idx, (root, file) in enumerate(files_to_process, 1):
        full_path = os.path.join(root, file)
        rel_path = os.path.relpath(full_path, target_root).replace("\\", "/")

        try:
            # Extract metadata
            metadata = extract_metadata_from_path(rel_path)

            # Save or update .meta.json if it doesn't exist or is different
            meta_file = full_path + ".meta.json"
            save_meta = True
            if os.path.exists(meta_file):
                try:
                    with open(meta_file, "r", encoding="utf-8") as f:
                        existing = json.load(f)
                        if existing == metadata:
                            save_meta = False
                except Exception:
                    pass

            if save_meta:
                with open(meta_file, "w", encoding="utf-8") as f:
                    json.dump(metadata, f, indent=2)

            processed_files += 1
            if idx % 10 == 0 or idx == total:
                msg = f"[{idx}/{total}] Processed metadata for {rel_path}"
                if progress_callback:
                    progress_callback(msg)

        except Exception as e:
            logger.error(
                f"[{idx}/{total}] Failed to process metadata for {rel_path}: {str(e)}"
            )
            errors.append(f"Failed to process {rel_path}: {str(e)}")

    msg = f"Lazy indexing complete. Processed metadata for {processed_files}/{total} files, with {len(errors)} errors."
    logger.info(msg)
    if progress_callback:
        progress_callback(msg)
    return {
        "status": "success",
        "processed_files": processed_files,
        "indexed_files": 0,  # In lazy mode, we don't index chunks during the scan
        "errors": errors,
    }


def lazy_index_file(rel_path: str):
    """
    On-demand indexing for text-based files.
    """
    settings = get_settings()
    target_root = settings.pkm_root
    full_path = os.path.join(target_root, rel_path)

    if not os.path.exists(full_path):
        logger.error(f"File not found for lazy indexing: {full_path}")
        return False

    path_lower = rel_path.lower()
    ext = "." + path_lower.rsplit(".", 1)[-1] if "." in path_lower else ""
    text_exts = {".yaml", ".yml", ".txt", ".md", ".html", ".xml", ".json", ".csv"}

    if ext not in text_exts:
        logger.info(f"Skipping vector indexing for binary/non-text file: {rel_path}")
        return False

    if vector_store.has_document(rel_path):
        return True

    try:
        logger.info(f"Lazy indexing (chunking): {rel_path}")
        with open(full_path, "r", encoding="utf-8") as f:
            text = f.read()

        metadata = extract_metadata_from_path(rel_path)
        chunks = chunk_text(text, settings.chunk_size, settings.chunk_overlap)

        ids = []
        texts = []
        metas = []

        for i, chunk in enumerate(chunks):
            ids.append(f"{rel_path}_{i}")
            texts.append(chunk)
            metas.append(metadata)

        if ids:
            vector_store.add_chunks(ids, texts, metas)
            logger.info(f"Successfully lazy indexed {rel_path}")
            return True
    except Exception as e:
        logger.error(f"Failed to lazy index {rel_path}: {e}")

    return False
