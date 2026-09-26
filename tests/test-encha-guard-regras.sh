#!/bin/bash
# Ciclo C4 (A1 do plano de segurança do EnchaT): script do serviço
# `encha-guard` (encha-setup-panel/guard/encha-guard.sh) que fecha as
# portas internas do Docker Swarm expostas à Internet (2377/tcp,
# 7946/tcp+udp, 4789/udp — confirmado com nmap/tcpdump numa VPS
# descartável). Este teste chama o script REAL como processo externo, com
# a flag "--render" (que só imprime o `nft -f -` gerado e sai — nunca entra
# no loop principal, nunca toca no sistema), e cobre:
#   1. ruleset básico (sem env vars) tem os 2 drops e NENHUM bloco "set";
#   2. ENCHA_GUARD_PEERS com 2 IPv4 válidos -> "set pares4" com os dois,
#      e a regra "accept" correspondente ANTES dos drops;
#   3. entrada inválida/maliciosa misturada com IPs válidos é descartada
#      sem nunca chegar ao ruleset (várias tentativas de injeção);
#   4. ENCHA_GUARD_PERMITIR com IPv6 não-loopback -> aparece em "pares6";
#   5. "iif lo accept" sempre presente;
#   6. a saída nunca menciona "flush ruleset" nem as tabelas do Docker
#      ("ip filter", "ip6 filter", "ip nat");
#   7. se "nft" estiver disponível, valida a sintaxe de verdade (nft -c -f -,
#      dry-run, sem aplicar nada) em 3 variantes.
#
#   8. o LOOP principal, contra um `nft` FALSO (nunca o do sistema):
#      DESATIVADO=1 remove a tabela e não aplica nada; SIGTERM encerra o
#      processo SEM remover a tabela.
#
# Segurança do próprio teste: TODA execução do script sob teste roda com um
# diretório de binários falsos na frente do PATH (`nft` e `sleep` falsos) e
# com prazo (vigia que mata o processo). Assim, se uma regressão fizer o
# "--render" cair no loop, o teste FALHA em segundos em vez de travar o CI —
# e nunca aplica regra de firewall de verdade na máquina que roda o teste
# (o `nft` real só é chamado na seção 7, sempre com "-c", dry-run).
#
# Roda com: bash tests/test-encha-guard-regras.sh
set -u
cd "$(dirname "$0")/.." || exit 1
falhas=0
falha() { echo "❌ FALHOU: $1"; falhas=$((falhas + 1)); }
ok() { echo "✅ $1"; }

SCRIPT="encha-setup-panel/guard/encha-guard.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "❌ FALHOU: $SCRIPT não existe"
  exit 1
fi

TMP_TESTE="$(mktemp -d)"
trap 'rm -rf "$TMP_TESTE"' EXIT

REAL_SLEEP="$(command -v sleep)"
FAKEBIN="$TMP_TESTE/bin"
mkdir -p "$FAKEBIN"

# `sleep` falso: o intervalo de ~60s do loop vira 0,2s (o script chama
# `sleep 60 &` pelo PATH).
cat > "$FAKEBIN/sleep" <<'FAKE'
#!/bin/sh
exec "$REAL_SLEEP" 0.2
FAKE

# `nft` falso: nunca toca no kernel. Estado da "tabela" num arquivo em
# $FAKE_NFT_DIR; toda chamada é registrada (argv) em $FAKE_NFT_DIR/chamadas.
# A listagem imita o que o nft real faz (reformata o texto, os contadores
# mudam a cada leitura e "-a" acrescenta "# handle N") — conteúdo igual,
# texto diferente do que foi aplicado, como no kernel de verdade.
cat > "$FAKEBIN/nft" <<'FAKE'
#!/bin/sh
d="${FAKE_NFT_DIR:?FAKE_NFT_DIR não definido}"
echo "$*" >> "$d/chamadas"
case "$*" in
  "-c -f -")
    cat > "$d/ultimo_check"
    if [ -s "$d/recusar" ] && grep -qF "$(cat "$d/recusar")" "$d/ultimo_check"; then
      echo "Error: rejeitado pelo nft falso" >&2
      exit 1
    fi
    exit 0
    ;;
  "-f -")
    cat > "$d/ultimo_stdin"
    # "$d/recusar", se existir, tem um trecho: ruleset que o contém é recusado
    # (simula o nft rejeitando a transação inteira por causa de um elemento).
    if [ -s "$d/recusar" ] && grep -qF "$(cat "$d/recusar")" "$d/ultimo_stdin"; then
      rm -f "$d/ultimo_stdin"
      echo "Error: rejeitado pelo nft falso" >&2
      exit 1
    fi
    awk '/^table inet encha_guard [{]$/ { n++ } n >= 1' "$d/ultimo_stdin" \
      | sed -e 's/^    /\t\t/' -e 's/^  /\t/' -e 's/priority -5;/priority filter - 5;/' > "$d/tabela"
    echo 0 > "$d/contador"
    exit 0
    ;;
  "list table inet encha_guard" | "-a list table inet encha_guard")
    [ -f "$d/tabela" ] || { echo "Error: No such file or directory" >&2; exit 1; }
    n="$(cat "$d/contador" 2>/dev/null || echo 0)"
    n=$((n + 1))
    echo "$n" > "$d/contador"
    # Como o nft real, lista cada "set" em várias linhas. Com
    # "$d/trafego_ssh" presente, os sets dinâmicos do limite de SSH ganham
    # elementos que mudam a CADA leitura (origem nova, "expires" contando),
    # no formato exato do nft 1.0.9 real (conferido na VPS de teste),
    # inclusive quebrados em duas linhas como o nft faz com lista longa.
    trafego=0
    [ -f "$d/trafego_ssh" ] && trafego=1
    awk -v n="$n" -v trafego="$trafego" '
      /^\tset [a-z0-9_]+ [{] .*[}]$/ {
        nome = $2
        corpo = $0
        sub(/^\tset [a-z0-9_]+ [{] */, "", corpo)
        sub(/ *[}]$/, "", corpo)
        print "\tset " nome " {"
        k = split(corpo, partes, ";")
        for (i = 1; i <= k; i++) {
          p = partes[i]
          gsub(/^ +| +$/, "", p)
          if (p != "") print "\t\t" p
        }
        if (trafego == 1 && nome ~ /^ssh_limite/) {
          print "\t\telements = { 198.51.100." n " limit rate over 20/minute burst 30 packets expires 1m" (59 - n % 59) "s908ms,"
          print "\t\t\t     203.0.113.9 limit rate over 20/minute burst 30 packets expires 1m" n "s568ms }"
        }
        print "\t}"
        next
      }
      { print }
    ' "$d/tabela" > "$d/listagem"
    if [ "$1" = "-a" ]; then
      sed -e "s/counter drop/counter packets $n bytes $((n * 60)) drop # handle $((n + 7))/" \
        -e "s/accept\$/accept # handle $((n + 3))/" "$d/listagem"
    else
      sed -e "s/counter drop/counter packets $n bytes $((n * 60)) drop/" "$d/listagem"
    fi
    exit 0
    ;;
  "delete table inet encha_guard")
    [ -f "$d/tabela" ] || exit 1
    rm -f "$d/tabela"
    exit 0
    ;;
  *)
    echo "nft falso: chamada inesperada: $*" >&2
    exit 2
    ;;
esac
FAKE
chmod +x "$FAKEBIN/sleep" "$FAKEBIN/nft"

