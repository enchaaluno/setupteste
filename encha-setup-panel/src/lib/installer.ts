import { z } from "zod";
import { getStack } from "./stacks/registry";
import {
  deploySwarmStack,
  discoverContext,
  ensurePostgresDatabase,
  ensurePostgresExtension,
  ensureSwarmVolume,
  listStacks,
  type Stack,
} from "./portainer";
import { RegistryAuthError } from "./registry-auth";
import { resolveRegistryAndPullImages } from "./registry-pull";
import { ReleaseInfoError, fetchLatestRelease } from "./release-info";
import { ativarTrackerPorEmail, TrackerAtivacaoError } from "./tracker-ativacao";
import { ensureHostDirs } from "./host-dirs";
import { logAudit } from "./audit";
import { encryptSecret } from "./crypto";
import { getDb } from "./db";
import { getOrCreateMachineId, buscarPareamento, chaveDoPareamento, consumirPareamento } from "./pairing-store";
import { fingerprintEnchat } from "./enchat-fingerprint";
import { APP_VERSION } from "./version";
import type { SwarmContext, GeneratedSecret, StackDefinition } from "./stacks/types";

// resolverAppHostname é o ÚNICO ponto que os dois call sites de
// getOrCreateMachineId/fingerprintEnchat usam pra obter o hostname (Ciclo
// 20) — extraído como função PURA e exportada para ser testável sem
// precisar montar um installStack inteiro (Portainer/DB/rede). `contexto`
// é só para a mensagem de erro dizer QUAL branch (registryAuth vs pairing)
// estava sem appHostname.
export function resolverAppHostname(def: StackDefinition, contexto: "registryAuth" | "pairing" | "emailActivation"): string {
  if (!def.appHostname) {
    throw new Error(`stack "${def.id}" declara ${contexto} mas não tem appHostname — fingerprint indeterminado.`);
  }
  return def.appHostname;
}

export type InstallInput = {
  stackId: string;
  values: Record<string, unknown>;
  swarmCtx: SwarmContext;
  token: string;
  user: string;
  ip: string;
};

export type InstallResult = {
  ok: boolean;
  stack?: Stack;
  error?: string;
  /** Causa estruturada (ver RegistryAuthReason/ReleaseInfoReason) — permite o cliente/API distinguir "chave errada" de "Console fora do ar" em vez de um 400 genérico pra tudo. */
  reason?: string;
  /** Status HTTP sugerido pra API route devolver — falha do lado do EnchaT vira 502/504/429, nunca 400. */
  httpStatus?: number;
  generatedSecrets?: GeneratedSecret[];
  /** Aviso não-bloqueante pós-deploy (ex.: fingerprint divergente — ver checarFingerprintPosDeploy). Instalação já subiu; isto é só um alerta pro card final. */
  aviso?: string;
  /** Link de primeiro acesso (StackDefinition.postInstall.setupUrl), montado com os segredos EFETIVOS do deploy. Contém segredo: só vai na resposta do POST, nunca em audit log. */
  setupUrl?: string;
};

// Mapeia a causa estruturada de RegistryAuthError/ReleaseInfoError pro status
// HTTP que a API route deve devolver. Sem isso, TODO erro de install virava
// 400 — foi exatamente isso que escondeu o 503 "registry_nao_configurado" do
// Console original: o cliente via só "Erro na instalação", sem status nem
// motivo, e não dava pra saber se o problema era a chave ou o serviço do
// EnchaT. Ver registry-auth.ts e release-info.ts para as taxonomias.
function statusForCause(e: unknown): { httpStatus: number; reason?: string } {
  if (e instanceof RegistryAuthError) {
    switch (e.reason) {
      case "timeout":
        return { httpStatus: 504, reason: e.reason };
      case "rate_limited":
        return { httpStatus: 429, reason: e.reason };
      case "unauthorized":
      case "chave_nao_encontrada":
      case "chave_revogada":
      case "chave_expirada":
      case "fingerprint_mismatch":
      case "updates_expirados":
        // Casos que são "culpa" da chave/licença informada, não do serviço
        // do EnchaT — a distinção fina entre eles vive só na `message` e no
        // `reason` (ver registry-auth.ts); o status HTTP pro chamador é o
        // mesmo 400 pros seis.
        return { httpStatus: 400, reason: e.reason };
      case "network":
      case "server":
      case "not_found":
      case "malformed":
      case "contract":
        return { httpStatus: 502, reason: e.reason };
    }
  }
  if (e instanceof ReleaseInfoError) {
    switch (e.reason) {
      case "timeout":
        return { httpStatus: 504, reason: e.reason };
      case "network":
      case "not_found":
      case "nao_publicada":
      case "server":
      case "malformed":
      case "contract":
        return { httpStatus: 502, reason: e.reason };
    }
  }
  if (e instanceof TrackerAtivacaoError) {
    switch (e.reason) {
      case "timeout":
        return { httpStatus: 504, reason: e.reason };
      case "rate_limited":
        return { httpStatus: 429, reason: e.reason };
      case "ativacao_recusada":
        // "Culpa" do e-mail informado (não reconhecido, licença revogada, já
        // vinculado a outra VPS) — mesmo tratamento 400 que as causas
        // equivalentes de RegistryAuthError acima, nunca 502.
        return { httpStatus: 400, reason: e.reason };
      case "registry_nao_configurado":
        return { httpStatus: 503, reason: e.reason };
      case "network":
      case "server":
      case "malformed":
      case "contract":
        return { httpStatus: 502, reason: e.reason };
    }
  }
  // Erro não estruturado (bug de código, falha do Portainer, etc.) — 500
  // continua correto: não é nem "chave errada" nem "Console fora do ar".
  return { httpStatus: 500 };
}

