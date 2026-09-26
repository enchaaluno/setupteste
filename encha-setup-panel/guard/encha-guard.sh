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
# ENCHA_GUARD_SSH_PORTAS (ciclo C7, achado A2 — mitigação automática para as
# VPS existentes que não vão rodar o fail2ban de verdade do C10): lista de
# portas SSH, mesmo separador espaço/vírgula das duas variáveis acima, opcional
# (default "22"). Cada porta é validada como inteiro decimal canônico 1-65535
# — a mesma disciplina defensiva das outras entradas de operador (formato +
# faixa numérica, nunca só a forma); a que não bater é DESCARTADA e logada,
# nunca interpolada crua no "nft -f -". Gera regras de LIMITE DE TAXA POR IP
# DE ORIGEM (não um drop incondicional, que derrubaria o SSH de verdade):
#   tcp dport { <portas> } ct state new update @ssh_limite4 { ip saddr limit rate over 20/minute burst 30 packets } drop
#   (e o mesmo para IPv6, agrupando a origem por /64 em @ssh_limite6)
# "ct state new" é CRÍTICO e nunca pode ser removido: sem ele, o limite se
# aplicaria a todo pacote de QUALQUER sessão SSH, inclusive as já
# autenticadas e abertas — derrubando uso normal, não só tentativas de força
# bruta. Com "ct state new", só a TAXA DE NOVAS TENTATIVAS DE CONEXÃO é
# limitada; sessões já estabelecidas nunca são afetadas (medido no kernel real
# da VPS de teste: sem "ct state new", uma sessão aberta teve 19 pacotes
# descartados; com ele, zero). O balde é POR ORIGEM (set dinâmico), nunca um
# só balde global: com um limite global, qualquer robô de força bruta gastava
# as 20 conexões/minuto de TODO MUNDO e o próprio operador ficava sem
# conseguir entrar por SSH durante o ataque (medido: 2 de 5 tentativas do IP
# legítimo passaram com o limite global; 5 de 5 com o limite por IP). Lista
# vazia (todas inválidas, ou ENCHA_GUARD_SSH_PORTAS="" explícito) => as regras
# e os sets são omitidos do ruleset, como pares4/pares6 já fazem quando não
# têm elemento nenhum.
#
# IMPORTANTE — nunca apagar a tabela ao encerrar: as regras vivem no kernel
# do HOST (rede `host`, contêiner sem net namespace próprio), não no
# contêiner. Um restart/replace do contêiner (deploy, update, OOM, reboot)
# não deve abrir a janela de exposição de novo só porque o processo antigo
# saiu. Por isso este script NUNCA registra um `trap` de limpeza em
# SIGTERM/EXIT — isso é intencional e não é um esquecimento. O único trap é
# o de sair (encerrar_sem_limpar, no loop principal), que só encerra o
# processo e nunca chama o nft.

set -u
# Sem expansão de curinga: a lista de pares é quebrada em itens por expansão
# SEM aspas (coletar_enderecos) — sem isto, um "*" na env var viraria os
# nomes de arquivo do diretório corrente, e um arquivo chamado "10.9.9.9"
# viraria um par liberado. (Não afeta os padrões de `case`, que não são
# expansão de nome de arquivo.)
set -f

# --- formato aceito (ver cabeçalho) --------------------------------------
RE_IPV4='^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'

log() {
  # Log simples em stderr, com prefixo — nada de segredo passa por aqui
  # (as env vars validadas são IPs/CIDRs, nunca credencial). printf, não
  # echo: o echo do dash interpreta "\c", "\n" etc. vindos da entrada.
  printf '[encha-guard] %s\n' "$*" >&2
}

# --- validação numérica --------------------------------------------------
#
# Regra geral: o validador nunca pode ser MAIS permissivo que o nft. Todo
# elemento aceito aqui entra no mesmo `nft -f -` das regras de drop — se o
# nft rejeitar um único elemento, a transação inteira falha e o guarda não
# aplica nada (portas do Swarm abertas). Conferido com o nft 1.1.5 real:
# "008.0.0.1" derruba a transação, e "010.0.0.1" é aceito mas lido como
# OCTAL pelo resolvedor (libera 8.0.0.1). Por isso número decimal canônico:
# sem zero à esquerda, nunca.

# Número decimal canônico ("0" ou sem zero à esquerda) entre 0 e "$2".
decimal_canonico_ate() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    0) return 0 ;;
    0*) return 1 ;;
  esac
  # Já tem no máximo 3 dígitos (garantido pela forma, ver quem chama) — o
  # `test` compara como decimal (sem zero à esquerda não há leitura octal).
  [ "$1" -le "$2" ]
}

