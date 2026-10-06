.PHONY: dev api web db lint typecheck test build

dev: ## API + web + Supabase local
	$(MAKE) db
	$(MAKE) -j2 api web

api:
	cd apps/api && uv run uvicorn app.main:app --reload --port 8000

web:
	cd apps/web && pnpm dev

db: ## Requiere Docker
	pnpm dlx supabase start

lint:
	cd apps/api && uv run ruff check . && uv run ruff format --check .
	cd apps/web && pnpm lint

typecheck:
	cd apps/api && uv run mypy app

test:
	cd apps/api && uv run pytest

build:
	cd apps/web && pnpm build
