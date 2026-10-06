# Dynamic QR — Project Hub

Plataforma SaaS multi-tenant de **QR dinámicos + NFC**. Cada código impreso apunta a `https://<dominio>/r/{slug}`; el destino se cambia desde el dashboard sin reimprimir y cada escaneo se mide.

```
Monky (plataforma)
 ├─ Cliente A (organización) → QR-001, QR-004 …
 ├─ Cliente B (organización) → QR-002, QR-005 …
 └─ Cliente C (organización) → QR-003, QR-006 …
```

## Índice
1. [Producto y requisitos](01-producto.md)
2. [Arquitectura](02-arquitectura.md)
3. [Modelo de datos](03-modelo-datos.md)
4. [API](04-api.md)
5. [Pantallas](05-pantallas.md)
6. [Seguridad y abuso](06-seguridad.md)
7. [Deploy e infraestructura](07-deploy.md)
8. [Módulos](modules/) · [ADRs](adr/) · [Flujo de agentes](../AGENTS.md) · [Tablero](../BOARD.md)

## Módulos
| Código | Módulo | Depende de | Sprint | Líder |
|---|---|---|---|---|
| DQR-00 | Fundaciones | — | S1 | devops |
| DQR-01 | Identidad y tenancy | 00 | S1 | db-architect |
| DQR-02 | Enlaces dinámicos | 01 | S1 | backend-api |
| DQR-03 | Redirector | 02 | S1 | backend-api |
| DQR-04 | Generación y diseño de QR | 02 | S2 | qr-nfc |
| DQR-05 | NFC | 02, 03 | S2 | qr-nfc |
| DQR-06 | Analytics | 03 | S3 | analytics |
| DQR-07 | Dashboard web | 01, 02 | S3 | frontend |
| DQR-08 | Seguridad y abuso | 02, 03 | S4 | security-reviewer |
| DQR-09 | Consola de plataforma Monky | 01 | S4 | frontend |
| DQR-10 | Infraestructura y deploy | 00 | S4 | devops |

## Roadmap
| Fase | Contenido |
|---|---|
| S0 | Hub, especificación, agentes, tablero (sin código) |
| S1 | Fundaciones, tenancy, enlaces, redirector |
| S2 | Generación/diseño QR, plantillas y Canva, NFC |
| S3 | Analytics y dashboard |
| S4 | Seguridad, consola Monky, producción |
| V2 | Dominios propios por cliente, reglas geo/dispositivo/horario, A/B, CSV masivo, API keys, webhooks, facturación |
| Futuro | App Canva Connect, marca blanca, landing "link in bio" |