# Roda "$@" com prazo: passado o prazo, mata com KILL e devolve 137.
com_prazo() {
  local prazo="$1"
  shift
  "$@" &
  local pid=$!
  ( "$REAL_SLEEP" "$prazo"; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local vigia=$!
  wait "$pid"
  local rc=$?
  kill "$vigia" 2>/dev/null
  wait "$vigia" 2>/dev/null
  return "$rc"
}

# Novo diretório de estado do nft falso (uma "máquina" limpa por cenário).
NFT_RENDER_DIR="$TMP_TESTE/nft-render"
mkdir -p "$NFT_RENDER_DIR"
: > "$NFT_RENDER_DIR/chamadas"

# SEMPRE chamada em segundo plano ("&", que já abre um subshell): o `exec`
# troca esse subshell pelo `sh` do script, então o PID de "$!" é o do próprio
# script — é nele que o SIGTERM e o KILL do vigia chegam. Sem o `exec`, o
# sinal mataria só o subshell do bash e o loop seguiria órfão (e o teste de
# SIGTERM passaria sem nunca ter sinalizado o script).
# shellcheck disable=SC2120 # "$@" é o repasse opcional (ex.: --render)
sob_teste() {
  FAKE_NFT_DIR="${FAKE_NFT_DIR:-$NFT_RENDER_DIR}" REAL_SLEEP="$REAL_SLEEP" \
    PATH="$FAKEBIN:$PATH" exec sh "$SCRIPT" "$@"
}

# Executor do script sob teste: sempre com "sh" explícito (POSIX sh, não
# bash), sempre "--render", sempre com os binários falsos e com prazo.
renderizar() {
  com_prazo 5 sob_teste --render
}

# --- 0. "--render" termina sozinho e nunca chama o nft --------------------

rc_render=0
( unset ENCHA_GUARD_PEERS ENCHA_GUARD_PERMITIR ENCHA_GUARD_DESATIVADO; renderizar ) >/dev/null 2>&1 || rc_render=$?
if [ "$rc_render" -eq 0 ]; then
  ok "--render: termina sozinho com status 0 (não cai no loop)"
else
  falha "--render: não terminou/saiu com status $rc_render (caiu no loop? foi morto pelo prazo?)"
fi

# --- 1. Sem env var nenhuma: ruleset básico, sem nenhum "set" -------------

saida_basica="$(
  unset ENCHA_GUARD_PEERS ENCHA_GUARD_PERMITIR ENCHA_GUARD_DESATIVADO
  renderizar
)"

if echo "$saida_basica" | grep -q 'tcp dport { 2377, 7946 } counter drop'; then
  ok "sem env vars: drop de tcp {2377,7946} presente"
else
  falha "sem env vars: drop de tcp {2377,7946} ausente"
fi

if echo "$saida_basica" | grep -q 'udp dport { 4789, 7946 } counter drop'; then
  ok "sem env vars: drop de udp {4789,7946} presente"
else
  falha "sem env vars: drop de udp {4789,7946} ausente"
fi

if echo "$saida_basica" | grep -q 'set pares4'; then
  falha "sem env vars: 'set pares4' apareceu (deveria ser omitido — lista vazia)"
else
  ok "sem env vars: nenhum 'set pares4'"
fi

if echo "$saida_basica" | grep -q 'set pares6'; then
  falha "sem env vars: 'set pares6' apareceu (deveria ser omitido — lista vazia)"
else
  ok "sem env vars: nenhum 'set pares6'"
fi

if echo "$saida_basica" | grep -q '@pares4\|@pares6'; then
  falha "sem env vars: referência a @pares4/@pares6 sem o set correspondente"
else
  ok "sem env vars: nenhuma referência a @pares4/@pares6"
fi

# --- 2. ENCHA_GUARD_PEERS com 2 IPv4 válidos ------------------------------

saida_ipv4="$(
  unset ENCHA_GUARD_PERMITIR ENCHA_GUARD_DESATIVADO
  ENCHA_GUARD_PEERS="10.0.0.5 10.0.0.6"
  export ENCHA_GUARD_PEERS
  renderizar
)"

if echo "$saida_ipv4" | grep -q 'set pares4'; then
  ok "IPv4: 'set pares4' presente"
else
  falha "IPv4: 'set pares4' ausente"
fi

if echo "$saida_ipv4" | grep -E 'set pares4.*10\.0\.0\.5.*10\.0\.0\.6|set pares4.*10\.0\.0\.6.*10\.0\.0\.5' >/dev/null; then
  ok "IPv4: os dois IPs aparecem no set pares4"
else
  falha "IPv4: os dois IPs não aparecem juntos no set pares4"
  echo "$saida_ipv4" | grep 'pares4'
fi

pos_accept="$(printf '%s\n' "$saida_ipv4" | grep -n 'ip saddr @pares4 accept' | head -1 | cut -d: -f1)"
pos_drop="$(printf '%s\n' "$saida_ipv4" | grep -n 'tcp dport { 2377, 7946 } counter drop' | head -1 | cut -d: -f1)"
if [ -n "$pos_accept" ] && [ -n "$pos_drop" ] && [ "$pos_accept" -lt "$pos_drop" ]; then
  ok "IPv4: 'ip saddr @pares4 accept' vem antes dos drops"
else
  falha "IPv4: 'ip saddr @pares4 accept' ausente ou não vem antes dos drops (accept=$pos_accept drop=$pos_drop)"
fi

if echo "$saida_ipv4" | grep -q 'set pares6'; then
  falha "IPv4 apenas: 'set pares6' apareceu (não deveria — nenhum IPv6 fornecido)"
else
  ok "IPv4 apenas: nenhum 'set pares6'"
fi

# --- 3. Entradas inválidas/maliciosas misturadas com IPs válidos ---------

# a) payload colado a uma tentativa de sintaxe do nft (chaves, ponto-e-vírgula,
#    palavra "flush ruleset" — o clássico "sair do valor da env var").
injecao_a="10.0.0.7 } ; flush ruleset 10.0.0.8"
# b) o mesmo veneno colado DENTRO do que pareceria um IP (sem espaço) — não
#    pode "aproveitar" o prefixo válido, o token inteiro tem que cair fora.
injecao_b="10.0.0.9;flush ruleset;10.0.0.10"
# c) aspas dentro do valor.
injecao_c='10.0.0.11 "malicioso" 10.0.0.12'
# d) quebra de linha literal dentro do valor.
injecao_d="10.0.0.13
flush ruleset
10.0.0.14"
# e) octeto fora de faixa (formato bate no regex solto, mas não numericamente).
injecao_e="999.999.999.999 10.0.0.15"

peers_maliciosos="$injecao_a,$injecao_b,$injecao_c,$injecao_d,$injecao_e"

saida_injecao="$(
  unset ENCHA_GUARD_PERMITIR ENCHA_GUARD_DESATIVADO
  ENCHA_GUARD_PEERS="$peers_maliciosos"
  export ENCHA_GUARD_PEERS
  renderizar 2>"$TMP_TESTE/stderr-injecao.log"
)"

falhou_injecao=0
for termo_proibido in 'flush' 'ruleset' 'malicioso' '999.999.999.999' '10.0.0.9;' ';10.0.0.10'; do
  if printf '%s\n' "$saida_injecao" | grep -qF "$termo_proibido"; then
    falha "injeção: termo/entrada maliciosa vazou pro ruleset: '$termo_proibido'"
    falhou_injecao=1
  fi
