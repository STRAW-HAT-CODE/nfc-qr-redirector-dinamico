import { describe, expect, it } from "vitest";

import { safeNext } from "./safe-next";

describe("safeNext", () => {
  it.each([
    "https://evil.com",
    "//evil.com",
    "/\\evil.com",
    "/\t/evil.com",
    "/\n/evil.com",
    "/\r/evil.com",
    "/\u0000/evil.com",
    "/\u007f/evil.com",
    "",
    null,
    undefined,
  ])("rechaza %j", (v) => {
    expect(safeNext(v as string | null | undefined)).toBe("/orgs");
  });

  it("usa el fallback indicado", () => {
    expect(safeNext("//evil.com", "/links")).toBe("/links");
  });

  it("/%09/evil.com queda como ruta interna (sin decodificar)", () => {
    const r = safeNext("/%09/evil.com");
    expect(r).toBe("/%09/evil.com");
    expect(new URL(r, "http://x").origin).toBe("http://x");
  });

  it.each([
    ["/links", "/links"],
    ["/links/abc?x=1#top", "/links/abc?x=1#top"],
    ["/settings/members", "/settings/members"],
  ])("acepta %s", (v, out) => {
    expect(safeNext(v)).toBe(out);
  });
});
