import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { getLocalAdmin, hasServiceCredentials, verifyLocalAdmin } from "./local-admin";

// C3 (M3, achado da auditoria em produção): getLocalAdmin/hasServiceCredentials
// passam a resolver a senha via lerSegredo (env direta OU `<NOME>_FILE`).
// Antes deste ciclo, hasServiceCredentials lia só a env direta e ignorava
// PORTAINER_PASSWORD_FILE — instalação só com o secret via _FILE caía no
// 503 "configuração incompleta" mesmo com credencial válida disponível.

const ENV_KEYS = [
  "PANEL_ADMIN_USER",
  "PANEL_ADMIN_PASSWORD",
  "PANEL_ADMIN_PASSWORD_FILE",
  "PORTAINER_USER",
  "PORTAINER_PASSWORD",
  "PORTAINER_PASSWORD_FILE",
] as const;

describe("getLocalAdmin / hasServiceCredentials (resolução de segredo via lerSegredo)", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "local-admin-"));
  });

  afterEach(() => {
    for (const k of ENV_KEYS) delete process.env[k];
    rmSync(dir, { recursive: true, force: true });
  });

  function arquivoCom(conteudo: string): string {
    const caminho = join(dir, "segredo");
    writeFileSync(caminho, conteudo);
    return caminho;
  }

  describe("hasServiceCredentials", () => {
    it("PORTAINER_PASSWORD_FILE sozinho (sem env direta) → true (RED do bug: hoje retorna false)", () => {
      process.env.PORTAINER_USER = "svc";
      process.env.PORTAINER_PASSWORD_FILE = arquivoCom("segredo-do-arquivo");
      expect(hasServiceCredentials()).toBe(true);
    });

    it("env direta sozinha (sem _FILE) → true", () => {
      process.env.PORTAINER_USER = "svc";
      process.env.PORTAINER_PASSWORD = "segredo-direto";
      expect(hasServiceCredentials()).toBe(true);
    });

    it("nem env nem _FILE → false", () => {
      process.env.PORTAINER_USER = "svc";
      expect(hasServiceCredentials()).toBe(false);
    });

    it("_FILE apontando para arquivo inexistente → false, sem lançar exceção", () => {
      process.env.PORTAINER_USER = "svc";
      process.env.PORTAINER_PASSWORD_FILE = join(dir, "nao-existe");
      expect(() => hasServiceCredentials()).not.toThrow();
      expect(hasServiceCredentials()).toBe(false);
    });

    it("sem PORTAINER_USER, mesmo com senha resolvível → false", () => {
      process.env.PORTAINER_PASSWORD = "segredo-direto";
      expect(hasServiceCredentials()).toBe(false);
    });
  });

  describe("getLocalAdmin", () => {
    it("usa o mesmo resolvedor para a senha: _FILE sozinho resolve o admin local", () => {
      process.env.PANEL_ADMIN_USER = "admin";
      process.env.PANEL_ADMIN_PASSWORD_FILE = arquivoCom("senha-do-arquivo\n");
      expect(getLocalAdmin()).toEqual({ user: "admin", password: "senha-do-arquivo" });
    });

    it("env direta não-vazia sempre vence sobre _FILE, mesmo com os dois definidos com valores diferentes", () => {
      process.env.PANEL_ADMIN_USER = "admin";
      process.env.PANEL_ADMIN_PASSWORD = "senha-da-env";
      process.env.PANEL_ADMIN_PASSWORD_FILE = arquivoCom("senha-do-arquivo");
      expect(getLocalAdmin()).toEqual({ user: "admin", password: "senha-da-env" });
    });

    it("conteúdo do arquivo com newline final vem sem o newline (.trim())", () => {
      process.env.PANEL_ADMIN_USER = "admin";
      process.env.PANEL_ADMIN_PASSWORD_FILE = arquivoCom("senha-com-newline\n");
      expect(getLocalAdmin()?.password).toBe("senha-com-newline");
    });

    it("env vazia (\"\") não conta como definida — cai para _FILE", () => {
      process.env.PANEL_ADMIN_USER = "admin";
      process.env.PANEL_ADMIN_PASSWORD = "";
      process.env.PANEL_ADMIN_PASSWORD_FILE = arquivoCom("senha-do-arquivo");
      expect(getLocalAdmin()?.password).toBe("senha-do-arquivo");
    });

    it("sem usuário → null mesmo com senha resolvível", () => {
      process.env.PANEL_ADMIN_PASSWORD = "senha-da-env";
      expect(getLocalAdmin()).toBeNull();
    });

    it("sem senha (nem env nem _FILE) → null", () => {
      process.env.PANEL_ADMIN_USER = "admin";
      expect(getLocalAdmin()).toBeNull();
    });
  });

  describe("verifyLocalAdmin (comparação em tempo constante não muda — só a origem da senha)", () => {
    it("aceita a senha lida via _FILE", () => {
      process.env.PANEL_ADMIN_USER = "admin";
      process.env.PANEL_ADMIN_PASSWORD_FILE = arquivoCom("senha-secreta\n");
      expect(verifyLocalAdmin("admin", "senha-secreta")).toBe(true);
      expect(verifyLocalAdmin("admin", "senha-errada")).toBe(false);
    });

    it("sem admin local configurado, sempre recusa", () => {
      expect(verifyLocalAdmin("admin", "qualquer")).toBe(false);
    });
  });
});
