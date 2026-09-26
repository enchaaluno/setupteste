import { Agent, fetch as undiciFetch, FormData, File } from "undici";
import { jwtExpiryMs } from "./jwt";
import { lerSegredo } from "./security/segredo";

const PORTAINER_URL = process.env.PORTAINER_URL ?? "http://portainer:9000";
const TLS_INSECURE =
  process.env.PORTAINER_TLS_INSECURE === "1" && process.env.NODE_ENV !== "production";

const insecureAgent = TLS_INSECURE
  ? new Agent({ connect: { rejectUnauthorized: false } })
  : undefined;

type FetchOpts = {
  method?: "GET" | "POST" | "PUT" | "DELETE";
  token?: string;
  body?: unknown;
  formData?: FormData;
  headers?: Record<string, string>;
};

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AnyInit = Record<string, any>;

async function call<T>(path: string, opts: FetchOpts = {}): Promise<T> {
  const headers: Record<string, string> = { ...(opts.headers ?? {}) };
  if (opts.token) headers["Authorization"] = `Bearer ${opts.token}`;
  let body: string | FormData | undefined;
  if (opts.formData) {
    body = opts.formData;
  } else if (opts.body !== undefined) {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify(opts.body);
  }

  const init: AnyInit = {
    method: opts.method ?? "GET",
    headers,
  };
  if (body !== undefined) init.body = body;
  if (insecureAgent) init.dispatcher = insecureAgent;

  const res = await undiciFetch(`${PORTAINER_URL}${path}`, init);

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new PortainerError(res.status, text || `HTTP ${res.status}`);
  }

  const ct = res.headers.get("content-type") ?? "";
  if (ct.includes("application/json")) return (await res.json()) as T;
  return (await res.text()) as unknown as T;
}

// Variante que nunca faz JSON.parse do corpo — necessária para endpoints do Docker
// Engine que respondem `Content-Type: application/json` mas com corpo em NDJSON
// (várias linhas JSON), como `POST /images/create`. `call()` quebraria em `res.json()`
// mesmo num pull bem-sucedido; aqui devolvemos o texto cru para quem chama decidir.
async function callRaw(path: string, opts: FetchOpts = {}): Promise<{ status: number; text: string }> {
  const headers: Record<string, string> = { ...(opts.headers ?? {}) };
  if (opts.token) headers["Authorization"] = `Bearer ${opts.token}`;
  let body: string | FormData | undefined;
  if (opts.formData) {
    body = opts.formData;
  } else if (opts.body !== undefined) {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify(opts.body);
  }

  const init: AnyInit = {
    method: opts.method ?? "GET",
    headers,
  };
  if (body !== undefined) init.body = body;
  if (insecureAgent) init.dispatcher = insecureAgent;

  const res = await undiciFetch(`${PORTAINER_URL}${path}`, init);
  const text = await res.text().catch(() => "");
  if (!res.ok) throw new PortainerError(res.status, text || `HTTP ${res.status}`);
  return { status: res.status, text };
}

export class PortainerError extends Error {
  constructor(public status: number, message: string) {
    super(message);
    this.name = "PortainerError";
  }
}

export type AuthResult = { jwt: string };
export type Endpoint = { Id: number; Name: string; Type: number };
export type SwarmInfo = { ID: string };
export type StackEnvVar = { name: string; value: string };
export type Stack = {
  Id: number;
  Name: string;
  EndpointId: number;
  Status: number;
  CreationDate: number;
  Env?: StackEnvVar[];
};

export async function authenticate(username: string, password: string): Promise<string> {
  const r = await call<AuthResult>("/api/auth", {
    method: "POST",
    body: { username, password },
  });
  return r.jwt;
}

// ─────────────────────────────────────────────────────────────────────────
// Token de serviço — usado quando o painel tem admin local próprio
// (PANEL_ADMIN_USER setado, ver src/lib/auth/local-admin.ts). Em vez de
// carregar o JWT do usuário logado na sessão, o painel se autentica sozinho
// no Portainer com PORTAINER_USER/PORTAINER_PASSWORD e reaproveita esse
// token entre requisições até perto de expirar. Ver src/lib/auth/require-token.ts.
// ─────────────────────────────────────────────────────────────────────────

let cachedServiceToken: { jwt: string; expMs: number } | null = null;
let inflightServiceAuth: Promise<string> | null = null;

const SERVICE_TOKEN_SAFETY_MARGIN_MS = 60_000;
const SERVICE_TOKEN_DEFAULT_TTL_MS = 30 * 60_000;

export function invalidateServiceToken(): void {
  cachedServiceToken = null;
}

async function authenticateService(): Promise<string> {
  const user = process.env.PORTAINER_USER;
  // Resolvedor único (C3, M3) — env direta vence sobre PORTAINER_PASSWORD_FILE;
  // ver src/lib/security/segredo.ts. `hasServiceCredentials` (local-admin.ts)
  // usa o mesmo resolvedor, então os dois lugares nunca divergem sobre se a
  // credencial de serviço está disponível.
  const password = lerSegredo("PORTAINER_PASSWORD");
  if (!user || !password) {
    throw new PortainerError(
      503,
      "Credenciais de serviço do Portainer ausentes (PORTAINER_USER/PORTAINER_PASSWORD)"
    );
  }
  const jwt = await authenticate(user, password);
  const expMs = jwtExpiryMs(jwt) ?? Date.now() + SERVICE_TOKEN_DEFAULT_TTL_MS;
  cachedServiceToken = { jwt, expMs };
  return jwt;
}

