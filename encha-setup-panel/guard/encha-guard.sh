#!/bin/sh
# encha-guard.sh — ciclo C4 do plano de segurança de infraestrutura (achado
# A1 da auditoria em produção real, 2026-09): a VPS instalada pelo Encha
# Setup expõe à Internet as portas internas do Docker Swarm — 2377/tcp (API
# de gestão do cluster), 7946/tcp+udp (gossip) e 4789/udp (VXLAN, tráfego
# real entre contêineres, inclusive dado de lead). Confirmado com nmap e
# tcpdump numa VPS descartável; nenhum firewall existia.
#
# Este script roda DENTRO do contêiner do serviço `encha-guard` (criado no
# C5/C6, fora deste ciclo) — mesma imagem do painel, rede `host` do nó,
# CAP_NET_ADMIN. É POSIX sh de propósito: o runtime é Alpine/BusyBox ash,
# não bash. Não assuma nenhum bashismo (arrays, [[ ]], "local", process
# substitution etc.) — o gate `sh -n` + shellcheck -s sh existe por isso.
#
# Responsabilidade única: manter a tabela nftables própria `inet
# encha_guard` aplicada e em dia. Nunca toca em outra tabela (Docker cria as
# suas próprias — "ip filter", "ip nat" etc. — e este script nunca as lê
# nem escreve).
#
# Formato de ENCHA_GUARD_PEERS / ENCHA_GUARD_PERMITIR: lista de IPs/CIDRs
# (IPv4 ou IPv6) aceitando espaço OU vírgula como separador (as duas formas
# convivem: "10.0.0.5,10.0.0.6" e "10.0.0.5 10.0.0.6" são equivalentes; a
# vírgula é normalizada para espaço antes do split). As duas variáveis têm o
# mesmo propósito (allowlist de pares) e são concatenadas — a distinção de
# nome é só para o operador organizar (ex.: PEERS = outros nós do Swarm,
# PERMITIR = IPs avulsos liberados manualmente).
#
# ENTRADA NÃO CONFIÁVEL: as duas variáveis vêm de configuração de operador,
# mas o script trata como hostil — cada item precisa bater EXATAMENTE no
# formato de IPv4/CIDR ou IPv6/CIDR abaixo (validação de forma + numérica,
# nunca só a forma). Qualquer item que não bata é DESCARTADO e logado, e
# JAMAIS interpolado bruto num "nft -f -" — é exatamente isso que bloqueia
# uma injeção do tipo `1.2.3.4 } ; flush ruleset` dentro do valor da env var:
# o valor nunca chega ao nft como texto livre, só como elemento de um `set`
# já validado dígito a dígito.
#
# ENCHA_GUARD_DESATIVADO=1 (ou "true"): desliga o guarda — a tabela existente
# é removida e nada mais é aplicado enquanto a flag estiver ativa.
#
# IMPORTANTE — nunca apagar a tabela ao encerrar: as regras vivem no kernel
# do HOST (rede `host`, contêiner sem net namespace próprio), não no
# contêiner. Um restart/replace do contêiner (deploy, update, OOM, reboot)
# não deve abrir a janela de exposição de novo só porque o processo antigo
# saiu. Por isso este script NUNCA registra um `trap` de limpeza em
# SIGTERM/EXIT — isso é intencional e não é um esquecimento.

set -u

# --- formato aceito (ver cabeçalho) --------------------------------------
RE_IPV4='^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'
RE_IPV6='^[0-9a-fA-F:]+(/[0-9]{1,3})?$'

log() {
  # Log simples em stderr, com prefixo — nada de segredo passa por aqui
  # (as env vars validadas são IPs/CIDRs, nunca credencial).
  echo "[encha-guard] $*" >&2
}

# --- validação numérica --------------------------------------------------

# Um octeto IPv4 (a forma [0-9]{1,3} já foi garantida por quem chama; aqui
# só a faixa 0-255). Comparação via `test`/`[` — nunca `$(( ))`: assim não
# corremos risco de um shell interpretar "0-liderado" como octal.
octeto_ipv4_valido() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$1" -le 255 ]
}