done
[ "$falhou_injecao" -eq 0 ] && ok "injeção: nenhum termo/entrada maliciosa vazou pro ruleset (5 tentativas testadas)"

# Os IPs válidos que sobrevivem a cada tentativa (os que NÃO estavam colados
# a lixo: 10.0.0.7, 10.0.0.8, 10.0.0.11, 10.0.0.12, 10.0.0.13, 10.0.0.14 e
# 10.0.0.15) precisam continuar presentes — prova que a validação descarta
# só o que é inválido, não a lista inteira.
esperados_validos="10.0.0.7 10.0.0.8 10.0.0.11 10.0.0.12 10.0.0.13 10.0.0.14 10.0.0.15"
faltando=0
for ip_valido in $esperados_validos; do
  if ! printf '%s\n' "$saida_injecao" | grep -qF "$ip_valido"; then
    falha "injeção: IP válido '$ip_valido' devia continuar no ruleset e não apareceu"
    faltando=1
  fi
done
[ "$faltando" -eq 0 ] && ok "injeção: todos os IPs válidos (não-colados a lixo) continuam no ruleset"

# 10.0.0.9 e 10.0.0.10 estavam colados ao veneno sem espaço (injecao_b) — o
# token inteiro (ex.: "10.0.0.9;flush") não bate no formato estrito, então
# o IP embutido também deve ser descartado (prova que colar não "salva"
# um prefixo válido).
if printf '%s\n' "$saida_injecao" | grep -qF '10.0.0.9' || printf '%s\n' "$saida_injecao" | grep -qF '10.0.0.10'; then
  falha "injeção: 10.0.0.9/10.0.0.10 (colados ao veneno sem separador) não deveriam ter passado"
else
  ok "injeção: token colado ao veneno (sem separador) é descartado por completo, IP embutido incluso"
fi

# O script deve ter LOGADO (stderr) a rejeição, nunca silenciar.
if grep -qi 'descartad' "$TMP_TESTE/stderr-injecao.log" 2>/dev/null; then
  ok "injeção: rejeição foi logada em stderr"
else
  falha "injeção: nada foi logado em stderr sobre entradas descartadas"
fi

# --- 4. IPv6 não-loopback em ENCHA_GUARD_PERMITIR -------------------------

saida_ipv6="$(
  unset ENCHA_GUARD_PEERS ENCHA_GUARD_DESATIVADO
  ENCHA_GUARD_PERMITIR="::1 fe80::1 2001:db8::1"
  export ENCHA_GUARD_PERMITIR
  renderizar
)"

if echo "$saida_ipv6" | grep -q 'set pares6' && echo "$saida_ipv6" | grep -qF '2001:db8::1'; then
  ok "IPv6: 2001:db8::1 aparece em pares6"
else
  falha "IPv6: 2001:db8::1 não aparece em pares6"
  echo "$saida_ipv6" | grep 'pares6'
fi

if echo "$saida_ipv6" | grep -q 'ip6 saddr @pares6 accept'; then
  ok "IPv6: regra 'ip6 saddr @pares6 accept' presente"
else
  falha "IPv6: regra 'ip6 saddr @pares6 accept' ausente"
fi

# --- 5. "iif lo accept" sempre presente -----------------------------------

for saida_nome_valor in "basica:$saida_basica" "ipv4:$saida_ipv4" "ipv6:$saida_ipv6"; do
  nome="${saida_nome_valor%%:*}"
  valor="${saida_nome_valor#*:}"
  if echo "$valor" | grep -q 'iif "lo" accept'; then
    ok "iif \"lo\" accept presente (variante: $nome)"
  else
    falha "iif \"lo\" accept AUSENTE (variante: $nome)"
  fi
done

# --- 6. Nunca toca nas tabelas do Docker, nunca "flush ruleset" ----------

for saida_nome_valor in "basica:$saida_basica" "ipv4:$saida_ipv4" "ipv6:$saida_ipv6" "injecao:$saida_injecao"; do
  nome="${saida_nome_valor%%:*}"
  valor="${saida_nome_valor#*:}"
  achado=0
  for proibido in 'flush ruleset' 'ip filter' 'ip6 filter' 'ip nat'; do
    if echo "$valor" | grep -qF "$proibido"; then
      falha "saída ($nome) contém '$proibido' — nunca deveria tocar nas tabelas do Docker nem fazer flush"
      achado=1
    fi
  done
  [ "$achado" -eq 0 ] && ok "saída ($nome): sem flush ruleset / tabelas do Docker"
done

# --- 6b. Validação rente ao que o nft aceita --------------------------------

# Toda entrada que o validador aceita vai para o MESMO `nft -f -` das regras
# de drop. Se o nft rejeitar um único elemento, a transação inteira falha e o
# guarda não aplica nada — as portas do Swarm ficam abertas. Por isso o
# validador precisa ser, no máximo, tão permissivo quanto o nft. Os casos
# "rejeitar" abaixo foram todos conferidos contra o nft 1.1.5 real (Alpine):
# ou o nft recusa a transação inteira (":", ":::", "12345::", "1::2::3",
# "1:2:3:4:5:6:7:8:9", "008.0.0.1"), ou aceita com OUTRO significado —
# "010.0.0.1" é lido como octal pelo resolvedor e libera 8.0.0.1, não
# 10.0.0.1. Zero à esquerda nunca é aceito (nem no octeto, nem no prefixo).
aceito_pelo_validador() {
  local saida
  saida="$(
    unset ENCHA_GUARD_PEERS ENCHA_GUARD_DESATIVADO
    ENCHA_GUARD_PERMITIR="$1"
    export ENCHA_GUARD_PERMITIR
    renderizar 2>/dev/null
  )"
  printf '%s\n' "$saida" | grep -q 'elements = {'
}

DEVEM_SER_REJEITADOS='010.0.0.1 008.0.0.1 10.0.0.01 10.0.0.1/08 10.0.0.1/ 10.0.0.1/33 : ::: :::1 1:2:3:4:5:6:7:8:9 1::2::3 12345:: :1:: 1: 1:2:3:4:5:6:7:8: 1:2:3:4:5:6:7:8:: 1::2:3:4:5:6:7:8 1:2:3:4:5:6:7 2001:db8::1/ 2001:db8::1/0128 2001:db8::1/129 2001:db8::g ::ffff:1.2.3.4'
DEVEM_SER_ACEITOS='0.0.0.0 10.0.0.1 10.0.0.1/0 10.0.0.0/24 255.255.255.255/32 :: ::1 1:: ::ffff 1:2:3:4:5:6:7:8 1:2:3:4:5:6:7:: ::2:3:4:5:6:7:8 fe80::1/64 2001:DB8::A 2001:db8::1/128'

rejeicao_ok=1
for entrada in $DEVEM_SER_REJEITADOS; do
  if aceito_pelo_validador "$entrada"; then
    falha "validador aceitou '$entrada' (o nft recusa ou lê com outro sentido)"
    rejeicao_ok=0
  fi
done
[ "$rejeicao_ok" -eq 1 ] && ok "validador: rejeita os casos que o nft recusa ou lê diferente (zero à esquerda, IPv6 malformado)"

aceite_ok=1
for entrada in $DEVEM_SER_ACEITOS; do
  if ! aceito_pelo_validador "$entrada"; then
    falha "validador rejeitou '$entrada' (endereço válido)"
    aceite_ok=0
  fi
done
[ "$aceite_ok" -eq 1 ] && ok "validador: aceita IPv4/IPv6/CIDR válidos, inclusive as formas comprimidas"

