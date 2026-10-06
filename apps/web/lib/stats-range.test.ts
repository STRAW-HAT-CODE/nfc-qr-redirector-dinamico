import { describe, expect, it } from "vitest";

import { eachDay, resolveRange, topWithOthers } from "./stats-range";

const now = new Date("2026-10-06T12:00:00Z");

describe("resolveRange", () => {
  it("usa 30 días por defecto", () => {
    expect(resolveRange({}, now)).toEqual({ from: "2026-09-07", to: "2026-10-06", preset: 30 });
  });
  it("acepta presets 7 y 90", () => {
    expect(resolveRange({ range: "7" }, now).from).toBe("2026-09-30");
    expect(resolveRange({ range: "90" }, now).preset).toBe(90);
  });
  it("ignora presets desconocidos", () => {
    expect(resolveRange({ range: "5" }, now).preset).toBe(30);
  });
  it("acepta un rango personalizado válido", () => {
    expect(resolveRange({ from: "2026-01-01", to: "2026-01-31" }, now)).toEqual({
      from: "2026-01-01",
      to: "2026-01-31",
      preset: null,
    });
  });
  it("rechaza más de 366 días, invertidos, futuros y basura", () => {
    expect(resolveRange({ from: "2025-01-01", to: "2026-10-06" }, now).notice).toMatch(/366/);
    expect(resolveRange({ from: "2026-02-01", to: "2026-01-01" }, now).notice).toBeDefined();
    expect(resolveRange({ from: "2026-10-01", to: "2026-10-20" }, now).notice).toBeDefined();
    expect(resolveRange({ from: "foo", to: "2026-01-01" }, now).preset).toBe(30);
    expect(resolveRange({ from: "2026-02-30", to: "2026-03-01" }, now).notice).toBeDefined();
  });
  it("permite exactamente 366 días", () => {
    expect(resolveRange({ from: "2025-10-06", to: "2026-10-06" }, now).preset).toBeNull();
  });
});

describe("eachDay", () => {
  it("incluye ambos extremos", () => {
    expect(eachDay("2026-02-27", "2026-03-01")).toEqual(["2026-02-27", "2026-02-28", "2026-03-01"]);
  });
});

describe("topWithOthers", () => {
  it("agrupa el resto y 'other' en otros", () => {
    const rows = [
      { key: "a", scans: 5 },
      { key: "b", scans: 4 },
      { key: "c", scans: 3 },
      { key: "other", scans: 2 },
    ];
    expect(topWithOthers(rows, 2)).toEqual([
      { key: "a", scans: 5 },
      { key: "b", scans: 4 },
      { key: "other", scans: 5 },
    ]);
  });
  it("sin resto no añade otros", () => {
    expect(topWithOthers([{ key: "a", scans: 1 }])).toEqual([{ key: "a", scans: 1 }]);
  });
});
