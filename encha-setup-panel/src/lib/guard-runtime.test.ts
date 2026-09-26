import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DockerNode, DockerServiceFull, ServiceSpec } from "./portainer";

// garantirGuardaSwarm/garantirGuardaSwarmOuLanca (guard-runtime.ts, ciclo
// C6 do plano de segurança — a COLA que decide QUANDO criar/atualizar o
// serviço Swarm `encha-guard`). Portainer inteiramente mockado (padrão já
// usado em stack-update-release.test.ts): nenhuma chamada de rede real.

const GUARD = "encha-guard";
const PANEL_SERVICE = "encha-panel_panel";
const PANEL_IMAGE = "ghcr.io/enchaaluno/setup-panel:0.5.0@sha256:cafe1234cafe1234";
const HOST_NET_ID = "net-host-resolvido-123";

function no(id: string, addr: string): DockerNode {
  return { ID: id, Status: { Addr: addr } };
}

function fakePanelService(image = PANEL_IMAGE): DockerServiceFull {
  return {
    ID: "svc-panel-1",
    Version: { Index: 1 },
    Spec: { Name: PANEL_SERVICE, TaskTemplate: { ContainerSpec: { Image: image } } },
  } as DockerServiceFull;
}

// Serviço `encha-guard` "atual" cujo spec é EXATAMENTE o que
// `especificacaoDesejada` produziria para os mesmos argumentos (1 nó, sem
// PERMITIR/DESATIVADO) — usado no teste "idêntico -> nada a fazer". A rede
// vem como ID resolvido (nunca a string "host"), replicando o achado do
// auditor do C5.
function fakeGuardServiceIdentico(overrides: {
  image?: string;
  env?: string[];
  labels?: Record<string, string>;
  version?: number;
} = {}): DockerServiceFull {
  return {
    ID: "svc-guard-1",
    Version: { Index: overrides.version ?? 3 },
    Spec: {
      Name: GUARD,
      Labels: { "com.encha.role": "swarm-guard", "com.encha.guard.versao": "0.5.0", ...overrides.labels },
      TaskTemplate: {
        ContainerSpec: {
          Image: overrides.image ?? PANEL_IMAGE,
          Env: overrides.env ?? ["ENCHA_GUARD_PEERS="],
          CapabilityAdd: ["CAP_NET_ADMIN"],
          CapabilityDrop: ["ALL"],
          Healthcheck: { Test: ["NONE"] },
        },
        Networks: [{ Target: HOST_NET_ID }],
      },
    },
  } as DockerServiceFull;
}

type SetupOpts = {
  nodes?: DockerNode[];
  guardAtual?: DockerServiceFull | null;
  panelService?: DockerServiceFull | null;
  hostNetworkId?: string | null;
  createServiceImpl?: (token: string, endpointId: number, spec: ServiceSpec) => Promise<{ ID: string }>;
  updateServiceImpl?: (
    token: string,
    endpointId: number,
    serviceId: string,
    version: number,
    spec: ServiceSpec
  ) => Promise<void>;
};

async function setupMocks(opts: SetupOpts = {}) {
  const listNodesMock = vi.fn(async () => opts.nodes ?? [no("n1", "10.0.0.5")]);
  // "panelService" ausente do objeto de opções -> default (fakePanelService());
  // "panelService: null" EXPLÍCITO -> simula o serviço do painel não
  // encontrado (usa "in" em vez de "??" porque null é um valor válido e
  // diferente de "não informado" aqui).
  const panelServiceOverride = "panelService" in opts ? opts.panelService : fakePanelService();
  const getServiceExactMock = vi.fn(async (_t: string, _e: number, name: string) => {
    if (name === GUARD) return opts.guardAtual ?? null;
    if (name === (process.env.ENCHA_PANEL_SERVICE_NAME?.trim() || PANEL_SERVICE)) return panelServiceOverride;
    return null;
  });
  const getHostNetworkIdMock = vi.fn(async () => opts.hostNetworkId ?? HOST_NET_ID);
  const createServiceMock = vi.fn(
    opts.createServiceImpl ?? (async (_t: string, _e: number, _s: ServiceSpec) => ({ ID: "svc-guard-novo" }))
  );
  const updateServiceMock = vi.fn(
    opts.updateServiceImpl ??
      (async (_t: string, _e: number, _id: string, _v: number, _s: ServiceSpec) => undefined)
  );
  const withServiceTokenMock = vi.fn(async (fn: (t: string) => Promise<unknown>) => fn("tok"));
  const discoverContextMock = vi.fn(async () => ({ endpointId: 1, swarmId: "swarm-1" }));

  vi.doMock("./portainer", async (importOriginal) => {
    const actual = await importOriginal<typeof import("./portainer")>();
    return {
      ...actual,
      listNodes: listNodesMock,
      getServiceExact: getServiceExactMock,
      getHostNetworkId: getHostNetworkIdMock,
      createService: createServiceMock,
      updateService: updateServiceMock,
      withServiceToken: withServiceTokenMock,
      discoverContext: discoverContextMock,
    };
  });

  return {
    listNodesMock,
    getServiceExactMock,
    getHostNetworkIdMock,
    createServiceMock,
    updateServiceMock,
    withServiceTokenMock,
    discoverContextMock,
  };
}