# --- 6c. Curinga de shell na entrada nunca vira nome de arquivo ------------

# A lista é quebrada em itens por expansão sem aspas; sem "set -f", um "*"
# na env var seria expandido para os nomes de arquivo do diretório corrente
# — e um arquivo chamado "10.9.9.9" viraria um par liberado.
dir_glob="$TMP_TESTE/glob"
mkdir -p "$dir_glob"
: > "$dir_glob/10.9.9.9"
saida_glob="$(
  unset ENCHA_GUARD_PEERS ENCHA_GUARD_DESATIVADO
  ENCHA_GUARD_PERMITIR='* 10.0.0.[0-9]*'
  export ENCHA_GUARD_PERMITIR
  script_abs="$PWD/$SCRIPT"
  cd "$dir_glob" && FAKE_NFT_DIR="$NFT_RENDER_DIR" REAL_SLEEP="$REAL_SLEEP" \
    PATH="$FAKEBIN:$PATH" com_prazo 5 sh "$script_abs" --render 2>/dev/null
)"
if printf '%s\n' "$saida_glob" | grep -qF '10.9.9.9'; then
  falha "curinga: '*' na env var foi expandido para nome de arquivo (10.9.9.9 virou par liberado)"
else
  ok "curinga: '*' na env var não é expandido para nomes de arquivo"
fi

# --- 7. Validação de sintaxe REAL com nft -c -f - (se disponível) --------

# Nunca instala pacote (um teste não mexe no sistema de quem o roda). O nft
# real só entra se já existir E puder falar com o netlink (root/CAP_NET_ADMIN)
# — "nft -c" sem permissão falha por EPERM, não por sintaxe, e isso não pode
# virar falso negativo num runner sem root.
if command -v nft >/dev/null 2>&1 && echo 'table inet encha_guard_sonda {}' | nft -c -f - >/dev/null 2>&1; then
  validar_sintaxe() {
    descricao="$1"
    saida="$2"
    if printf '%s\n' "$saida" | nft -c -f - >"$TMP_TESTE/nft-erro.log" 2>&1; then
      ok "nft -c -f -: sintaxe válida ($descricao)"
    else
      falha "nft -c -f -: sintaxe INVÁLIDA ($descricao) — $(cat "$TMP_TESTE/nft-erro.log")"
    fi
  }
  validar_sintaxe "vazio (sem sets)" "$saida_basica"
  validar_sintaxe "só IPv4" "$saida_ipv4"
  saida_mista="$(
    unset ENCHA_GUARD_DESATIVADO
    ENCHA_GUARD_PEERS="10.0.0.5 10.0.0.6"
    ENCHA_GUARD_PERMITIR="2001:db8::1"
    export ENCHA_GUARD_PEERS ENCHA_GUARD_PERMITIR
    renderizar
  )"
  validar_sintaxe "IPv4 + IPv6" "$saida_mista"
  # Tudo que o validador aceita, junto, tem que passar no nft real.
  saida_bordas="$(
    unset ENCHA_GUARD_PEERS ENCHA_GUARD_DESATIVADO
    ENCHA_GUARD_PERMITIR="$DEVEM_SER_ACEITOS"
    export ENCHA_GUARD_PERMITIR
    renderizar 2>/dev/null
  )"
  validar_sintaxe "todas as bordas aceitas pelo validador" "$saida_bordas"
  # E cada caso rejeitado, se passasse, derrubaria a transação ou mudaria o
  # sentido — confere que o nft real de fato recusa os que dizemos recusar
  # por sintaxe (os de sentido diferente, como 010.0.0.1, ele aceita).
  for entrada in ':' ':::' '12345::' '1::2::3' '1:2:3:4:5:6:7:8:9' '008.0.0.1'; do
    if printf 'table inet encha_guard_sonda { set s { type %s; flags interval; elements = { %s }; }; }\n' \
        "$(case "$entrada" in *:*) echo ipv6_addr ;; *) echo ipv4_addr ;; esac)" "$entrada" \
        | nft -c -f - >/dev/null 2>&1; then
      falha "nft real ACEITOU '$entrada' — revise a lista de rejeição do teste"
    fi
  done
  ok "nft real: recusa os casos de sintaxe que o validador também recusa"
else
  echo "ℹ️  'nft' real indisponível (ausente ou sem CAP_NET_ADMIN) — pulando a validação de sintaxe real. A geração de regras já foi coberta pelos testes 1-6 acima."
fi

# --- 8. Loop principal contra o nft falso ----------------------------------

# Roda o loop por "$1" segundos num diretório de estado novo ("$2"), manda
# SIGTERM e espera até 3s pela saída. LOOP_SAIU=1 se saiu sozinho. Com "$3"
# (segundos), apaga por fora, nesse instante, o arquivo "$4" do estado do nft
# falso (padrão: "tabela" — simula alguém removendo a tabela do kernel; ou
# "recusar" — o nft deixa de recusar a transação) e segue até completar "$1".
rodar_loop() {
  local segundos="$1" dir="$2" apagar_em="${3:-}" apagar_o_que="${4:-tabela}"
  mkdir -p "$dir"
  : > "$dir/chamadas"
  # shellcheck disable=SC2119 # sem argumento de propósito: é o loop real
  FAKE_NFT_DIR="$dir" sob_teste 2>"$dir/stderr" &
  local pid=$!
  if [ -n "$apagar_em" ]; then
    "$REAL_SLEEP" "$apagar_em"
    rm -f "${dir:?}/$apagar_o_que"
    "$REAL_SLEEP" "$(awk -v a="$segundos" -v b="$apagar_em" 'BEGIN { print a - b }')"
  else
    "$REAL_SLEEP" "$segundos"
  fi
  kill -TERM "$pid" 2>/dev/null
  LOOP_SAIU=0
  for _ in $(seq 1 30); do
    if ! kill -0 "$pid" 2>/dev/null; then
      LOOP_SAIU=1
      break
    fi
    "$REAL_SLEEP" 0.1
  done
  [ "$LOOP_SAIU" -eq 1 ] || kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 0
}

conta_chamadas() { grep -cxF -- "$2" "$1/chamadas" 2>/dev/null || true; }

# 8a. DESATIVADO=1 com a tabela já aplicada: remove e não aplica nada.
dir_desat="$TMP_TESTE/loop-desativado"
mkdir -p "$dir_desat"
printf 'table inet encha_guard {\n}\n' > "$dir_desat/tabela"
(
  unset ENCHA_GUARD_PEERS ENCHA_GUARD_PERMITIR
  ENCHA_GUARD_DESATIVADO=1
  export ENCHA_GUARD_DESATIVADO
  rodar_loop 1 "$dir_desat"
)
if [ "$(conta_chamadas "$dir_desat" 'delete table inet encha_guard')" -ge 1 ] && [ ! -f "$dir_desat/tabela" ]; then
  ok "loop: ENCHA_GUARD_DESATIVADO=1 remove a tabela"
else
  falha "loop: ENCHA_GUARD_DESATIVADO=1 não removeu a tabela ($(tr '\n' '|' < "$dir_desat/chamadas"))"
fi
if [ "$(conta_chamadas "$dir_desat" '-f -')" -eq 0 ]; then
  ok "loop: ENCHA_GUARD_DESATIVADO=1 nunca aplica ruleset"
else
  falha "loop: ENCHA_GUARD_DESATIVADO=1 aplicou ruleset mesmo desativado"
fi

