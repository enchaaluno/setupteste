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
  pinfy_db_password: "pinfy-db-pw-fake",
  pinfy_session_key: "pinfy-session-key-fake",
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

describe("enchat — estado persistente do sidecar enchat_updater", () => {
  it("o enchat_updater monta /var/enchat/updater em /data e aponta STATE_FILE para lá", () => {
    const bloco = blocoDoServico(enchat.generateYaml(valuesValidos, secrets, ctxBase), "enchat_updater");
    expect(bloco).toContain("- /var/enchat/updater:/data");
    expect(bloco).toContain('STATE_FILE: "/data/estado.json"');
  });

  it("o updater também atualiza o Pinfy bundled (PINFY_* apontam para os serviços DESTA stack)", () => {
    const yaml = enchat.generateYaml(valuesValidos, secrets, ctxBase);
    const updater = blocoDoServico(yaml, "enchat_updater");
    // Os serviços referenciados existem no próprio YAML, com as portas certas.
    expect(blocoDoServico(yaml, "enchat_pinfy")).toBeTruthy();
    expect(updater).toContain('PINFY_SERVICE: "enchat_pinfy"');
    // Swarm nomeia <stack>_<serviço>; a stack do painel se chama "enchat"
    // (installer.ts: stackId sem hífens) — mesmo padrão do SWARM_SERVICE do app.
    expect(updater).toContain('SWARM_SERVICE: "enchat_enchat_app"');
    expect(updater).toContain('PINFY_SWARM_SERVICE: "enchat_enchat_pinfy"');
    expect(updater).toContain('PINFY_HEALTHZ_URL: "http://enchat_pinfy:3000/api/health"');
    expect(updater).toContain('HEALTHZ_URL: "http://enchat_app:8080/api/healthz"');
    // Em Swarm, PINFY_SERVICE sem PINFY_SWARM_SERVICE derruba o boot do sidecar.
    expect(updater).toMatch(/PINFY_SERVICE:[\s\S]*PINFY_SWARM_SERVICE:/);
  });

  it("o diretório do bind mount está em hostDirs (o Swarm não cria bind mount sozinho)", () => {
    const caminhos = (enchat.hostDirs ?? []).map((d) => (typeof d === "string" ? d : d.path));
    expect(caminhos).toContain("/var/enchat/updater");
  });
});

describe("enchat — S12: papel restrito \"pinfy\" no Postgres + sessão cifrada", () => {
  it("generateSecrets gera pinfy_db_password e pinfy_session_key", () => {
    const gerados = enchat.generateSecrets!(valuesValidos);
    const dbPassword = gerados.find((g) => g.name === "pinfy_db_password");
    const sessionKey = gerados.find((g) => g.name === "pinfy_session_key");
    expect(dbPassword).toBeDefined();
    expect(sessionKey).toBeDefined();
    // [A-Za-z0-9_-] só (contrato do app, internal/appcore), 32-128 chars —
    // hex de 24 bytes = 48 chars, dentro da janela.
    expect(dbPassword!.value).toMatch(/^[A-Za-z0-9_-]{32,128}$/);
    // 32 bytes aleatórios em hex = 64 chars (contrato da cifra AES-256-GCM).
    expect(sessionKey!.value).toMatch(/^[0-9a-f]{64}$/);
    expect(dbPassword!.value).not.toBe(sessionKey!.value);
  });

  it("dois sorteios dão valores diferentes para as duas (não é constante)", () => {
    const a = enchat.generateSecrets!(valuesValidos);
    const b = enchat.generateSecrets!(valuesValidos);
    expect(a.find((g) => g.name === "pinfy_db_password")!.value).not.toBe(
      b.find((g) => g.name === "pinfy_db_password")!.value
    );
    expect(a.find((g) => g.name === "pinfy_session_key")!.value).not.toBe(
      b.find((g) => g.name === "pinfy_session_key")!.value
    );
  });

  it("pinfy_session_key é `reveal` (perda é irrecuperável, como enchat_master_key); pinfy_db_password não é (segredo interno entre containers)", () => {
    const gerados = enchat.generateSecrets!(valuesValidos);
    expect(gerados.find((g) => g.name === "pinfy_session_key")!.reveal).toBe(true);
    expect(gerados.find((g) => g.name === "pinfy_db_password")!.reveal).toBeFalsy();
  });

  it("o enchat_app recebe PINFY_DB_PASSWORD", () => {
    const bloco = blocoDoServico(enchat.generateYaml(valuesValidos, secrets, ctxBase), "enchat_app");
    expect(bloco).toContain(`PINFY_DB_PASSWORD: "${secrets.pinfy_db_password}"`);
    expect(bloco).not.toContain(secrets.pinfy_session_key);
  });

  it("o enchat_pinfy conecta no Postgres como o usuário restrito \"pinfy\" (nunca mais \"enchat\") com a PINFY_DB_PASSWORD", () => {
    const bloco = blocoDoServico(enchat.generateYaml(valuesValidos, secrets, ctxBase), "enchat_pinfy");
    expect(bloco).toContain(`DATABASE_URL: "postgresql://pinfy:${secrets.pinfy_db_password}@enchat_postgres:5432/enchat?schema=pinfy&sslmode=disable"`);
    expect(bloco).not.toMatch(/postgresql:\/\/enchat:/);
  });

  it("o enchat_pinfy recebe SESSION_KEY (cifra a sessão do WhatsApp) e SÓ ele", () => {
    const yaml = enchat.generateYaml(valuesValidos, secrets, ctxBase);
    expect(blocoDoServico(yaml, "enchat_pinfy")).toContain(`SESSION_KEY: "${secrets.pinfy_session_key}"`);
    for (const s of ["enchat_app", "enchat_updater", "enchat_postgres"]) {
      expect(blocoDoServico(yaml, s)).not.toContain(secrets.pinfy_session_key);
    }
  });

  it("as notas avisam para guardar a PINFY_SESSION_KEY", () => {
    const notas = enchat.postInstall!.notes as (v: Record<string, unknown>) => string[];
    expect(notas(valuesValidos).some((n) => n.includes("PINFY_SESSION_KEY"))).toBe(true);
  });
});

describe("enchat — pós-instalação", () => {
  it("setupUrl monta https://<domínio>/?setup=<enchat_setup_token>", () => {
    expect(enchat.postInstall!.setupUrl!(valuesValidos, secrets)).toBe(
      `https://crm.exemplo.com/?setup=${secrets.enchat_setup_token}`
    );
  });

  it("accessUrl continua limpo (sem token) — installer.ts o usa para bater em /api/license", () => {
    expect(enchat.postInstall!.accessUrl!(valuesValidos)).toBe("https://crm.exemplo.com");
  });

  it("as notas citam o link de primeiro acesso, com e sem pareamento", () => {
    const notas = enchat.postInstall!.notes as (v: Record<string, unknown>) => string[];
    for (const v of [valuesValidos, { ...valuesValidos, licenca_pareamento_id: "0".repeat(32) }]) {
      expect(notas(v).some((n) => n.includes("administrador"))).toBe(true);
    }
  });
});
