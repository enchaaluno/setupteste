import { describe, expect, it } from "vitest";
import { montarSpecGuarda, peersFromNodes, type MontarSpecGuardaArgs } from "./swarm-guard";
import type { DockerNode } from "./portainer";

// Cobre o builder puro do serviço Swarm `encha-guard` (ciclo C5 do plano de
// segurança — achado A1) e a extração de endereços de nós. Sem rede: só
// confere a forma do objeto produzido.

const baseArgs: MontarSpecGuardaArgs = {
  imagemPainel: "ghcr.io/enchaaluno/setup-panel@sha256:abc123def456",
  versaoApp: "0.4.1",
  peers: [],
};

describe("montarSpecGuarda", () => {
  it("Mode.Global presente", () => {
    const spec = montarSpecGuarda(baseArgs);
    expect(spec.Mode).toEqual({ Global: {} });
  });

  it("NENHUM label de namespace de stack — só com.encha.role/com.encha.guard.versao", () => {
    const spec = montarSpecGuarda(baseArgs);
    expect(spec.Labels).toEqual({
      "com.encha.role": "swarm-guard",
      "com.encha.guard.versao": "0.4.1",
    });
    expect(spec.Labels?.["com.docker.stack.namespace"]).toBeUndefined();
    expect(Object.keys(spec.Labels ?? {})).not.toContain("com.docker.stack.namespace");
  });

  it("Healthcheck: {Test:['NONE']} — desativa o herdado da imagem do painel", () => {
    const spec = montarSpecGuarda(baseArgs);
    expect(spec.TaskTemplate.ContainerSpec.Healthcheck).toEqual({ Test: ["NONE"] });
  });

  it("CapabilityDrop:['ALL'] + CapabilityAdd:['CAP_NET_ADMIN'], nada mais em nenhum dos dois", () => {
    const spec = montarSpecGuarda(baseArgs);
    expect(spec.TaskTemplate.ContainerSpec.CapabilityDrop).toEqual(["ALL"]);
    expect(spec.TaskTemplate.ContainerSpec.CapabilityAdd).toEqual(["CAP_NET_ADMIN"]);
  });

  it("ReadOnly: true", () => {
    const spec = montarSpecGuarda(baseArgs);
    expect(spec.TaskTemplate.ContainerSpec.ReadOnly).toBe(true);
  });

  it("rede é [{Target:'host'}]", () => {
    const spec = montarSpecGuarda(baseArgs);
    expect(spec.TaskTemplate.Networks).toEqual([{ Target: "host" }]);
  });

  it("Command é exatamente ['/usr/local/bin/encha-guard'], sem argumentos extras", () => {
    const spec = montarSpecGuarda(baseArgs);
    expect(spec.TaskTemplate.ContainerSpec.Command).toEqual(["/usr/local/bin/encha-guard"]);
  });

  it("a imagem usada é EXATAMENTE imagemPainel, nunca reconstruída a partir de versaoApp", () => {
    const spec = montarSpecGuarda({
      ...baseArgs,
      imagemPainel: "ghcr.io/enchaaluno/setup-panel@sha256:deadbeef00112233",
      versaoApp: "9.9.9", // deliberadamente diferente/incoerente com a imagem
    });
    expect(spec.TaskTemplate.ContainerSpec.Image).toBe(
      "ghcr.io/enchaaluno/setup-panel@sha256:deadbeef00112233"
    );
    // versaoApp só aparece no label, nunca embutida na imagem.
    expect(spec.TaskTemplate.ContainerSpec.Image).not.toContain("9.9.9");
    expect(spec.Labels?.["com.encha.guard.versao"]).toBe("9.9.9");
  });

  it("desativado:true inclui ENCHA_GUARD_DESATIVADO=1 no Env", () => {
    const spec = montarSpecGuarda({ ...baseArgs, desativado: true });
    expect(spec.TaskTemplate.ContainerSpec.Env).toContain("ENCHA_GUARD_DESATIVADO=1");
  });

  it("desativado:false NÃO inclui a var", () => {
    const spec = montarSpecGuarda({ ...baseArgs, desativado: false });
    expect(spec.TaskTemplate.ContainerSpec.Env?.some((e) => e.startsWith("ENCHA_GUARD_DESATIVADO"))).toBe(
      false
    );
  });

  it("desativado ausente NÃO inclui a var (mesmo comportamento de false)", () => {
    const spec = montarSpecGuarda(baseArgs);
    expect(spec.TaskTemplate.ContainerSpec.Env?.some((e) => e.startsWith("ENCHA_GUARD_DESATIVADO"))).toBe(
      false
    );
  });

  it("peers:[] produz ENCHA_GUARD_PEERS=\"\" (var presente, vazia)", () => {
    const spec = montarSpecGuarda({ ...baseArgs, peers: [] });
    expect(spec.TaskTemplate.ContainerSpec.Env).toContain("ENCHA_GUARD_PEERS=");
  });

  it("peers com itens junta por vírgula em ENCHA_GUARD_PEERS", () => {
    const spec = montarSpecGuarda({ ...baseArgs, peers: ["10.0.0.5", "10.0.0.6"] });
    expect(spec.TaskTemplate.ContainerSpec.Env).toContain("ENCHA_GUARD_PEERS=10.0.0.5,10.0.0.6");
  });

  it("permitirExtra, quando presente, entra como ENCHA_GUARD_PERMITIR cru (sem validar aqui)", () => {
    const spec = montarSpecGuarda({ ...baseArgs, permitirExtra: "203.0.113.9" });
    expect(spec.TaskTemplate.ContainerSpec.Env).toContain("ENCHA_GUARD_PERMITIR=203.0.113.9");
  });

  it("sem permitirExtra, a var não aparece", () => {
    const spec = montarSpecGuarda(baseArgs);
    expect(spec.TaskTemplate.ContainerSpec.Env?.some((e) => e.startsWith("ENCHA_GUARD_PERMITIR"))).toBe(
      false
    );
  });

  it("User é '0' (root, necessário pro CAP_NET_ADMIN)", () => {
    const spec = montarSpecGuarda(baseArgs);
    expect(spec.TaskTemplate.ContainerSpec.User).toBe("0");
  });

  it("RestartPolicy: any, com Delay em nanossegundos (5s)", () => {
    const spec = montarSpecGuarda(baseArgs);
    expect(spec.TaskTemplate.RestartPolicy).toEqual({ Condition: "any", Delay: 5_000_000_000 });
  });

  it("Resources.Limits: 0.1 CPU / 64MiB", () => {
    const spec = montarSpecGuarda(baseArgs);
    expect(spec.TaskTemplate.Resources).toEqual({
      Limits: { NanoCPUs: 100_000_000, MemoryBytes: 67_108_864 },
    });
  });

  it("Placement.Constraints inclui node.platform.os == linux", () => {
    const spec = montarSpecGuarda(baseArgs);
    expect(spec.TaskTemplate.Placement).toEqual({ Constraints: ["node.platform.os == linux"] });
  });

  it("Name é 'encha-guard'", () => {
    const spec = montarSpecGuarda(baseArgs);
    expect(spec.Name).toBe("encha-guard");
  });

  it("determinismo: mesmos argumentos produzem objetos deepEqual", () => {
    const args: MontarSpecGuardaArgs = {
      imagemPainel: "ghcr.io/enchaaluno/setup-panel@sha256:cafe1234",
      versaoApp: "0.4.1",
      peers: ["10.0.0.5", "10.0.0.6"],
      permitirExtra: "203.0.113.9",
      desativado: false,
    };
    expect(montarSpecGuarda(args)).toEqual(montarSpecGuarda({ ...args }));
  });
});

