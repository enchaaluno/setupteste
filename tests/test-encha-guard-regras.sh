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
  "-f -")
    cat > "$d/ultimo_stdin"
    if [ -n "${FAKE_NFT_REJEITAR:-}" ] && grep -qF "$FAKE_NFT_REJEITAR" "$d/ultimo_stdin"; then
      echo "Error: rejeitado pelo nft falso ($FAKE_NFT_REJEITAR)" >&2
      exit 1
    fi
    awk '/^table inet encha_guard \{$/ { n++ } n >= 2' "$d/ultimo_stdin" \
      | sed -e 's/^    /\t\t/' -e 's/^  /\t/' -e 's/priority -5;/priority filter - 5;/' > "$d/tabela"
    echo 0 > "$d/contador"
    exit 0
    ;;
  "list table inet encha_guard" | "-a list table inet encha_guard")
    [ -f "$d/tabela" ] || { echo "Error: No such file or directory" >&2; exit 1; }
    n="$(cat "$d/contador" 2>/dev/null || echo 0)"
    n=$((n + 1))
    echo "$n" > "$d/contador"
    if [ "$1" = "-a" ]; then
      sed -e "s/counter drop/counter packets $n bytes $((n * 60)) drop # handle $((n + 7))/" \
        -e "s/accept\$/accept # handle $((n + 3))/" "$d/tabela"
    else
      sed -e "s/counter drop/counter packets $n bytes $((n * 60)) drop/" "$d/tabela"
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
else
  echo "ℹ️  'nft' real indisponível (ausente ou sem CAP_NET_ADMIN) — pulando a validação de sintaxe real. A geração de regras já foi coberta pelos testes 1-6 acima."
fi

# --- 8. Loop principal contra o nft falso ----------------------------------

# Roda o loop por "$1" segundos num diretório de estado novo ("$2"), manda
# SIGTERM e espera até 3s pela saída. LOOP_SAIU=1 se saiu sozinho.
rodar_loop() {
  local segundos="$1" dir="$2"
  mkdir -p "$dir"
  : > "$dir/chamadas"
  # shellcheck disable=SC2119 # sem argumento de propósito: é o loop real
  FAKE_NFT_DIR="$dir" sob_teste 2>"$dir/stderr" &
  local pid=$!
  "$REAL_SLEEP" "$segundos"
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

echo ""
[ "$falhas" -eq 0 ] || exit 1
echo "✅ todos os testes de encha-guard.sh passaram"