# Um octeto IPv4: decimal canônico 0-255.
octeto_ipv4_valido() {
  case "$1" in
    ??? | ?? | ?) : ;;
    *) return 1 ;;
  esac
  decimal_canonico_ate "$1" 255
}

# Prefixo /N genérico (CIDR), com o teto certo pra família (32 ou 128).
prefixo_valido() {
  case "$1" in
    ??? | ?? | ?) : ;;
    *) return 1 ;;
  esac
  decimal_canonico_ate "$1" "$2"
}

# Porta TCP (ENCHA_GUARD_SSH_PORTAS): decimal canônico 1-65535 — mesmo teto de
# comprimento (1 a 5 dígitos) antes do "test" numérico, pelo mesmo motivo dos
# octetos/prefixos acima (nunca deixar uma string de dígitos absurdamente
# longa chegar ao "-le"). decimal_canonico_ate aceita "0" como válido (é
# correto para octeto IPv4); porta 0 não é uma porta TCP válida, então é
# rejeitada aqui antes de delegar.
porta_valida() {
  case "$1" in
    ????? | ???? | ??? | ?? | ?) : ;;
    *) return 1 ;;
  esac
  [ "$1" = "0" ] && return 1
  decimal_canonico_ate "$1" 65535
}

# --- validação por família -----------------------------------------------

ipv4_valido() {
  entrada="$1"
  case "$entrada" in
    '' | *[!0-9./]*) return 1 ;;
  esac
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

  case "$entrada" in
    */*) prefixo_valido "$prefixo" 32 || return 1 ;;
  esac

  return 0
}

# Conta os grupos hex de uma lista "g:g:g" (sem "::"). Cada grupo tem 1 a 4
# dígitos hex; lista vazia = 0 grupos. Resultado em GRUPOS_HEX (global, sem
# subshell). Falha em grupo vazio (":" solto na ponta ou dobrado) ou inválido.
contar_grupos_hex() {
  lista="$1"
  GRUPOS_HEX=0
  [ -n "$lista" ] || return 0
  case "$lista" in
    :* | *: | *::*) return 1 ;;
  esac
  resto="$lista"
  while :; do
    grupo="${resto%%:*}"
    case "$grupo" in
      '' | ?????* | *[!0-9a-fA-F]*) return 1 ;;
    esac
    GRUPOS_HEX=$((GRUPOS_HEX + 1))
    [ "$GRUPOS_HEX" -le 8 ] || return 1
    case "$resto" in
      *:*) resto="${resto#*:}" ;;
      *) break ;;
    esac
  done
  return 0
}

# IPv6 pela gramática do RFC 4291 (sem a forma com IPv4 embutido, que é
# descartada): 8 grupos de 1-4 hex, ou menos com UM "::" (que vale por pelo
# menos um grupo de zeros); prefixo opcional 0-128 decimal canônico.
ipv6_valido() {
  entrada="$1"
  case "$entrada" in
    '' | *[!0-9a-fA-F:/]*) return 1 ;;
    *:*) : ;;
    *) return 1 ;;
  esac

  case "$entrada" in
    */*/*) return 1 ;;
    */*)
      prefixo_valido "${entrada#*/}" 128 || return 1
      ip_parte="${entrada%/*}"
      ;;
    *) ip_parte="$entrada" ;;
  esac

  case "$ip_parte" in
    *:::* | *::*::*) return 1 ;;
    *::*)
      contar_grupos_hex "${ip_parte%%::*}" || return 1
      esquerda="$GRUPOS_HEX"
      contar_grupos_hex "${ip_parte#*::}" || return 1
      [ $((esquerda + GRUPOS_HEX)) -le 7 ] || return 1
      ;;
    *)
      contar_grupos_hex "$ip_parte" || return 1
      [ "$GRUPOS_HEX" -eq 8 ] || return 1
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

# Normaliza o separador de ENCHA_GUARD_SSH_PORTAS (vírgula -> espaço), com
# default "22" só quando a variável está DESATIVADA (unset) — "${VAR-padrao}"
# de propósito (não "${VAR:-padrao}"): ENCHA_GUARD_SSH_PORTAS="" explícito
# precisa continuar vazio (a regra some do ruleset), nunca cair no default.
listar_portas_ssh_candidatas() {
  bruto="${ENCHA_GUARD_SSH_PORTAS-22}"
  printf '%s' "$bruto" | tr ',' ' '
}

