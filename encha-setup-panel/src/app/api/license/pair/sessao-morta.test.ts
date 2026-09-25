import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { NextRequest } from "next/server";

// Sessão de pareamento que o Console deixou de conhecer (404/410 — expirou ou
// foi apagada, ex.: "Reset de teste"). Antes: o poll respondia "aguardando"
// pra sempre, o CPF virava "nao_confirmou_cpf" e "Gerar outro código"
// retomava a MESMA sessão morta (pareamentoAtivo ainda a via 'aberto').
// Aqui o banco do painel é real (DB_PATH isolado, mesmo padrão de
// pairing-store.test.ts) e só o Console (license-pairing) é simulado.

let dbDir: string;
const STACK = "enchat";
let ipSeq = 0;

beforeEach(() => {
  vi.resetModules();
  dbDir = mkdtempSync(path.join(tmpdir(), "encha-setup-sessao-morta-"));
  process.env.DB_PATH = path.join(dbDir, "panel.db");
  ipSeq += 1; // rate limit é em memória por IP — um IP por teste evita vazar entre eles
});

afterEach(() => {
  vi.doUnmock("@/lib/auth/require-token");
  vi.doUnmock("@/lib/locale");
  vi.doUnmock("@/lib/csrf");
  vi.doUnmock("@/lib/stacks/registry");
  vi.doUnmock("@/lib/license-pairing");
  vi.doUnmock("@/lib/release-info");
  rmSync(dbDir, { recursive: true, force: true });
  delete process.env.DB_PATH;
});

type Mocks = {
  pairPoll: ReturnType<typeof vi.fn>;
  pairCpf: ReturnType<typeof vi.fn>;
  pairStart: ReturnType<typeof vi.fn>;
};

async function montar(): Promise<Mocks> {
  const mocks: Mocks = { pairPoll: vi.fn(), pairCpf: vi.fn(), pairStart: vi.fn() };
  vi.doMock("@/lib/auth/require-token", () => ({
    requireSessionToken: vi.fn(async () => ({ session: { user: "tester" }, token: "tok" })),
  }));
  vi.doMock("@/lib/locale", () => ({ resolveLocale: vi.fn(async () => "pt") }));
  vi.doMock("@/lib/csrf", () => ({
    verifyOrigin: () => true,
    verifyCsrf: async () => true,
    getClientIp: () => `10.9.0.${ipSeq}`,
  }));
  vi.doMock("@/lib/stacks/registry", () => ({
    getStack: () => ({
      id: STACK,
      appHostname: "enchat-app",
      pairing: { consoleBaseUrl: "http://console.invalid", edicao: "free" },
    }),
  }));
  vi.doMock("@/lib/release-info", async (orig) => ({
    ...(await orig<typeof import("@/lib/release-info")>()),
    fetchLatestRelease: vi.fn(async () => ({ version: "0.0.0" })),
  }));
  // PairingError REAL (as rotas fazem instanceof); só as chamadas de rede são simuladas.
  vi.doMock("@/lib/license-pairing", async (orig) => ({
    ...(await orig<typeof import("@/lib/license-pairing")>()),
    pairPoll: mocks.pairPoll,
    pairCpf: mocks.pairCpf,
    pairStart: mocks.pairStart,
  }));
  return mocks;
}