export async function getServiceToken(): Promise<string> {
  if (cachedServiceToken && Date.now() < cachedServiceToken.expMs - SERVICE_TOKEN_SAFETY_MARGIN_MS) {
    return cachedServiceToken.jwt;
  }
  if (inflightServiceAuth) return inflightServiceAuth;
  inflightServiceAuth = authenticateService().finally(() => {
    inflightServiceAuth = null;
  });
  return inflightServiceAuth;
}

// Executa `fn` com o token de serviço, e tenta de novo UMA vez com token
// fresco se a chamada falhar por expiração/rejeição (401/403) — necessário
// porque operações longas (install de stack, pull de imagem) podem
// atravessar a expiração do JWT.
export async function withServiceToken<T>(fn: (token: string) => Promise<T>): Promise<T> {
  const token = await getServiceToken();
  try {
    return await fn(token);
  } catch (e) {
    if (e instanceof PortainerError && (e.status === 401 || e.status === 403)) {
      invalidateServiceToken();
      const fresh = await getServiceToken();
      return fn(fresh);
    }
    throw e;
  }
}

export async function listEndpoints(token: string): Promise<Endpoint[]> {
  return call<Endpoint[]>("/api/endpoints", { token });
}

export async function getSwarm(token: string, endpointId: number): Promise<SwarmInfo> {
  return call<SwarmInfo>(`/api/endpoints/${endpointId}/docker/swarm`, { token });
}

// Nó do Swarm, como a API do Docker Engine devolve em GET /nodes (via proxy
// do Portainer). `Status.Addr` existe em todo nó (manager ou worker) e é só
// o IP, sem porta — é o endereço que o Swarm usa para o próprio tráfego de
// cluster (gossip/VXLAN), por isso é o candidato natural pra allowlist do
// encha-guard (ver src/lib/swarm-guard.ts, `peersFromNodes`). `ManagerStatus`
// só existe em nós manager e o `Addr` ali costuma vir como "IP:porta"
// (porta de gestão do Swarm, 2377) — mantido aqui como alternativa/contexto
// extra, não como fonte primária.
export type DockerNode = {
  ID: string;
  Status: { Addr: string };
  ManagerStatus?: { Addr: string; Leader?: boolean };
};

export async function listNodes(token: string, endpointId: number): Promise<DockerNode[]> {
  return call<DockerNode[]>(`/api/endpoints/${endpointId}/docker/nodes`, { token });
}

export async function listStacks(token: string): Promise<Stack[]> {
  return call<Stack[]>("/api/stacks", { token });
}

export async function getStackById(token: string, id: number): Promise<Stack> {
  return call<Stack>(`/api/stacks/${id}`, { token });
}

export async function deploySwarmStack(args: {
  token: string;
  name: string;
  yaml: string;
  swarmId: string;
  endpointId: number;
}): Promise<Stack> {
  const fd = new FormData();
  fd.append("Name", args.name);
  fd.append("SwarmID", args.swarmId);
  fd.append("endpointId", String(args.endpointId));
  fd.append("file", new File([args.yaml], `${args.name}.yaml`, { type: "text/yaml" }));
  return call<Stack>("/api/stacks/create/swarm/file", {
    method: "POST",
    token: args.token,
    formData: fd,
  });
}

// Compose armazenado de uma stack criada/gerenciada pela API do Portainer
// (GET /api/stacks/{id}/file). Usado pelo self-update do painel para
// patchear PANEL_IMAGE_TAG sem perder o resto do compose nem o Env
// armazenado — ver src/lib/updater.ts.
export async function getStackFile(token: string, id: number): Promise<string> {
  const r = await call<{ StackFileContent: string }>(`/api/stacks/${id}/file`, { token });
  return r.StackFileContent;
}

export async function updateSwarmStack(
  token: string,
  id: number,
  endpointId: number,
  args: {
    stackFileContent: string;
    env: Array<{ name: string; value: string }>;
    prune?: boolean;
    pullImage?: boolean;
  }
): Promise<Stack> {
  return call<Stack>(`/api/stacks/${id}?endpointId=${endpointId}`, {
    method: "PUT",
    token,
    body: {
      StackFileContent: args.stackFileContent,
      Env: args.env,
      Prune: args.prune ?? false,
      PullImage: args.pullImage ?? true,
    },
  });
}

type DockerService = {
  Spec?: {
    Name?: string;
    Labels?: Record<string, string>;
    TaskTemplate?: { ContainerSpec?: { Image?: string } };
  };
  ServiceStatus?: { RunningTasks?: number; DesiredTasks?: number };
};

export type SwarmStackStatus = {
  name: string;
  desired: number;
  running: number;
  ready: boolean;
  /**
   * Imagem em execução por serviço, chaveada pelo nome completo no Swarm
   * (ex.: "evolution_evolution_api"). Sai de graça: já percorremos todos os
   * services aqui, então detectar atualização não custa chamada extra.
   * O Docker devolve a imagem com digest anexado
   * ("repo:tag@sha256:..."), então compare sempre com `stripDigest`.
   */
  images: Record<string, string>;
};

/**
 * Remove o "@sha256:..." que o Docker anexa à imagem em execução. Sem isso
 * toda comparação com a imagem-alvo daria "diferente" e o painel ofereceria
 * uma atualização que não existe.
 */
export function stripDigest(image: string): string {
  const at = image.indexOf("@");
  return at === -1 ? image : image.slice(0, at);
}