# Preenche PORTAS_SSH_VALIDAS (global, espaço-separada) só com o que passou em
# porta_valida — mesmo padrão de coletar_enderecos: o que não bate é
# DESCARTADO e logado, nunca chega ao "nft -f -".
PORTAS_SSH_VALIDAS=""

coletar_portas_ssh() {
  PORTAS_SSH_VALIDAS=""
  for candidato in $(listar_portas_ssh_candidatas); do
    [ -n "$candidato" ] || continue
    if porta_valida "$candidato"; then
      PORTAS_SSH_VALIDAS="$PORTAS_SSH_VALIDAS $candidato"
    else
      log "porta SSH descartada (fora do formato válido, inteiro decimal 1-65535): $candidato"
    fi
  done
  PORTAS_SSH_VALIDAS="${PORTAS_SSH_VALIDAS# }"
}

# --- geração do ruleset -----------------------------------------------------

# Imprime no stdout o `nft -f -` completo. Só inclui um bloco "set" (e a
# regra "accept" correspondente) quando existe ao menos 1 endereço válido
# daquela família — um `set` com "elements = {}" vazio é erro de sintaxe do
# nft, então a ausência total de pares nunca deve gerar um set vazio.
gerar_ruleset() {
  coletar_enderecos
  montar_ruleset "$IPV4_VALIDOS" "$IPV6_VALIDOS"
}

# Mesmo ruleset, com as listas de pares passadas explicitamente ("$1" IPv4,
# "$2" IPv6, espaço-separadas e JÁ validadas). Com as duas vazias, é a versão
# sem os pares — a primeira falha fechada (aplicar_se_necessario). "$3" =
# "sem_ssh" omite também o limite de SSH: é a versão MÍNIMA (só lo + drops do
# Swarm), a última falha fechada — texto fixo, que nenhuma env var altera.
montar_ruleset() {
  IPV4_VALIDOS="$1"
  IPV6_VALIDOS="$2"
  if [ "${3:-}" = "sem_ssh" ]; then
    PORTAS_SSH_VALIDAS=""
  else
    coletar_portas_ssh
  fi

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

  # Baldes do limite de SSH, um por origem (C7). size = teto de memória no
  # kernel (entrada não autenticada alimenta o set); cheio, a regra
  # simplesmente não casa para origens novas — o SSH segue com a própria
  # autenticação, nada é derrubado. timeout 2m com "update" (renova a cada
  # tentativa): o balde de quem continua tentando nunca é recriado cheio, e o
  # de quem parou some depois que já teria se recarregado (30 fichas a
  # 20/min = 90s). O conteúdo destes dois sets muda a cada conexão SSH — ver
  # normalizar_ruleset, que os ignora na comparação.
  if [ -n "$PORTAS_SSH_VALIDAS" ]; then
    echo '  set ssh_limite4 { type ipv4_addr; size 65535; flags dynamic,timeout; timeout 2m; }'
    echo '  set ssh_limite6 { type ipv6_addr; size 65535; flags dynamic,timeout; timeout 2m; }'
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
  # C7 (achado A2): limite de taxa de NOVAS conexões SSH POR IP DE ORIGEM
  # (IPv6 agrupado por /64 — um /64 inteiro costuma ser de uma só máquina, e
  # por endereço exato o atacante trocaria de IP a cada tentativa) — nunca um
  # drop incondicional, nunca um balde global (ver cabeçalho). "ct state new"
  # restringe o limite à taxa de tentativas de conexão; sem ele, toda sessão
  # SSH já aberta cairia sob o mesmo limite. Depois dos accepts de lo e dos
  # pares: IP da allowlist nunca é limitado. Omitida quando não há nenhuma
  # porta válida (ver coletar_portas_ssh).
  if [ -n "$PORTAS_SSH_VALIDAS" ]; then
    portas_ssh_fmt="$(printf '%s' "$PORTAS_SSH_VALIDAS" | tr ' ' ',')"
    echo "    tcp dport { $portas_ssh_fmt } ct state new update @ssh_limite4 { ip saddr limit rate over 20/minute burst 30 packets } drop"
    echo "    tcp dport { $portas_ssh_fmt } ct state new update @ssh_limite6 { ip6 saddr and ffff:ffff:ffff:ffff:: limit rate over 20/minute burst 30 packets } drop"
  fi
  echo '    tcp dport { 2377, 7946 } counter drop'
  echo '    udp dport { 4789, 7946 } counter drop'
  echo '  }'
  echo '}'
}

