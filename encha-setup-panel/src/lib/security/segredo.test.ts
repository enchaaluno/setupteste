import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
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
    vi.restoreAllMocks();
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

  // Auditoria C3: `_FILE` configurado mas inutilizável é erro de instalação
  // que muda o modo de login (local → passthrough) — não pode ser silencioso,
  // mas também não pode poluir o log a cada requisição nem vazar o conteúdo.
  describe("aviso de _FILE inutilizável", () => {
    it("arquivo inexistente: avisa com o nome da variável e o código do erro", () => {
      const aviso = vi.spyOn(console, "warn").mockImplementation(() => {});
      process.env[`${NOME}_FILE`] = join(dir, "nao-existe");
      expect(lerSegredo(NOME)).toBeUndefined();
      expect(aviso).toHaveBeenCalledTimes(1);
      expect(String(aviso.mock.calls[0][0])).toContain(`${NOME}_FILE`);
      expect(String(aviso.mock.calls[0][0])).toContain("ENOENT");
    });

    it("avisa uma vez só por causa, mesmo chamado a cada requisição", () => {
      const aviso = vi.spyOn(console, "warn").mockImplementation(() => {});
      process.env[`${NOME}_FILE`] = join(dir, "nao-existe");
      lerSegredo(NOME);
      lerSegredo(NOME);
      lerSegredo(NOME);
      expect(aviso).toHaveBeenCalledTimes(1);
    });

    it("arquivo vazio (só newline): avisa como vazio", () => {
      const aviso = vi.spyOn(console, "warn").mockImplementation(() => {});
      const caminho = join(dir, "segredo");
      writeFileSync(caminho, "\n");
      process.env[`${NOME}_FILE`] = caminho;
      expect(lerSegredo(NOME)).toBeUndefined();
      expect(aviso).toHaveBeenCalledTimes(1);
      expect(String(aviso.mock.calls[0][0])).toContain("vazio");
    });

    it("env direta vence: nem toca no _FILE quebrado, então não avisa", () => {
      const aviso = vi.spyOn(console, "warn").mockImplementation(() => {});
      process.env[NOME] = "valor-da-env";
      process.env[`${NOME}_FILE`] = join(dir, "nao-existe");
      expect(lerSegredo(NOME)).toBe("valor-da-env");
      expect(aviso).not.toHaveBeenCalled();
    });

    it("leitura bem-sucedida não avisa e nunca loga o conteúdo", () => {
      const aviso = vi.spyOn(console, "warn").mockImplementation(() => {});
      const log = vi.spyOn(console, "log").mockImplementation(() => {});
      const erro = vi.spyOn(console, "error").mockImplementation(() => {});
      const caminho = join(dir, "segredo");
      writeFileSync(caminho, "segredo-que-nao-pode-vazar\n");
      process.env[`${NOME}_FILE`] = caminho;
      expect(lerSegredo(NOME)).toBe("segredo-que-nao-pode-vazar");
      expect(aviso).not.toHaveBeenCalled();
      expect(log).not.toHaveBeenCalled();
      expect(erro).not.toHaveBeenCalled();
    });

    it.skipIf(process.getuid?.() === 0)("sem permissão de leitura: avisa EACCES sem o conteúdo", () => {
      const aviso = vi.spyOn(console, "warn").mockImplementation(() => {});
      const caminho = join(dir, "segredo");
      writeFileSync(caminho, "segredo-que-nao-pode-vazar");
      chmodSync(caminho, 0o000);
      process.env[`${NOME}_FILE`] = caminho;
      expect(lerSegredo(NOME)).toBeUndefined();
      expect(aviso).toHaveBeenCalledTimes(1);
      const msg = String(aviso.mock.calls[0][0]);
      expect(msg).toContain("EACCES");
      expect(msg).not.toContain("segredo-que-nao-pode-vazar");
    });
  });
});
