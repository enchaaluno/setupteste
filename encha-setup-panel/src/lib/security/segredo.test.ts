import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { lerSegredo } from "./segredo";

// C3 (M3) — resolvedor único de segredo: env direta OU `<NOME>_FILE`. Cobre
// as regras de precedência descritas em src/lib/security/segredo.ts.

const NOME = "TESTE_SEGREDO_XYZ";

describe("lerSegredo", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "ler-segredo-"));
  });

  afterEach(() => {
    delete process.env[NOME];
    delete process.env[`${NOME}_FILE`];
    rmSync(dir, { recursive: true, force: true });
  });

  it("retorna a env direta quando definida", () => {
    process.env[NOME] = "valor-direto";
    expect(lerSegredo(NOME)).toBe("valor-direto");
  });

  it("sem env direta, lê o conteúdo do arquivo apontado por <NOME>_FILE", () => {
    const caminho = join(dir, "segredo");
    writeFileSync(caminho, "valor-do-arquivo");
    process.env[`${NOME}_FILE`] = caminho;
    expect(lerSegredo(NOME)).toBe("valor-do-arquivo");
  });

  it("remove o newline final comum em secrets montados", () => {
    const caminho = join(dir, "segredo");
    writeFileSync(caminho, "valor-com-newline\n");
    process.env[`${NOME}_FILE`] = caminho;
    expect(lerSegredo(NOME)).toBe("valor-com-newline");
  });

  it("env direta não-vazia SEMPRE vence sobre _FILE, mesmo com valores diferentes nos dois", () => {
    process.env[NOME] = "valor-da-env";
    const caminho = join(dir, "segredo");
    writeFileSync(caminho, "valor-do-arquivo");
    process.env[`${NOME}_FILE`] = caminho;
    expect(lerSegredo(NOME)).toBe("valor-da-env");
  });

  it("env vazia (string \"\") não conta como definida — cai para _FILE", () => {
    process.env[NOME] = "";
    const caminho = join(dir, "segredo");
    writeFileSync(caminho, "valor-do-arquivo");
    process.env[`${NOME}_FILE`] = caminho;
    expect(lerSegredo(NOME)).toBe("valor-do-arquivo");
  });

  it("env só com espaços também não conta como definida", () => {
    process.env[NOME] = "   ";
    const caminho = join(dir, "segredo");
    writeFileSync(caminho, "valor-do-arquivo");
    process.env[`${NOME}_FILE`] = caminho;
    expect(lerSegredo(NOME)).toBe("valor-do-arquivo");
  });

  it("_FILE apontando para arquivo inexistente resolve para undefined, sem lançar exceção", () => {
    process.env[`${NOME}_FILE`] = join(dir, "nao-existe");
    expect(() => lerSegredo(NOME)).not.toThrow();
    expect(lerSegredo(NOME)).toBeUndefined();
  });

  it("sem env e sem _FILE, resolve para undefined", () => {
    expect(lerSegredo(NOME)).toBeUndefined();
  });

  it("_FILE definido mas vazio (string \"\") é tratado como ausente", () => {
    process.env[`${NOME}_FILE`] = "";
    expect(lerSegredo(NOME)).toBeUndefined();
  });
});