# --- loop principal ----------------------------------------------------------

# `sleep 60 &` + `wait` em vez de `sleep 60` bloqueante: com o trap de
# TERM/INT registrado (encerrar_sem_limpar), o sinal interrompe o `wait` na
# hora e o processo sai, em vez de esperar o intervalo inteiro.
dormir_intervalo() {
  sleep 60 &
  wait "$!" 2>/dev/null
}

tabela_existe() {
  nft list table inet encha_guard >/dev/null 2>&1
}

# Normaliza a LISTAGEM do nft (`nft list table ...`) para comparar conteúdo,
# não texto cru: tira "# handle N" (mudam a cada aplicação), troca
# "counter packets N bytes M" por "counter" (sobem a cada pacote descartado)
# e descarta espaço no fim e linhas vazias. Descarta também o "elements = {
# ... }" dos sets dinâmicos do limite de SSH (ssh_limite4/ssh_limite6): o
# kernel acrescenta um elemento por origem a cada tentativa de conexão SSH,
# com "expires" contando para baixo — sem isto, qualquer SSH nos últimos 2
# minutos fazia a tabela parecer "alterada", e o loop a recriava a cada
# ciclo, zerando os baldes de todo mundo (o atacante ganhava 30 tentativas
# novas por minuto) e logando a cada 60s. Os elementos de pares4/pares6 (a
# allowlist) continuam na comparação.
normalizar_ruleset() {
  awk '
    /^[[:space:]]*set ssh_limite[46] [{]/ { dinamico = 1 }
    dinamico && /^[[:space:]]*elements = [{]/ { pulando = 1 }
    pulando { if ($0 ~ /[}][[:space:]]*$/) pulando = 0; next }
    dinamico && /^[[:space:]]*[}][[:space:]]*$/ { dinamico = 0 }
    { print }
  ' | sed -E -e 's/#[[:space:]]*handle[[:space:]]+[0-9]+//g' \
    -e 's/counter packets [0-9]+ bytes [0-9]+/counter/g' \
    -e 's/[[:space:]]+$//' | grep -v '^[[:space:]]*$'
}

listar_tabela_normalizada() {
  nft list table inet encha_guard 2>/dev/null | normalizar_ruleset
}

# Listagem normalizada da tabela logo DEPOIS da última aplicação bem-sucedida
# deste processo. É contra ela — e nunca contra o texto que foi aplicado —
# que a tabela atual é comparada: o nft reformata o que recebe (tabs, blocos
# de set em várias linhas, "priority filter - 5", e o auto-merge funde
# elementos: "10.0.0.5,10.0.0.6" volta como "10.0.0.5-10.0.0.6"), então o
# texto de entrada NUNCA é igual à listagem, e compará-los reaplicava a
# tabela a cada ciclo (zerando os contadores e logando a cada minuto).
# Vazia = nada aplicado ainda por este processo -> aplica.
ULTIMA_LISTAGEM=""

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

# Aplica "$1" via `nft -f -` (transação atômica). Sucesso: guarda a listagem
# resultante em ULTIMA_LISTAGEM. Falha: limpa ULTIMA_LISTAGEM e deixa a saída
# do nft em ERRO_NFT.
aplicar_ruleset() {
  if ERRO_NFT="$(printf '%s\n' "$1" | nft -f - 2>&1)"; then
    ULTIMA_LISTAGEM="$(listar_tabela_normalizada)"
    return 0
  fi
  ULTIMA_LISTAGEM=""
  return 1
}

# 1 = a versão completa foi recusada pelo nft e a tabela aplicada é uma das
# versões de falha fechada — sem os pares, ou a mínima (ver
# aplicar_se_necessario).
MODO_SEM_PARES=0