# 8b. Loop normal: aplica, e SIGTERM encerra SEM remover a tabela.
dir_term="$TMP_TESTE/loop-term"
(
  unset ENCHA_GUARD_PEERS ENCHA_GUARD_PERMITIR ENCHA_GUARD_DESATIVADO
  rodar_loop 1 "$dir_term"
  echo "$LOOP_SAIU" > "$dir_term/saiu"
)
if [ "$(conta_chamadas "$dir_term" '-f -')" -ge 1 ] && grep -qF 'udp dport { 4789, 7946 } counter drop' "$dir_term/ultimo_stdin" 2>/dev/null; then
  ok "loop: aplica o ruleset (com o drop de udp 4789) pelo nft"
else
  falha "loop: não aplicou o ruleset esperado ($(tr '\n' '|' < "$dir_term/chamadas"))"
fi
if [ "$(conta_chamadas "$dir_term" 'delete table inet encha_guard')" -eq 0 ] && [ -f "$dir_term/tabela" ]; then
  ok "loop: SIGTERM NÃO remove a tabela (regras sobrevivem ao restart do contêiner)"
else
  falha "loop: SIGTERM removeu a tabela — a proteção cairia a cada restart/update do serviço"
fi
if [ "$(cat "$dir_term/saiu" 2>/dev/null)" = "1" ]; then
  ok "loop: SIGTERM encerra o processo em até 3s"
else
  falha "loop: o processo não saiu em até 3s depois do SIGTERM"
fi


# 8c. Idempotência: com a tabela intacta, o loop NÃO reaplica a cada ciclo
# (reaplicar zera os contadores de drop e enche o log a cada minuto). O nft
# (falso e real) devolve a tabela em formato diferente do que foi aplicado,
# com contadores que mudam e "# handle N" — a comparação tem que sobreviver
# a isso. Em ~1,4s o loop dá ~7 voltas: tem que haver exatamente 1 aplicação.
dir_idem="$TMP_TESTE/loop-idempotente"
(
  unset ENCHA_GUARD_DESATIVADO
  ENCHA_GUARD_PEERS="10.0.0.5,10.0.0.6"
  ENCHA_GUARD_PERMITIR="2001:db8::1"
  export ENCHA_GUARD_PEERS ENCHA_GUARD_PERMITIR
  rodar_loop 1.4 "$dir_idem"
)
aplicacoes="$(conta_chamadas "$dir_idem" '-f -')"
if [ "$aplicacoes" -eq 1 ]; then
  ok "loop: tabela intacta não é reaplicada (1 aplicação em ~7 ciclos)"
else
  falha "loop: tabela intacta reaplicada a cada ciclo ($aplicacoes aplicações em ~7 ciclos)"
fi

# 8d. Tabela apagada por fora no meio do caminho: volta no ciclo seguinte,
# e só uma vez.
dir_some="$TMP_TESTE/loop-tabela-some"
(
  unset ENCHA_GUARD_PEERS ENCHA_GUARD_PERMITIR ENCHA_GUARD_DESATIVADO
  rodar_loop 1.6 "$dir_some" 0.7
)
aplicacoes="$(conta_chamadas "$dir_some" '-f -')"
if [ "$aplicacoes" -eq 2 ] && [ -f "$dir_some/tabela" ]; then
  ok "loop: tabela removida por fora é reaplicada (2 aplicações no total)"
else
  falha "loop: tabela removida por fora — esperadas 2 aplicações e a tabela de volta, houve $aplicacoes"
fi


# 8e. Falha fechada: se o nft recusar a transação com a allowlist (versão
# nova do nft mais estrita, elemento que escapou do validador), as portas
# NÃO podem ficar abertas — o guarda aplica as regras de drop sem os pares,
# avisa no log e, nos ciclos seguintes, só CONFERE (nft -c) se a versão
# completa já passa, sem reaplicar nada (contadores intactos).
dir_fecha="$TMP_TESTE/loop-falha-fechada"
mkdir -p "$dir_fecha"
printf 'pares6' > "$dir_fecha/recusar"
(
  unset ENCHA_GUARD_DESATIVADO
  ENCHA_GUARD_PEERS="10.0.0.5"
  ENCHA_GUARD_PERMITIR="2001:db8::1"
  export ENCHA_GUARD_PEERS ENCHA_GUARD_PERMITIR
  rodar_loop 1.4 "$dir_fecha"
)
if [ -f "$dir_fecha/tabela" ] && grep -qF 'udp dport { 4789, 7946 } counter drop' "$dir_fecha/ultimo_stdin" 2>/dev/null \
    && ! grep -qF 'pares' "$dir_fecha/ultimo_stdin"; then
  ok "falha fechada: allowlist recusada pelo nft -> drops aplicados sem os pares"
else
  falha "falha fechada: allowlist recusada pelo nft deixou o guarda sem regra nenhuma (portas abertas)"
fi
if grep -qF '(falha fechada)' "$dir_fecha/stderr" 2>/dev/null; then
  ok "falha fechada: o modo degradado é avisado no log"
else
  falha "falha fechada: o modo degradado não foi avisado no log"
fi
aplicacoes="$(conta_chamadas "$dir_fecha" '-f -')"
if [ "$aplicacoes" -eq 2 ]; then
  ok "falha fechada: não reaplica a cada ciclo (completa recusada + sem pares = 2 aplicações)"
else
  falha "falha fechada: esperadas 2 aplicações (completa recusada + sem pares), houve $aplicacoes"
fi

# 8f. ...e quando a versão completa volta a passar (falha transitória), o
# guarda a aplica sozinho, sem esperar reinício do contêiner.
dir_volta="$TMP_TESTE/loop-falha-transitoria"
mkdir -p "$dir_volta"
printf 'pares4' > "$dir_volta/recusar"
(
  unset ENCHA_GUARD_PERMITIR ENCHA_GUARD_DESATIVADO
  ENCHA_GUARD_PEERS="10.0.0.5"
  export ENCHA_GUARD_PEERS
  rodar_loop 1.6 "$dir_volta" 0.7 recusar
)
if grep -qF '@pares4 accept' "$dir_volta/ultimo_stdin" 2>/dev/null && [ -f "$dir_volta/tabela" ]; then
  ok "falha fechada: quando o nft volta a aceitar, a versão completa (com pares) é aplicada"
else
  falha "falha fechada: a versão completa não voltou depois que o nft passou a aceitar"
fi

# 8g. PID 1: no contêiner o script é o PID 1, e o kernel descarta sinal para
# o PID 1 cuja ação é a padrão — sem um trap, o SIGTERM do `docker stop` era
# ignorado e cada update esperava o stop_grace_period inteiro até o SIGKILL
# (medido na VPS: 15s/137 sem trap, 0s/0 com). Isso não dá para reproduzir
# fora de um namespace de PID, então aqui a checagem é estrutural: há trap
# de TERM, e o handler só encerra — nunca chama o nft (o 8b já prova, pelo
# comportamento, que o SIGTERM não remove a tabela).
corpo_handler="$(sed -n '/^encerrar_sem_limpar() {/,/^}/p' "$SCRIPT")"
if grep -Eq '^[[:space:]]*trap encerrar_sem_limpar TERM' "$SCRIPT" && [ -n "$corpo_handler" ] \
    && ! printf '%s\n' "$corpo_handler" | grep -q 'nft'; then
  ok "PID 1: trap de TERM registrado, e o handler só encerra (não chama o nft)"