function shouldEncryptField(name: string): boolean {
  return /pass|senha|secret|token|key|apikey/i.test(name);
}

// Remove campos que nunca devem ser persistidos (ex.: chave de licença) —
// nem no blob criptografado, nem no meta do audit log. Cópia rasa; não muda
// o objeto original.
function stripTransient(
  values: Record<string, unknown>,
  transientFields?: string[]
): Record<string, unknown> {
  if (!transientFields?.length) return values;
  const out = { ...values };
  for (const f of transientFields) delete out[f];
  return out;
}

function buildSecretMap(secrets: GeneratedSecret[], reused: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const s of secrets) {
    if (s.value === "REUSE_POSTGRES") {
      out[s.name] = reused.senha_postgres ?? "";
    } else if (s.value === "REUSE_MINIO") {
      out[s.name] = reused.minio_access ?? "";
    } else if (s.value === "REUSE_MYSQL") {
      out[s.name] = reused.senha_mysql ?? "";
    } else {
      out[s.name] = s.value;
    }
  }
  return out;
}

async function loadReusedSecrets(): Promise<Record<string, string>> {
  const db = getDb();
  const row = db
    .prepare("SELECT encrypted_envs FROM stack_secrets WHERE stack_name = ?")
    .get("__shared__") as { encrypted_envs: string } | undefined;
  if (!row) return {};
  try {
    const { decryptSecret } = await import("./crypto");
    return JSON.parse(decryptSecret(row.encrypted_envs));
  } catch {
    return {};
  }
}

// Segredos que a PRÓPRIA stack já gerou numa instalação anterior (ex.:
// enchat_master_key, postgres_password do "enchat"). Diferente de
// loadReusedSecrets (que só cobre os sentinels REUSE_* compartilhados entre
// stacks distintas), isto cobre o reinstall/retry da MESMA stack: sem isso,
// cada POST /api/stacks gera valores novos via randomBytes, e um segundo
// install (retry após falha parcial, ou o operador clicando "Instalar" de
// novo) troca ENCHAT_MASTER_KEY e a senha do Postgres por baixo do capô —
// a app já teria dados gravados sob a chave/senha antigas e o boot aborta
// no canary de criptografia (ver internal/crypto no repo do EnchaT).
async function loadStackOwnSecrets(stackName: string): Promise<Record<string, string>> {
  const db = getDb();
  const row = db
    .prepare("SELECT encrypted_envs FROM stack_secrets WHERE stack_name = ?")
    .get(stackName) as { encrypted_envs: string } | undefined;
  if (!row) return {};
  try {
    const { decryptSecret } = await import("./crypto");
    const parsed = JSON.parse(decryptSecret(row.encrypted_envs)) as { generated?: GeneratedSecret[] };
    const out: Record<string, string> = {};
    for (const g of parsed.generated ?? []) {
      if (g && typeof g.name === "string" && typeof g.value === "string") out[g.name] = g.value;
    }
    return out;
  } catch {
    return {};
  }
}

function saveSharedSecrets(secrets: Record<string, string>): void {
  const db = getDb();
  const blob = encryptSecret(JSON.stringify(secrets));
  const now = Date.now();
  db.prepare(
    `INSERT INTO stack_secrets (stack_name, encrypted_envs, created_at, updated_at)
     VALUES (?, ?, ?, ?)
     ON CONFLICT(stack_name) DO UPDATE SET encrypted_envs = excluded.encrypted_envs, updated_at = excluded.updated_at`
  ).run("__shared__", blob, now, now);
}