# Compara a tabela aplicada agora com a que este processo deixou na última
# aplicação e só chama `nft -f -` quando ela sumiu ou mudou (ou quando este
# processo ainda não aplicou nada). "$1" = ruleset completo, "$2" = o mesmo
# sem os pares, "$3" = o mínimo (sem pares e sem o limite de SSH); os três
# calculados uma vez no início do loop — as env vars
# não mudam durante a vida do contêiner (mudar env de um serviço Swarm recria
# a tarefa). Nunca deixa o script morrer por causa do nft — falha vira log e
# o loop segue (o contêiner não pode crash-loop por causa disso).
#
# FALHA FECHADA: se o nft recusar a transação completa (um elemento da
# allowlist que o nft desta versão não aceita — um só derruba a transação
# inteira), as portas não podem ficar abertas por causa da allowlist: aplica
# a versão sem os pares (lo + limite de SSH + drops) e avisa. Se nem ela
# passar — o limite de SSH do C7 usa set dinâmico com "limit", que um kernel
# antigo pode recusar, e sem esta terceira camada isso deixava o guarda sem
# regra NENHUMA (as portas do Swarm abertas por causa de uma mitigação de
# SSH) —, aplica a versão mínima (só lo + drops do Swarm, texto fixo). Nos
# ciclos seguintes, com a tabela intacta, só CONFERE com `nft -c` (não aplica
# nada, contadores intactos) se a versão completa já passa — e a aplica
# quando passar.
aplicar_se_necessario() {
  ruleset_completo="$1"
  ruleset_sem_pares="$2"
  ruleset_minimo="$3"

  if ! command -v nft >/dev/null 2>&1; then
    log "comando 'nft' não encontrado no PATH — nada a fazer neste ciclo."
    return 0
  fi

  if [ -n "$ULTIMA_LISTAGEM" ] && tabela_existe; then
    atual="$(listar_tabela_normalizada)"
    if [ "$atual" = "$ULTIMA_LISTAGEM" ]; then
      if [ "$MODO_SEM_PARES" -eq 0 ]; then
        return 0
      fi
      if ! printf '%s\n' "$ruleset_completo" | nft -c -f - >/dev/null 2>&1; then
        return 0
      fi
    fi
  fi

  if aplicar_ruleset "$ruleset_completo"; then
    MODO_SEM_PARES=0
    log "ruleset aplicado (tabela ausente, alterada ou primeira aplicação deste processo)."
    return 0
  fi
  log "falha ao aplicar o ruleset via 'nft -f -': $ERRO_NFT"

  if [ "$ruleset_sem_pares" != "$ruleset_completo" ]; then
    if aplicar_ruleset "$ruleset_sem_pares"; then
      MODO_SEM_PARES=1
      log "ATENÇÃO: o nft recusou a allowlist (ENCHA_GUARD_PEERS/ENCHA_GUARD_PERMITIR) — regras de drop aplicadas SEM os pares (falha fechada). Corrija a lista; o guarda confere de novo a cada ciclo."
      return 0
    fi
    log "falha ao aplicar até a versão sem os pares via 'nft -f -': $ERRO_NFT"
  fi

  if [ "$ruleset_minimo" = "$ruleset_sem_pares" ]; then
    return 0
  fi
  if aplicar_ruleset "$ruleset_minimo"; then
    MODO_SEM_PARES=1
    log "ATENÇÃO: o nft recusou o limite de conexões SSH (ENCHA_GUARD_SSH_PORTAS, ou o kernel sem suporte a set dinâmico com limite) — aplicados SÓ os drops do Swarm, sem pares e sem limite de SSH (falha fechada). O guarda confere de novo a cada ciclo."
  else
    log "falha ao aplicar até a versão mínima (só os drops) via 'nft -f -': $ERRO_NFT"
  fi
  return 0
}

# Trap de TERM/INT: SÓ encerra — nunca remove a tabela (ver cabeçalho). Sem
# ele, o SIGTERM do `docker stop`/update do Swarm era ignorado: no contêiner,
# este script é o PID 1, e o kernel não entrega ao PID 1 sinal cuja ação é a
# padrão. Conferido na VPS de teste: `docker stop -t 15` levava 16s e
# terminava em SIGKILL (137); cada update/reinício do serviço esperava o
# stop_grace_period inteiro.
encerrar_sem_limpar() {
  log "sinal de encerramento recebido — saindo SEM remover a tabela (as regras ficam no kernel do host)."
  exit 0
}

loop_principal() {
  trap encerrar_sem_limpar TERM INT
  log "iniciando — checagem a cada ~60s. A tabela nunca é removida ao sair (regras vivem no kernel do host)."
  ruleset_completo_do_processo=""
  ruleset_sem_pares_do_processo=""
  ruleset_minimo_do_processo=""
  if ! desativado_ativo; then
    ruleset_completo_do_processo="$(gerar_ruleset)"
    ruleset_sem_pares_do_processo="$(montar_ruleset "" "")"
    ruleset_minimo_do_processo="$(montar_ruleset "" "" sem_ssh)"
  fi
  while :; do
    if desativado_ativo; then
      aplicar_desativado
    else
      aplicar_se_necessario "$ruleset_completo_do_processo" "$ruleset_sem_pares_do_processo" "$ruleset_minimo_do_processo"
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
