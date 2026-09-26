import { isIP } from "node:net";
import type { DockerNode, ServiceSpec } from "./portainer";

// Builder PURO do spec do serviço Swarm `encha-guard` (ciclo C5 do plano de
// segurança — achado A1). Só monta objetos: nenhuma chamada de rede, nenhum
// I/O. Quem decide QUANDO criar/atualizar esse serviço (busca por nome
// exato, compara spec desejado vs. atual, preserva overrides do operador)
// é o C6 — este arquivo só garante que, para os MESMOS argumentos, o spec
// produzido é sempre IGUAL (determinismo — ver swarm-guard.test.ts), o que
// é o que permite ao C6 comparar "desejado" com "atual" sem falso positivo.

export const GUARD_SERVICE_NAME = "encha-guard";
// Congelado, e sempre COPIADO para dentro do spec (nunca a mesma
// referência): se o spec devolvido fosse alterado por quem chama (ex.: o C6
// mesclando algo), a constante mudaria junto e todo spec seguinte sairia
// diferente — quebrando o determinismo do qual a comparação do C6 depende.
export const GUARD_COMMAND: readonly string[] = Object.freeze(["/usr/local/bin/encha-guard"]);

export type MontarSpecGuardaArgs = {
  /**
   * Imagem COM DIGEST que o serviço do painel está rodando agora (quem
   * descobre isso é o C6). Usada tal e qual — NUNCA reconstruída a partir
   * de `versaoApp`, porque o objetivo é rodar exatamente o mesmo binário
   * (mesmo script `encha-guard`) que o painel já tem local, sem pull novo.
   */
  imagemPainel: string;
  /** Só rotula (`com.encha.guard.versao`) — não influencia a imagem usada. */
  versaoApp: string;
  /** Lista de IPs já resolvida (ver `peersFromNodes`). */
  peers: string[];
  /** Valor cru de ENCHA_GUARD_PERMITIR, se configurado manualmente — repassado sem validar (o script do C4 valida). */
  permitirExtra?: string;
  /** true → inclui ENCHA_GUARD_DESATIVADO=1 no ambiente do serviço. */
  desativado?: boolean;
};

/**
 * Monta o `ServiceSpec` do serviço Swarm `encha-guard`. Função pura: mesma
 * entrada sempre produz a mesma saída (mesma ordem de chaves/itens em toda
 * parte), para o C6 poder comparar "spec desejado" com o que já está
 * implantado sem falso positivo de diferença.
 *
 * Decisões fixas, todas com motivo:
 * - `Mode.Global`: uma tarefa por nó, sem replica count pra gerenciar.
 * - SEM nenhum label de namespace de stack (nem
 *   `com.docker.stack.namespace`): é isso que mantém o serviço INVISÍVEL
 *   para `listSwarmStackStatuses` (que só agrupa services que têm esse
 *   label) e para a aba Stacks do Portainer — o guarda não é uma stack,
 *   é infraestrutura de segurança que o painel gerencia sozinho.
 * - `Command` sem argumentos: o script já roda em loop quando chamado sem
 *   `--render` (ver guard/encha-guard.sh).
 * - `CapabilityDrop: ["ALL"]` + só `CAP_NET_ADMIN` de volta: o mínimo
 *   necessário pra manipular nftables, nada mais.
 * - `ReadOnly: true`: o script não escreve nada em disco além do que o
 *   kernel já guarda (a tabela nft vive no kernel, não em arquivo).
 * - `Healthcheck: { Test: ["NONE"] }`: CRÍTICO. A imagem do painel herda um
 *   HEALTHCHECK que faz `wget 127.0.0.1:3000/api/health` (ver Dockerfile) —
 *   na rede `host` desse serviço nada escuta a porta 3000, então sem este
 *   override o Swarm mataria a tarefa a cada ~2min por healthcheck falho.
 * - `Networks: [{ Target: "host" }]`: precisa ver as interfaces reais do
 *   nó pra aplicar nftables contra o tráfego real, não uma rede overlay.
 * - `RestartPolicy.Condition: "any"`: serviço de vida longa, sempre volta.
 * - `Resources.Limits`: 0.1 CPU / 64MiB — o script é só um loop de shell
 *   chamando nft a cada 60s, não precisa de mais.
 */
export function montarSpecGuarda(args: MontarSpecGuardaArgs): ServiceSpec {
  // ENCHA_GUARD_PEERS sempre presente, mesmo vazia — nunca omitida quando
  // `peers` é []. Mantém o array de Env com o mesmo formato/índice
  // independente do tamanho da allowlist, o que é o que torna a saída
  // desta função comparável de forma estável pelo C6 (evita um "spec
  // difere" espúrio só porque a allowlist ficou vazia numa rodada e não
  // noutra). O script do C4 já trata `ENCHA_GUARD_PEERS` vazia/ausente do
  // mesmo jeito, então esta escolha não muda comportamento nenhum nele.
  const env: string[] = [`ENCHA_GUARD_PEERS=${args.peers.join(",")}`];
  if (args.permitirExtra) env.push(`ENCHA_GUARD_PERMITIR=${args.permitirExtra}`);
  if (args.desativado) env.push("ENCHA_GUARD_DESATIVADO=1");

  return {
    Name: GUARD_SERVICE_NAME,
    Labels: {
      "com.encha.role": "swarm-guard",
      "com.encha.guard.versao": args.versaoApp,
    },
    Mode: { Global: {} },
    TaskTemplate: {
      ContainerSpec: {
        Image: args.imagemPainel,
        Command: [...GUARD_COMMAND],
        User: "0",
        Env: env,
        CapabilityDrop: ["ALL"],
        CapabilityAdd: ["CAP_NET_ADMIN"],
        ReadOnly: true,
        Healthcheck: { Test: ["NONE"] },
      },
      Networks: [{ Target: "host" }],
      RestartPolicy: { Condition: "any", Delay: 5_000_000_000 },
      Resources: { Limits: { NanoCPUs: 100_000_000, MemoryBytes: 67_108_864 } },
      Placement: { Constraints: ["node.platform.os == linux"] },
    },
  };
}

