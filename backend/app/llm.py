import httpx
from app.config import get_settings
import os
import base64


async def generate_answer(
    query: str, retrieved_chunks: list[dict], file_path: str = None
):
    settings = get_settings()
    base_url = settings.vlm_base_url if settings.vlm_base_url else settings.llm_base_url
    url = f"{base_url}/api/generate"

    prompt = f"{settings.system_prompt}\n\n" "Context:\n"

    for i, chunk in enumerate(retrieved_chunks):
        path = chunk["metadata"].get("path", "Unknown File")
        snippet = chunk["snippet"]
        prompt += f"--- Source {i+1} ({path}) ---\n{snippet}\n\n"

    images = []
    if file_path:
        full_path = os.path.join(settings.pkm_root, file_path)
        if os.path.exists(full_path):
            ext = full_path.rsplit(".", 1)[-1].lower() if "." in full_path else ""
            if ext in ["pdf"]:
                try:
                    import pypdfium2 as pdfium
                    import io

                    pdf = pdfium.PdfDocument(full_path)
                    for page_idx in range(min(len(pdf), 5)):  # limit to 5 pages
                        page = pdf[page_idx]
                        img = page.render(scale=2).to_pil()
                        buf = io.BytesIO()
                        img.save(buf, format="JPEG")
                        images.append(base64.b64encode(buf.getvalue()).decode("utf-8"))
                    prompt += f"--- Source (Attached File: {file_path}) ---\n"
                    prompt += f"(The first {len(images)} pages of the PDF are attached as images to this request.)\n\n"

                    # Also include text if possible
                    from docling.document_converter import (
                        DocumentConverter,
                        PdfFormatOption,
                    )
                    from docling.datamodel.base_models import InputFormat
                    from docling.datamodel.pipeline_options import PdfPipelineOptions

                    pipeline_options = PdfPipelineOptions()
                    pipeline_options.do_ocr = False
                    converter = DocumentConverter(
                        format_options={
                            InputFormat.PDF: PdfFormatOption(
                                pipeline_options=pipeline_options
                            )
                        }
                    )
                    result = converter.convert(full_path)
                    text = result.document.export_to_markdown()
                    prompt += f"--- Extracted Text from PDF ---\n{text}\n\n"
                except Exception as e:
                    print(f"Failed to process PDF: {e}")
            elif ext in ["docx", "pptx", "xlsx"]:
                try:
                    from docling.document_converter import DocumentConverter

                    converter = DocumentConverter()
                    result = converter.convert(full_path)
                    text = result.document.export_to_markdown()
                    prompt += f"--- Source (Attached File Content: {file_path}) ---\n{text}\n\n"
                except Exception as e:
                    print(
                        f"Failed to process binary file {file_path} with Docling: {e}"
                    )
            elif ext in ["png", "jpg", "jpeg", "webp", "gif", "bmp"]:
                with open(full_path, "rb") as f:
                    encoded = base64.b64encode(f.read()).decode("utf-8")
                    images.append(encoded)
                prompt += f"--- Source (Attached File: {file_path}) ---\n"
                prompt += "(The image file is attached to this request.)\n\n"
            else:
                pass  # Other files are already handled or included via chunks

    prompt += f"Query: {query}\n\nAnswer:"

    payload = {"model": settings.llm_model, "prompt": prompt, "stream": False}

    if images:
        payload["images"] = images

    headers = {}
    if settings.llm_api_token:
        headers["Authorization"] = f"Bearer {settings.llm_api_token}"

    try:
        async with httpx.AsyncClient() as client:
            response = await client.post(
                url, json=payload, headers=headers, timeout=600.0
            )
            if response.status_code != 200:
                error_msg = f"HTTP {response.status_code}"
                try:
                    error_data = response.json()
                    if "error" in error_data:
                        error_msg += f": {error_data['error']}"
                except Exception:
                    error_msg += f": {response.text}"
                return f"Error communicating with LLM/VLM at {base_url}: {error_msg}"

            data = response.json()
            return data.get("response", "")
    except httpx.RequestError as e:
        err_str = str(e)
        if not err_str:
            err_str = type(e).__name__
        return f"Error communicating with LLM/VLM at {base_url}: {err_str}"
    except Exception as e:
        err_str = str(e)
        if not err_str:
            err_str = type(e).__name__
        return f"Error generating answer: {err_str}"