export async function listSwarmStackStatuses(
  token: string,
  endpointId: number
): Promise<SwarmStackStatus[]> {
  const services = await call<DockerService[]>(
    `/api/endpoints/${endpointId}/docker/services?status=true`,
    { token }
  );
  const byStack = new Map<
    string,
    { desired: number; running: number; images: Record<string, string> }
  >();
  for (const svc of services) {
    const ns = svc.Spec?.Labels?.["com.docker.stack.namespace"];
    if (!ns) continue;
    const cur = byStack.get(ns) ?? { desired: 0, running: 0, images: {} };
    cur.desired += svc.ServiceStatus?.DesiredTasks ?? 0;
    cur.running += svc.ServiceStatus?.RunningTasks ?? 0;
    const svcName = svc.Spec?.Name;
    const image = svc.Spec?.TaskTemplate?.ContainerSpec?.Image;
    if (svcName && image) cur.images[svcName] = stripDigest(image);
    byStack.set(ns, cur);
  }
  return Array.from(byStack.entries()).map(([name, s]) => ({
    name,
    desired: s.desired,
    running: s.running,
    ready: s.desired === 0 || s.running >= s.desired,
    images: s.images,
  }));
}

// Service completo do Docker Engine API (subset que usamos para o self-update).
export type DockerServiceFull = {
  ID: string;
  Version: { Index: number };
  Spec: {
    Name?: string;
    Labels?: Record<string, string>;
    TaskTemplate?: {
      ContainerSpec?: { Image?: string };
      // demais campos preservados via spread ao reenviar
      [k: string]: unknown;
    };
    [k: string]: unknown;
  };
};

// Encontra um service Swarm pelo nome (ex: "encha-panel_panel"), via proxy Docker do Portainer.
export async function getServiceByName(
  token: string,
  endpointId: number,
  name: string
): Promise<DockerServiceFull | null> {
  const filters = encodeURIComponent(JSON.stringify({ name: [name] }));
  const services = await call<DockerServiceFull[]>(
    `/api/endpoints/${endpointId}/docker/services?filters=${filters}`,
    { token }
  );
  // O filtro `name` do Docker é prefixo; casa exatamente pelo Spec.Name.
  return services.find((s) => s.Spec?.Name === name) ?? services[0] ?? null;
}

// Mesma busca de getServiceByName, mas SEM o fallback `?? services[0]`.
// Existe por um bug real daquela função: o filtro `name` da API do Docker é
// por PREFIXO, então buscar "encha-guard" quando só existe um serviço
// "encha-guard-teste" devolve esse serviço na lista — e `getServiceByName`
// cai nele via `?? services[0]` em vez de sinalizar ausência. Para um
// algoritmo idempotente (ex.: o guard do C6, que decide "criar" vs
// "atualizar" com base em existir ou não um serviço de nome EXATO), esse
// fallback é perigoso: atualizaria um serviço errado pensando ser o
// gerenciado. `getServiceByName` continua como está (usada hoje só onde o
// fallback nunca importa, ex. `resolvePanelNodeConstraint` contra o nome
// fixo `encha-panel_panel`) — este helper é adicional, não substitui aquele.
export async function getServiceExact(
  token: string,
  endpointId: number,
  name: string
): Promise<DockerServiceFull | null> {
  const filters = encodeURIComponent(JSON.stringify({ name: [name] }));
  const services = await call<DockerServiceFull[]>(
    `/api/endpoints/${endpointId}/docker/services?filters=${filters}`,
    { token }
  );
  return services.find((s) => s.Spec?.Name === name) ?? null;
}

// ─────────────────────────────────────────────────────────────────────────
// Spec completo de SERVIÇO Swarm de longa duração (ex.: `encha-guard`,
// C5/C6) — superset do ContainerSpec/TaskTemplate usados por SwarmJobSpec
// (jobs efêmeros de uma execução, ver mais abaixo). Reaproveita os mesmos
// nomes de campo já usados ali (Image/Command/Args/Env/User/TTY/Labels/
// Mounts, e o tipo SwarmJobMount) e acrescenta só o que job avulso nunca
// precisou: capacidades Linux, filesystem somente-leitura, healthcheck
// (para desativar o herdado da imagem), rede explícita, política de
// restart de serviço de vida longa (Condition "any", com Delay) e limites
// de recursos. Não duplica SwarmJobSpec — os dois convivem porque modelam
// coisas diferentes (job de uma execução vs. serviço sempre-rodando).
// ─────────────────────────────────────────────────────────────────────────

export type ServiceContainerSpec = {
  Image: string;
  Command?: string[];
  Args?: string[];
  Env?: string[];
  User?: string;
  TTY?: boolean;
  Labels?: Record<string, string>;
  Mounts?: SwarmJobMount[];
  CapabilityAdd?: string[];
  CapabilityDrop?: string[];
  ReadOnly?: boolean;
  Healthcheck?: { Test: string[] };
};

export type NetworkAttachmentConfig = { Target: string };

// `Delay`/`Window` em NANOSSEGUNDOS — é assim que a API do Docker Engine
// modela toda duração em TaskSpec.RestartPolicy (mesma unidade usada em
// `docker service inspect`, campo `RestartPolicy.Delay`), nunca como string
// tipo "5s" (isso é só a notação da CLI `docker service create --restart-delay`,
// que a CLI converte para nanossegundos antes de enviar à API).
export type ServiceRestartPolicy = {
  Condition: "none" | "any" | "on-failure";
  Delay?: number;
  MaxAttempts?: number;
  Window?: number;
};