beforeEach(() => {
  vi.resetModules();
});

afterEach(() => {
  vi.doUnmock("./portainer");
  vi.restoreAllMocks();
});

describe("garantirGuardaSwarm", () => {
  it("ausente + 1 nó -> createService chamado, com o spec correto (Name, imagem do painel, Mode.Global, rede host)", async () => {
    const { createServiceMock, updateServiceMock } = await setupMocks({ guardAtual: null });
    const { garantirGuardaSwarm } = await import("./guard-runtime");

    await garantirGuardaSwarm("tok", 1);

    expect(createServiceMock).toHaveBeenCalledTimes(1);
    expect(updateServiceMock).not.toHaveBeenCalled();
    const spec: ServiceSpec = createServiceMock.mock.calls[0][2];
    expect(spec.Name).toBe(GUARD);
    expect(spec.Mode).toEqual({ Global: {} });
    expect(spec.TaskTemplate.ContainerSpec.Image).toBe(PANEL_IMAGE);
    expect(spec.TaskTemplate.Networks).toEqual([{ Target: "host" }]);
  });

  it("ausente + 2 nós -> NADA chamado (nem create nem update), com aviso de log", async () => {
    const avisoMock = vi.spyOn(console, "warn").mockImplementation(() => {});
    const { createServiceMock, updateServiceMock, getServiceExactMock } = await setupMocks({
      guardAtual: null,
      nodes: [no("n1", "10.0.0.5"), no("n2", "10.0.0.6")],
    });
    const { garantirGuardaSwarm } = await import("./guard-runtime");

    await garantirGuardaSwarm("tok", 1);

    expect(createServiceMock).not.toHaveBeenCalled();
    expect(updateServiceMock).not.toHaveBeenCalled();
    expect(getServiceExactMock).not.toHaveBeenCalled(); // nem chega a buscar o serviço
    expect(avisoMock).toHaveBeenCalledWith(expect.stringContaining("2 nós"));
  });

  it("existente com spec idêntico ao desejado -> nada chamado", async () => {
    const { createServiceMock, updateServiceMock } = await setupMocks({
      guardAtual: fakeGuardServiceIdentico(),
    });
    const { garantirGuardaSwarm } = await import("./guard-runtime");

    await garantirGuardaSwarm("tok", 1);

    expect(createServiceMock).not.toHaveBeenCalled();
    expect(updateServiceMock).not.toHaveBeenCalled();
  });

  it("imagem mudou -> updateService chamado, preservando ENCHA_GUARD_PERMITIR já presente no Env do atual", async () => {
    const { createServiceMock, updateServiceMock } = await setupMocks({
      guardAtual: fakeGuardServiceIdentico({
        image: "ghcr.io/enchaaluno/setup-panel:0.4.9@sha256:imagemvelha",
        env: ["ENCHA_GUARD_PEERS=", "ENCHA_GUARD_PERMITIR=203.0.113.9"],
      }),
    });
    const { garantirGuardaSwarm } = await import("./guard-runtime");

    await garantirGuardaSwarm("tok", 1);

    expect(createServiceMock).not.toHaveBeenCalled();
    expect(updateServiceMock).toHaveBeenCalledTimes(1);
    const [, , serviceId, version, spec] = updateServiceMock.mock.calls[0] as [
      string,
      number,
      string,
      number,
      ServiceSpec,
    ];
    expect(serviceId).toBe("svc-guard-1");
    expect(version).toBe(3);
    expect(spec.TaskTemplate.ContainerSpec.Image).toBe(PANEL_IMAGE);
    expect(spec.TaskTemplate.ContainerSpec.Env).toContain("ENCHA_GUARD_PERMITIR=203.0.113.9");
  });

  it("409 do createService (criado em paralelo) é tratado sem lançar", async () => {
    const avisoMock = vi.spyOn(console, "warn").mockImplementation(() => {});
    const { PortainerError } = await import("./portainer");
    const { createServiceMock } = await setupMocks({
      guardAtual: null,
      createServiceImpl: async () => {
        throw new PortainerError(409, "conflict");
      },
    });
    const { garantirGuardaSwarm } = await import("./guard-runtime");

    await expect(garantirGuardaSwarm("tok", 1)).resolves.toBeUndefined();
    expect(createServiceMock).toHaveBeenCalledTimes(1);
    expect(avisoMock).toHaveBeenCalledWith(expect.stringContaining("409"));
  });

  // Auditoria C6: no update, 409 NÃO é "corrida de Version.Index" (essa o
  // Docker devolve como 500 "update out of sequence"); é conflito real. Em
  // qualquer caso o update NÃO foi aplicado — nunca pode ser tratado como
  // sucesso/aviso de concorrência: sobe como erro (logado por
  // garantirGuardaSwarm) e a próxima janela relê e tenta de novo.
  it("409 do updateService NÃO é engolido: sobe como erro e é logado como falha (a próxima janela relê)", async () => {
    const erroMock = vi.spyOn(console, "error").mockImplementation(() => {});
    const avisoMock = vi.spyOn(console, "warn").mockImplementation(() => {});
    const logMock = vi.spyOn(console, "log").mockImplementation(() => {});
    const { PortainerError } = await import("./portainer");
    const { updateServiceMock } = await setupMocks({
      guardAtual: fakeGuardServiceIdentico({ image: "outra-imagem@sha256:x" }),
      updateServiceImpl: async () => {
        throw new PortainerError(409, "conflict");
      },
    });
    const { garantirGuardaSwarm, garantirGuardaSwarmOuLanca } = await import("./guard-runtime");

    await expect(garantirGuardaSwarmOuLanca("tok", 1)).rejects.toMatchObject({ status: 409 });
    await expect(garantirGuardaSwarm("tok", 1)).resolves.toBeUndefined();
    expect(updateServiceMock).toHaveBeenCalledTimes(2);
    expect(erroMock).toHaveBeenCalled();
    expect(avisoMock).not.toHaveBeenCalled();
    expect(logMock).not.toHaveBeenCalledWith(expect.stringContaining("atualizado"));
  });

  it("500 'update out of sequence' (a corrida real de Version.Index no Docker) também sobe como erro", async () => {
    const erroMock = vi.spyOn(console, "error").mockImplementation(() => {});
    const { PortainerError } = await import("./portainer");
    await setupMocks({
      guardAtual: fakeGuardServiceIdentico({ image: "outra-imagem@sha256:x" }),
      updateServiceImpl: async () => {
        throw new PortainerError(500, "rpc error: code = Unknown desc = update out of sequence");
      },
    });
    const { garantirGuardaSwarm, garantirGuardaSwarmOuLanca } = await import("./guard-runtime");

    await expect(garantirGuardaSwarmOuLanca("tok", 1)).rejects.toMatchObject({ status: 500 });
    await expect(garantirGuardaSwarm("tok", 1)).resolves.toBeUndefined();
    expect(erroMock).toHaveBeenCalled();
  });

  it("erro que NÃO é 409 no createService também nunca escapa de garantirGuardaSwarm (é engolido e logado)", async () => {
    const erroMock = vi.spyOn(console, "error").mockImplementation(() => {});
    await setupMocks({
      guardAtual: null,
      createServiceImpl: async () => {
        throw new Error("falha de rede qualquer");
      },
    });
    const { garantirGuardaSwarm } = await import("./guard-runtime");

    await expect(garantirGuardaSwarm("tok", 1)).resolves.toBeUndefined();
    expect(erroMock).toHaveBeenCalled();
  });

  it("label com.encha.guard.gerenciado=false presente -> NUNCA chama create/update", async () => {
    const { createServiceMock, updateServiceMock } = await setupMocks({
      guardAtual: fakeGuardServiceIdentico({
        image: "imagem-bem-diferente@sha256:x", // garante que, se checado, geraria update
        labels: { "com.encha.guard.gerenciado": "false" },
      }),
    });
    const { garantirGuardaSwarm } = await import("./guard-runtime");

    await garantirGuardaSwarm("tok", 1);

    expect(createServiceMock).not.toHaveBeenCalled();
    expect(updateServiceMock).not.toHaveBeenCalled();
  });

  it("serviço 'encha-guard' com label com.encha.role diferente (nome parecido/conflito) -> NUNCA toca", async () => {
    const erroMock = vi.spyOn(console, "error").mockImplementation(() => {});
    const { createServiceMock, updateServiceMock } = await setupMocks({
      guardAtual: fakeGuardServiceIdentico({ labels: { "com.encha.role": "outra-coisa" } }),
    });
    const { garantirGuardaSwarm } = await import("./guard-runtime");

    await garantirGuardaSwarm("tok", 1);

    expect(createServiceMock).not.toHaveBeenCalled();
    expect(updateServiceMock).not.toHaveBeenCalled();
    expect(erroMock).toHaveBeenCalled();
  });

  // Prova que a busca usa getServiceExact (casamento EXATO), não
  // getServiceByName (que casaria por prefixo) — o mock simula a API real
  // devolvendo null quando só existe "encha-guard-x" e se pede "encha-guard"
  // exato, e a consequência observável é: trata como AUSENTE e cria.
  it("só existe um serviço de nome parecido ('encha-guard-x') -> tratado como ausente, cria", async () => {
    const { createServiceMock, getServiceExactMock } = await setupMocks({ guardAtual: null });
    const { garantirGuardaSwarm } = await import("./guard-runtime");

    await garantirGuardaSwarm("tok", 1);

    // getServiceExact foi chamado com o nome EXATO "encha-guard" (nunca um
    // prefixo/variação) — é essa chamada exata que devolveria null mesmo
    // com "encha-guard-x" existindo, ao contrário de getServiceByName.
    expect(getServiceExactMock).toHaveBeenCalledWith("tok", 1, GUARD);
    expect(createServiceMock).toHaveBeenCalledTimes(1);
  });

  it("painel sem imagem resolvível (serviço do painel ausente) -> não cria nem atualiza, loga erro", async () => {
    const erroMock = vi.spyOn(console, "error").mockImplementation(() => {});
    const { createServiceMock, updateServiceMock } = await setupMocks({
      guardAtual: null,
      panelService: null,
    });
    const { garantirGuardaSwarm } = await import("./guard-runtime");

    await garantirGuardaSwarm("tok", 1);

    expect(createServiceMock).not.toHaveBeenCalled();
    expect(updateServiceMock).not.toHaveBeenCalled();
    expect(erroMock).toHaveBeenCalled();
  });

  it("respeita ENCHA_PANEL_SERVICE_NAME quando definida, em vez do fallback 'encha-panel_panel'", async () => {
    process.env.ENCHA_PANEL_SERVICE_NAME = "outra-stack_painel";
    try {
      const getServiceExactMock = vi.fn(async (_t: string, _e: number, name: string) => {
        if (name === GUARD) return null;
        if (name === "outra-stack_painel") return fakePanelService();
        return null;
      });
      vi.doMock("./portainer", async (importOriginal) => {
        const actual = await importOriginal<typeof import("./portainer")>();
        return {
          ...actual,
          listNodes: vi.fn(async () => [no("n1", "10.0.0.5")]),
          getServiceExact: getServiceExactMock,
          getHostNetworkId: vi.fn(async () => HOST_NET_ID),
          createService: vi.fn(async () => ({ ID: "x" })),
          updateService: vi.fn(async () => undefined),
        };
      });
      const { garantirGuardaSwarm } = await import("./guard-runtime");

      await garantirGuardaSwarm("tok", 1);

      expect(getServiceExactMock).toHaveBeenCalledWith("tok", 1, "outra-stack_painel");
    } finally {
      delete process.env.ENCHA_PANEL_SERVICE_NAME;
    }
  });
});