else
  falha "PID 1: sem trap de TERM (o docker stop espera o SIGKILL) ou o handler chama o nft"
fi

# --- 9. C7 (achado A2): limite de taxa de NOVAS conexões SSH -------------
#
# Mitigação automática para as VPS existentes que não vão rodar o fail2ban de
# verdade do C10 (decisão do Carlos, 2026-09-25): limite de taxa de NOVAS
# conexões SSH por IP de origem dentro do próprio nft, sem derrubar sessões
# já abertas.

# 9a. Default (sem ENCHA_GUARD_SSH_PORTAS): porta 22, "ct state new" e o
# limite exatos do plano — 20/minute, burst 30 packets.
saida_ssh_default="$(
  unset ENCHA_GUARD_PEERS ENCHA_GUARD_PERMITIR ENCHA_GUARD_DESATIVADO ENCHA_GUARD_SSH_PORTAS
  renderizar
)"
if echo "$saida_ssh_default" | grep -qF 'tcp dport { 22 } ct state new update @ssh_limite4 { ip saddr limit rate over 20/minute burst 30 packets } drop'; then
  ok "SSH: default (sem env var) -> porta 22, ct state new, 20/minute burst 30 POR IPv4 de origem"
else
  falha "SSH: default não gerou a regra IPv4 esperada (porta 22, ct state new, balde por origem, limite do plano)"
  echo "$saida_ssh_default" | grep 'ct state'
fi
if echo "$saida_ssh_default" | grep -qF 'tcp dport { 22 } ct state new update @ssh_limite6 { ip6 saddr and ffff:ffff:ffff:ffff:: limit rate over 20/minute burst 30 packets } drop'; then
  ok "SSH: default -> mesma regra para IPv6, balde por /64 de origem"
else
  falha "SSH: default não gerou a regra IPv6 esperada (balde por /64 de origem)"
  echo "$saida_ssh_default" | grep 'ct state'
fi

# 9a'. Balde POR ORIGEM, nunca global (achado da auditoria C7): um "limit
# rate" solto na regra é um balde único para a Internet inteira — o robô de
# força bruta gasta as 20/min de todo mundo e o operador fica sem SSH durante
# o ataque (medido no kernel real: 2 de 5 tentativas do IP legítimo passaram
# com o limite global, 5 de 5 com o limite por IP). Todo "limit rate" do
# ruleset tem que estar DENTRO de um "update @ssh_limite* { <origem> ... }".
if printf '%s\n' "$saida_ssh_default" | grep 'limit rate' | grep -vq 'update @ssh_limite[46] { ip6\{0,1\} saddr '; then
  falha "SSH: há 'limit rate' fora de um set dinâmico por origem — balde GLOBAL, o atacante tranca o operador para fora"
  printf '%s\n' "$saida_ssh_default" | grep 'limit rate'
else
  ok "SSH: todo 'limit rate' é por origem (update @ssh_limite4/6), nunca um balde global"
fi
if echo "$saida_ssh_default" | grep -qF 'set ssh_limite4 { type ipv4_addr; size 65535; flags dynamic,timeout; timeout 2m; }' \
    && echo "$saida_ssh_default" | grep -qF 'set ssh_limite6 { type ipv6_addr; size 65535; flags dynamic,timeout; timeout 2m; }'; then
  ok "SSH: sets dos baldes declarados com teto de memória (size) e expiração (timeout 2m)"
else
  falha "SSH: sets ssh_limite4/ssh_limite6 ausentes ou sem size/timeout (memória do kernel sem teto)"
fi

# 9b. Duas portas, espaço OU vírgula como separador (mesmo padrão de
# ENCHA_GUARD_PEERS/ENCHA_GUARD_PERMITIR).
saida_ssh_2portas="$(
  unset ENCHA_GUARD_PEERS ENCHA_GUARD_PERMITIR ENCHA_GUARD_DESATIVADO
  ENCHA_GUARD_SSH_PORTAS="22 2222"
  export ENCHA_GUARD_SSH_PORTAS
  renderizar
)"
if echo "$saida_ssh_2portas" | grep -qF 'tcp dport { 22,2222 } ct state new'; then
  ok "SSH: ENCHA_GUARD_SSH_PORTAS=\"22 2222\" -> as duas portas juntas no dport"
else
  falha "SSH: as duas portas customizadas (espaço) não apareceram juntas no dport"
  echo "$saida_ssh_2portas" | grep 'ct state'
fi

saida_ssh_2portas_virgula="$(
  unset ENCHA_GUARD_PEERS ENCHA_GUARD_PERMITIR ENCHA_GUARD_DESATIVADO
  ENCHA_GUARD_SSH_PORTAS="22,2222"
  export ENCHA_GUARD_SSH_PORTAS
  renderizar
)"
if echo "$saida_ssh_2portas_virgula" | grep -qF 'tcp dport { 22,2222 } ct state new'; then
  ok "SSH: vírgula como separador produz o mesmo resultado que espaço"
else
  falha "SSH: vírgula como separador não produziu o mesmo resultado que espaço"
fi

# 9c. Porta inválida (fora de faixa, ou não-numérica) misturada com válidas:
# descartada e logada, as válidas continuam — nunca a lista inteira cai.
saida_ssh_invalida="$(
  unset ENCHA_GUARD_PEERS ENCHA_GUARD_PERMITIR ENCHA_GUARD_DESATIVADO
  ENCHA_GUARD_SSH_PORTAS="22 99999 2222"
  export ENCHA_GUARD_SSH_PORTAS
  renderizar 2>"$TMP_TESTE/stderr-ssh-invalida.log"
)"
if echo "$saida_ssh_invalida" | grep -qF 'tcp dport { 22,2222 } ct state new' \
    && ! echo "$saida_ssh_invalida" | grep -qF '99999'; then
  ok "SSH: porta fora de faixa (99999) descartada, portas válidas (22, 2222) continuam"
else
  falha "SSH: porta fora de faixa não foi descartada corretamente"
  echo "$saida_ssh_invalida" | grep 'ct state'
fi
if grep -qi 'porta ssh descartada' "$TMP_TESTE/stderr-ssh-invalida.log" 2>/dev/null; then
  ok "SSH: porta descartada foi logada em stderr"
else
  falha "SSH: porta descartada não foi logada em stderr"
fi

saida_ssh_letras="$(
  unset ENCHA_GUARD_PEERS ENCHA_GUARD_PERMITIR ENCHA_GUARD_DESATIVADO
  ENCHA_GUARD_SSH_PORTAS="22 abc"
  export ENCHA_GUARD_SSH_PORTAS
  renderizar
)"
if echo "$saida_ssh_letras" | grep -qF 'tcp dport { 22 } ct state new' \
    && ! echo "$saida_ssh_letras" | grep -qF 'abc'; then
  ok "SSH: entrada não-numérica ('abc') descartada, porta válida (22) continua"
else
  falha "SSH: entrada não-numérica não foi descartada corretamente"
  echo "$saida_ssh_letras" | grep 'ct state'
fi

# 9d. ENCHA_GUARD_SSH_PORTAS="" explícito: a regra de rate-limit SOME do
# ruleset (mesmo padrão condicional de pares4/pares6 quando vazios), mas as
# outras regras continuam normais.
saida_ssh_vazio="$(
  unset ENCHA_GUARD_PEERS ENCHA_GUARD_PERMITIR ENCHA_GUARD_DESATIVADO
  ENCHA_GUARD_SSH_PORTAS=""
  export ENCHA_GUARD_SSH_PORTAS
  renderizar
)"
if echo "$saida_ssh_vazio" | grep -q 'ct state new\|ssh_limite'; then
  falha "SSH: ENCHA_GUARD_SSH_PORTAS=\"\" deveria remover a regra de rate-limit (e os sets), mas apareceu"