# Prefixo /N genérico (CIDR), com o teto certo pra família (32 ou 128).
prefixo_valido() {
  valor="$1"
  maximo="$2"
  case "$valor" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$valor" -le "$maximo" ]
}

# --- validação por família -----------------------------------------------

ipv4_valido() {
  entrada="$1"
  printf '%s' "$entrada" | grep -Eq "$RE_IPV4" || return 1

  case "$entrada" in
    */*)
      prefixo="${entrada#*/}"
      ip_parte="${entrada%/*}"
      ;;
    *)
      prefixo=""
      ip_parte="$entrada"
      ;;
  esac

  resto="$ip_parte"
  o1="${resto%%.*}"
  resto="${resto#*.}"
  o2="${resto%%.*}"
  resto="${resto#*.}"
  o3="${resto%%.*}"
  resto="${resto#*.}"
  o4="$resto"

  for oct in "$o1" "$o2" "$o3" "$o4"; do
    octeto_ipv4_valido "$oct" || return 1
  done

  if [ -n "$prefixo" ]; then
    prefixo_valido "$prefixo" 32 || return 1
  fi

  return 0
}

ipv6_valido() {
  entrada="$1"
  printf '%s' "$entrada" | grep -Eq "$RE_IPV6" || return 1

  # RE_IPV6 é solto de propósito (só restringe o alfabeto), então exige-se
  # ao menos um ":" aqui — sem isso, uma string só de dígitos como "1234"
  # (sem ponto, então nunca bateria como IPv4) passaria pela forma sem ser
  # um IPv6 de fato.
  case "$entrada" in
    *:*) : ;;
    *) return 1 ;;
  esac

  case "$entrada" in
    */*)
      prefixo="${entrada#*/}"
      prefixo_valido "$prefixo" 128 || return 1
      ;;
  esac

  return 0
}

# --- coleta e classificação ------------------------------------------------

# Normaliza o separador (vírgula -> espaço) das duas variáveis de allowlist,
# concatenadas (mesma finalidade, ver cabeçalho).
listar_candidatos() {
  bruto="${ENCHA_GUARD_PEERS:-},${ENCHA_GUARD_PERMITIR:-}"
  printf '%s' "$bruto" | tr ',' ' '
}

# Preenche IPV4_VALIDOS / IPV6_VALIDOS (globais, espaço-separadas) só com o
# que passou nas duas validações acima; tudo mais é descartado e logado — é
# aqui, e só aqui, que uma entrada maliciosa é jogada fora antes de qualquer
# contato com o `nft -f -`.
IPV4_VALIDOS=""
IPV6_VALIDOS=""

coletar_enderecos() {
  IPV4_VALIDOS=""
  IPV6_VALIDOS=""
  for candidato in $(listar_candidatos); do
    [ -n "$candidato" ] || continue
    if ipv4_valido "$candidato"; then
      IPV4_VALIDOS="$IPV4_VALIDOS $candidato"
    elif ipv6_valido "$candidato"; then
      IPV6_VALIDOS="$IPV6_VALIDOS $candidato"
    else
      log "entrada descartada (fora do formato estrito de IPv4/CIDR ou IPv6/CIDR): $candidato"
    fi
  done
  IPV4_VALIDOS="${IPV4_VALIDOS# }"
  IPV6_VALIDOS="${IPV6_VALIDOS# }"
}

# --- geração do ruleset -----------------------------------------------------

