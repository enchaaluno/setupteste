import { hasServiceCredentials } from "./auth/local-admin";
import {
  createService,
  discoverContext,
  getHostNetworkId,
  getServiceExact,
  listNodes,
  PortainerError,
  withServiceToken,
  updateService,
  type DockerServiceFull,
  type ServiceSpec,
} from "./portainer";
import {
  compararEnv,
  compararNetworks,
  desativadoNaoReconhecido,
  especificacaoDesejada,
  GUARD_SERVICE_NAME,
  peersFromNodes,
} from "./swarm-guard";

// Ciclo C6 do plano de segurança (achado A1) — a COLA que decide QUANDO
// criar/atualizar o serviço Swarm `encha-guard` e ONDE isso roda no painel
// (instrumentation.ts, no boot; e no login legado, sem credencial de
// serviço). Builder puro + comparação: src/lib/swarm-guard.ts. Helpers de
// baixo nível contra a API do Portainer: src/lib/portainer.ts (C5).
//
// TUDO aqui é "melhor esforço": nunca deixa um erro subir e derrubar quem
// chamou (o boot do painel, ou a resposta de login) — loga e a próxima
// janela (20s → 6h, ver `inicializarGarantiaGuardaSwarm`) tenta de novo.

// Nome do service Swarm do próprio painel — de onde lemos a imagem
// canônica (`repo:tag@sha256:...`) que o `encha-guard` vai rodar (nunca
// reconstruída a partir de ENCHA_VERSION/APP_VERSION, ver
// src/lib/swarm-guard.ts). Não existe hoje, no painel ou em nenhuma
// dependência (undici/Docker Engine API), uma forma de um processo
// descobrir sozinho "o nome do service Swarm que me contém" a partir do
// próprio HOSTNAME/container ID sem UMA chamada extra por container
// (`GET /containers/{id}/json` já dentro do proxy do Portainer, e ainda
// assim o Docker não expõe o nome do SERVICE nesse endpoint — só
// `com.docker.swarm.service.name` num container já em execução, que é
// exatamente o problema que estamos tentando resolver pra outra coisa).
// `updater.ts`/`resolvePanelNodeConstraint` (ambos pré-C6) já assumem o
// nome fixo "encha-panel_panel" sem essa descoberta — aqui em vez de repetir
// o mesmo hardcode uma TERCEIRA vez, ele fica configurável por
// `ENCHA_PANEL_SERVICE_NAME`, com esse hardcode como fallback (mesmo valor
// dos outros dois lugares, então nenhuma instalação existente precisa
// definir a env var pra continuar funcionando).
const PANEL_SERVICE_NOME_PADRAO = "encha-panel_panel";

function nomeServicoDoPainel(): string {
  return process.env.ENCHA_PANEL_SERVICE_NAME?.trim() || PANEL_SERVICE_NOME_PADRAO;
}

const ROLE_LABEL = "com.encha.role";
const ROLE_VALOR = "swarm-guard";
const LABEL_GERENCIADO = "com.encha.guard.gerenciado";

/**
 * Garante o serviço Swarm `encha-guard`: cria se ausente (só com exatamente
 * 1 nó), atualiza se o spec desejado difere do implantado, ou não faz nada
 * — idempotente, e NUNCA lança para quem chama. Ver o algoritmo completo em
 * `garantirGuardaSwarmOuLanca` (mesma função, sem o try/catch de topo —
 * separada só para os testes poderem exercitar cada ramo sem um catch
 * escondendo um `expect` que falhou por outro motivo).
 */
export async function garantirGuardaSwarm(token: string, endpointId: number): Promise<void> {
  try {
    await garantirGuardaSwarmOuLanca(token, endpointId);
  } catch (e) {
    console.error("[guard] falha ao garantir o serviço encha-guard (a próxima janela tenta de novo):", e);
  }
}

