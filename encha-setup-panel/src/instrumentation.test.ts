import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// register() (ciclo C6 do plano de segurança) tem que ficar FINO: só decide
// se está no runtime nodejs e, se sim, delega tudo pra
// inicializarGarantiaGuardaSwarm (src/lib/guard-runtime.ts, testada
// separadamente em guard-runtime.test.ts). Aqui testamos só essa fiação —
// nenhum mock de Portainer necessário porque inicializarGarantiaGuardaSwarm
// em si está mockada.

const NEXT_RUNTIME_ORIGINAL = process.env.NEXT_RUNTIME;

beforeEach(() => {
  vi.resetModules();
});

afterEach(() => {
  if (NEXT_RUNTIME_ORIGINAL === undefined) delete process.env.NEXT_RUNTIME;
  else process.env.NEXT_RUNTIME = NEXT_RUNTIME_ORIGINAL;
  vi.doUnmock("@/lib/guard-runtime");
});

describe("register (instrumentation.ts)", () => {
  it("NEXT_RUNTIME=nodejs -> chama inicializarGarantiaGuardaSwarm", async () => {
    process.env.NEXT_RUNTIME = "nodejs";
    const inicializarMock = vi.fn();
    vi.doMock("@/lib/guard-runtime", () => ({ inicializarGarantiaGuardaSwarm: inicializarMock }));

    const { register } = await import("./instrumentation");
    await register();

    expect(inicializarMock).toHaveBeenCalledTimes(1);
  });

  it("NEXT_RUNTIME=edge -> NÃO chama (nem importa) inicializarGarantiaGuardaSwarm", async () => {
    process.env.NEXT_RUNTIME = "edge";
    const inicializarMock = vi.fn();
    vi.doMock("@/lib/guard-runtime", () => ({ inicializarGarantiaGuardaSwarm: inicializarMock }));

    const { register } = await import("./instrumentation");
    await register();

    expect(inicializarMock).not.toHaveBeenCalled();
  });

  it("NEXT_RUNTIME ausente -> não chama (mesmo comportamento de 'edge')", async () => {
    delete process.env.NEXT_RUNTIME;
    const inicializarMock = vi.fn();
    vi.doMock("@/lib/guard-runtime", () => ({ inicializarGarantiaGuardaSwarm: inicializarMock }));

    const { register } = await import("./instrumentation");
    await register();

    expect(inicializarMock).not.toHaveBeenCalled();
  });

  it("erro em inicializarGarantiaGuardaSwarm nunca escapa de register() (engolido e logado)", async () => {
    process.env.NEXT_RUNTIME = "nodejs";
    const erroMock = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.doMock("@/lib/guard-runtime", () => ({
      inicializarGarantiaGuardaSwarm: () => {
        throw new Error("falha ao agendar");
      },
    }));

    const { register } = await import("./instrumentation");

    await expect(register()).resolves.toBeUndefined();
    expect(erroMock).toHaveBeenCalled();
  });
});