export type ServiceMode =
  | { Global: Record<string, never> }
  | { Replicated: { Replicas: number } }
  | { ReplicatedJob: { MaxConcurrent: number; TotalCompletions: number } };

export type ServiceSpec = {
  Name: string;
  Labels?: Record<string, string>;
  Mode: ServiceMode;
  TaskTemplate: {
    ContainerSpec: ServiceContainerSpec;
    Networks?: NetworkAttachmentConfig[];
    RestartPolicy?: ServiceRestartPolicy;
    Placement?: { Constraints?: string[] };
    Resources?: { Limits?: { NanoCPUs?: number; MemoryBytes?: number } };
  };
};

// Cria um serviço Swarm a partir de um spec completo (ex.: o `encha-guard`
// montado por `montarSpecGuarda`, src/lib/swarm-guard.ts). Quem decide
// QUANDO criar/atualizar é o C6 — este helper só faz a chamada.
export async function createService(
  token: string,
  endpointId: number,
  spec: ServiceSpec
): Promise<{ ID: string }> {
  return call<{ ID: string }>(`/api/endpoints/${endpointId}/docker/services/create`, {
    method: "POST",
    token,
    body: spec,
  });
}

// Atualiza um serviço Swarm existente com um spec completo. `version` é o
// `Version.Index` lido do serviço ANTES desta chamada (ver DockerServiceFull)
// — a API do Docker exige esse número pra detectar corrida com outra
// atualização concorrente e recusa (409) se estiver desatualizado.
export async function updateService(
  token: string,
  endpointId: number,
  serviceId: string,
  version: number,
  spec: ServiceSpec
): Promise<void> {
  await call(`/api/endpoints/${endpointId}/docker/services/${serviceId}/update?version=${version}`, {
    method: "POST",
    token,
    body: spec,
  });
}

// Atualiza a imagem de um service preservando o restante do Spec (rolling update no Swarm).
export async function updateServiceImage(
  token: string,
  endpointId: number,
  service: DockerServiceFull,
  newImage: string
): Promise<void> {
  const spec = {
    ...service.Spec,
    TaskTemplate: {
      ...service.Spec.TaskTemplate,
      ContainerSpec: {
        ...service.Spec.TaskTemplate?.ContainerSpec,
        Image: newImage,
      },
    },
  };
  await call(
    `/api/endpoints/${endpointId}/docker/services/${service.ID}/update?version=${service.Version.Index}`,
    { method: "POST", token, body: spec }
  );
}

export async function ensureSwarmVolume(
  token: string,
  endpointId: number,
  name: string
): Promise<void> {
  try {
    await call(`/api/endpoints/${endpointId}/docker/volumes/create`, {
      method: "POST",
      token,
      body: { Name: name, Driver: "local" },
    });
  } catch (e) {
    // 409 = volume já existe, ok
    if (!(e instanceof PortainerError) || e.status !== 409) throw e;
  }
}

type DockerContainer = { Id: string; State?: string };
type ExecCreateResponse = { Id: string };
type ExecInspect = { ExitCode: number | null };

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

// Acha o container em execução de um service Swarm (ex: "postgres_postgres") via label do Docker.
async function findRunningContainerId(
  token: string,
  endpointId: number,
  serviceName: string
): Promise<string | null> {
  const filters = encodeURIComponent(
    JSON.stringify({
      label: [`com.docker.swarm.service.name=${serviceName}`],
      status: ["running"],
    })
  );
  const containers = await call<DockerContainer[]>(
    `/api/endpoints/${endpointId}/docker/containers/json?filters=${filters}`,
    { token }
  );
  return containers[0]?.Id ?? null;
}

// Espera o container do service ficar `running` (mitiga corrida no deploy em 2 estágios).
async function waitForRunningContainer(
  token: string,
  endpointId: number,
  serviceName: string,
  opts: { retries?: number; delayMs?: number } = {}
): Promise<string> {
  const retries = opts.retries ?? 10;
  const delayMs = opts.delayMs ?? 3000;
  for (let attempt = 1; attempt <= retries; attempt++) {
    const id = await findRunningContainerId(token, endpointId, serviceName);
    if (id) return id;
    if (attempt < retries) await sleep(delayMs);
  }
  throw new Error(
    `Serviço ${serviceName} não está rodando — instale/aguarde a stack correspondente antes de continuar`
  );
}

// Roda um comando dentro de um container via Docker exec (proxy Docker do Portainer).
async function dockerExec(
  token: string,
  endpointId: number,
  containerId: string,
  cmd: string[]
): Promise<{ exitCode: number; output: string }> {
  const created = await call<ExecCreateResponse>(
    `/api/endpoints/${endpointId}/docker/containers/${containerId}/exec`,
    {
      method: "POST",
      token,
      body: { AttachStdout: true, AttachStderr: true, Tty: false, Cmd: cmd },
    }
  );
  const output = await call<string>(`/api/endpoints/${endpointId}/docker/exec/${created.Id}/start`, {
    method: "POST",
    token,
    body: { Detach: false, Tty: false },
  });
  const inspect = await call<ExecInspect>(`/api/endpoints/${endpointId}/docker/exec/${created.Id}/json`, {
    token,
  });
  return { exitCode: inspect.ExitCode ?? 0, output: typeof output === "string" ? output : "" };
}

const POSTGRES_SERVICE_NAME = "postgres_postgres";

