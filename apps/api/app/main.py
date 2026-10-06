from fastapi import FastAPI

app = FastAPI(title="Dynamic QR API")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}
