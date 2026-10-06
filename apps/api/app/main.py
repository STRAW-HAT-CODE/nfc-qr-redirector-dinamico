from fastapi import FastAPI

from app.errors import register_error_handlers

app = FastAPI(title="Dynamic QR API")
register_error_handlers(app)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}