# Imprime no stdout o `nft -f -` completo. Só inclui um bloco "set" (e a
# regra "accept" correspondente) quando existe ao menos 1 endereço válido
# daquela família — um `set` com "elements = {}" vazio é erro de sintaxe do
# nft, então a ausência total de pares nunca deve gerar um set vazio.
gerar_ruleset() {
  coletar_enderecos

  echo 'table inet encha_guard {}'
  echo 'delete table inet encha_guard'
  echo 'table inet encha_guard {'

  if [ -n "$IPV4_VALIDOS" ]; then
    elementos4="$(printf '%s' "$IPV4_VALIDOS" | tr ' ' ',')"
    echo "  set pares4 { type ipv4_addr; flags interval; auto-merge; elements = { $elementos4 }; }"
  fi

  if [ -n "$IPV6_VALIDOS" ]; then
    elementos6="$(printf '%s' "$IPV6_VALIDOS" | tr ' ' ',')"
    echo "  set pares6 { type ipv6_addr; flags interval; auto-merge; elements = { $elementos6 }; }"
  fi

  echo '  chain entrada {'
  echo '    type filter hook input priority -5; policy accept;'
  echo '    iif "lo" accept'
  if [ -n "$IPV4_VALIDOS" ]; then
    echo '    ip saddr @pares4 accept'
  fi
  if [ -n "$IPV6_VALIDOS" ]; then
    echo '    ip6 saddr @pares6 accept'
  fi
  echo '    tcp dport { 2377, 7946 } counter drop'
  echo '    udp dport { 4789, 7946 } counter drop'
  echo '  }'
  echo '}'
}

# --- loop principal ----------------------------------------------------------

# `sleep 60 &` + `wait` em vez de `sleep 60` bloqueante: um SIGTERM chega ao
# `wait` na hora (o `sleep` filho recebe o sinal e morre, o `wait` retorna),
# em vez de esperar o intervalo inteiro antes do contêiner conseguir parar.
dormir_intervalo() {
  sleep 60 &
  wait "$!" 2>/dev/null
}

tabela_existe() {
  nft list table inet encha_guard >/dev/null 2>&1
}

# Remove os "# handle N" (mudam a cada aplicação, mesmo com o ruleset
# semanticamente igual) e linhas vazias/espaço nas pontas, pra comparar
# conteúdo e não texto cru.
normalizar_ruleset() {
  sed -E 's/#[[:space:]]*handle[[:space:]]+[0-9]+//g' | sed -E 's/[[:space:]]+$//' | grep -v '^[[:space:]]*$'
}

# Desativado (ENCHA_GUARD_DESATIVADO=1/true): remove a tabela se existir e
# não aplica nada enquanto a flag estiver ligada. Log só na transição (o
# `tabela_existe` como guarda evita logar a cada ciclo de 60s).
desativado_ativo() {
  case "${ENCHA_GUARD_DESATIVADO:-}" in
    1 | true | TRUE | True) return 0 ;;
    *) return 1 ;;
  esac
}

aplicar_desativado() {
  if tabela_existe; then
    if nft delete table inet encha_guard 2>/dev/null; then
      log "ENCHA_GUARD_DESATIVADO ativo: tabela inet encha_guard removida."
    else
      log "ENCHA_GUARD_DESATIVADO ativo: tentativa de remover a tabela falhou (siga adiante, pode já ter sumido)."
    fi
  fi
}

# Gera o ruleset desejado, compara com o aplicado agora e só chama
# `nft -f -` quando é diferente ou a tabela não existe. Nunca deixa o script
# morrer por causa do nft — falha vira log e o loop segue (o contêiner não
# pode crash-loop por causa disso).
aplicar_se_necessario() {
  if ! command -v nft >/dev/null 2>&1; then
    log "comando 'nft' não encontrado no PATH — nada a fazer neste ciclo."
    return 0
  fi

  ruleset_bruto="$(gerar_ruleset)"
  desejado="$(printf '%s\n' "$ruleset_bruto" | normalizar_ruleset)"

  if tabela_existe; then
    atual="$(nft -a list table inet encha_guard 2>/dev/null | normalizar_ruleset)"
    if [ "$desejado" = "$atual" ]; then
      return 0
    fi
  fi

  saida="$(printf '%s\n' "$ruleset_bruto" | nft -f - 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    log "ruleset aplicado (tabela ausente ou diferente da desejada)."
  else
    log "falha ao aplicar o ruleset via 'nft -f -': $saida"
  fi
  return 0
}

loop_principal() {
  log "iniciando — checagem a cada ~60s. A tabela nunca é removida ao sair (regras vivem no kernel do host)."
  while :; do
    if desativado_ativo; then
      aplicar_desativado
    else
      aplicar_se_necessario
    fi
    dormir_intervalo
  done
}

main() {
  if [ "${1:-}" = "--render" ]; then
    gerar_ruleset
    return 0
  fi
  loop_principal
}

main "$@"