describe("tentarGarantirGuardaSwarm", () => {
  it("obtém token de serviço e endpointId, e chama garantirGuardaSwarm", async () => {
    // guardAtual idêntico ao desejado -> garantirGuardaSwarm não chama
    // create/update; o que este teste prova é a fiação de token/endpointId.
    const { withServiceTokenMock, discoverContextMock } = await setupMocks({
      guardAtual: fakeGuardServiceIdentico(),
    });
    const { tentarGarantirGuardaSwarm } = await import("./guard-runtime");

    await tentarGarantirGuardaSwarm();

    expect(withServiceTokenMock).toHaveBeenCalledTimes(1);
    expect(discoverContextMock).toHaveBeenCalledWith("tok");
  });

  it("erro em withServiceToken nunca escapa (engolido e logado)", async () => {
    const erroMock = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.doMock("./portainer", async (importOriginal) => {
      const actual = await importOriginal<typeof import("./portainer")>();
      return {
        ...actual,
        withServiceToken: vi.fn(async () => {
          throw new Error("sem credencial");
        }),
      };
    });
    const { tentarGarantirGuardaSwarm } = await import("./guard-runtime");

    await expect(tentarGarantirGuardaSwarm()).resolves.toBeUndefined();
    expect(erroMock).toHaveBeenCalled();
  });
});

