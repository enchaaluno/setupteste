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
# O loop principal (sem --render) NUNCA é chamado aqui — ele manipularia o
# firewall real da máquina que roda o teste. Cobertura do loop (mudança
# detectada, SIGTERM não apaga a tabela) é validação na VPS real (V2 do
# plano), não teste de unidade no Mac.
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

# Executor do script sob teste: sempre com "sh" explícito (POSIX sh, não
# bash) e sempre "--render" — nunca deixa cair no loop principal.
renderizar() {
  sh "$SCRIPT" --render
}

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
  renderizar 2>/tmp/encha-guard-teste-stderr.log
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
if grep -qi 'descartad' /tmp/encha-guard-teste-stderr.log 2>/dev/null; then
  ok "injeção: rejeição foi logada em stderr"
else
  falha "injeção: nada foi logado em stderr sobre entradas descartadas"
fi
rm -f /tmp/encha-guard-teste-stderr.log

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

if ! command -v nft >/dev/null 2>&1; then
  # Tentativa best-effort — o Mac normalmente não tem apt nem nft; não é
  # falha do teste, é ausência de ferramenta no ambiente local.
  apt-get install -y nftables >/dev/null 2>&1 || true
fi

if command -v nft >/dev/null 2>&1; then
  validar_sintaxe() {
    descricao="$1"
    saida="$2"
    if printf '%s\n' "$saida" | nft -c -f - >/tmp/encha-guard-nft-erro.log 2>&1; then
      ok "nft -c -f -: sintaxe válida ($descricao)"
    else
      falha "nft -c -f -: sintaxe INVÁLIDA ($descricao) — $(cat /tmp/encha-guard-nft-erro.log)"
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
  rm -f /tmp/encha-guard-nft-erro.log
else
  echo "ℹ️  'nft' não disponível neste ambiente (Mac sem pacote nftables/sem apt) — pulando a validação de sintaxe real. A geração de regras já foi coberta pelos testes 1-6 acima."
fi

echo ""
[ "$falhas" -eq 0 ] || exit 1
echo "✅ todos os testes de encha-guard.sh passaram"
