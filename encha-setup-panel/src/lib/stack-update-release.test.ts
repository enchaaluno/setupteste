import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { z } from "zod";
import type { StackDefinition } from "./stacks/types";
import type { DockerServiceFull } from "./portainer";

// applyReleaseUpdate (stack-update-release.ts, Ciclo 29) — testado com uma
// stack SINTÉTICA e mocks de discoverContext/getServiceByName/
// updateServiceImage/resolveRegistryAndPullImages/getOrCreateMachineId/
// fetchLatestReleaseCached. Cobre as 6 mutações do contrato (M1, M2, M5
// aqui; M3 em registry-pull.test.ts, M4 em installer.test.ts, M6 na rota).

const FAKE_STACK_ID = "fake-update-stack";

function fakeDef(overrides: Partial<StackDefinition> = {}): StackDefinition {
  return {
    id: FAKE_STACK_ID,
    name: "Fake Update Stack",
    description: "Stack sintética só para testar applyReleaseUpdate.",
    category: "analytics",
    icon: "bar-chart-3",
    dependsOn: [],
    optionNumber: 996,
    appHostname: "fake-update-app",
    fields: [],
    schema: z.object({}),
    generateYaml: () => 'version: "3.7"\nservices: {}\n',
    release: { baseUrl: "https://console.exemplo.com", app: "fake", edicao: "full", canal: "beta" },
    registryAuth: {
      registryHost: "ghcr.io",
      registryName: "GHCR Fake",
      exchangeUrl: "https://console.exemplo.com/api/v1/fake/registry-auth",
      licenseField: "chave_licenca",
      images: () => [],
      licenseEnvVar: "FAKE_CHAVE",
      licenseEnvService: "app",
    },
    updateViaRelease: (release) => [
      { service: "app", image: `ghcr.io/x/fake:${release.imageTag}` },
      { service: "updater", image: `ghcr.io/x/fake-updater:${release.imageTag}` },
    ],
    ...overrides,
  };
}

function fakeService(id: string, image: string, env: string[] = []): DockerServiceFull {
  return {
    ID: id,
    Version: { Index: 1 },
    Spec: {
      Name: id,
      TaskTemplate: { ContainerSpec: { Image: image, Env: env } },
    },
  } as DockerServiceFull;
}

function fakeRelease(imageTag = "1.1.0") {
  return { version: imageTag, imageRepo: "ghcr.io/x/fake", imageTag, obrigatoria: false };
}

type SetupOpts = {
  appImage?: string;
  updaterImage?: string;
  appEnv?: string[];
  releaseTag?: string;
  def?: StackDefinition;
};

async function setupMocks(opts: SetupOpts = {}) {
  const ordem: string[] = [];
  const def = opts.def ?? fakeDef();
  const stackName = FAKE_STACK_ID.replace(/-/g, "_");

  const state = {
    app: fakeService(`${stackName}_app`, opts.appImage ?? "ghcr.io/x/fake:1.0.0", opts.appEnv ?? ["FAKE_CHAVE=chave-do-env"]),
    updater: fakeService(`${stackName}_updater`, opts.updaterImage ?? "ghcr.io/x/fake-updater:1.0.0"),
  };

  const discoverContextMock = vi.fn(async () => ({ endpointId: 1, swarmId: "swarm-1" }));
  const getServiceByNameMock = vi.fn(async (_token: string, _endpointId: number, name: string) => {
    if (name === `${stackName}_app`) return state.app;
    if (name === `${stackName}_updater`) return state.updater;
    return null;
  });
  const updateServiceImageMock = vi.fn(async (_token: string, _endpointId: number, svc: DockerServiceFull, newImage: string) => {
    ordem.push("update");
    if (svc.ID === state.app.ID) state.app = fakeService(state.app.ID, newImage, opts.appEnv ?? ["FAKE_CHAVE=chave-do-env"]);
    else if (svc.ID === state.updater.ID) state.updater = fakeService(state.updater.ID, newImage);
  });
  const resolveRegistryAndPullImagesMock = vi.fn(async () => {
    ordem.push("pull");
  });
  const getOrCreateMachineIdMock = vi.fn(() => ({ machineId: "mid-1", fingerprint: "fp-1", legacy: false }));
  const fetchLatestReleaseCachedMock = vi.fn(async () => fakeRelease(opts.releaseTag ?? "1.1.0"));
  const logAuditMock = vi.fn();

  vi.doMock("./portainer", async (importOriginal) => {
    const actual = await importOriginal<typeof import("./portainer")>();
    return {
      ...actual,
      discoverContext: discoverContextMock,
      getServiceByName: getServiceByNameMock,
      updateServiceImage: updateServiceImageMock,
    };
  });
  vi.doMock("./release-info", async (importOriginal) => {
    const actual = await importOriginal<typeof import("./release-info")>();
    return { ...actual, fetchLatestReleaseCached: fetchLatestReleaseCachedMock };
  });
  vi.doMock("./registry-pull", () => ({ resolveRegistryAndPullImages: resolveRegistryAndPullImagesMock }));
  vi.doMock("./pairing-store", () => ({ getOrCreateMachineId: getOrCreateMachineIdMock }));
  vi.doMock("./audit", () => ({ logAudit: logAuditMock }));

  return {
    ordem,
    def,
    state,
    discoverContextMock,
    getServiceByNameMock,
    updateServiceImageMock,
    resolveRegistryAndPullImagesMock,
    getOrCreateMachineIdMock,
    fetchLatestReleaseCachedMock,
    logAuditMock,
  };
}

