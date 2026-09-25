import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

// Link de primeiro acesso remontado do material que o instalador já guarda
// cifrado em stack_secrets. Banco real isolado (DB_PATH) e chave mestra fixa.

let dbDir: string;
const TOKEN = "TOKEN-DE-TESTE-0123456789abcdef";

beforeEach(() => {
  vi.resetModules();
  dbDir = mkdtempSync(path.join(tmpdir(), "encha-setup-primeiro-acesso-"));
  process.env.DB_PATH = path.join(dbDir, "panel.db");
  vi.doMock("@/lib/security/master-key", () => ({ getMasterKey: () => Buffer.alloc(32, 7) }));
});

afterEach(() => {
  vi.doUnmock("@/lib/security/master-key");
  rmSync(dbDir, { recursive: true, force: true });
  delete process.env.DB_PATH;
});

async function gravarSegredos(stackName: string, conteudo: unknown | string) {
  const { getDb } = await import("@/lib/db");
  const { encryptSecret } = await import("@/lib/crypto");
  const blob = typeof conteudo === "string" ? conteudo : encryptSecret(JSON.stringify(conteudo));
  const now = Date.now();
  getDb()
    .prepare("INSERT INTO stack_secrets (stack_name, encrypted_envs, created_at, updated_at) VALUES (?, ?, ?, ?)")
    .run(stackName, blob, now, now);
}

const segredosDoEnchat = (over: Record<string, unknown> = {}) => ({
  values: { url_enchat: "crm.exemplo.com" },
  generated: [
    { name: "enchat_master_key", value: "nao-deve-vazar" },
    { name: "enchat_setup_token", value: TOKEN },
  ],
  ...over,
});

describe("lerLinkPrimeiroAcesso", () => {
  it("remonta o MESMO link que o install mostrou (setupUrl da definição da stack)", async () => {
    await gravarSegredos("enchat", segredosDoEnchat());
    const { lerLinkPrimeiroAcesso } = await import("./primeiro-acesso");

    expect(await lerLinkPrimeiroAcesso("enchat")).toEqual({
      setupUrl: `https://crm.exemplo.com/?setup=${TOKEN}`,
      dominio: "crm.exemplo.com",
    });
  });

  it("sem linha em stack_secrets (instalação de fora do painel): null", async () => {
    const { lerLinkPrimeiroAcesso } = await import("./primeiro-acesso");
    expect(await lerLinkPrimeiroAcesso("enchat")).toBeNull();
  });

  it("sem o token gerado, ou sem os valores: null (nunca um link quebrado)", async () => {
    await gravarSegredos("enchat", segredosDoEnchat({ generated: [{ name: "enchat_master_key", value: "x" }] }));
    const { lerLinkPrimeiroAcesso } = await import("./primeiro-acesso");
    expect(await lerLinkPrimeiroAcesso("enchat")).toBeNull();
  });

  it("blob corrompido / chave mestra diferente: null, sem lançar", async () => {
    await gravarSegredos("enchat", "isto-nao-e-um-blob-valido");
    const { lerLinkPrimeiroAcesso } = await import("./primeiro-acesso");
    expect(await lerLinkPrimeiroAcesso("enchat")).toBeNull();
  });

  it("stack sem postInstall.setupUrl (ex.: Encha Tracker) ou desconhecida: null", async () => {
    await gravarSegredos("encha_tracker", segredosDoEnchat());
    const { lerLinkPrimeiroAcesso } = await import("./primeiro-acesso");
    expect(await lerLinkPrimeiroAcesso("encha-tracker")).toBeNull();
    expect(await lerLinkPrimeiroAcesso("nao-existe")).toBeNull();
  });
});

describe("appPrecisaSetup", () => {
  const resposta = (corpo: unknown, status = 200) =>
    vi.fn(async () => new Response(JSON.stringify(corpo), { status, headers: { "content-type": "application/json" } }));

  it("true/false vêm de precisa_setup, consultando o endereço público do app", async () => {
    const { appPrecisaSetup } = await import("./primeiro-acesso");
    const sim = resposta({ precisa_setup: true, exige_token: true });
    expect(await appPrecisaSetup("crm.exemplo.com", sim as unknown as typeof fetch)).toBe(true);
    expect(sim.mock.calls[0][0]).toBe("https://crm.exemplo.com/api/setup/status");
    expect(await appPrecisaSetup("crm.exemplo.com", resposta({ precisa_setup: false }) as unknown as typeof fetch)).toBe(false);
  });

  it("app fora do ar, HTTP de erro ou corpo inesperado: null (não dá pra saber)", async () => {
    const { appPrecisaSetup } = await import("./primeiro-acesso");
    const caiu = vi.fn(async () => {
      throw new Error("ECONNREFUSED");
    });
    expect(await appPrecisaSetup("x.com", caiu as unknown as typeof fetch)).toBeNull();
    expect(await appPrecisaSetup("x.com", resposta({}, 502) as unknown as typeof fetch)).toBeNull();
    expect(await appPrecisaSetup("x.com", resposta({ precisa_setup: "sim" }) as unknown as typeof fetch)).toBeNull();
  });
});