describe("peersFromNodes", () => {
  function no(addr: string | undefined, managerAddr?: string): DockerNode {
    return {
      ID: `node-${addr ?? "sem-addr"}`,
      Status: { Addr: addr as string },
      ...(managerAddr ? { ManagerStatus: { Addr: managerAddr } } : {}),
    };
  }

  it("1 nó só → lista vazia (não precisa se autopermitir)", () => {
    expect(peersFromNodes([no("10.0.0.5")])).toEqual([]);
  });

  it("0 nós → lista vazia", () => {
    expect(peersFromNodes([])).toEqual([]);
  });

  it("2 nós → lista com os dois endereços, sem porta", () => {
    const nodes = [no("10.0.0.5"), no("10.0.0.6")];
    expect(peersFromNodes(nodes)).toEqual(["10.0.0.5", "10.0.0.6"]);
  });

  it("3+ nós → todos os endereços", () => {
    const nodes = [no("10.0.0.5"), no("10.0.0.6"), no("10.0.0.7")];
    expect(peersFromNodes(nodes)).toEqual(["10.0.0.5", "10.0.0.6", "10.0.0.7"]);
  });

  it("usa ManagerStatus.Addr (com porta) quando Status.Addr está vazio, cortando a porta", () => {
    const nodes = [no("10.0.0.5"), no("", "10.0.0.9:2377")];
    expect(peersFromNodes(nodes)).toEqual(["10.0.0.5", "10.0.0.9"]);
  });

  it("IPv6 entre colchetes com porta é extraído sem colchetes e sem porta", () => {
    const nodes = [no("10.0.0.5"), no("[fd00::1]:2377")];
    expect(peersFromNodes(nodes)).toEqual(["10.0.0.5", "fd00::1"]);
  });

  it("IPv6 puro sem colchetes/porta em Status.Addr fica intacto", () => {
    const nodes = [no("10.0.0.5"), no("fd00::1")];
    expect(peersFromNodes(nodes)).toEqual(["10.0.0.5", "fd00::1"]);
  });

  it("nó com Status.Addr mal formado/vazio e sem ManagerStatus é ignorado, não quebra a função", () => {
    const nodes = [no("10.0.0.5"), no(""), no("10.0.0.6")];
    expect(peersFromNodes(nodes)).toEqual(["10.0.0.5", "10.0.0.6"]);
  });

  it("nó com colchete sem fechamento (malformado) é ignorado", () => {
    const nodes = [no("10.0.0.5"), no("[fd00::1"), no("10.0.0.6")];
    expect(peersFromNodes(nodes)).toEqual(["10.0.0.5", "10.0.0.6"]);
  });

  // Entradas adversariais/malformadas: nunca lançam, e nada que não seja um
  // IP literal de par chega a ENCHA_GUARD_PEERS (o script aceita CIDR lá).
  it("nó sem Status, Status sem Addr, Addr undefined e elemento null são ignorados sem lançar", () => {
    const nodes = [
      { ID: "sem-status" },
      { ID: "status-vazio", Status: {} },
      { ID: "addr-undefined", Status: { Addr: undefined } },
      null,
      { ID: "ok", Status: { Addr: "10.0.0.6" } },
      { ID: "ok2", Status: { Addr: "10.0.0.7" } },
    ] as unknown as DockerNode[];
    expect(peersFromNodes(nodes)).toEqual(["10.0.0.6", "10.0.0.7"]);
  });

  it("Status.Addr com porta ('10.0.0.5:2377') e IPv6 '[::1]:2377' saem sem porta/colchetes", () => {
    expect(peersFromNodes([no("10.0.0.5:2377"), no("[fd00::2]:2377")])).toEqual(["10.0.0.5", "fd00::2"]);
  });

  it("CIDR em Addr NUNCA vira par ('0.0.0.0/0' liberaria a Internet inteira)", () => {
    expect(peersFromNodes([no("0.0.0.0/0"), no("::/0"), no("10.0.0.0/8"), no("10.0.0.6")])).toEqual(["10.0.0.6"]);
  });

  it("Status.Addr '0.0.0.0' (não especificado) cai para o IP real de ManagerStatus.Addr", () => {
    expect(peersFromNodes([no("0.0.0.0", "31.97.144.25:2377"), no("10.0.0.6")])).toEqual([
      "10.0.0.6",
      "31.97.144.25",
    ]);
    expect(peersFromNodes([no("::", "[fd00::9]:2377"), no("10.0.0.6")])).toEqual(["10.0.0.6", "fd00::9"]);
  });

  it("lixo que não é IP literal (lista com vírgula, espaço, hostname, zona IPv6) é ignorado", () => {
    const nodes = [no("10.0.0.5,1.2.3.4"), no("10.0.0.5 1.2.3.4"), no("node-1.local"), no("fe80::1%eth0"), no("10.0.0.6")];
    expect(peersFromNodes(nodes)).toEqual(["10.0.0.6"]);
  });

  it("determinismo: ordem dos nós na resposta da API não muda a saída; IP repetido sai uma vez só", () => {
    const a = peersFromNodes([no("10.0.0.7"), no("10.0.0.5"), no("10.0.0.6")]);
    const b = peersFromNodes([no("10.0.0.6"), no("10.0.0.7"), no("10.0.0.5")]);
    expect(a).toEqual(b);
    expect(peersFromNodes([no("10.0.0.6"), no("10.0.0.5"), no("10.0.0.6")])).toEqual(["10.0.0.5", "10.0.0.6"]);
  });

  it("determinismo: mesma entrada produz a mesma saída", () => {
    const nodes = [no("10.0.0.5"), no("10.0.0.6")];
    expect(peersFromNodes(nodes)).toEqual(peersFromNodes(nodes.map((n) => ({ ...n }))));
  });
});