export async function garantirGuardaSwarmOuLanca(token: string, endpointId: number): Promise<void> {
  const nodes = await listNodes(token, endpointId);
  if (nodes.length !== 1) {
    console.warn(
      `[guard] encha-guard não gerenciado: o cluster tem ${nodes.length} nós, e este mecanismo só cria/atualiza o serviço com exatamente 1 nó — ver plano de segurança (A1) / documentação.`
    );
    return;
  }

  const atual = await getServiceExact(token, endpointId, GUARD_SERVICE_NAME);

  if (atual) {
    const role = atual.Spec.Labels?.[ROLE_LABEL];
    if (role !== ROLE_VALOR) {
      console.error(
        `[guard] existe um serviço "${GUARD_SERVICE_NAME}" no Swarm sem o label ${ROLE_LABEL}="${ROLE_VALOR}" ` +
          `(achado: ${role === undefined ? "label ausente" : `${ROLE_LABEL}="${role}"`}) — não é o serviço que o ` +
          `painel gerencia; NUNCA sobrescrevendo um serviço de terceiros só porque o nome bateu.`
      );
      return;
    }
    if (atual.Spec.Labels?.[LABEL_GERENCIADO] === "false") {
      console.log(
        `[guard] ${GUARD_SERVICE_NAME} está marcado com ${LABEL_GERENCIADO}=false — respeitando a escolha do operador, não tocando nele.`
      );
      return;
    }
  }

  const nomePainel = nomeServicoDoPainel();
  const painel = await getServiceExact(token, endpointId, nomePainel);
  const imagemPainel = painel?.Spec.TaskTemplate?.ContainerSpec?.Image;
  if (!imagemPainel) {
    console.error(
      `[guard] não encontrou a imagem em execução do próprio serviço do painel ("${nomePainel}") — sem uma ` +
        `imagem canônica (repo:tag@sha256:...) pra usar, não é seguro criar/atualizar o encha-guard agora.`
    );
    return;
  }

  const peers = peersFromNodes(nodes);
  const desejado = especificacaoDesejada({
    imagemPainel,
    // Só rótulo (com.encha.guard.versao) — nunca usado para montar a
    // imagem em si (ver montarSpecGuarda, src/lib/swarm-guard.ts).
    versaoApp: process.env.APP_VERSION ?? "0.0.0",
    peers,
    atual,
  });

  const desativadoIgnorado = desativadoNaoReconhecido(atual);
  if (desativadoIgnorado !== undefined) {
    console.warn(
      `[guard] ${GUARD_SERVICE_NAME}: ENCHA_GUARD_DESATIVADO="${desativadoIgnorado}" não é um valor que desliga o ` +
        `guarda (só 1, true, TRUE ou True) — o guarda continua ATIVO. O valor é mantido como está; corrija-o no ` +
        `Portainer se a intenção era desligar.`
    );
  }

  if (!atual) {
    await criarGuarda(token, endpointId, desejado);
    return;
  }

  const hostNetworkId = await getHostNetworkId(token, endpointId).catch(() => null);
  if (specEquivalenteAoAtual(atual, desejado, hostNetworkId)) {
    console.debug(`[guard] ${GUARD_SERVICE_NAME}: spec já é o desejado, nada a fazer.`);
    return;
  }

  await atualizarGuarda(token, endpointId, atual, desejado);
}

async function criarGuarda(token: string, endpointId: number, desejado: ServiceSpec): Promise<void> {
  try {
    await createService(token, endpointId, desejado);
    console.log(`[guard] ${GUARD_SERVICE_NAME} criado.`);
  } catch (e) {
    // 409 = outra chamada concorrente (ex.: outra tentativa periódica, ou o
    // login legado disparando ao mesmo tempo do boot) já criou — a próxima
    // janela reconcilia contra o que existir. Nunca propaga.
    if (e instanceof PortainerError && e.status === 409) {
      console.warn(`[guard] ${GUARD_SERVICE_NAME} já foi criado em paralelo (409) — a próxima janela reconcilia.`);
      return;
    }
    throw e;
  }
}

async function atualizarGuarda(
  token: string,
  endpointId: number,
  atual: DockerServiceFull,
  desejado: ServiceSpec
): Promise<void> {
  // SEM tratamento especial de 409 aqui (ao contrário do create). No update,
  // o Docker NÃO sinaliza corrida de Version.Index com 409: o swarmkit
  // devolve `update out of sequence` (store.ErrSequenceConflict, erro gRPC
  // sem código → HTTP 500). Um 409 no update só vem de codes.AlreadyExists
  // — conflito real e persistente, que se repetiria a cada janela. Em
  // qualquer falha o update NÃO foi aplicado: deixa subir para o catch de
  // garantirGuardaSwarm (console.error com a mensagem real) e a próxima
  // janela relê o serviço (Version.Index novo) e tenta de novo. Nunca
  // "engolir como sucesso".
  await updateService(token, endpointId, atual.ID, atual.Version.Index, desejado);
  console.log(`[guard] ${GUARD_SERVICE_NAME} atualizado.`);
}