describe("inicializarGarantiaGuardaSwarm (agendamento)", () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.doUnmock("./auth/local-admin");
  });

  // Não usamos vi.spyOn no próprio módulo pra "interceptar"
  // tentarGarantirGuardaSwarm chamado de dentro de inicializarGarantiaGuardaSwarm
  // (mesmo módulo ES — o binding interno não passa pelo objeto de exports
  // que o spy substitui, então o spy nunca veria a chamada). Em vez disso,
  // usamos o mock de withServiceToken (setupMocks, já usado nos testes de
  // garantirGuardaSwarm acima) como sinal observável de que uma tentativa
  // de verdade rodou.
  it("sem credenciais de serviço -> nada é agendado (nenhuma tentativa roda, mesmo passando 6h)", async () => {
    vi.useFakeTimers();
    const { withServiceTokenMock } = await setupMocks({ guardAtual: fakeGuardServiceIdentico() });
    vi.doMock("./auth/local-admin", async (importOriginal) => {
      const actual = await importOriginal<typeof import("./auth/local-admin")>();
      return { ...actual, hasServiceCredentials: () => false };
    });
    const { inicializarGarantiaGuardaSwarm } = await import("./guard-runtime");

    inicializarGarantiaGuardaSwarm();
    await vi.advanceTimersByTimeAsync(6 * 60 * 60_000 + 60_000);

    expect(withServiceTokenMock).not.toHaveBeenCalled();
  });

  it("com credenciais de serviço -> roda uma tentativa ~20s depois, e de novo a cada ~6h", async () => {
    vi.useFakeTimers();
    const { withServiceTokenMock } = await setupMocks({ guardAtual: fakeGuardServiceIdentico() });
    vi.doMock("./auth/local-admin", async (importOriginal) => {
      const actual = await importOriginal<typeof import("./auth/local-admin")>();
      return { ...actual, hasServiceCredentials: () => true };
    });
    const { inicializarGarantiaGuardaSwarm } = await import("./guard-runtime");

    inicializarGarantiaGuardaSwarm();

    await vi.advanceTimersByTimeAsync(19_000);
    expect(withServiceTokenMock).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(2_000); // passa dos 20s
    expect(withServiceTokenMock).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(6 * 60 * 60_000);
    expect(withServiceTokenMock).toHaveBeenCalledTimes(2);

    await vi.advanceTimersByTimeAsync(6 * 60 * 60_000);
    expect(withServiceTokenMock).toHaveBeenCalledTimes(3);
  });

  it("os dois timers são criados com .unref() disponível chamado (não impedem o processo de sair)", async () => {
    vi.doMock("./auth/local-admin", async (importOriginal) => {
      const actual = await importOriginal<typeof import("./auth/local-admin")>();
      return { ...actual, hasServiceCredentials: () => true };
    });
    const setTimeoutSpy = vi.spyOn(global, "setTimeout");
    const setIntervalSpy = vi.spyOn(global, "setInterval");
    const { inicializarGarantiaGuardaSwarm } = await import("./guard-runtime");

    inicializarGarantiaGuardaSwarm();

    expect(setTimeoutSpy).toHaveBeenCalledTimes(1);
    expect(setIntervalSpy).toHaveBeenCalledTimes(1);
    const timeoutHandle = setTimeoutSpy.mock.results[0].value as NodeJS.Timeout;
    const intervalHandle = setIntervalSpy.mock.results[0].value as NodeJS.Timeout;
    expect(typeof timeoutHandle.unref).toBe("function");
    expect(typeof intervalHandle.unref).toBe("function");
    // limpa de verdade (nunca deixa o timer real de 6h correndo pós-teste).
    clearTimeout(timeoutHandle);
    clearInterval(intervalHandle);
  });
});