// Garante que um banco exista no Postgres compartilhado — idempotente, nunca dropa dados.
export async function ensurePostgresDatabase(
  token: string,
  endpointId: number,
  dbName: string
): Promise<void> {
  if (!/^[a-zA-Z0-9_]+$/.test(dbName)) {
    throw new Error(`Nome de banco inválido: "${dbName}"`);
  }

  const containerId = await waitForRunningContainer(token, endpointId, POSTGRES_SERVICE_NAME);

  const sql =
    `psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${dbName}'" | grep -q 1 ` +
    `|| psql -U postgres -c "CREATE DATABASE ${dbName}"`;
  const { exitCode, output } = await dockerExec(token, endpointId, containerId, ["sh", "-c", sql]);

  if (exitCode !== 0) {
    throw new PortainerError(500, `Falha ao criar banco '${dbName}': ${output || `exit code ${exitCode}`}`);
  }
}

// Garante uma extensão num banco do Postgres compartilhado — idempotente
// (CREATE EXTENSION IF NOT EXISTS). Chamado depois de ensurePostgresDatabase
// para o mesmo banco. Mesma validação de dbName; extension passa pelo mesmo
// regex (nomes de extensão do Postgres também são identificadores simples) —
// nunca interpolar input de usuário aqui sem essa checagem.
export async function ensurePostgresExtension(
  token: string,
  endpointId: number,
  dbName: string,
  extension: string
): Promise<void> {
  if (!/^[a-zA-Z0-9_]+$/.test(dbName)) {
    throw new Error(`Nome de banco inválido: "${dbName}"`);
  }
  if (!/^[a-zA-Z0-9_]+$/.test(extension)) {
    throw new Error(`Nome de extensão inválido: "${extension}"`);
  }

  const containerId = await waitForRunningContainer(token, endpointId, POSTGRES_SERVICE_NAME);

  const sql = `psql -U postgres -d ${dbName} -c "CREATE EXTENSION IF NOT EXISTS ${extension}"`;
  const { exitCode, output } = await dockerExec(token, endpointId, containerId, ["sh", "-c", sql]);

  if (exitCode !== 0) {
    throw new PortainerError(
      500,
      `Falha ao criar extensão '${extension}' no banco '${dbName}': ${output || `exit code ${exitCode}`}`
    );
  }
}

export async function pingPortainer(): Promise<boolean> {
  try {
    const init: AnyInit = {};
    if (insecureAgent) init.dispatcher = insecureAgent;
    const res = await undiciFetch(`${PORTAINER_URL}/api/system/status`, init);
    return res.ok;
  } catch {
    return false;
  }
}

export async function discoverContext(
  token: string
): Promise<{ endpointId: number; swarmId: string }> {
  const endpoints = await listEndpoints(token);
  if (!endpoints.length) throw new Error("Nenhum endpoint Portainer encontrado");
  const endpointId = endpoints[0].Id;
  const swarm = await getSwarm(token, endpointId);
  return { endpointId, swarmId: swarm.ID };
}

// ─────────────────────────────────────────────────────────────────────────
// Containers avulsos (one-shot) — usado pelo updater de scripts do host
// (src/lib/host-updater.ts). O painel não tem docker.sock nem é privilegiado;
// tudo isto passa pela API do Portainer com o JWT do usuário logado.
// ─────────────────────────────────────────────────────────────────────────

// Confere se uma imagem já está presente no node (evita pull desnecessário —
// o caminho principal do updater de scripts usa a própria imagem do painel,
// que por definição já está no node que está atendendo a requisição).
export async function imageExistsLocally(
  token: string,
  endpointId: number,
  image: string
): Promise<boolean> {
  try {
    await call(`/api/endpoints/${endpointId}/docker/images/${encodeURIComponent(image)}/json`, {
      token,
    });
    return true;
  } catch (e) {
    if (e instanceof PortainerError && e.status === 404) return false;
    throw e;
  }
}

// Pull de imagem — usado tanto no fallback do updater de scripts (imagem
// pública) quanto no pré-pull de imagens privadas antes de instalar uma
// stack (com credencial de registry, ver pullImageWithRegistry). `POST
// /images/create` responde 200 com um stream NDJSON mesmo quando o pull
// falha no meio; a falha aparece como uma linha com chave "error". callRaw()
// é obrigatório aqui — call() quebraria em res.json().
async function pullImageRaw(
  token: string,
  endpointId: number,
  image: string,
  headers?: Record<string, string>
): Promise<void> {
  const sep = image.lastIndexOf(":");
  // lastIndexOf evita cortar no host quando a imagem tem registry com porta;
  // aqui não há porta, mas é mais seguro que split(":")[0].
  const repo = sep > image.lastIndexOf("/") ? image.slice(0, sep) : image;
  const tag = sep > image.lastIndexOf("/") ? image.slice(sep + 1) : "latest";
  const { text } = await callRaw(
    `/api/endpoints/${endpointId}/docker/images/create` +
      `?fromImage=${encodeURIComponent(repo)}&tag=${encodeURIComponent(tag)}`,
    { method: "POST", token, headers }
  );
  const lines = text.split("\n").filter(Boolean);
  for (const line of lines) {
    try {
      const obj = JSON.parse(line);
      if (obj?.error) throw new PortainerError(500, `Falha no pull de ${image}: ${obj.error}`);
    } catch (e) {
      if (e instanceof PortainerError) throw e;
      // linha não-JSON isolada — ignora, não é indicativo de erro
    }
  }
}

export async function pullImage(token: string, endpointId: number, image: string): Promise<void> {
  return pullImageRaw(token, endpointId, image);
}

