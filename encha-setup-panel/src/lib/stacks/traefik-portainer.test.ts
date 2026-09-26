import { describe, expect, it } from "vitest";
import { PORTAINER_VERSION, traefikPortainer } from "./traefik-portainer";
import type { SwarmContext } from "./types";

// Ciclo C1 (M2 do plano de segurança do EnchaT): o catálogo do painel
// espelhava "portainer/agent:latest" e "portainer/portainer-ce:latest" — o
// mesmo achado de auditoria do secondary.sh. Este teste garante que as duas
// imagens usam a constante PORTAINER_VERSION, nunca ":latest" solto, e que
// agent e server nunca divergem de versão entre si.

const values = {
  url_portainer: "portainer.exemplo.com",
  user_portainer: "administrador",
  pass_portainer: "Senha-Muito-Forte-123!",
  nome_servidor: "encha",
  nome_rede_interna: "enchaNet",
  email_ssl: "admin@exemplo.com",
};

const ctx: SwarmContext = {
  networkName: "enchaNet",
  serverName: "encha",
  email: "admin@exemplo.com",
};

describe("traefikPortainer.generateYaml — versão fixa do Portainer (C1)", () => {
  it("usa PORTAINER_VERSION para o agent e para o server", () => {
    const yaml = traefikPortainer.generateYaml(values, {}, ctx);
    expect(yaml).toContain(`image: portainer/agent:${PORTAINER_VERSION}`);
    expect(yaml).toContain(`image: portainer/portainer-ce:${PORTAINER_VERSION}`);
  });

  it("nunca usa :latest para o agent ou para o server", () => {
    const yaml = traefikPortainer.generateYaml(values, {}, ctx);
    expect(yaml).not.toContain("portainer/agent:latest");
    expect(yaml).not.toContain("portainer/portainer-ce:latest");
    expect(yaml).not.toContain("portainer-ce:latest");
  });

  it("agent e server nunca divergem de versão", () => {
    const yaml = traefikPortainer.generateYaml(values, {}, ctx);
    const tagAgent = yaml.match(/image: portainer\/agent:(\S+)/)?.[1];
    const tagServer = yaml.match(/image: portainer\/portainer-ce:(\S+)/)?.[1];
    expect(tagAgent).toBeDefined();
    expect(tagServer).toBeDefined();
    expect(tagAgent).toBe(tagServer);
  });

  it("PORTAINER_VERSION é uma versão semver simples (X.Y.Z), sem 'latest'", () => {
    expect(PORTAINER_VERSION).toMatch(/^\d+\.\d+\.\d+$/);
  });
});
