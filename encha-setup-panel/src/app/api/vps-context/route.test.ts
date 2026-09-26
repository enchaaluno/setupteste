import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// GET /api/vps-context (C8, plano de segurança / A2): o campo
// protecaoSshInstalada precisa refletir o marcador do C10, nos dois
// cenários, sem quebrar autenticação nem os campos já existentes de
// getVpsContext(). @/lib/vps-context inteiro é mockado — o leitor de fs já
// tem cobertura própria em vps-context.test.ts.

beforeEach(() => {
  vi.resetModules();
});

afterEach(() => {
  vi.doUnmock("@/lib/session");
  vi.doUnmock("@/lib/locale");
  vi.doUnmock("@/lib/vps-context");
});

function mockComuns(opts: { logado: boolean; protegida: boolean }) {
  vi.doMock("@/lib/session", () => ({
    readSession: vi.fn(async () => (opts.logado ? { user: "tester" } : null)),
  }));
  vi.doMock("@/lib/locale", () => ({ resolveLocale: vi.fn(async () => "pt") }));
  vi.doMock("@/lib/vps-context", () => ({
    getVpsContext: vi.fn(() => ({
      nome_servidor: "srv-teste",
      nome_rede_interna: "net-teste",
      email_ssl: "teste@x.com",
      url_portainer: "portainer.teste.com",
    })),
    protecaoSshInstalada: vi.fn(() => opts.protegida),
  }));
}

describe("GET /api/vps-context", () => {
  it("sem sessão -> 401, não chama getVpsContext/protecaoSshInstalada", async () => {
    mockComuns({ logado: false, protegida: false });
    const { getVpsContext, protecaoSshInstalada } = await import("@/lib/vps-context");
    const { GET } = await import("./route");
    const res = await GET();
    expect(res.status).toBe(401);
    expect(getVpsContext).not.toHaveBeenCalled();
    expect(protecaoSshInstalada).not.toHaveBeenCalled();
  });

  it("marcador ausente -> protecaoSshInstalada:false no payload, resto de getVpsContext intacto", async () => {
    mockComuns({ logado: true, protegida: false });
    const { GET } = await import("./route");
    const res = await GET();
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toEqual({
      nome_servidor: "srv-teste",
      nome_rede_interna: "net-teste",
      email_ssl: "teste@x.com",
      url_portainer: "portainer.teste.com",
      protecaoSshInstalada: false,
    });
  });

  it("marcador presente -> protecaoSshInstalada:true no payload", async () => {
    mockComuns({ logado: true, protegida: true });
    const { GET } = await import("./route");
    const res = await GET();
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.protecaoSshInstalada).toBe(true);
  });
});