// Pull autenticado — usado antes de instalar stacks com imagem privada (ex.:
// EnchaT). O header X-Registry-Auth só é reescrito pelo proxy do Portainer
// quando o JSON decodificado contém "registryId" (ele troca pela credencial
// real do registry cadastrado); credencial crua passaria direto e quebraria
// por incompatibilidade de encoding entre o Portainer e o daemon Docker.
export async function pullImageWithRegistry(
  token: string,
  endpointId: number,
  image: string,
  registryId: number
): Promise<void> {
  const auth = Buffer.from(JSON.stringify({ registryId })).toString("base64");
  return pullImageRaw(token, endpointId, image, { "X-Registry-Auth": auth });
}

// ─────────────────────────────────────────────────────────────────────────
// Registries privados (ex.: GHCR) — necessário para o `docker stack deploy`
// nativo do Portainer anexar EncodedRegistryAuth às tasks de imagem privada.
// GET/POST/PUT exigem usuário admin do Portainer.
// ─────────────────────────────────────────────────────────────────────────

export type PortainerRegistry = {
  Id: number;
  Name: string;
  URL: string;
  Type: number;
  Authentication: boolean;
  Username: string;
};

export async function listRegistries(token: string): Promise<PortainerRegistry[]> {
  return call<PortainerRegistry[]>("/api/registries", { token });
}

// Type 3 = CustomRegistry. NÃO usar 8 (GithubRegistry) — o Validate() do
// Portainer rejeita esse tipo no create com 400. URL deve ser o host exato
// ("ghcr.io", sem esquema/barra) — o deploy casa por igualdade de string
// contra o domínio da imagem.
export async function createRegistry(
  token: string,
  p: { name: string; url: string; username: string; password: string }
): Promise<PortainerRegistry> {
  return call<PortainerRegistry>("/api/registries", {
    method: "POST",
    token,
    body: {
      Name: p.name,
      Type: 3,
      URL: p.url,
      Authentication: true,
      Username: p.username,
      Password: p.password,
      TLS: true,
    },
  });
}

export async function updateRegistry(
  token: string,
  id: number,
  p: { name: string; url: string; username: string; password: string }
): Promise<PortainerRegistry> {
  return call<PortainerRegistry>(`/api/registries/${id}`, {
    method: "PUT",
    token,
    body: {
      Name: p.name,
      URL: p.url,
      Authentication: true,
      Username: p.username,
      Password: p.password,
    },
  });
}

export type ContainerSpec = {
  Image: string;
  Entrypoint?: string[];
  Cmd?: string[];
  Env?: string[];
  User?: string;
  Tty?: boolean;
  Labels?: Record<string, string>;
  HostConfig: {
    Binds?: string[];
    AutoRemove?: boolean;
    NetworkMode?: string;
    Privileged?: boolean;
    RestartPolicy?: { Name: string };
  };
};

export async function createContainer(
  token: string,
  endpointId: number,
  name: string,
  spec: ContainerSpec
): Promise<{ Id: string }> {
  return call<{ Id: string }>(
    `/api/endpoints/${endpointId}/docker/containers/create?name=${encodeURIComponent(name)}`,
    { method: "POST", token, body: spec }
  );
}

export async function startContainer(token: string, endpointId: number, id: string): Promise<void> {
  await call(`/api/endpoints/${endpointId}/docker/containers/${id}/start`, {
    method: "POST",
    token,
  });
}

type ContainerInspect = {
  State?: { Running?: boolean; ExitCode?: number; Status?: string; Error?: string };
};

export async function inspectContainer(
  token: string,
  endpointId: number,
  id: string
): Promise<ContainerInspect> {
  return call<ContainerInspect>(`/api/endpoints/${endpointId}/docker/containers/${id}/json`, {
    token,
  });
}

// Espera o container sair via polling (NÃO usa `POST /containers/{id}/wait`,
// que bloqueia a requisição HTTP sem timeout configurado — arriscado atrás de
// Traefik/Portainer). Teto de ~2min; em timeout, força remoção e devolve exitCode -1.
export async function waitForContainerExit(
  token: string,
  endpointId: number,
  id: string,
  opts: { timeoutMs?: number; intervalMs?: number } = {}
): Promise<{ exitCode: number; timedOut: boolean }> {
  const timeoutMs = opts.timeoutMs ?? 120_000;
  const intervalMs = opts.intervalMs ?? 2000;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const info = await inspectContainer(token, endpointId, id);
    if (info.State?.Running === false) {
      return { exitCode: info.State.ExitCode ?? -1, timedOut: false };
    }
    await sleep(intervalMs);
  }
  return { exitCode: -1, timedOut: true };
}

export async function getContainerLogs(
  token: string,
  endpointId: number,
  id: string,
  tail = 200
): Promise<string> {
  const { text } = await callRaw(
    `/api/endpoints/${endpointId}/docker/containers/${id}/logs?stdout=1&stderr=1&tail=${tail}`,
    { token }
  );
  return text;
}

export async function removeContainer(
  token: string,
  endpointId: number,
  id: string
): Promise<void> {
  try {
    await call(`/api/endpoints/${endpointId}/docker/containers/${id}?force=1&v=1`, {
      method: "DELETE",
      token,
    });
  } catch (e) {
    // 404 = já não existe — ok, alvo era remover.
    if (!(e instanceof PortainerError) || e.status !== 404) throw e;
  }
}

