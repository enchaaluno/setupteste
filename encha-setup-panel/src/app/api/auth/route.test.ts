import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";

// Auditoria C6: no modo legado (sem admin próprio), o login dispara
// dispararGarantiaAposLoginLegado(jwt) — fire-and-forget. Aqui o
// guard-runtime é o REAL (não mockado): só o Portainer é simulado, travando
// ou falhando em pontos diferentes do fluxo do guarda. A garantia provada:
// nada que aconteça dentro do guarda atrasa, falha ou muda a resposta do
// login. Se alguém trocar o disparo por um `await` do fluxo do guarda, o
// caso "Portainer trava" estoura o tempo e o caso "lança" vira 502.

type PortainerOverrides = Record<string, unknown>;

async function carregarRota(overrides: PortainerOverrides) {
  vi.doMock("@/lib/locale", () => ({ resolveLocale: vi.fn(async () => "pt") }));
  vi.doMock("@/lib/csrf", () => ({
    verifyOrigin: () => true,
    verifyCsrf: async () => true,
    getClientIp: () => "10.9.9.9",
    newCsrfToken: () => "csrf",
  }));
  vi.doMock("@/lib/security/rate-limit", () => ({
    checkRateLimit: () => ({ allowed: true, remaining: 4, resetMs: 0 }),
  }));
  vi.doMock("@/lib/session", () => ({
    createSession: vi.fn(async () => undefined),
    setCsrfCookie: vi.fn(async () => undefined),
    destroySession: vi.fn(async () => undefined),
  }));
  vi.doMock("@/lib/audit", () => ({ logAudit: vi.fn() }));
  vi.doMock("@/lib/auth/local-admin", async (importOriginal) => {
    const actual = await importOriginal<typeof import("@/lib/auth/local-admin")>();
    return { ...actual, getLocalAdmin: () => null, hasServiceCredentials: () => false };
  });
  vi.doMock("@/lib/portainer", async (importOriginal) => {
    const actual = await importOriginal<typeof import("@/lib/portainer")>();
    return { ...actual, authenticate: vi.fn(async () => "jwt-do-usuario"), ...overrides };
  });
  return import("./route");
}

function requisicaoLogin() {
  return new NextRequest("http://localhost/api/auth", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ username: "admin", password: "senha-qualquer" }),
  });
}

// Corre a resposta contra um relógio: se o login esperasse o guarda, o
// "nunca resolve" abaixo nunca devolveria nada.
async function comPrazo<T>(p: Promise<T>, ms = 2_000): Promise<T> {
  let t: NodeJS.Timeout | undefined;
  const prazo = new Promise<never>((_, rej) => {
    t = setTimeout(() => rej(new Error("login esperou o guarda (não é fire-and-forget)")), ms);
  });
  try {
    return await Promise.race([p, prazo]);
  } finally {
    clearTimeout(t);
  }
}

beforeEach(() => {
  vi.resetModules();
});

afterEach(() => {
  for (const m of [
    "@/lib/locale",
    "@/lib/csrf",
    "@/lib/security/rate-limit",
    "@/lib/session",
    "@/lib/audit",
    "@/lib/auth/local-admin",
    "@/lib/portainer",
  ]) {
    vi.doUnmock(m);
  }
  vi.restoreAllMocks();
});

describe("POST /api/auth (modo legado) — garantia do encha-guard é fire-and-forget", () => {
  it("Portainer TRAVA na descoberta do endpoint -> login responde 200 na hora, mesmo assim", async () => {
    const discoverContext = vi.fn(() => new Promise<never>(() => {}));
    const { POST } = await carregarRota({ discoverContext });

    const res = await comPrazo(POST(requisicaoLogin()));

    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
    expect(discoverContext).toHaveBeenCalledWith("jwt-do-usuario"); // o disparo aconteceu
  });

  it("descoberta LANÇA de forma síncrona -> login continua 200 e o erro só vai para o log", async () => {
    const erroMock = vi.spyOn(console, "error").mockImplementation(() => {});
    const discoverContext = vi.fn(() => {
      throw new Error("explodiu síncrono");
    });
    const { POST } = await carregarRota({ discoverContext });

    const res = await comPrazo(POST(requisicaoLogin()));
    await new Promise((r) => setTimeout(r, 0));

    expect(res.status).toBe(200);
    expect(erroMock).toHaveBeenCalledWith(
      expect.stringContaining("[guard]"),
      expect.objectContaining({ message: "explodiu síncrono" })
    );
  });

  it("falha no meio do guarda (listNodes rejeita) -> login continua 200", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const listNodes = vi.fn(async () => {
      throw new Error("Portainer fora");
    });
    const { POST } = await carregarRota({
      discoverContext: vi.fn(async () => ({ endpointId: 1, swarmId: "s" })),
      listNodes,
    });

    const res = await comPrazo(POST(requisicaoLogin()));
    await new Promise((r) => setTimeout(r, 0));

    expect(res.status).toBe(200);
    expect(listNodes).toHaveBeenCalled();
  });

  it("login inválido (Portainer 401) -> 401 e o guarda NUNCA é disparado", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { PortainerError } = await import("@/lib/portainer");
    const discoverContext = vi.fn(async () => ({ endpointId: 1, swarmId: "s" }));
    const { POST } = await carregarRota({
      authenticate: vi.fn(async () => {
        throw new PortainerError(401, "bad creds");
      }),
      discoverContext,
    });

    const res = await comPrazo(POST(requisicaoLogin()));

    expect(res.status).toBe(401);
    expect(discoverContext).not.toHaveBeenCalled();
  });
});
