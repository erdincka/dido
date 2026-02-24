import os
from pydantic_settings import BaseSettings

import json

SETTINGS_FILE = os.path.join(os.path.dirname(__file__), "settings.json")


class Settings(BaseSettings):
    pkm_root: str = os.getenv("PKM_ROOT", "/data")
    llm_base_url: str = os.getenv("LLM_BASE_URL", "http://localhost:11434")
    llm_model: str = os.getenv("LLM_MODEL", "qwen3-vl:latest")
    llm_api_token: str | None = os.getenv("LLM_API_TOKEN")
    vlm_base_url: str | None = os.getenv("VLM_BASE_URL")
    chroma_db_dir: str = os.getenv("CHROMA_DB_DIR", "/chroma-data")
    collection_name: str = os.getenv("COLLECTION_NAME", "pkm_documents")
    index_timeout: int = int(os.getenv("INDEX_TIMEOUT", "600"))
    system_prompt: str = os.getenv(
        "SYSTEM_PROMPT",
        "You are an assistant answering questions based on the user's personal knowledge management (PKM) files. Your answer must be highly factual and based strictly on the provided context. Include references to the context where the answer is derived from.",
    )
    chunk_size: int = int(os.getenv("CHUNK_SIZE", "1000"))
    chunk_overlap: int = int(os.getenv("CHUNK_OVERLAP", "200"))
    top_k: int = int(os.getenv("TOP_K", "5"))

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"


def load_persistent_settings():
    if os.path.exists(SETTINGS_FILE):
        try:
            with open(SETTINGS_FILE, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return {}


settings = Settings(**load_persistent_settings())


def get_settings():
    return settings


def update_settings(new_settings: dict):
    global settings
    for key, value in new_settings.items():
        if hasattr(settings, key) and value is not None:
            setattr(settings, key, value)

    # Persist to disk
    try:
        with open(SETTINGS_FILE, "w") as f:
            # We only save the fields that are part of the Settings model
            dump = {k: v for k, v in settings.model_dump().items() if v is not None}
            json.dump(dump, f, indent=2)
    except Exception as e:
        import logging

        logging.getLogger("dido").error(f"Failed to save settings to disk: {e}")

    return settings
