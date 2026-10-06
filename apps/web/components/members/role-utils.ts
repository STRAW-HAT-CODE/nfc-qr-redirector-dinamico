import type { Role } from "@/lib/api";

export const ROLE_LABEL: Record<Role, string> = {
  viewer: "Lector",
  editor: "Editor",
  admin: "Admin",
  owner: "Owner",
};

export const ALL_ROLES: Role[] = ["viewer", "editor", "admin", "owner"];

/** Roles que el rol del actor puede asignar: owner solo lo asigna un owner. */
export const assignableRoles = (actor: Role): Role[] =>
  actor === "owner" ? ALL_ROLES : ALL_ROLES.filter((r) => r !== "owner");

/** Un admin no puede modificar ni quitar a un owner. */
export const canManage = (actor: Role, target: Role) => actor === "owner" || target !== "owner";
