import chromadb
from app.config import get_settings


class VectorStore:
    def __init__(self):
        settings = get_settings()
        self.client = chromadb.PersistentClient(path=settings.chroma_db_dir)
        self.collection_name = settings.collection_name
        self._get_or_create_collection()

    def _get_or_create_collection(self):
        try:
            self.collection = self.client.get_collection(name=self.collection_name)
        except Exception:
            self.collection = self.client.create_collection(name=self.collection_name)

    def _ensure_collection(self):
        try:
            self.collection.count()
        except Exception:
            self._get_or_create_collection()

    def reset_collection(self):
        try:
            self.client.delete_collection(name=self.collection_name)
        except Exception:
            pass
        self.collection = self.client.create_collection(name=self.collection_name)

    def add_chunks(
        self,
        ids: list[str],
        texts: list[str],
        metadatas: list[dict],
        batch_size: int = 200,
    ):
        self._ensure_collection()
        if not ids:
            return

        # Chroma handles None values poorly for metadata filtering, replacing None with empty string
        cleaned_metadatas = []
        for meta in metadatas:
            cleaned = {k: (v if v is not None else "") for k, v in meta.items()}
            if "tags" in cleaned and isinstance(cleaned["tags"], list):
                cleaned["tags"] = ",".join(
                    cleaned["tags"]
                )  # Convert lists to string for simpler storage
            cleaned_metadatas.append(cleaned)

        total_chunks = len(ids)
        import logging

        logger = logging.getLogger("dido")

        for i in range(0, total_chunks, batch_size):
            end = min(i + batch_size, total_chunks)
            batch_ids = ids[i:end]
            batch_texts = texts[i:end]
            batch_metas = cleaned_metadatas[i:end]

            logger.info(
                f"Adding batch {i//batch_size + 1}/{(total_chunks-1)//batch_size + 1} ({len(batch_ids)} chunks)"
            )
            self.collection.add(
                ids=batch_ids, documents=batch_texts, metadatas=batch_metas
            )

    def has_document(self, rel_path: str) -> bool:
        self._ensure_collection()
        try:
            results = self.collection.get(where={"path": {"$eq": rel_path}}, limit=1)
            return len(results.get("ids", [])) > 0
        except Exception:
            return False

    def update_metadata(self, rel_path: str, new_metadata: dict) -> bool:
        self._ensure_collection()
        try:
            results = self.collection.get(where={"path": {"$eq": rel_path}})
            if not results or not results.get("ids"):
                return False

            ids = results["ids"]
            cleaned_metadatas = []
            for _ in ids:
                cleaned = {
                    k: (v if v is not None else "") for k, v in new_metadata.items()
                }
                cleaned["path"] = rel_path
                if "tags" in cleaned and isinstance(cleaned["tags"], list):
                    cleaned["tags"] = ",".join(cleaned["tags"])
                elif "tags" in cleaned and isinstance(cleaned["tags"], str):
                    # keep it as is
                    pass
                cleaned_metadatas.append(cleaned)

            self.collection.update(ids=ids, metadatas=cleaned_metadatas)
            return True
        except Exception as e:
            import logging

            logging.getLogger("dido").error(
                f"Failed to update metadata in vector store for {rel_path}: {e}"
            )
            return False

    def query(self, query_text: str, filters: dict = None, top_k: int = 5):
        self._ensure_collection()
        # Format filters for chroma
        where = {}
        if filters:
            conditions = []
            for k, v in filters.items():
                if v:
                    if isinstance(v, list) and k == "tags":
                        for tag in v:
                            conditions.append({k: {"$contains": tag}})
                    elif k == "path":
                        if "." in str(v).rsplit("/", 1)[-1]:
                            conditions.append({k: {"$eq": v}})
                        else:
                            conditions.append({k: {"$contains": v}})
                    else:
                        conditions.append({k: {"$eq": v}})

            if len(conditions) == 1:
                where = conditions[0]
            elif len(conditions) > 1:
                where = {"$and": conditions}

        results = self.collection.query(
            query_texts=[query_text], n_results=top_k, where=where if where else None
        )
        return results

    def get_metadata_values(self):
        self._ensure_collection()
        try:
            # Simple approach: fetch all metadatas (not ideal for huge datasets, but okay for v1)
            results = self.collection.get(include=["metadatas"])
            metadatas = results.get("metadatas", [])

            values = {
                "country": set(),
                "customer": set(),
                "partner": set(),
                "project": set(),
                "extension": set(),
            }

            for m in metadatas:
                for k in values.keys():
                    if m.get(k):
                        values[k].add(m[k])

            return {k: sorted(list(v)) for k, v in values.items()}
        except Exception:
            return {}


vector_store = VectorStore()
