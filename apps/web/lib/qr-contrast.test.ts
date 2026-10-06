import { describe, expect, it } from "vitest";

import { contrastRatio, contrastWarnings } from "./qr-contrast";

describe("qr-contrast", () => {
  it("negro sobre blanco = 21:1", () => {
    expect(contrastRatio("#000", "#ffffff")).toBeCloseTo(21, 0);
  });
  it("sin avisos con buen contraste", () => {
    expect(contrastWarnings("#000000", "#ffffff")).toEqual([]);
  });
  it("avisa contraste bajo e invertido", () => {
    expect(contrastWarnings("#cccccc", "#ffffff")).toHaveLength(1);
    expect(contrastWarnings("#ffffff", "#000000")).toHaveLength(1);
  });
  it("hex inválido no avisa", () => {
    expect(contrastRatio("rojo", "#fff")).toBeNull();
    expect(contrastWarnings("x", "y")).toEqual([]);
  });
});
