import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { NextRequest } from "next/server";

// GET /api/stacks/enchat/primeiro-acesso: o link (?setup=) some quando o app já
// tem administrador e nunca vai para audit/cache. DB real isolado; só a sessão,
// o locale e o fetch do status do app são simulados.

let dbDir: string;
let n = 0;
const TOKEN = "TOKEN-DE-TESTE-0123456789abcdef";

beforeEach(() => {
  vi.resetModules();
  n += 1;
  dbDir = mkdtempSync(path.join(tmpdir(), "encha-setup-rota-pa-"));
  process.env.DB_PATH = path.join(dbDir, "panel.db");
  vi.doMock("@/lib/security/master-key", () => ({ getMasterKey: () => Buffer.alloc(32, 7) }));
  vi.doMock("@/lib/locale", () => ({ resolveLocale: vi.fn(async () => "pt") }));
  vi.doMock("@/lib/csrf", () => ({ getClientIp: () => `10.8.0.${n}` }));
});

afterEach(() => {
  vi.doUnmock("@/lib/security/master-key");
  vi.doUnmock("@/lib/locale");
  vi.doUnmock("@/lib/csrf");
  vi.doUnmock("@/lib/session");
  vi.unstubAllGlobals();
  rmSync(dbDir, { recursive: true, force: true });
  delete process.env.DB_PATH;
});

function comSessao(logada: boolean) {
  vi.doMock("@/lib/session", () => ({ readSession: vi.fn(async () => (logada ? { user: `u${n}` } : null)) }));
}

function appResponde(corpo: unknown | "fora") {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => {
      if (corpo === "fora") throw new Error("ECONNREFUSED");
      return new Response(JSON.stringify(corpo), { status: 200, headers: { "content-type": "application/json" } });
    })
  );
}

async function gravarSegredos() {
  const { getDb } = await import("@/lib/db");
  const { encryptSecret } = await import("@/lib/crypto");
  const blob = encryptSecret(
    JSON.stringify({
      values: { url_enchat: "crm.exemplo.com" },
      generated: [{ name: "enchat_setup_token", value: TOKEN }],
    })
  );
  const now = Date.now();
  getDb()
    .prepare("INSERT INTO stack_secrets (stack_name, encrypted_envs, created_at, updated_at) VALUES (?, ?, ?, ?)")
    .run("enchat", blob, now, now);
}

async function chamar(id = "enchat") {
  const { GET } = await import("./route");
  return GET(new NextRequest(`http://localhost/api/stacks/${id}/primeiro-acesso`), {
    params: Promise.resolve({ id }),
  });
}

describe("GET /api/stacks/[id]/primeiro-acesso", () => {
  it("sem sessão: 401 e nenhum segredo lido", async () => {
    comSessao(false);
    await gravarSegredos();
    const res = await chamar();
    expect(res.status).toBe(401);
    expect(JSON.stringify(await res.json())).not.toContain(TOKEN);
  });

  it("stack sem link de primeiro acesso ou inexistente: 404", async () => {
    comSessao(true);
    expect((await chamar("nao-existe")).status).toBe(404);
    expect((await chamar("encha-tracker")).status).toBe(404);
  });

  it("app ainda sem administrador: devolve o link, sem cache", async () => {
    comSessao(true);
    await gravarSegredos();
    appResponde({ precisa_setup: true, exige_token: true });

    const res = await chamar();

    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(await res.json()).toEqual({ setupUrl: `https://crm.exemplo.com/?setup=${TOKEN}` });
  });

  it("app JÁ tem administrador: jaCriado, e o link NÃO é devolvido", async () => {
    comSessao(true);
    await gravarSegredos();
    appResponde({ precisa_setup: false, exige_token: false });

    const corpo = await (await chamar()).json();

    expect(corpo).toEqual({ jaCriado: true });
    expect(JSON.stringify(corpo)).not.toContain(TOKEN);
  });

  it("app fora do ar: ainda entrega o link (não dá pra saber; o usuário não fica preso)", async () => {
    comSessao(true);
    await gravarSegredos();
    appResponde("fora");
    expect(await (await chamar()).json()).toEqual({ setupUrl: `https://crm.exemplo.com/?setup=${TOKEN}` });
  });

  it("painel sem o material (instalação de fora): disponivel=false", async () => {
    comSessao(true);
    appResponde({ precisa_setup: true });
    expect(await (await chamar()).json()).toEqual({ disponivel: false });
  });

  it("o token nunca aparece na trilha de auditoria", async () => {
    comSessao(true);
    await gravarSegredos();
    appResponde({ precisa_setup: true });
    await chamar();

    const { getDb } = await import("@/lib/db");
    const linhas = getDb().prepare("SELECT action, meta FROM audit_log").all() as { action: string; meta: string }[];
    expect(linhas.some((l) => l.action === "stack.primeiro_acesso")).toBe(true);
    expect(JSON.stringify(linhas)).not.toContain(TOKEN);
  });
});
