import os
import re
from typing import Dict, Any


def extract_metadata_from_path(rel_path: str) -> Dict[str, Any]:
    # Normalize to forward slashes
    rel_path = rel_path.replace("\\", "/")
    parts = rel_path.split("/")
    filename = parts[-1]

    ext = ""
    if "." in filename:
        ext = filename.rsplit(".", 1)[-1].lower()

    # Defaults
    metadata = {
        "path": rel_path,
        "extension": ext,
        "country": None,
        "customer": None,
        "partner": None,
        "project": None,
        "date": None,
        "tags": [],
    }

    # Date extraction from filename
    # e.g. 20250409 -> 2025-04-09
    date_match = re.search(r"\b(20\d{2})[-_]?([01]\d)[-_]?([0-3]\d)\b", filename)
    if date_match:
        year, month, day = date_match.groups()
        metadata["date"] = f"{year}-{month}-{day}"
    else:
        # e.g. 2025-04-09
        date_match_2 = re.search(
            r"\b(20\d{2})-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])\b", filename
        )
        if date_match_2:
            metadata["date"] = date_match_2.group(0)

    if len(parts) > 1:
        root_dir = parts[0].lower()
        if root_dir in ["customers", "archive"]:
            # usually `Country - Customer` or `Country - Customer - Project`
            if len(parts) > 2:
                customer_dir = parts[1]
                cust_parts = [p.strip() for p in customer_dir.split("-")]

                if len(cust_parts) >= 2:
                    if len(cust_parts[0]) <= 3 or root_dir == "customers":
                        metadata["country"] = cust_parts[0]
                        metadata["customer"] = cust_parts[1]
                        if len(cust_parts) > 2:
                            metadata["project"] = " - ".join(cust_parts[2:])
                    else:
                        # e.g. Gone - UKCloud - NES
                        metadata["partner"] = cust_parts[1]
                        if len(cust_parts) > 2:
                            metadata["customer"] = cust_parts[2]
                else:
                    metadata["customer"] = customer_dir

                # Next part could be project
                if not metadata.get("project") and len(parts) > 3:
                    metadata["project"] = parts[2]

            # File name heuristics for project
            if not metadata.get("project") and " - " in filename:
                fn_parts = [p.strip() for p in filename.rsplit(".", 1)[0].split("-")]
                if len(fn_parts) >= 2:
                    # assume the last part or part after date is project
                    metadata["project"] = fn_parts[-1]

        elif root_dir == "products":
            if len(parts) > 2:
                metadata["project"] = parts[1]  # Product name as project

    # Load overrides from .meta.json if present
    try:
        from app.config import get_settings
        import json

        settings = get_settings()
        meta_file = os.path.join(settings.pkm_root, rel_path + ".meta.json")
        if os.path.exists(meta_file):
            with open(meta_file, "r", encoding="utf-8") as f:
                overrides = json.load(f)
            metadata.update(overrides)
    except Exception as e:
        import logging

        logging.getLogger("dido").error(
            f"Failed to load metadata overrides for {rel_path}: {e}"
        )

    return metadata