// Varre containers órfãos de execuções anteriores que travaram e nunca foram
// removidos (crash do painel a meio do passo, timeout, etc.) — evita que o
// nome fixo do container fique permanentemente "ocupado" (409 no create).
export async function listContainersByLabel(
  token: string,
  endpointId: number,
  label: string
): Promise<Array<{ Id: string; Names?: string[]; Created?: number }>> {
  const filters = encodeURIComponent(JSON.stringify({ label: [label], all: ["true"] }));
  return call(`/api/endpoints/${endpointId}/docker/containers/json?all=1&filters=${filters}`, {
    token,
  });
}

// Cria, roda até o fim, coleta logs e remove um container avulso (one-shot).
// Sempre remove em `finally` — mesmo em erro/timeout — para não vazar o nome
// nem deixar processo root-equivalente pendurado no host.
export async function runOneShotContainer(
  token: string,
  endpointId: number,
  args: { name: string; label: string; spec: ContainerSpec; timeoutMs?: number }
): Promise<{ exitCode: number; logs: string; timedOut: boolean }> {
  // Varredura de órfãos com o mesmo label antes de criar um novo.
  const orphans = await listContainersByLabel(token, endpointId, args.label);
  for (const o of orphans) {
    await removeContainer(token, endpointId, o.Id);
  }

  const { Id } = await createContainer(token, endpointId, args.name, {
    ...args.spec,
    HostConfig: { ...args.spec.HostConfig, AutoRemove: false },
  });

  try {
    await startContainer(token, endpointId, Id);
    const { exitCode, timedOut } = await waitForContainerExit(token, endpointId, Id, {
      timeoutMs: args.timeoutMs,
    });
    const logs = await getContainerLogs(token, endpointId, Id).catch(() => "");
    return { exitCode, logs, timedOut };
  } finally {
    await removeContainer(token, endpointId, Id).catch(() => {});
  }
}

// ---------------------------------------------------------------------------
// Job avulso via Swarm (services/create com Mode.ReplicatedJob) — substitui
// createContainer+startContainer para evitar um bug do proxy Portainer/agent:
// `POST .../containers/{id}/start` SEM corpo sai como `Content-Length: 0` do
// painel (confirmado com undici), mas em Go um request de saída com
// `ContentLength == 0` e `Body` não-nulo é tratado como tamanho desconhecido
// e reencodado como `Transfer-Encoding: chunked` — o Docker rejeita isso em
// `/start` com "starting container with non-empty request body was
// deprecated since API v1.22 and removed in v1.24". Todo POST para
// services/create SEMPRE leva corpo JSON, então nunca bate nesse caminho.

export type SwarmJobMount = { Type: "bind"; Source: string; Target: string; ReadOnly?: boolean };

export type SwarmJobSpec = {
  Name: string;
  Labels?: Record<string, string>;
  TaskTemplate: {
    ContainerSpec: {
      Image: string;
      Command?: string[];
      Args?: string[];
      Env?: string[];
      User?: string;
      TTY?: boolean;
      Labels?: Record<string, string>;
      Mounts?: SwarmJobMount[];
    };
    RestartPolicy: { Condition: "none" };
    Placement?: { Constraints?: string[] };
  };
  Mode: { ReplicatedJob: { MaxConcurrent: number; TotalCompletions: number } };
};

// Converte o ContainerSpec (usado hoje pelo caminho de container avulso) num
// SwarmJobSpec equivalente. Função pura — ver portainer-job-spec.test.ts.
// `NetworkMode`, `AutoRemove` e `Privileged:false` não têm equivalente/uso
// aqui: `Privileged:false` já é o default, e o Swarm sempre limpa a task ao
// remover o service.
//
// NÃO fixar `Networks: []` no ServiceSpec: o script do updater faz I/O
// externo (wget no codeload). Sem `Networks` explícito, o Docker anexa o
// service à rede `ingress` por padrão — igual a qualquer outro service Swarm
// sem `--network` — e essa rede tem saída via docker_gwbridge/NAT no node,
// dando acesso à internet mesmo sem publicar porta nenhuma (confirmado:
// não é um "sem rede nenhuma" como pareceria à primeira vista comparando com
// o antigo `NetworkMode: "bridge"` de container avulso).
export function containerSpecToServiceSpec(
  name: string,
  spec: ContainerSpec,
  constraints: string[]
): SwarmJobSpec {
  const mounts: SwarmJobMount[] = (spec.HostConfig.Binds ?? []).map((bind) => {
    const [source, target, mode] = bind.split(":");
    return { Type: "bind", Source: source, Target: target, ReadOnly: mode === "ro" };
  });

  return {
    Name: name,
    Labels: spec.Labels,
    TaskTemplate: {
      ContainerSpec: {
        Image: spec.Image,
        Command: spec.Entrypoint,
        Args: spec.Cmd,
        Env: spec.Env,
        User: spec.User,
        TTY: spec.Tty,
        Labels: spec.Labels,
        Mounts: mounts.length ? mounts : undefined,
      },
      RestartPolicy: { Condition: "none" },
      Placement: constraints.length ? { Constraints: constraints } : undefined,
    },
    Mode: { ReplicatedJob: { MaxConcurrent: 1, TotalCompletions: 1 } },
  };
}

export async function createSwarmJob(
  token: string,
  endpointId: number,
  spec: SwarmJobSpec
): Promise<{ ID: string }> {
  return call<{ ID: string }>(`/api/endpoints/${endpointId}/docker/services/create`, {
    method: "POST",
    token,
    body: spec,
  });
}

export type SwarmTask = {
  ID: string;
  ServiceID: string;
  NodeID?: string;
  DesiredState?: string;
  Status?: {
    State?: string;
    Err?: string;
    Timestamp?: string;
    ContainerStatus?: { ContainerID?: string; ExitCode?: number };
  };
};