// Extrai o endereço de um nó (ver DockerNode em src/lib/portainer.ts).
// `Status.Addr` existe em todo nó (manager ou worker) e é a fonte
// preferida: é só o IP, sem porta, no formato que o Swarm usa para o
// próprio tráfego de cluster. `ManagerStatus.Addr` (só managers) serve de
// alternativa quando `Status.Addr` vier vazio/malformado, e costuma trazer
// porta (":2377") — por isso os dois passam pela mesma limpeza de
// porta/colchetes de IPv6 abaixo.
//
// Só aceita um IP LITERAL (IPv4 ou IPv6, sem prefixo/CIDR, sem zona "%eth0",
// sem vírgula/espaço) e nunca o endereço não especificado ("0.0.0.0"/"::").
// O script do guarda aceita CIDR em ENCHA_GUARD_PEERS, então um "Addr" que
// viesse como "0.0.0.0/0" viraria "liberar a Internet inteira"; e um
// "0.0.0.0" em Status.Addr (o Docker já reportou isso para managers) tomava
// o lugar do IP real que está em ManagerStatus.Addr, deixando o par de
// verdade FORA da allowlist (tráfego do cluster descartado). Candidato que
// não passa aqui cai para o próximo; nenhum passando = nó ignorado.
function extrairEndereco(node: DockerNode | null | undefined): string | null {
  if (!node || typeof node !== "object") return null;
  const candidatos = [node.Status?.Addr, node.ManagerStatus?.Addr];
  for (const bruto of candidatos) {
    const limpo = limparEndereco(bruto);
    if (limpo && enderecoDePar(limpo)) return limpo;
  }
  return null;
}

function enderecoDePar(ip: string): boolean {
  if (ip.includes("%")) return false;
  const familia = isIP(ip);
  if (familia === 0) return false;
  if (familia === 4) return ip !== "0.0.0.0";
  return !/^[0:]+$/.test(ip); // "::", "0::0", "0:0:0:0:0:0:0:0"
}

// "[::1]:2377" -> "::1" · "10.0.0.5:2377" -> "10.0.0.5" · "10.0.0.5" -> "10.0.0.5"
// Entrada vazia/ausente/malformada (ex.: "[" sem "]" de fechamento) -> null.
function limparEndereco(bruto: unknown): string | null {
  if (typeof bruto !== "string" || !bruto) return null;
  const valor = bruto.trim();
  if (!valor) return null;

  if (valor.startsWith("[")) {
    const fim = valor.indexOf("]");
    if (fim === -1) return null; // malformado — sem colchete de fechamento
    const ip = valor.slice(1, fim);
    return ip || null;
  }

  // IPv4 com porta ("10.0.0.5:2377") tem exatamente um ":" seguido só de
  // dígitos no final; IPv6 sem colchetes (mais de um ":") fica intacto —
  // nunca cortamos no meio de um endereço IPv6 puro.
  const ultimoDoisPontos = valor.lastIndexOf(":");
  if (ultimoDoisPontos !== -1) {
    const resto = valor.slice(ultimoDoisPontos + 1);
    const temUmSoDoisPontos = valor.indexOf(":") === ultimoDoisPontos;
    if (temUmSoDoisPontos && /^\d+$/.test(resto)) {
      return valor.slice(0, ultimoDoisPontos) || null;
    }
  }
  return valor;
}

/**
 * Extrai a lista de endereços dos nós do Swarm para `ENCHA_GUARD_PEERS` —
 * de TODOS os nós listados, sem filtrar por estado (um nó "down" que volta
 * precisa já estar liberado).
 * Nó único: a allowlist é vazia — o guarda já aceita `lo`, e um pacote com
 * IP local de origem que chegasse de fora seria descartado como martian de
 * qualquer forma, então não há necessidade de o nó se autopermitir. Com 2+
 * nós, devolve o endereço de cada nó que conseguiu ser extraído (nós com
 * `Status.Addr`/`ManagerStatus.Addr` vazios ou malformados são ignorados,
 * nunca quebram a função).
 */
export function peersFromNodes(nodes: DockerNode[]): string[] {
  if (nodes.length <= 1) return [];
  const enderecos = new Set<string>();
  for (const node of nodes) {
    const endereco = extrairEndereco(node);
    if (endereco) enderecos.add(endereco);
  }
  // Ordenada e sem repetição: a saída depende só do CONJUNTO de endereços,
  // nunca da ordem em que a API devolveu os nós nem de dois nós reportarem
  // o mesmo IP — senão o C6, comparando o Env desejado com o atual, veria
  // "spec difere" sem nada ter mudado e recriaria a tarefa do guarda à toa.
  return Array.from(enderecos).sort();
}
