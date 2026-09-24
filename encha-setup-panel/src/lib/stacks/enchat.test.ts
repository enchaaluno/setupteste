import { describe, expect, it } from "vitest";
import { enchat } from "./enchat";
import type { SwarmContext } from "./types";

const valuesValidos = {
  url_enchat: "crm.exemplo.com",
  chave_licenca: "CHAVE-DE-TESTE-123",
};

const secrets = {
  enchat_master_key: "master-key-fake",
  postgres_password: "postgres-pw-fake",
  pinfy_master_key: "pinfy-master-fake",
  pinfy_webhook_token: "pinfy-webhook-fake",
  pinfy_panel_password: "pinfy-panel-fake",
  updater_token: "updater-token-fake",
  enchat_setup_token: "setup-token-fake-0123456789abcdef",
};

const ctxBase: SwarmContext = {
  networkName: "rede_traefik",
  serverName: "vps-teste",
  email: "operador@exemplo.com",
  release: { version: "0.3.2", imageRepo: "ghcr.io/enchainterno/enchat-free", imageTag: "0.3.2", obrigatoria: false },
  machineId: "0123456789abcdef0123456789abcdef",
  fingerprint: "58132042721689d3e6fb25654444e5b7",
};

// Recorta o bloco de UM serviço do YAML gerado (do "  <nome>:" até o
// próximo serviço/bloco no mesmo nível) — assim um teste afirma "esta env
// está NESTE serviço", não só "aparece em algum lugar do arquivo".
function blocoDoServico(yaml: string, servico: string): string {
  const linhas = yaml.split("\n");
  const inicio = linhas.findIndex((l) => l === `  ${servico}:`);
  if (inicio === -1) throw new Error(`serviço ${servico} não encontrado no YAML`);
  let fim = linhas.length;
  for (let i = inicio + 1; i < linhas.length; i++) {
    if (/^ {0,2}\S/.test(linhas[i])) {
      fim = i;
      break;
    }
  }
  return linhas.slice(inicio, fim).join("\n");
}

describe("enchat — token de primeiro acesso (ENCHAT_SETUP_TOKEN)", () => {
  it("generateSecrets gera enchat_setup_token em base64url com pelo menos 20 caracteres (mínimo do app)", () => {
    const gerados = enchat.generateSecrets!(valuesValidos);
    const token = gerados.find((g) => g.name === "enchat_setup_token");
    expect(token).toBeDefined();
    expect(token!.value).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(token!.value.length).toBeGreaterThanOrEqual(20);
  });

  it("dois sorteios dão tokens diferentes (não é constante)", () => {
    const a = enchat.generateSecrets!(valuesValidos).find((g) => g.name === "enchat_setup_token")!.value;
    const b = enchat.generateSecrets!(valuesValidos).find((g) => g.name === "enchat_setup_token")!.value;
    expect(a).not.toBe(b);
  });

  it("não é `reveal` — o operador recebe o link pronto (setupUrl), não o token cru num card de segredo", () => {
    const token = enchat.generateSecrets!(valuesValidos).find((g) => g.name === "enchat_setup_token");
    expect(token!.reveal).toBeFalsy();
  });

  it("o serviço enchat_app recebe ENCHAT_SETUP_TOKEN com o valor do segredo", () => {
    const yaml = enchat.generateYaml(valuesValidos, secrets, ctxBase);
    expect(blocoDoServico(yaml, "enchat_app")).toContain(`ENCHAT_SETUP_TOKEN: "${secrets.enchat_setup_token}"`);
  });

  it("o token não vaza para outros serviços (updater/pinfy/postgres)", () => {
    const yaml = enchat.generateYaml(valuesValidos, secrets, ctxBase);
    for (const s of ["enchat_updater", "enchat_pinfy", "enchat_postgres"]) {
      expect(blocoDoServico(yaml, s)).not.toContain(secrets.enchat_setup_token);
    }
  });
});