function req(url: string, body: Record<string, unknown>): NextRequest {
  return new NextRequest(`http://localhost${url}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function abrirSessao(consoleSessionId = "35", codigo = "ENCHAT-TNY3YW") {
  const store = await import("@/lib/pairing-store");
  const { machineId, fingerprint } = store.getOrCreateMachineId(STACK, "enchat-app");
  return store.criarPareamento({
    stackId: STACK,
    machineId,
    fingerprint,
    consoleSessionId,
    codigoExibicao: codigo,
    expiresAt: Math.floor(Date.now() / 1000) + 900,
  });
}

async function erroNotFound() {
  const { PairingError } = await import("@/lib/license-pairing");
  return new PairingError("not_found", "Sessão de pareamento não encontrada ou expirada", 404, "sessao_nao_encontrada");
}

describe("pair/poll — sessão que o Console não conhece mais", () => {
  it("404 do Console: responde 'expirado' e a linha local vira 'falhou' (libera o slot)", async () => {
    const m = await montar();
    const row = await abrirSessao();
    m.pairPoll.mockRejectedValue(await erroNotFound());

    const { POST } = await import("./poll/route");
    const res = await POST(req("/api/license/pair/poll", { stackId: STACK, pairingId: row.id }));

    expect(await res.json()).toEqual({ status: "expirado" });
    const store = await import("@/lib/pairing-store");
    expect(store.buscarPareamento(row.id)?.status).toBe("falhou");
    expect(store.pareamentoAtivo(STACK)).toBeNull();
  });

  it("erro de rede no Console NÃO mata a sessão: continua 'aguardando' e 'aberto'", async () => {
    const m = await montar();
    const row = await abrirSessao();
    const { PairingError } = await import("@/lib/license-pairing");
    m.pairPoll.mockRejectedValue(new PairingError("network", "sem rota", undefined));

    const { POST } = await import("./poll/route");
    const res = await POST(req("/api/license/pair/poll", { stackId: STACK, pairingId: row.id }));

    expect(await res.json()).toEqual({ status: "aguardando" });
    const store = await import("@/lib/pairing-store");
    expect(store.buscarPareamento(row.id)?.status).toBe("aberto");
  });
});

describe("pair/cpf — sessão que o Console não conhece mais", () => {
  it("404 do Console: 410 sessao_expirada com frase traduzida (não 'nao_confirmou_cpf') e slot liberado", async () => {
    const m = await montar();
    const row = await abrirSessao();
    m.pairCpf.mockRejectedValue(await erroNotFound());

    const { POST } = await import("./cpf/route");
    const res = await POST(req("/api/license/pair/cpf", { stackId: STACK, pairingId: row.id, cpf: "12345678909" }));

    expect(res.status).toBe(410);
    const corpo = await res.json();
    expect(corpo.error).toBe("sessao_expirada");
    expect(corpo.message).toMatch(/expirou/i);
    const store = await import("@/lib/pairing-store");
    expect(store.buscarPareamento(row.id)?.status).toBe("falhou");
  });

  it("CPF que não confere continua sendo revelado como tal (não vira sessao_expirada)", async () => {
    const m = await montar();
    const row = await abrirSessao();
    const { PairingError } = await import("@/lib/license-pairing");
    m.pairCpf.mockRejectedValue(
      new PairingError("recusado", "cpf", 409, "cpf_nao_confere", { error: "cpf_nao_confere", tentativas_restantes: 1 })
    );

    const { POST } = await import("./cpf/route");
    const res = await POST(req("/api/license/pair/cpf", { stackId: STACK, pairingId: row.id, cpf: "12345678909" }));

    expect(res.status).toBe(409);
    expect(await res.json()).toMatchObject({ error: "cpf_nao_confere", tentativas_restantes: 1 });
    const store = await import("@/lib/pairing-store");
    expect(store.buscarPareamento(row.id)?.status).toBe("aberto");
  });
});

describe("pair/start — 'Gerar outro código'", () => {
  function sessaoNova(id: string, codigo: string) {
    return {
      sessionId: id,
      codigo,
      codigoExibicao: codigo,
      expiraEm: Math.floor(Date.now() / 1000) + 900,
    };
  }

  it("sem 'novo' retoma a sessão aberta (reabrir o modal não gasta tentativa do Console)", async () => {
    const m = await montar();
    const row = await abrirSessao("35", "ENCHAT-TNY3YW");

    const { POST } = await import("./start/route");
    const res = await POST(req("/api/license/pair/start", { stackId: STACK }));
    const corpo = await res.json();

    expect(corpo).toMatchObject({ pairingId: row.id, codigoExibicao: "ENCHAT-TNY3YW", retomado: true });
    expect(m.pairStart).not.toHaveBeenCalled();
  });

  it("com novo=true descarta a aberta e devolve um código DIFERENTE", async () => {
    const m = await montar();
    const antiga = await abrirSessao("35", "ENCHAT-TNY3YW");
    m.pairStart.mockResolvedValue(sessaoNova("36", "ENCHAT-NOVO01"));

    const { POST } = await import("./start/route");
    const res = await POST(req("/api/license/pair/start", { stackId: STACK, novo: true }));
    const corpo = await res.json();

    expect(m.pairStart).toHaveBeenCalledTimes(1);
    expect(corpo.retomado).toBeUndefined();
    expect(corpo.pairingId).not.toBe(antiga.id);
    expect(corpo.codigoExibicao).toBe("ENCHAT-NOVO01");
    const store = await import("@/lib/pairing-store");
    expect(store.buscarPareamento(antiga.id)?.status).toBe("falhou");
    expect(store.pareamentoAtivo(STACK)?.id).toBe(corpo.pairingId);
  });

  it("com novo=true NÃO descarta uma sessão 'confirmado' (guarda a chave emitida)", async () => {
    const m = await montar();
    const row = await abrirSessao("35", "ENCHAT-TNY3YW");
    const store = await import("@/lib/pairing-store");
    store.confirmarPareamento(row.id, "CHAVE-DE-TESTE-123", "gratis");

    const { POST } = await import("./start/route");
    const res = await POST(req("/api/license/pair/start", { stackId: STACK, novo: true }));
    const corpo = await res.json();

    expect(corpo).toMatchObject({ pairingId: row.id, status: "confirmado", retomado: true });
    expect(m.pairStart).not.toHaveBeenCalled();
    expect(store.buscarPareamento(row.id)?.status).toBe("confirmado");
  });
});
