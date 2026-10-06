from fastapi import FastAPI

from app.errors import register_error_handlers
from app.routers import links, orgs

app = FastAPI(title="Dynamic QR API")
register_error_handlers(app)
app.include_router(orgs.router)
app.include_router(links.router)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}
