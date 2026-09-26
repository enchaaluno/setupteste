import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// C3 (M3): authenticateService() (privada) resolve PORTAINER_PASSWORD via
// lerSegredo em vez da lógica ad-hoc que só olhava PORTAINER_PASSWORD_FILE
// (sem cair para a env quando os dois estavam definidos). Exercitado através
// de getServiceToken(), a única porta de entrada pública — mocka o `fetch`
// do undici para nunca bater numa rede real e captura o corpo enviado a
// POST /api/auth pra confirmar QUAL senha foi usada.

const ENV_KEYS = ["PORTAINER_USER", "PORTAINER_PASSWORD", "PORTAINER_PASSWORD_FILE"] as const;

describe("authenticateService / getServiceToken (credencial de serviço do Portainer)", () => {
  let dir: string;

  beforeEach(() => {
    vi.resetModules();
    dir = mkdtempSync(join(tmpdir(), "portainer-service-cred-"));
  });

  afterEach(() => {
    for (const k of ENV_KEYS) delete process.env[k];
    rmSync(dir, { recursive: true, force: true });
    vi.doUnmock("undici");
  });

  function arquivoCom(conteudo: string): string {
    const caminho = join(dir, "senha");
    writeFileSync(caminho, conteudo);
    return caminho;
  }

  function mockAuthFetch() {
    const fetchMock = vi.fn(async (_url: string, init: { body?: string }) => {
      return new Response(JSON.stringify({ jwt: "cabecalho.corpo.assinatura" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });
    return fetchMock;
  }

  async function carregarPortainerComFetch(fetchMock: ReturnType<typeof mockAuthFetch>) {
    vi.doMock("undici", async (importOriginal) => {
      const actual = await importOriginal<typeof import("undici")>();
      return { ...actual, fetch: fetchMock };
    });
    return import("./portainer");
  }

  // Não é o RED do 503: a lógica antiga de authenticateService já lia o
  // _FILE sozinho (o 503 vinha de hasServiceCredentials, coberto em
  // auth/local-admin.test.ts). Este caso fixa que a troca pelo lerSegredo
  // não perdeu o suporte que já existia. Os que falham contra o código
  // anterior são "env direta vence" (o antigo dava prioridade ao _FILE) e
  // "arquivo inexistente" (o antigo vazava o ENOENT cru em vez do 503).
  it("PORTAINER_PASSWORD_FILE sozinho (sem env direta) autentica com sucesso", async () => {
    process.env.PORTAINER_USER = "svc";
    process.env.PORTAINER_PASSWORD_FILE = arquivoCom("senha-do-arquivo\n");

    const fetchMock = mockAuthFetch();
    const { getServiceToken } = await carregarPortainerComFetch(fetchMock);

    const jwt = await getServiceToken();
    expect(jwt).toBe("cabecalho.corpo.assinatura");

    const [, init] = fetchMock.mock.calls[0];
    expect(JSON.parse((init as { body: string }).body)).toEqual({
      username: "svc",
      password: "senha-do-arquivo",
    });
  });

  it("env direta vence sobre _FILE mesmo com os dois definidos", async () => {
    process.env.PORTAINER_USER = "svc";
    process.env.PORTAINER_PASSWORD = "senha-da-env";
    process.env.PORTAINER_PASSWORD_FILE = arquivoCom("senha-do-arquivo");

    const fetchMock = mockAuthFetch();
    const { getServiceToken } = await carregarPortainerComFetch(fetchMock);

    await getServiceToken();
    const [, init] = fetchMock.mock.calls[0];
    expect(JSON.parse((init as { body: string }).body).password).toBe("senha-da-env");
  });

  it("sem env e com _FILE apontando para arquivo inexistente: 503 claro, nunca lança erro cru de fs", async () => {
    process.env.PORTAINER_USER = "svc";
    process.env.PORTAINER_PASSWORD_FILE = join(dir, "nao-existe");

    const fetchMock = mockAuthFetch();
    const { getServiceToken } = await carregarPortainerComFetch(fetchMock);

    await expect(getServiceToken()).rejects.toMatchObject({ status: 503 });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("sem PORTAINER_USER: 503, mesmo com senha resolvível", async () => {
    process.env.PORTAINER_PASSWORD = "senha-da-env";

    const fetchMock = mockAuthFetch();
    const { getServiceToken } = await carregarPortainerComFetch(fetchMock);

    await expect(getServiceToken()).rejects.toMatchObject({ status: 503 });
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