beforeEach(() => {
  vi.resetModules();
});

afterEach(() => {
  vi.doUnmock("./portainer");
  vi.doUnmock("./release-info");
  vi.doUnmock("./registry-pull");
  vi.doUnmock("./pairing-store");
  vi.doUnmock("./audit");
});

describe("applyReleaseUpdate", () => {
  it("caminho feliz: pré-puxa (autenticado) e SÓ DEPOIS troca a imagem dos dois serviços", async () => {
    const { def, resolveRegistryAndPullImagesMock, updateServiceImageMock, logAuditMock } = await setupMocks();
    const { applyReleaseUpdate } = await import("./stack-update-release");

    const result = await applyReleaseUpdate({ token: "tok", stackId: FAKE_STACK_ID, def, user: "tester", ip: "127.0.0.1" });

    expect(result.atualizados).toHaveLength(2);
    expect(updateServiceImageMock).toHaveBeenCalledTimes(2);
    expect(resolveRegistryAndPullImagesMock).toHaveBeenCalledTimes(1);
    expect(resolveRegistryAndPullImagesMock).toHaveBeenCalledWith(
      expect.objectContaining({
        chave: "chave-do-env",
        fingerprint: "fp-1",
        images: ["ghcr.io/x/fake:1.1.0", "ghcr.io/x/fake-updater:1.1.0"],
      })
    );
    expect(logAuditMock).toHaveBeenCalledTimes(1);
    expect(logAuditMock.mock.calls[0][0].action).toBe("stack.update");
    expect(logAuditMock.mock.calls[0][0].result).toBe("ok");
    // 20s: é o PRIMEIRO teste do arquivo e paga o import a frio do grafo de
    // módulos (portainer, registry-pull...). Com a suíte inteira rodando em
    // paralelo o default de 5s estourava (5019-5031ms) sem nenhum defeito
    // de lógica — isolado ele leva ~1s.
  }, 20_000);

  // M1 — A MAIS IMPORTANTE: pré-pull autenticado tem que acontecer ANTES de
  // qualquer updateServiceImage. Sem isso, o Swarm tentaria puxar a imagem
  // privada sem credencial e a task ficaria presa em `pending` — o mesmo
  // defeito que este ciclo existe pra fechar.
  it("M1: resolveRegistryAndPullImages roda ANTES de updateServiceImage", async () => {
    const { def, ordem } = await setupMocks();
    const { applyReleaseUpdate } = await import("./stack-update-release");

    await applyReleaseUpdate({ token: "tok", stackId: FAKE_STACK_ID, def, user: "tester", ip: "127.0.0.1" });

    expect(ordem[0]).toBe("pull");
    expect(ordem.slice(1)).toEqual(["update", "update"]);
  });

  // M2 — a chave TEM que vir do Env do serviço rodando, nunca de um campo
  // persistido (que nem existe neste fluxo). Serviço fake com
  // FAKE_CHAVE=X no Env — resolveRegistryAndPullImages tem que ser chamado
  // com chave:"X" exatamente.
  it("M2: a chave é lida do Env do serviço rodando (FAKE_CHAVE=X), não de um campo persistido", async () => {
    const { def, resolveRegistryAndPullImagesMock } = await setupMocks({ appEnv: ["OUTRA_VAR=y", "FAKE_CHAVE=X"] });
    const { applyReleaseUpdate } = await import("./stack-update-release");

    await applyReleaseUpdate({ token: "tok", stackId: FAKE_STACK_ID, def, user: "tester", ip: "127.0.0.1" });

    expect(resolveRegistryAndPullImagesMock).toHaveBeenCalledWith(expect.objectContaining({ chave: "X" }));
  });

  it("Env sem a variável de licença lança erro claro, sem chamar pull/update", async () => {
    const { def, resolveRegistryAndPullImagesMock, updateServiceImageMock } = await setupMocks({ appEnv: ["OUTRA_VAR=y"] });
    const { applyReleaseUpdate } = await import("./stack-update-release");

    await expect(
      applyReleaseUpdate({ token: "tok", stackId: FAKE_STACK_ID, def, user: "tester", ip: "127.0.0.1" })
    ).rejects.toThrow(/FAKE_CHAVE.*não encontrada/);

    expect(resolveRegistryAndPullImagesMock).not.toHaveBeenCalled();
    expect(updateServiceImageMock).not.toHaveBeenCalled();
  });

  it("idempotente: já na versão-alvo em ambos os serviços -> {atualizados:[]}, zero pull/update/audit", async () => {
    const { def, resolveRegistryAndPullImagesMock, updateServiceImageMock, logAuditMock } = await setupMocks({
      appImage: "ghcr.io/x/fake:1.1.0",
      updaterImage: "ghcr.io/x/fake-updater:1.1.0",
      releaseTag: "1.1.0",
    });
    const { applyReleaseUpdate } = await import("./stack-update-release");

    const result = await applyReleaseUpdate({ token: "tok", stackId: FAKE_STACK_ID, def, user: "tester", ip: "127.0.0.1" });

    expect(result.atualizados).toEqual([]);
    expect(resolveRegistryAndPullImagesMock).not.toHaveBeenCalled();
    expect(updateServiceImageMock).not.toHaveBeenCalled();
    expect(logAuditMock).not.toHaveBeenCalled();
  });

  // M5 — idempotência: chamar applyReleaseUpdate DUAS VEZES seguidas com o
  // mesmo fake (o mock de updateServiceImage atualiza o estado, simulando o
  // Swarm de verdade) — a segunda chamada tem que resultar em ZERO chamadas
  // de pull/update.
  it("M5: a 2ª chamada seguida (já atualizado pela 1ª) não repete pull/update", async () => {
    const mocks = await setupMocks();
    const { def, resolveRegistryAndPullImagesMock, updateServiceImageMock } = mocks;
    const { applyReleaseUpdate } = await import("./stack-update-release");

    const primeira = await applyReleaseUpdate({ token: "tok", stackId: FAKE_STACK_ID, def, user: "tester", ip: "127.0.0.1" });
    expect(primeira.atualizados).toHaveLength(2);
    expect(resolveRegistryAndPullImagesMock).toHaveBeenCalledTimes(1);
    expect(updateServiceImageMock).toHaveBeenCalledTimes(2);

    const segunda = await applyReleaseUpdate({ token: "tok", stackId: FAKE_STACK_ID, def, user: "tester", ip: "127.0.0.1" });
    expect(segunda.atualizados).toEqual([]);
    expect(resolveRegistryAndPullImagesMock).toHaveBeenCalledTimes(1); // continua 1, não subiu
    expect(updateServiceImageMock).toHaveBeenCalledTimes(2); // continua 2, não subiu
  });

  it("serviço esperado ausente no Swarm lança erro claro", async () => {
    const { def, getServiceByNameMock } = await setupMocks();
    getServiceByNameMock.mockImplementation(async () => null);
    const { applyReleaseUpdate } = await import("./stack-update-release");

    await expect(
      applyReleaseUpdate({ token: "tok", stackId: FAKE_STACK_ID, def, user: "tester", ip: "127.0.0.1" })
    ).rejects.toThrow(/não está rodando/);
  });

  it("wiring ausente (sem updateViaRelease) lança e loga stack.update.fail", async () => {
    const { logAuditMock } = await setupMocks();
    const semUpdateViaRelease = fakeDef({ updateViaRelease: undefined });
    const { applyReleaseUpdate } = await import("./stack-update-release");

    await expect(
      applyReleaseUpdate({ token: "tok", stackId: FAKE_STACK_ID, def: semUpdateViaRelease, user: "tester", ip: "127.0.0.1" })
    ).rejects.toThrow(/bug de wiring/);

    expect(logAuditMock).toHaveBeenCalledTimes(1);
    expect(logAuditMock.mock.calls[0][0].action).toBe("stack.update.fail");
  });
});