function saveStackSecrets(
  stackName: string,
  envs: Record<string, unknown>,
  generated: GeneratedSecret[],
  transientFields?: string[]
): void {
  // Defesa em profundidade: mesmo que o chamador já tenha filtrado, nunca
  // deixar um campo transiente (ex.: chave de licença) chegar aqui dentro.
  if (transientFields?.some((f) => f in envs)) {
    throw new Error("Tentativa de persistir campo transiente em stack_secrets — bug no installer.");
  }
  const safe: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(envs)) {
    safe[k] = shouldEncryptField(k) ? "[encrypted]" : v;
  }
  const payload = { values: safe, generated_count: generated.length };
  const db = getDb();
  const blob = encryptSecret(JSON.stringify({ values: envs, generated }));
  const now = Date.now();
  db.prepare(
    `INSERT INTO stack_secrets (stack_name, encrypted_envs, created_at, updated_at)
     VALUES (?, ?, ?, ?)
     ON CONFLICT(stack_name) DO UPDATE SET encrypted_envs = excluded.encrypted_envs, updated_at = excluded.updated_at`
  ).run(stackName, blob, now, now);
  logAudit({
    user: "system",
    ip: "local",
    action: "stack.install",
    target: stackName,
    result: "ok",
    meta: payload,
  });
}

// Confere, depois do deploy, se o fingerprint que o APP ACABOU DE CALCULAR
// (GET /api/license, já rodando na VPS) bate com o que o PAINEL vinculou no
// Console durante o pareamento. Existem dois clientes independentes falando
// o mesmo protocolo (painel via SQLite local, app via ENCHAT_MACHINE_ID no
// env) — só coincidem porque o painel copia machineId pro YAML; nada
// verificava que deu certo. Quando diverge, o app pede pareamento de novo e
// a nova sessão é recusada como "já ativada em outro servidor", sobre uma
// licença que é do próprio cliente — exatamente o bug real encontrado no
// teste E2E. Best-effort: nunca lança, nunca derruba um install que já
// funcionou; só alimenta `aviso` no InstallResult pro card final avisar cedo
// em vez do cliente descobrir pela tela de pareamento.
async function checarFingerprintPosDeploy(accessUrl: string, fingerprintEsperado: string): Promise<string | undefined> {
  const tentativas = 3;
  for (let tentativa = 1; tentativa <= tentativas; tentativa++) {
    await new Promise((resolve) => setTimeout(resolve, 3000));
    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 5000);
      const r = await fetch(`${accessUrl}/api/license`, { signal: controller.signal, cache: "no-store" });
      clearTimeout(timeout);
      if (!r.ok) continue;
      const body = (await r.json()) as { fingerprint?: string };
      if (!body.fingerprint) continue;
      if (body.fingerprint !== fingerprintEsperado) {
        return (
          "O app subiu, mas o identificador que ele calculou não bate com o que foi vinculado à licença " +
          "durante o pareamento — ele pode pedir ativação de novo. Se isso acontecer, use a opção " +
          "\"esta licença é minha\" na tela de ativação para resolver sem precisar de suporte."
        );
      }
      return undefined; // bateu — sem aviso.
    } catch {
      // App ainda subindo, rede instável, etc. — tenta de novo, e se todas
      // as tentativas falharem, simplesmente não há aviso (não é evidência
      // de divergência, só de indisponibilidade transitória).
    }
  }
  return undefined;
}

