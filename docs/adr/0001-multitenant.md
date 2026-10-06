# ADR-0001 · Multi-tenant SaaS

- Estado: Aceptado
- Fecha: 2026-10-05

## Contexto
Monky ofrece el servicio a varios clientes (negocios), cada uno con sus propios QR.

## Decisión
Organizaciones como tenants. Toda tabla de negocio lleva `org_id` con RLS. Roles owner/admin/editor/viewer por organización y `platform_admins` para Monky.

## Alternativas descartadas
Uso interno de una sola cuenta; multi-usuario sin organizaciones.

## Consecuencias
Aislamiento garantizado por la base de datos; cada migración necesita políticas RLS y tests de aislamiento.