export async function listServiceTasks(
  token: string,
  endpointId: number,
  serviceId: string
): Promise<SwarmTask[]> {
  const filters = encodeURIComponent(JSON.stringify({ service: [serviceId] }));
  return call<SwarmTask[]>(`/api/endpoints/${endpointId}/docker/tasks?filters=${filters}`, {
    token,
  });
}

const TERMINAL_TASK_STATES = new Set(["complete", "failed", "rejected", "shutdown", "orphaned"]);

// Classifica o conjunto de tasks de um service Swarm (função pura — testável
// sem rede). Escolhe a task mais recente por Status.Timestamp e devolve o
// exit code se ela já chegou num estado terminal.
export function taskOutcome(tasks: SwarmTask[]): { done: false } | { done: true; exitCode: number } {
  if (!tasks.length) return { done: false };
  const newest = [...tasks].sort((a, b) =>
    (b.Status?.Timestamp ?? "").localeCompare(a.Status?.Timestamp ?? "")
  )[0];
  const state = newest.Status?.State ?? "";
  if (!TERMINAL_TASK_STATES.has(state)) return { done: false };
  if (state === "complete") {
    return { done: true, exitCode: newest.Status?.ContainerStatus?.ExitCode ?? 0 };
  }
  return { done: true, exitCode: newest.Status?.ContainerStatus?.ExitCode ?? -1 };
}

export async function getServiceLogs(
  token: string,
  endpointId: number,
  serviceId: string,
  tail = 200
): Promise<string> {
  const { text } = await callRaw(
    `/api/endpoints/${endpointId}/docker/services/${serviceId}/logs?stdout=1&stderr=1&tail=${tail}`,
    { token }
  );
  return text;
}

export async function removeService(token: string, endpointId: number, serviceId: string): Promise<void> {
  try {
    await call(`/api/endpoints/${endpointId}/docker/services/${serviceId}`, {
      method: "DELETE",
      token,
    });
  } catch (e) {
    // 404 = já não existe — ok, alvo era remover.
    if (!(e instanceof PortainerError) || e.status !== 404) throw e;
  }
}

export async function listServicesByLabel(
  token: string,
  endpointId: number,
  label: string
): Promise<Array<{ ID: string }>> {
  const filters = encodeURIComponent(JSON.stringify({ label: [label] }));
  return call(`/api/endpoints/${endpointId}/docker/services?filters=${filters}`, { token });
}

// Resolve o NodeID onde o próprio service do painel está rodando, para
// constranger o job avulso a esse nó exato — mais seguro que
// `node.role == manager` num cluster com mais de um manager, onde o job
// poderia cair num manager cujo /root é um filesystem diferente do que o
// painel está rodando. Cai para `node.role == manager` se não conseguir
// resolver (comportamento de hoje, correto em cluster de manager único).
export async function resolvePanelNodeConstraint(token: string, endpointId: number): Promise<string[]> {
  try {
    const service = await getServiceByName(token, endpointId, "encha-panel_panel");
    if (!service) return ["node.role == manager"];
    const tasks = await listServiceTasks(token, endpointId, service.ID);
    const running = tasks.find((t) => t.Status?.State === "running" && t.NodeID);
    return running?.NodeID ? [`node.id == ${running.NodeID}`] : ["node.role == manager"];
  } catch {
    return ["node.role == manager"];
  }
}

// Cria, roda até o fim, coleta logs e remove um job avulso do Swarm — mesmo
// contrato de retorno de runOneShotContainer, para que os chamadores só
// troquem o nome da função. Se o ambiente não suportar services/create com
// Mode.ReplicatedJob (Swarm não iniciado, ou Docker Engine antigo pré-1.41 —
// possível pelo fallback de instalação sem pin em secondary.sh), cai de
// volta para o caminho de container avulso.
export async function runOneShotJob(
  token: string,
  endpointId: number,
  args: { name: string; label: string; spec: ContainerSpec; timeoutMs?: number; constraints?: string[] }
): Promise<{ exitCode: number; logs: string; timedOut: boolean }> {
  const orphans = await listServicesByLabel(token, endpointId, args.label);
  for (const o of orphans) {
    await removeService(token, endpointId, o.ID);
  }

  const constraints = args.constraints ?? (await resolvePanelNodeConstraint(token, endpointId));
  const jobSpec = containerSpecToServiceSpec(args.name, args.spec, constraints);

  let serviceId: string;
  try {
    ({ ID: serviceId } = await createSwarmJob(token, endpointId, jobSpec));
  } catch (e) {
    // Ambiente sem suporte a job do Swarm — volta ao caminho de container avulso.
    if (e instanceof PortainerError && [400, 404, 501].includes(e.status)) {
      return runOneShotContainer(token, endpointId, args);
    }
    throw e;
  }

  const timeoutMs = args.timeoutMs ?? 120_000;
  const intervalMs = 2000;
  const deadline = Date.now() + timeoutMs;
  try {
    let exitCode = -1;
    let timedOut = true;
    while (Date.now() < deadline) {
      const tasks = await listServiceTasks(token, endpointId, serviceId);
      const outcome = taskOutcome(tasks);
      if (outcome.done) {
        exitCode = outcome.exitCode;
        timedOut = false;
        break;
      }
      await sleep(intervalMs);
    }
    const logs = await getServiceLogs(token, endpointId, serviceId).catch(() => "");
    return { exitCode, logs, timedOut };
  } finally {
    await removeService(token, endpointId, serviceId).catch(() => {});
  }
}
