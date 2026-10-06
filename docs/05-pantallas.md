# 5 · Pantallas y componentes (apps/web)

| Pantalla | Ruta | Componentes clave | Rol |
|---|---|---|---|
| Login / registro | `/login`, `/signup` | AuthForm | — |
| Selector de organización | `/orgs` | OrgSwitcher, CreateOrgDialog | autenticado |
| Lista de enlaces | `/links` | LinksTable (búsqueda, estado, escaneos 7 d), EmptyState | viewer |
| Crear enlace | `/links/new` | LinkForm (destino, nombre, fallback, vigencia) | editor |
| Detalle / editar | `/links/[id]` | DestinationEditor, StatusToggle, HistoryList | viewer/editor |
| Diseñador de QR | `/links/[id]/design` | QrPreview, ColorPickers, LogoUpload, FramePicker, ContrastWarning, DownloadMenu, TemplatesGallery, "Terminar en Canva" | editor |
| Tags NFC | `/links/[id]/nfc` | NfcTagList, NdefUrlCopy, WriteGuide | editor |
| Analytics | `/analytics`, `/links/[id]/stats` | DateRange, KpiCards, ScansChart, BreakdownTables | viewer |
| Miembros | `/settings/members` | MembersTable, InviteDialog | admin |
| Consola Monky | `/platform` | OrgsTable, PlanEditor, SuspendAction | platform admin |
| Enlace no disponible | (servida por la API) | Página estática ligera | público |

Guías: shadcn/ui, estados vacío/carga/error en toda pantalla, responsive, claro/oscuro, accesible (contraste AA, foco visible).