else
  ok "SSH: ENCHA_GUARD_SSH_PORTAS=\"\" (vazio explícito) remove a regra de rate-limit"
fi
if echo "$saida_ssh_vazio" | grep -q 'iif "lo" accept' \
    && echo "$saida_ssh_vazio" | grep -q 'tcp dport { 2377, 7946 } counter drop' \
    && echo "$saida_ssh_vazio" | grep -q 'udp dport { 4789, 7946 } counter drop'; then
  ok "SSH: com a regra de rate-limit ausente, as outras regras (lo, drops fixos) continuam normais"
else
  falha "SSH: outras regras não sobreviveram à ausência da regra de rate-limit"
fi

# 9e. Regressão do C7 ("tira ct state new, sessões estabelecidas ficam
# limitadas"): "ct state new" tem que estar SEMPRE presente na MESMA regra
# do rate-limit — não apenas em algum lugar do arquivo, mas antes do "limit
# rate" daquela linha. Esta é a prova de mutação: um "ct state new" removido
# do gerador faria esta asserção falhar imediatamente.
# Linha a linha (IPv4 E IPv6): tirar de uma só das duas também tem que falhar.
regras_limite=0
regras_sem_ct_new=0
while IFS= read -r linha_regra_ssh; do
  regras_limite=$((regras_limite + 1))
  case "$linha_regra_ssh" in
    *'ct state new'*'limit rate over 20/minute burst 30 packets'*' drop') : ;;
    *) regras_sem_ct_new=$((regras_sem_ct_new + 1)) ;;
  esac
done <<EOF_REGRAS_SSH
$(printf '%s\n' "$saida_ssh_default" | grep 'limit rate')
EOF_REGRAS_SSH
if [ "$regras_limite" -eq 2 ] && [ "$regras_sem_ct_new" -eq 0 ]; then
  ok "regressão C7: as 2 regras de rate-limit SSH (IPv4 e IPv6) contêm 'ct state new' antes do 'limit rate' (sessões já abertas não são afetadas)"
else
  falha "regressão C7: 'ct state new' ausente (ou fora de ordem) em $regras_sem_ct_new de $regras_limite regra(s) de rate-limit SSH — sessões SSH já abertas cairiam sob o limite"
fi

# 9f. Ordem: a regra de rate-limit SSH vem ANTES dos drops fixos de
# 2377/7946/4789 (leitura lógica: lo -> pares -> rate-limit SSH -> drops).
pos_ssh="$(printf '%s\n' "$saida_ssh_default" | grep -n 'ct state new' | head -1 | cut -d: -f1)"
pos_drop_swarm="$(printf '%s\n' "$saida_ssh_default" | grep -n 'tcp dport { 2377, 7946 } counter drop' | head -1 | cut -d: -f1)"
if [ -n "$pos_ssh" ] && [ -n "$pos_drop_swarm" ] && [ "$pos_ssh" -lt "$pos_drop_swarm" ]; then
  ok "SSH: a regra de rate-limit vem antes dos drops fixos de 2377/7946/4789"
else
  falha "SSH: a regra de rate-limit não vem antes dos drops fixos (ssh=$pos_ssh drop=$pos_drop_swarm)"
fi

# 9f'. Allowlist ANTES do limite de SSH: um par (PEERS/PERMITIR) já recebeu
# "accept" e a chain acabou para ele — o operador confiável nunca tem as
# próprias reconexões limitadas (conferido no kernel real: 45 conexões
# seguidas de um IP da allowlist, 45 aceitas, nenhum elemento no balde).
saida_ssh_pares="$(
  unset ENCHA_GUARD_DESATIVADO ENCHA_GUARD_SSH_PORTAS
  ENCHA_GUARD_PEERS="10.0.0.5"
  ENCHA_GUARD_PERMITIR="2001:db8::1"
  export ENCHA_GUARD_PEERS ENCHA_GUARD_PERMITIR
  renderizar
)"
pos_p4="$(printf '%s\n' "$saida_ssh_pares" | grep -n 'ip saddr @pares4 accept' | head -1 | cut -d: -f1)"
pos_p6="$(printf '%s\n' "$saida_ssh_pares" | grep -n 'ip6 saddr @pares6 accept' | head -1 | cut -d: -f1)"
pos_ssh1="$(printf '%s\n' "$saida_ssh_pares" | grep -n 'ct state new' | head -1 | cut -d: -f1)"
if [ -n "$pos_p4" ] && [ -n "$pos_p6" ] && [ -n "$pos_ssh1" ] && [ "$pos_p4" -lt "$pos_ssh1" ] && [ "$pos_p6" -lt "$pos_ssh1" ]; then
  ok "SSH: accepts da allowlist (pares4/pares6) vêm antes do limite — par confiável nunca é limitado"
else
  falha "SSH: o limite de SSH vem antes da allowlist (p4=$pos_p4 p6=$pos_p6 ssh=$pos_ssh1) — o operador confiável seria limitado"
fi

# 9c'. Bordas da porta: 1 e 65535 passam; 0 (porta TCP inválida — o
# decimal_canonico_ate aceita "0" porque serve a octeto IPv4), zero à
# esquerda, 65536, 2^64+22 (nunca pode "dar a volta" no test numérico), sinal,
# hexa e notação científica caem.
porta_aceita() {
  local saida
  saida="$(
    unset ENCHA_GUARD_PEERS ENCHA_GUARD_PERMITIR ENCHA_GUARD_DESATIVADO
    ENCHA_GUARD_SSH_PORTAS="$1"
    export ENCHA_GUARD_SSH_PORTAS
    renderizar 2>/dev/null
  )"
  printf '%s\n' "$saida" | grep -q 'ct state new'
}
bordas_ok=1
for porta in 0 00 022 65536 123456 18446744073709551638 -1 +22 2e3 0x16 22a; do
  if porta_aceita "$porta"; then
    falha "SSH: porta inválida '$porta' foi aceita no dport"
    bordas_ok=0
  fi
done
for porta in 1 65535; do
  if ! porta_aceita "$porta"; then
    falha "SSH: porta válida '$porta' foi descartada"
    bordas_ok=0
  fi
done
[ "$bordas_ok" -eq 1 ] && ok "SSH: bordas da porta (0/00/022/65536/sinal/hexa rejeitadas; 1 e 65535 aceitas)"

# 9h. Idempotência com tráfego SSH (achado da auditoria C7): o kernel põe um
# elemento por origem nos sets ssh_limite4/6 a cada tentativa de SSH, com
# "expires" contando — a listagem muda sozinha. Se a comparação do loop não
# ignorar isso, a tabela é recriada a cada ciclo de 60s: os baldes de todo
# mundo zeram (o atacante ganha 30 tentativas novas por minuto) e o log
# enche. Com tráfego SSH contínuo, em ~7 ciclos, exatamente 1 aplicação.
dir_trafego="$TMP_TESTE/loop-trafego-ssh"
mkdir -p "$dir_trafego"
: > "$dir_trafego/trafego_ssh"
(
  unset ENCHA_GUARD_DESATIVADO ENCHA_GUARD_SSH_PORTAS
  ENCHA_GUARD_PEERS="10.0.0.5,10.0.0.6"
  export ENCHA_GUARD_PEERS
  rodar_loop 1.4 "$dir_trafego"
)
aplicacoes="$(conta_chamadas "$dir_trafego" '-f -')"
if [ "$aplicacoes" -eq 1 ]; then
  ok "loop: tráfego SSH (elementos dos baldes mudando) não faz a tabela ser reaplicada (1 aplicação em ~7 ciclos)"