export async function installStack(input: InstallInput): Promise<InstallResult> {
  const def = getStack(input.stackId);
  if (!def) return { ok: false, error: "Stack desconhecida" };

  const parsed = def.schema.safeParse(input.values);
  if (!parsed.success) {
    return { ok: false, error: parsed.error.errors.map((e: z.ZodIssue) => e.message).join("; ") };
  }

  try {
    // Pareamento self-service de licença (Fase 4): se a stack declara
    // `pairing` e o form mandou uma sessão confirmada, a chave e o
    // machine_id vêm DAQUI — nunca da chave digitada à mão nem recomputados
    // por getOrCreateMachineId. É essa fonte única que garante que o
    // fingerprint usado no exchange do registryAuth (abaixo) e o
    // ENCHAT_MACHINE_ID injetado no YAML são EXATAMENTE o que o Console já
    // vinculou no pareamento — qualquer divergência aqui vira
    // fingerprint_mismatch irreversível depois do primeiro boot.
    let pareamentoId: string | undefined;
    let pareamentoMachineId: string | undefined;
    let pareamentoFingerprint: string | undefined;
    if (def.pairing) {
      const hostnameParaPareamento = resolverAppHostname(def, "pairing");
      const pid = String(parsed.data[def.pairing.sessionField] ?? "");
      if (pid) {
        const row = buscarPareamento(pid);
        if (!row || row.stack_id !== input.stackId) {
          throw new Error("Sessão de pareamento de licença não encontrada — gere um novo pareamento e tente de novo.");
        }
        if (row.status !== "confirmado") {
          throw new Error(`Sessão de pareamento de licença ainda não confirmada (status: ${row.status}).`);
        }
        // Sanidade: o fingerprint gravado tem que bater com a fórmula
        // aplicada ao machine_id gravado — nunca deveria divergir (os dois
        // nascem juntos em getOrCreateMachineId), mas seguir com uma
        // inconsistência aqui instalaria com um fingerprint errado, então
        // aborta em vez de tentar adivinhar qual dos dois está certo.
        if (fingerprintEnchat(row.machine_id, hostnameParaPareamento) !== row.fingerprint) {
          throw new Error("Inconsistência no pareamento de licença (fingerprint não bate com machine_id) — instalação abortada.");
        }
        // Guarda contra instalar a edição errada com o plano errado: como
        // pairStart manda suporta_selecao=true, o Console pode confirmar
        // com uma licença PAGA (basico/pro/max) se for a única elegível pro
        // CPF — mas esta stack só instala a imagem "free". Sem esta
        // checagem, o cliente instalaria o binário Grátis com uma chave
        // paga, que na melhor hipótese é desperdício e na pior confunde o
        // /licenses/check depois. `plano` fica nulo em pareamentos de antes
        // desta checagem existir — não bloqueia esses retroativamente.
        if (def.pairing.edicao === "free" && row.plano && row.plano !== "gratis") {
          throw new Error(
            `Esta licença é do plano "${row.plano}", não do Grátis — gere uma licença grátis para instalar esta edição, ou instale a edição MAX com esta chave.`
          );
        }
        const chave = chaveDoPareamento(pid);
        if (!chave) {
          throw new Error("Não foi possível recuperar a chave de licença do pareamento confirmado.");
        }
        parsed.data[def.pairing.targetField] = chave;
        pareamentoId = pid;
        pareamentoMachineId = row.machine_id;
        pareamentoFingerprint = row.fingerprint;
      }
    }

    // Ativação síncrona por e-mail (Ciclo D) — se a stack declara
    // `emailActivation`, o e-mail digitado no campo-fonte é trocado por uma
    // chave AQUI, antes de qualquer outra coisa: é essa chave que
    // registryAuth (mais abaixo) e generateYaml precisam para funcionar.
    // Fingerprint resolvido do MESMO jeito que registryAuth usa quando não
    // há pareamento (getOrCreateMachineId) — guardado para reaproveitar lá
    // embaixo em vez de recalcular (idempotente, mas reaproveitar deixa
    // explícito que é o MESMO valor em todo o fluxo). Falha aqui aborta
    // ANTES de discoverContext/deploySwarmStack — nenhuma instalação sobe
    // pra VPS com um e-mail que o Console não reconheceu.
    let ativacaoMachineId: string | undefined;
    let ativacaoFingerprint: string | undefined;
    if (def.emailActivation) {
      // Normaliza (trim + minúsculas) ANTES de mandar pro Console — o
      // Console também normaliza do lado dele, mas o instalador não pode
      // DEPENDER disso: é o instalador quem decide se um e-mail digitado
      // com espaço/maiúscula bateu ou não, então tem que aplicar a mesma
      // normalização por conta própria (achado do Ciclo D: sem isto, " E@X.com "
      // e "e@x.com" pareceriam entradas diferentes em qualquer comparação
      // futura feita aqui, mesmo os dois ativando a MESMA licença no Console).
      const email = String(parsed.data[def.emailActivation.sourceField] ?? "")
        .trim()
        .toLowerCase();
      if (!email) {
        throw new Error(
          `Campo "${def.emailActivation.sourceField}" (e-mail da compra) é obrigatório para instalar esta stack.`
        );
      }
      const hostnameParaAtivacao = resolverAppHostname(def, "emailActivation");
      const { machineId, fingerprint } = getOrCreateMachineId(input.stackId, hostnameParaAtivacao);
      try {
        const { chave } = await ativarTrackerPorEmail(
          def.emailActivation.consoleBaseUrl,
          email,
          fingerprint,
          APP_VERSION
        );
        parsed.data[def.emailActivation.targetField] = chave;
        ativacaoMachineId = machineId;
        ativacaoFingerprint = fingerprint;
        logAudit({
          user: input.user,
          ip: input.ip,
          action: "license.tracker.ativar",
          target: input.stackId,
          result: "ok",
          meta: {}, // nunca o e-mail nem a chave.
        });
      } catch (e) {
        const meta: Record<string, unknown> = {
          error: e instanceof Error ? e.message : "Erro desconhecido",
        };
        if (e instanceof TrackerAtivacaoError) {
          meta.reason = e.reason;
          if (e.httpStatus !== undefined) meta.httpStatus = e.httpStatus;
        }
        logAudit({
          user: input.user,
          ip: input.ip,
          action: "license.tracker.ativar.fail",
          target: input.stackId,
          result: "error",
          meta,
        });
        throw e;
      }
    }

    const reused = await loadReusedSecrets();
    const previousOwn = await loadStackOwnSecrets(input.stackId);
    const generated = (def.generateSecrets?.(parsed.data) ?? []).map((g) => {
      if (g.value === "REUSE_POSTGRES" || g.value === "REUSE_MINIO" || g.value === "REUSE_MYSQL") return g;
      const prev = previousOwn[g.name];
      return prev !== undefined ? { ...g, value: prev } : g;
    });
    const secretMap = buildSecretMap(generated, reused);

    const sharedToPersist: Record<string, string> = { ...reused };
    for (const g of generated) {
      if (g.value === "REUSE_POSTGRES" || g.value === "REUSE_MINIO" || g.value === "REUSE_MYSQL") continue;
      if (def.id === "postgres" && g.name === "senha_postgres") sharedToPersist.senha_postgres = g.value;
      if (def.id === "minio" && g.name === "minio_access") sharedToPersist.minio_access = g.value;
      if (def.id === "mysql" && g.name === "senha_mysql") sharedToPersist.senha_mysql = g.value;
    }

    // Resolve a versão/imagem pelo Console ANTES do YAML e do registryAuth —
    // as duas etapas seguintes dependem do resultado (generateYaml monta
    // `image:` a partir daqui; registryAuth.images pré-puxa a mesma imagem).
    let effectiveCtx = input.swarmCtx;
    if (def.release) {
      try {
        const release = await fetchLatestRelease(
          def.release.baseUrl,
          def.release.app,
          def.release.edicao,
          def.release.canal
        );
        effectiveCtx = { ...input.swarmCtx, release };
        logAudit({
          user: input.user,
          ip: input.ip,
          action: "release.resolve",
          target: def.release.baseUrl,
          result: "ok",
          meta: { version: release.version, image_repo: release.imageRepo, image_tag: release.imageTag },
        });
      } catch (e) {
        const meta: Record<string, unknown> = {
          error: e instanceof Error ? e.message : "Erro desconhecido",
        };
        if (e instanceof ReleaseInfoError) {
          meta.reason = e.reason;
          if (e.httpStatus !== undefined) meta.httpStatus = e.httpStatus;
          if (e.serverDetail !== undefined) meta.serverDetail = e.serverDetail;
        }
        logAudit({
          user: input.user,
          ip: input.ip,
          action: "release.resolve.fail",
          target: def.release.baseUrl,
          result: "error",
          meta,
        });
        throw e;
      }
    }

    // Machine id + fingerprint de instalação — mesmo gate declarativo de
    // `release` acima (stacks com registryAuth são as que precisam de
    // licenciamento vinculado a ESTA VPS). Cunhado ANTES do generateYaml
    // porque o YAML e o exchange de registryAuth precisam do MESMO valor;
    // recalcular depois abriria a chance de divergir. Se um pareamento foi
    // resolvido acima, os valores vêm DELE (nunca recomputados) — é a
    // mesma dupla que o Console já vinculou. Sem pareamento (chave colada
    // à mão), `getOrCreateMachineId` decide (e já cuida de preservar o
    // fingerprint de uma instalação anterior, nunca cunhando um novo por
    // cima de uma stack já instalada).
    if (def.registryAuth) {
      if (pareamentoMachineId !== undefined && pareamentoFingerprint !== undefined) {
        effectiveCtx = { ...effectiveCtx, machineId: pareamentoMachineId, fingerprint: pareamentoFingerprint };
      } else if (ativacaoMachineId !== undefined && ativacaoFingerprint !== undefined) {
        effectiveCtx = { ...effectiveCtx, machineId: ativacaoMachineId, fingerprint: ativacaoFingerprint };
      } else {
        const { machineId, fingerprint } = getOrCreateMachineId(input.stackId, resolverAppHostname(def, "registryAuth"));
        effectiveCtx = { ...effectiveCtx, machineId, fingerprint };
      }
    }

    const yaml = def.generateYaml(parsed.data, secretMap, effectiveCtx);
    const { endpointId, swarmId } = await discoverContext(input.token);

    // Credencial de registro privado (ex.: GHCR) — precisa existir no
    // Portainer ANTES do deploy, é lá que ele resolve o EncodedRegistryAuth
    // por serviço. O pré-pull falha rápido se a chave não tiver acesso, em
    // vez de deixar as tasks presas em `pending` sem explicação.
    //
    // Extraído para registry-pull.ts (Ciclo 29) — mesmo comportamento
    // (3 tentativas, backoff, classificação de erro transitório, os dois
    // logAudit), reaproveitado pelo caminho de UPDATE
    // (stack-update-release.ts) sem duplicar a lógica.
    if (def.registryAuth) {
      const chave = String(parsed.data[def.registryAuth.licenseField] ?? "");
      await resolveRegistryAndPullImages({
        token: input.token,
        endpointId,
        user: input.user,
        ip: input.ip,
        registryAuth: def.registryAuth,
        chave,
        fingerprint: effectiveCtx.fingerprint,
        images: def.registryAuth.images(parsed.data, effectiveCtx.release),
      });
    }

    // Diretórios de bind mount no node manager — o Swarm não os cria sozinho.
    if (def.hostDirs?.length) {
      await ensureHostDirs(input.token, endpointId, def.hostDirs);
    }

    for (const vol of def.externalVolumes ?? []) {
      await ensureSwarmVolume(input.token, endpointId, vol);
    }
    for (const db of def.postgresDatabases ?? []) {
      await ensurePostgresDatabase(input.token, endpointId, db);
    }
    for (const { database, extensions } of def.postgresExtensions ?? []) {
      for (const ext of extensions) {
        await ensurePostgresExtension(input.token, endpointId, database, ext);
      }
    }
    const stack = await deploySwarmStack({
      token: input.token,
      name: input.stackId.replace(/-/g, "_"),
      yaml,
      swarmId,
      endpointId,
    });

    saveStackSecrets(input.stackId, stripTransient(parsed.data, def.transientFields), generated, def.transientFields);
    if (Object.keys(sharedToPersist).length > 0) saveSharedSecrets(sharedToPersist);

    // Só consome o pareamento DEPOIS do deploy ter sucesso — se o Console
    // caísse ou o deploy falhasse antes deste ponto, a chave continua
    // recuperável (cifrada em license_pairings) para uma nova tentativa,
    // em vez de perdida junto com uma sessão já marcada como usada.
    if (pareamentoId) consumirPareamento(pareamentoId);

    let aviso: string | undefined;
    if (pareamentoFingerprint && def.postInstall?.accessUrl) {
      aviso = await checarFingerprintPosDeploy(def.postInstall.accessUrl(parsed.data), pareamentoFingerprint);
    }

    logAudit({
      user: input.user,
      ip: input.ip,
      action: "stack.install",
      target: input.stackId,
      result: "ok",
      meta: { portainer_stack_id: stack.Id, ...(aviso ? { aviso_fingerprint: true } : {}) },
    });

    // Montado aqui (e não na rota) porque só aqui existe o secretMap efetivo
    // — com o valor reaproveitado de stack_secrets num reinstall, que é o
    // mesmo que foi para o env do app.
    const setupUrl = def.postInstall?.setupUrl?.(parsed.data, secretMap);

    return { ok: true, stack, generatedSecrets: generated, aviso, setupUrl };
  } catch (e) {
    const msg = e instanceof Error ? e.message : "Erro desconhecido";
    const { httpStatus, reason } = statusForCause(e);
    logAudit({
      user: input.user,
      ip: input.ip,
      action: "stack.install.fail",
      target: input.stackId,
      result: "error",
      meta: { error: msg, reason, httpStatus },
    });
    return { ok: false, error: msg, reason, httpStatus };
  }
}

export async function listInstalledStacks(token: string): Promise<Stack[]> {
  return listStacks(token);
}