// Campos comparados: imagem, Healthcheck, capabilities e Networks (resolvendo
// o ID da rede `host`, achado do auditor do C5) — Env via `compararEnv`. Não
// compara Labels (com.encha.guard.versao muda a cada versão do painel, sem
// nenhum efeito de comportamento — mudar isso sozinho nunca deveria
// disparar um update).
function specEquivalenteAoAtual(
  atual: DockerServiceFull,
  desejado: ServiceSpec,
  hostNetworkId: string | null
): boolean {
  const atualCS = atual.Spec.TaskTemplate?.ContainerSpec;
  const desejadoCS = desejado.TaskTemplate.ContainerSpec;

  if ((atualCS?.Image ?? null) !== desejadoCS.Image) return false;
  if (JSON.stringify(atualCS?.Healthcheck ?? null) !== JSON.stringify(desejadoCS.Healthcheck ?? null)) return false;
  if (!mesmoConjunto(atualCS?.CapabilityAdd, desejadoCS.CapabilityAdd)) return false;
  if (!mesmoConjunto(atualCS?.CapabilityDrop, desejadoCS.CapabilityDrop)) return false;
  if (!compararEnv(atualCS?.Env ?? [], desejadoCS.Env ?? [])) return false;
  if (!compararNetworks(atual.Spec.TaskTemplate?.Networks, desejado.TaskTemplate.Networks, hostNetworkId)) {
    return false;
  }
  return true;
}

function mesmoConjunto(a: string[] | undefined, b: string[] | undefined): boolean {
  const sa = [...(a ?? [])].sort();
  const sb = [...(b ?? [])].sort();
  return JSON.stringify(sa) === JSON.stringify(sb);
}

// ─────────────────────────────────────────────────────────────────────────
// Agendamento (boot do painel) — chamado por src/instrumentation.ts.
// Extraído daqui (em vez de dentro de register()) só pra ficar testável sem
// depender do runtime hook do Next.js.
// ─────────────────────────────────────────────────────────────────────────

const PRIMEIRA_TENTATIVA_MS = 20_000;
const INTERVALO_MS = 6 * 60 * 60_000; // 6h

// Uma tentativa: token de serviço + endpoint do Swarm + garantirGuardaSwarm.
// Nunca lança (mesma regra de garantirGuardaSwarm) — quem agenda (setTimeout/
// setInterval) não tem pra quem propagar um erro de qualquer forma.
export async function tentarGarantirGuardaSwarm(): Promise<void> {
  try {
    await withServiceToken(async (token) => {
      const { endpointId } = await discoverContext(token);
      await garantirGuardaSwarm(token, endpointId);
    });
  } catch (e) {
    console.error("[guard] tentativa periódica de garantir o encha-guard falhou (a próxima janela tenta de novo):", e);
  }
}

/**
 * Agenda a garantia periódica do `encha-guard`: só quando o painel tem
 * credencial de serviço do Portainer (`hasServiceCredentials`) — sem ela,
 * `withServiceToken` só falharia a cada tentativa; instalações legadas sem
 * admin próprio garantem o serviço no login (ver
 * `dispararGarantiaAposLoginLegado` e src/app/api/auth/route.ts).
 *
 * `.unref()` nos dois timers: SEM isso, um `setInterval` de 6h mantém o
 * event loop do Node vivo pra sempre, e o processo nunca sai sozinho num
 * `SIGTERM` gracioso (o container ficaria preso até o Swarm forçar
 * `SIGKILL` depois do grace period) — `.unref()` diz ao Node "não me
 * conte pra decidir se o processo deve continuar rodando", sem cancelar o
 * timer nem impedir os disparos normais.
 */
export function inicializarGarantiaGuardaSwarm(): void {
  if (!hasServiceCredentials()) {
    console.log(
      "[guard] sem credenciais de serviço do Portainer no boot — garantia periódica do encha-guard desativada " +
        "(instalação legada: o login admin garante o serviço, ver rota de auth)."
    );
    return;
  }

  const primeiro = setTimeout(() => void tentarGarantirGuardaSwarm(), PRIMEIRA_TENTATIVA_MS);
  primeiro.unref?.();

  const repetido = setInterval(() => void tentarGarantirGuardaSwarm(), INTERVALO_MS);
  repetido.unref?.();
}

// ─────────────────────────────────────────────────────────────────────────
// Fallback para instalações legadas (sem PANEL_ADMIN_USER/credencial de
// serviço) — disparado depois de um login bem-sucedido, ver
// src/app/api/auth/route.ts ("Modo legado"). Fire-and-forget de propósito:
// nunca deve atrasar a resposta do login, e nunca deve fazer o login
// "falhar" por causa do guarda.
// ─────────────────────────────────────────────────────────────────────────

export function dispararGarantiaAposLoginLegado(jwt: string): void {
  void (async () => {
    try {
      const { endpointId } = await discoverContext(jwt);
      await garantirGuardaSwarm(jwt, endpointId);
    } catch (e) {
      console.error("[guard] falha ao garantir o encha-guard após login legado (a próxima janela tenta de novo):", e);
    }
  })();
}