else
  falha "loop: tráfego SSH fez a tabela ser reaplicada a cada ciclo ($aplicacoes aplicações) — os baldes do limite zeram a cada minuto"
fi

# ...mas ignorar os baldes não pode cegar a comparação para a ALLOWLIST: um
# elemento de pares4 trocado por fora ainda é "tabela alterada" e volta.
dir_pares_mexidos="$TMP_TESTE/loop-pares-mexidos"
mkdir -p "$dir_pares_mexidos"
: > "$dir_pares_mexidos/chamadas"
: > "$dir_pares_mexidos/trafego_ssh"
(
  unset ENCHA_GUARD_DESATIVADO ENCHA_GUARD_SSH_PORTAS ENCHA_GUARD_PERMITIR
  ENCHA_GUARD_PEERS="10.0.0.5"
  export ENCHA_GUARD_PEERS
  FAKE_NFT_DIR="$dir_pares_mexidos" sob_teste 2>"$dir_pares_mexidos/stderr" &
  pid=$!
  "$REAL_SLEEP" 0.7
  sed 's/10\.0\.0\.5/10.0.0.99/' "$dir_pares_mexidos/tabela" > "$dir_pares_mexidos/tabela.novo"
  mv "$dir_pares_mexidos/tabela.novo" "$dir_pares_mexidos/tabela"
  "$REAL_SLEEP" 0.7
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
)
aplicacoes="$(conta_chamadas "$dir_pares_mexidos" '-f -')"
if [ "$aplicacoes" -eq 2 ] && grep -qF '10.0.0.5' "$dir_pares_mexidos/tabela" 2>/dev/null; then
  ok "loop: allowlist (pares4) alterada por fora ainda é detectada e restaurada, mesmo com os baldes ignorados"
else
  falha "loop: allowlist alterada por fora não foi restaurada ($aplicacoes aplicações) — a normalização escondeu demais"
fi

# 9i. Falha fechada com o limite de SSH (achado da auditoria C7): a versão
# "sem pares" também leva o limite de SSH (set dinâmico com "limit" — um
# kernel antigo pode recusar). Se o nft recusar essa regra, o guarda NÃO pode
# ficar sem regra nenhuma (portas do Swarm abertas por causa de uma
# mitigação de SSH): cai na versão mínima, só lo + drops, e avisa.
dir_ssh_recusado="$TMP_TESTE/loop-ssh-recusado"
mkdir -p "$dir_ssh_recusado"
printf 'ssh_limite' > "$dir_ssh_recusado/recusar"
(
  unset ENCHA_GUARD_PEERS ENCHA_GUARD_PERMITIR ENCHA_GUARD_DESATIVADO ENCHA_GUARD_SSH_PORTAS
  rodar_loop 1.4 "$dir_ssh_recusado"
)
if [ -f "$dir_ssh_recusado/tabela" ] && grep -qF 'tcp dport { 2377, 7946 } counter drop' "$dir_ssh_recusado/ultimo_stdin" 2>/dev/null \
    && grep -qF 'udp dport { 4789, 7946 } counter drop' "$dir_ssh_recusado/ultimo_stdin" \
    && ! grep -qF 'ssh_limite' "$dir_ssh_recusado/ultimo_stdin"; then
  ok "falha fechada: limite de SSH recusado pelo nft (sem allowlist) -> drops do Swarm aplicados mesmo assim"
else
  falha "falha fechada: limite de SSH recusado pelo nft deixou o guarda sem regra nenhuma (portas do Swarm abertas)"
fi
if grep -qF 'sem limite de SSH (falha fechada)' "$dir_ssh_recusado/stderr" 2>/dev/null; then
  ok "falha fechada: a queda para a versão mínima é avisada no log"
else
  falha "falha fechada: a queda para a versão mínima não foi avisada no log"
fi
aplicacoes="$(conta_chamadas "$dir_ssh_recusado" '-f -')"
if [ "$aplicacoes" -eq 2 ]; then
  ok "falha fechada: versão mínima não é reaplicada a cada ciclo (completa recusada + mínima = 2 aplicações)"
else
  falha "falha fechada: esperadas 2 aplicações (completa recusada + mínima), houve $aplicacoes"
fi

# ...com allowlist: completa recusada, sem pares (ainda com SSH) recusada,
# mínima aplicada — 3 aplicações, e a allowlist recusada nunca "salva" nada.
dir_ssh_recusado_pares="$TMP_TESTE/loop-ssh-recusado-pares"
mkdir -p "$dir_ssh_recusado_pares"
printf 'ssh_limite' > "$dir_ssh_recusado_pares/recusar"
(
  unset ENCHA_GUARD_PERMITIR ENCHA_GUARD_DESATIVADO ENCHA_GUARD_SSH_PORTAS
  ENCHA_GUARD_PEERS="10.0.0.5"
  export ENCHA_GUARD_PEERS
  rodar_loop 1.4 "$dir_ssh_recusado_pares"
)
aplicacoes="$(conta_chamadas "$dir_ssh_recusado_pares" '-f -')"
if [ "$aplicacoes" -eq 3 ] && [ -f "$dir_ssh_recusado_pares/tabela" ] \
    && grep -qF 'udp dport { 4789, 7946 } counter drop' "$dir_ssh_recusado_pares/ultimo_stdin" 2>/dev/null \
    && ! grep -qF 'pares' "$dir_ssh_recusado_pares/ultimo_stdin"; then
  ok "falha fechada: com allowlist, completa e sem-pares recusadas -> mínima aplicada (3 aplicações, sem reaplicar a cada ciclo)"
else
  falha "falha fechada: com allowlist e limite de SSH recusado, esperada a versão mínima em 3 aplicações, houve $aplicacoes"
fi

# E o caso do C4 continua: allowlist recusada, limite de SSH aceito -> a
# versão sem pares MANTÉM o limite de SSH (não desce à mínima sem motivo).
if grep -qF 'update @ssh_limite4' "$dir_fecha/ultimo_stdin" 2>/dev/null; then
  ok "falha fechada: allowlist recusada mantém o limite de SSH na versão sem pares"
else
  falha "falha fechada: allowlist recusada derrubou também o limite de SSH (desceu à mínima sem motivo)"
fi

# 9g. Sintaxe real (nft -c), se disponível — mesmo guard de disponibilidade
# e mesma função "validar_sintaxe" da seção 7 (definida só quando o "nft"
# real existe e fala com o netlink).
if command -v nft >/dev/null 2>&1 && echo 'table inet encha_guard_sonda {}' | nft -c -f - >/dev/null 2>&1; then
  validar_sintaxe "SSH: default (porta 22)" "$saida_ssh_default"
  validar_sintaxe "SSH: portas customizadas (22,2222)" "$saida_ssh_2portas"
else
  echo "ℹ️  'nft' real indisponível — pulando a validação de sintaxe real das regras de rate-limit SSH (seção 9 acima já cobre a geração)."
fi

echo ""
[ "$falhas" -eq 0 ] || exit 1
echo "✅ todos os testes de encha-guard.sh passaram"
