#!/bin/bash
# Ciclo C10 (achado A2 do plano de segurança do EnchaT): fail2ban de verdade
# pro SSH — instalar_protecao_ssh (secondary.sh) escreve
# filter.d/sshd.local + jail.d/encha-sshd.local, confirma o serviço ativo
# antes de gravar o marcador não secreto que o painel lê (C8), e o
# dispatcher em main() dispara a função direto quando "proteger-ssh" é o
# primeiro argumento — sem passar pelo menu interativo.
#
# Roda a função REAL (extraída de secondary.sh) com apt-get/systemctl/sshd
# FALSOS no PATH e um prefixo de /etc/fail2ban configurável
# (ENCHA_FAIL2BAN_ETC_PREFIX) — NUNCA escreve em /etc/fail2ban de verdade
# neste Mac/runner. O marcador /root/dados_vps/seguranca também é
# redirecionado pra um diretório temporário, com o mesmo truque de
# substituição de caminho que tests/test-admin-portainer.sh e
# tests/test-dados-enchat-permissao.sh já usam.
#
# Roda com: bash tests/test-fail2ban-config.sh
set -u
cd "$(dirname "$0")/.." || exit 1
falhas=0
falha() { echo "❌ FALHOU: $1"; falhas=$((falhas + 1)); }
ok() { echo "✅ $1"; }

extrair_funcao() {
  local nome="$1"
  awk -v alvo="$nome" '
    $0 ~ "^" alvo "\\(\\) \\{$" { f = 1 }
    f { print }
    f && /^\}$/ { exit }
  ' secondary.sh
}

fn_instalar="$(extrair_funcao instalar_protecao_ssh)"
fn_main="$(extrair_funcao main)"

if [ -z "$fn_instalar" ]; then
  echo "❌ FALHOU: função instalar_protecao_ssh não encontrada em secondary.sh — rode depois de implementar o C10"
  exit 1
fi
if [ -z "$fn_main" ]; then
  echo "❌ FALHOU: função main não encontrada em secondary.sh"
  exit 1
fi

# Redireciona o marcador /root/dados_vps/seguranca pra um diretório
# temporário por cenário — mesmo truque de test-admin-portainer.sh.
fn_instalar_com_dv() {
  local dv="$1"
  echo "${fn_instalar//\/root\/dados_vps//$dv}"
}

# --- Catálogo mínimo: só as chaves que instalar_protecao_ssh usa, com o
# valor REAL de MSG_PT (se o texto mudar em secondary.sh, este teste segue a
# mudança). EN/ES ficam por conta de i18n/check-parity.sh.
t() {
    local chave="$1"; shift
    local nomevar="MSG_${chave}"
    local template="${!nomevar}"
    [ -z "$template" ] && template="$chave"
    if [ "$#" -gt 0 ]; then
        printf -- "$template" "$@"
    else
        printf '%s' "$template"
    fi
}
for chave in instalar_protecao_ssh_instalando instalar_protecao_ssh_falha_pacote \
             instalar_protecao_ssh_falha_servico instalar_protecao_ssh_sucesso; do
  valor="$(grep -m1 "^MSG_PT\[$chave\]=" secondary.sh | sed -E "s/^MSG_PT\[$chave\]=//")"
  if [ -z "$valor" ]; then
    echo "❌ FALHOU: MSG_PT[$chave] não encontrada em secondary.sh"
    exit 1
  fi
  eval "MSG_${chave}=$valor"
done

# --- Ambiente com apt-get/systemctl/sshd/fail2ban-client falsos no PATH ---
BINDIR="$(mktemp -d)"
trap 'rm -rf "$BINDIR"' EXIT

cat > "$BINDIR/apt-get" <<'EOF'
#!/bin/bash
[ -n "${FAKE_APT_LOG:-}" ] && echo "$*" >> "$FAKE_APT_LOG"
exit 0
EOF

# sshd falso: "-T" imprime o conteúdo de $FAKE_SSHD_T (uma linha "port N"
# por porta configurada, como o sshd real faria com múltiplos "Port").
cat > "$BINDIR/sshd" <<'EOF'
#!/bin/bash
if [ "$1" = "-T" ]; then
  printf '%s\n' "${FAKE_SSHD_T:-port 22}"
fi
exit 0
EOF

# systemctl falso: "is-active --quiet fail2ban" segue $FAKE_SYSTEMCTL_ATIVO
# (1 = ativo, 0 = inativo); "enable"/"restart" só logam e sempre "funcionam"
# (o teste de falha simula o serviço não subindo via FAKE_SYSTEMCTL_ATIVO=0
# combinado com fail2ban-client também falhando, não via enable/restart
# retornando erro — replica o "confirma de verdade depois" da função real).
cat > "$BINDIR/systemctl" <<'EOF'
#!/bin/bash
[ -n "${FAKE_SYSTEMCTL_LOG:-}" ] && echo "$*" >> "$FAKE_SYSTEMCTL_LOG"
case "$1 $2" in
  "is-active --quiet")
    [ "${FAKE_SYSTEMCTL_ATIVO:-1}" = "1" ] && exit 0 || exit 1
    ;;
  *)
    exit 0
    ;;
esac
EOF

# fail2ban-client falso: presença no PATH = "pacote instalado" (a função só
# checa `command -v fail2ban-client`); "ping" segue $FAKE_FAIL2BAN_PING (1 =
# responde, 0 = recusa); "status sshd" segue $FAKE_FAIL2BAN_JAIL (1 = a jail
# sshd existe e responde, 0 = não — servidor caído, ou de pé sem a jail). A
# confirmação real da função é SÓ "status sshd" (auditoria C10): ping e
# systemctl is-active mentem logo depois do restart (Type=simple).
cat > "$BINDIR/fail2ban-client" <<'EOF'
#!/bin/bash
if [ "$1" = "ping" ]; then
  [ "${FAKE_FAIL2BAN_PING:-1}" = "1" ] && exit 0 || exit 1
fi
if [ "$1" = "status" ] && [ "${2:-}" = "sshd" ]; then
  [ -n "${FAKE_FAIL2BAN_STATUS_LOG:-}" ] && echo "status sshd" >> "$FAKE_FAIL2BAN_STATUS_LOG"
  [ "${FAKE_FAIL2BAN_JAIL:-1}" = "1" ] && exit 0 || exit 1
fi
exit 0
EOF

# sleep falso: a função espera a jail subir (até ~15 s) — no teste, o
# cenário de falha não pode custar 15 s de verdade.
cat > "$BINDIR/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF

chmod +x "$BINDIR"/apt-get "$BINDIR"/sshd "$BINDIR"/systemctl "$BINDIR"/fail2ban-client "$BINDIR"/sleep

# Roda instalar_protecao_ssh isolada num subshell (PATH falso + prefixos
# temporários). Ecoa RC=<código> no final do stdout salvo em $3 pra
# inspecionar.
rodar() {
  local etc_prefix="$1" dv="$2" saida="$3"
  local fn
  fn="$(fn_instalar_com_dv "$dv")"
  (
    set +u
    export PATH="$BINDIR:$PATH"
    export ENCHA_FAIL2BAN_ETC_PREFIX="$etc_prefix"
    eval "$fn"
    instalar_protecao_ssh
    echo "RC=$?"
  ) > "$saida" 2>&1
}

# ============================================================
# 1. journalmatch cobre ssh.service, sshd.service, _COMM=sshd, _COMM=sshd-session
# 2. backend = systemd sempre presente
# 3. Porta descoberta corretamente (múltiplas linhas "port" -> junta com vírgula)
# ============================================================
ETC1="$(mktemp -d)"; DV1="$(mktemp -d)"
FAKE_SSHD_T=$'port 22\nport 2222' FAKE_SYSTEMCTL_ATIVO=1 FAKE_FAIL2BAN_PING=1 \
  rodar "$ETC1" "$DV1" "$DV1/saida.log"

jail1="$ETC1/jail.d/encha-sshd.local"
if [ ! -f "$jail1" ]; then
  falha "jail.d/encha-sshd.local não foi criado"
else
  if grep -q '^journalmatch = _SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service + _COMM=sshd + _COMM=sshd-session$' "$jail1"; then
    ok "journalmatch cobre ssh.service, sshd.service, _COMM=sshd e _COMM=sshd-session"
  else
    falha "journalmatch não bate o esperado: $(grep '^journalmatch' "$jail1")"
  fi

  if grep -q '^backend = systemd$' "$jail1"; then
    ok "backend = systemd presente"
  else
    falha "backend = systemd ausente em jail.d/encha-sshd.local"
  fi

  if grep -q '^port = 22,2222$' "$jail1"; then
    ok "porta(s) descobertas de sshd -T (múltiplas linhas 'port') -> '22,2222' no jail"
  else
    falha "port não bate o esperado (22,2222): $(grep '^port' "$jail1")"
  fi

  for chave in "enabled = true" "banaction = iptables-multiport" "maxretry = 5" \
               "findtime = 10m" "bantime = 1h" "bantime.increment = true" \
               "bantime.maxtime = 1d"; do
    if grep -qF "$chave" "$jail1"; then
      ok "jail contém '$chave'"
    else
      falha "jail não contém '$chave'"
    fi
  done
fi

filtro1="$ETC1/filter.d/sshd.local"
if [ -f "$filtro1" ] && grep -q '^_daemon = sshd(?:-session|-auth)?$' "$filtro1"; then
  ok "filter.d/sshd.local sobrescreve _daemon para reconhecer sshd-session/sshd-auth"
else
  falha "filter.d/sshd.local ausente ou sem o override de _daemon esperado"
fi

# ============================================================
# 4. Fallback de porta pra 22 quando sshd -T não devolve nada
# ============================================================
ETC_FB="$(mktemp -d)"; DV_FB="$(mktemp -d)"
FAKE_SSHD_T="" FAKE_SYSTEMCTL_ATIVO=1 FAKE_FAIL2BAN_PING=1 \
  rodar "$ETC_FB" "$DV_FB" "$DV_FB/saida.log"
if grep -q '^port = 22$' "$ETC_FB/jail.d/encha-sshd.local" 2>/dev/null; then
  ok "sshd -T sem saída -> fallback de porta pra 22"
else
  falha "fallback de porta pra 22 não aconteceu: $(grep '^port' "$ETC_FB/jail.d/encha-sshd.local" 2>/dev/null)"
fi

# ============================================================
# 5. ignoreip: sempre tem loopback; com $SSH_CLIENT, inclui o IP do operador
# ============================================================
ETC2="$(mktemp -d)"; DV2="$(mktemp -d)"
(
  set +u
  export PATH="$BINDIR:$PATH"
  export ENCHA_FAIL2BAN_ETC_PREFIX="$ETC2"
  export FAKE_SYSTEMCTL_ATIVO=1 FAKE_FAIL2BAN_PING=1
  fn="$(fn_instalar_com_dv "$DV2")"
  eval "$fn"
  unset SSH_CLIENT
  instalar_protecao_ssh
) > "$DV2/saida.log" 2>&1
if grep -qE '^ignoreip = 127\.0\.0\.1/8 ::1$' "$ETC2/jail.d/encha-sshd.local" 2>/dev/null; then
  ok "sem \$SSH_CLIENT: ignoreip só com loopback"
else
  falha "ignoreip sem SSH_CLIENT não bate: $(grep '^ignoreip' "$ETC2/jail.d/encha-sshd.local" 2>/dev/null)"
fi

ETC3="$(mktemp -d)"; DV3="$(mktemp -d)"
(
  set +u
  export PATH="$BINDIR:$PATH"
  export ENCHA_FAIL2BAN_ETC_PREFIX="$ETC3"
  export FAKE_SYSTEMCTL_ATIVO=1 FAKE_FAIL2BAN_PING=1
  export SSH_CLIENT="203.0.113.5 54321 22"
  fn="$(fn_instalar_com_dv "$DV3")"
  eval "$fn"
  instalar_protecao_ssh
) > "$DV3/saida.log" 2>&1
if grep -qE '^ignoreip = 127\.0\.0\.1/8 ::1 203\.0\.113\.5$' "$ETC3/jail.d/encha-sshd.local" 2>/dev/null; then
  ok "com \$SSH_CLIENT: ignoreip inclui o IP do operador (primeiro campo)"
else
  falha "ignoreip com SSH_CLIENT não bate: $(grep '^ignoreip' "$ETC3/jail.d/encha-sshd.local" 2>/dev/null)"
fi

# ============================================================
# 6. Marcador só é gravado quando systemctl/fail2ban-client confirmam
#    sucesso — e explicitamente NÃO gravado quando os dois falham.
# ============================================================
ETC4="$(mktemp -d)"; DV4="$(mktemp -d)"
FAKE_SYSTEMCTL_ATIVO=1 FAKE_FAIL2BAN_PING=1 rodar "$ETC4" "$DV4" "$DV4/saida.log"
if [ -f "$DV4/seguranca" ]; then
  modo="$(stat -c %a "$DV4/seguranca" 2>/dev/null || stat -f %Lp "$DV4/seguranca")"
  if [ "$modo" = "644" ]; then
    ok "sucesso confirmado: marcador gravado com modo 644"
  else
    falha "marcador gravado com modo $modo, esperado 644"
  fi
  if grep -q "RC=0" "$DV4/saida.log"; then
    ok "sucesso confirmado: instalar_protecao_ssh retornou 0"
  else
    falha "instalar_protecao_ssh não retornou 0 no cenário de sucesso: $(cat "$DV4/saida.log")"
  fi
else
  falha "marcador não foi gravado no cenário de sucesso (systemctl e fail2ban-client OK)"
fi

ETC5="$(mktemp -d)"; DV5="$(mktemp -d)"
FAKE_SYSTEMCTL_ATIVO=0 FAKE_FAIL2BAN_PING=0 FAKE_FAIL2BAN_JAIL=0 rodar "$ETC5" "$DV5" "$DV5/saida.log"
if [ -f "$DV5/seguranca" ]; then
  falha "marcador foi gravado mesmo com fail2ban NÃO confirmando ativo (systemctl, ping e status sshd falharam) — mentira pro painel"
else
  ok "fail2ban 'falhou' no fake (systemctl, ping e status sshd negativos): marcador NÃO gravado"
fi
if grep -q "RC=1" "$DV5/saida.log"; then
  ok "cenário de falha: instalar_protecao_ssh retornou 1"
else
  falha "instalar_protecao_ssh não retornou 1 no cenário de falha: $(cat "$DV5/saida.log")"
fi

# Auditoria C10 — a corrida medida na VPS de teste: logo depois do restart,
# systemctl já diz "active" e o ping pode até responder, mas a jail sshd
# não existe (config quebrada: o servidor morre ~1 s depois; ou a jail
# desligada por outro jail.d/*.local). Só "status sshd" conta.
ETC5B="$(mktemp -d)"; DV5B="$(mktemp -d)"
FAKE_SYSTEMCTL_ATIVO=1 FAKE_FAIL2BAN_PING=1 FAKE_FAIL2BAN_JAIL=0 rodar "$ETC5B" "$DV5B" "$DV5B/saida.log"
if [ -f "$DV5B/seguranca" ]; then
  falha "marcador gravado com systemctl 'active' + ping OK mas SEM a jail sshd — o painel diria 'protegido' com o fail2ban prestes a cair"
else
  ok "systemctl 'active' + ping OK mas jail sshd ausente: marcador NÃO gravado"
fi
if grep -q "RC=1" "$DV5B/saida.log"; then
  ok "jail sshd ausente: instalar_protecao_ssh retornou 1"
else
  falha "jail sshd ausente: instalar_protecao_ssh não retornou 1: $(cat "$DV5B/saida.log")"
fi

# A jail demora a responder (servidor ainda lendo a config): a função espera
# em vez de desistir na primeira tentativa. Aqui a jail só "sobe" na 3ª
# consulta.
ETC5C="$(mktemp -d)"; DV5C="$(mktemp -d)"
cat > "$BINDIR/fail2ban-client-lento" <<'EOF'
#!/bin/bash
if [ "$1" = "status" ] && [ "${2:-}" = "sshd" ]; then
  n=$(cat "$FAKE_CONTADOR" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_CONTADOR"
  [ "$n" -ge 3 ] && exit 0 || exit 1
fi
exit 0
EOF
chmod +x "$BINDIR/fail2ban-client-lento"
BIN_LENTO="$(mktemp -d)"
cp "$BINDIR"/apt-get "$BINDIR"/sshd "$BINDIR"/systemctl "$BINDIR"/sleep "$BIN_LENTO"/
cp "$BINDIR/fail2ban-client-lento" "$BIN_LENTO/fail2ban-client"
(
  set +u
  export PATH="$BIN_LENTO:$PATH"
  export ENCHA_FAIL2BAN_ETC_PREFIX="$ETC5C" FAKE_CONTADOR="$DV5C/contador"
  fn="$(fn_instalar_com_dv "$DV5C")"
  eval "$fn"
  instalar_protecao_ssh
  echo "RC=$?"
) > "$DV5C/saida.log" 2>&1
if [ -f "$DV5C/seguranca" ] && grep -q "RC=0" "$DV5C/saida.log"; then
  ok "jail sshd lenta (responde na 3ª consulta): a função espera e confirma"
else
  falha "jail sshd lenta: a função desistiu antes da jail responder: $(cat "$DV5C/saida.log")"
fi
rm -rf "$BIN_LENTO"

# Marcador de uma execução anterior não pode sobreviver a uma falha: senão
# o painel continua dizendo "SSH protegido" com o fail2ban caído.
ETC5D="$(mktemp -d)"; DV5D="$(mktemp -d)"
printf 'fail2ban=ok\n' > "$DV5D/seguranca"
FAKE_SYSTEMCTL_ATIVO=0 FAKE_FAIL2BAN_PING=0 FAKE_FAIL2BAN_JAIL=0 rodar "$ETC5D" "$DV5D" "$DV5D/saida.log"
if [ -f "$DV5D/seguranca" ]; then
  falha "marcador ANTIGO sobreviveu a uma execução que falhou — o painel mentiria 'SSH protegido'"
else
  ok "falha remove o marcador antigo (nenhum 'protegido' velho sobrevive)"
fi

# "enable" sempre, mesmo com o serviço já ativo — senão um fail2ban
# desabilitado no boot some no próximo reboot com o marcador gravado.
ETC5E="$(mktemp -d)"; DV5E="$(mktemp -d)"
FAKE_SYSTEMCTL_LOG="$DV5E/systemctl.log" FAKE_SYSTEMCTL_ATIVO=1 FAKE_FAIL2BAN_JAIL=1 \
  rodar "$ETC5E" "$DV5E" "$DV5E/saida.log"
if grep -qE '^enable( --now)? fail2ban$' "$DV5E/systemctl.log" 2>/dev/null; then
  ok "serviço já ativo: 'systemctl enable fail2ban' chamado mesmo assim (sobrevive a reboot)"
else
  falha "serviço já ativo: 'systemctl enable fail2ban' não foi chamado — $(tr '\n' ';' < "$DV5E/systemctl.log" 2>/dev/null)"
fi

# ============================================================
# 7. Idempotência: rodar duas vezes não duplica linhas nem falha.
# ============================================================
ETC6="$(mktemp -d)"; DV6="$(mktemp -d)"
FAKE_SYSTEMCTL_ATIVO=1 FAKE_FAIL2BAN_PING=1 rodar "$ETC6" "$DV6" "$DV6/saida1.log"
FAKE_SYSTEMCTL_ATIVO=1 FAKE_FAIL2BAN_PING=1 rodar "$ETC6" "$DV6" "$DV6/saida2.log"

n_daemon="$(grep -c '^_daemon = ' "$ETC6/filter.d/sshd.local" 2>/dev/null || echo 0)"
n_sshd_block="$(grep -c '^\[sshd\]$' "$ETC6/jail.d/encha-sshd.local" 2>/dev/null || echo 0)"
if [ "$n_daemon" -eq 1 ] && [ "$n_sshd_block" -eq 1 ]; then
  ok "idempotência: rodar duas vezes não duplica linhas de config"
else
  falha "idempotência: config duplicada após 2ª execução (_daemon: $n_daemon, [sshd]: $n_sshd_block)"
fi
if grep -q "RC=0" "$DV6/saida2.log"; then
  ok "idempotência: 2ª execução também retorna 0"
else
  falha "idempotência: 2ª execução falhou: $(cat "$DV6/saida2.log")"
fi

# ============================================================
# 8. main() com "proteger-ssh" em $1 chama instalar_protecao_ssh direto,
#    sem passar pelo menu — isola o dispatcher com funções fake (não
#    depende da instalar_protecao_ssh real nem de processar_menu_unlimited
#    real, que leria terminal indefinidamente).
# ============================================================
MENU_LOG="$(mktemp -d)/menu.log"
PROTEGER_LOG="$(mktemp -d)/proteger.log"

(
  set +u
  processar_menu_unlimited() { echo "MENU_CHAMADO" >> "$MENU_LOG"; }
  instalar_protecao_ssh() { echo "PROTEGER_CHAMADO" >> "$PROTEGER_LOG"; return 0; }
  eval "$fn_main"
  main proteger-ssh
) > /dev/null 2>&1

if [ -f "$PROTEGER_LOG" ] && [ ! -f "$MENU_LOG" ]; then
  ok "main() com \$1=proteger-ssh: chama instalar_protecao_ssh, NÃO chama o menu"
else
  falha "main() com \$1=proteger-ssh não disparou do jeito certo (proteger: $([ -f "$PROTEGER_LOG" ] && echo sim || echo não), menu: $([ -f "$MENU_LOG" ] && echo sim || echo não))"
fi

rm -f "$MENU_LOG" "$PROTEGER_LOG"
(
  set +u
  processar_menu_unlimited() { echo "MENU_CHAMADO" >> "$MENU_LOG"; }
  instalar_protecao_ssh() { echo "PROTEGER_CHAMADO" >> "$PROTEGER_LOG"; return 0; }
  eval "$fn_main"
  main
) > /dev/null 2>&1

if [ -f "$MENU_LOG" ] && [ ! -f "$PROTEGER_LOG" ]; then
  ok "main() sem argumento: cai no menu de sempre, não chama instalar_protecao_ssh"
else
  falha "main() sem argumento não caiu no menu do jeito certo"
fi

# ============================================================
# 8b. Avisos de senha/root do resumo final (main.sh): o passo a passo grava
#     num drop-in 00-encha.conf e valida com `sshd -t` — nunca "edite o
#     sshd_config" (auditoria C10: no Debian 13 o Include de
#     sshd_config.d/*.conf fica no topo e o PRIMEIRO valor vence; na VPS de
#     teste o 50-cloud-init.conf ligava a senha com o sshd_config dizendo
#     "no"). Vale para os 3 idiomas.
# ============================================================
for idioma in PT EN ES; do
  for chave in mostrar_resumo_ssh_senha_aviso mostrar_resumo_ssh_root_aviso; do
    linha="$(grep -m1 "^MSG_${idioma}\[$chave\]=" main.sh)"
    if printf '%s' "$linha" | grep -qF '/etc/ssh/sshd_config.d/00-encha.conf' \
       && printf '%s' "$linha" | grep -qF 'sshd -t &&'; then
      ok "MSG_${idioma}[$chave]: drop-in 00-encha.conf + sshd -t antes do restart"
    else
      falha "MSG_${idioma}[$chave] não manda gravar em sshd_config.d/00-encha.conf com sshd -t antes do restart: $linha"
    fi
  done
done

# ============================================================
# 8c. Onde a proteção dispara sozinha (auditoria C10): UMA chamada
#     automática, no main.sh, no ponto em que os dois fluxos de instalação
#     (infra completa e só painel) convergem — depois do painel instalado e
#     antes do resumo final. No secondary.sh, só a opção 96 do menu e o
#     dispatcher `proteger-ssh` — nunca dentro das funções de infra
#     (ferramenta_traefik_e_portainer/instalar_traefik_e_portainer), que a
#     opção 02 do menu roda numa reinstalação.
# ============================================================
chamadas() {
  # Linhas que CHAMAM a função (a palavra solta, sem "_" nem "(" depois — a
  # definição, as chaves MSG_*[instalar_protecao_ssh_*] e t(...) ficam de
  # fora), ignorando comentários.
  grep -nE '(^|[^_[:alnum:]])instalar_protecao_ssh([^_[:alnum:](]|$)' "$1" \
    | grep -vE '^[0-9]+:[[:space:]]*#'
}
chamadas_main="$(chamadas main.sh)"
n_main="$(printf '%s\n' "$chamadas_main" | grep -c .)"
ln_chamada="$(printf '%s\n' "$chamadas_main" | grep -E '^[0-9]+:if instalar_protecao_ssh; then$' | cut -d: -f1)"
ln_painel="$(grep -nE '^if ! ferramenta_encha_panel; then$' main.sh | cut -d: -f1)"
ln_resumo="$(grep -nE '^mostrar_resumo_final$' main.sh | cut -d: -f1)"
if [ "$n_main" -eq 1 ] && [ -n "$ln_chamada" ] && [ -n "$ln_painel" ] && [ -n "$ln_resumo" ] \
   && [ "$ln_chamada" -gt "$ln_painel" ] && [ "$ln_chamada" -lt "$ln_resumo" ]; then
  ok "main.sh: uma chamada automática, no nível de cima, entre ferramenta_encha_panel e mostrar_resumo_final"
else
  falha "main.sh: chamada automática fora do ponto de convergência (chamadas: $n_main; linha $ln_chamada; painel $ln_painel; resumo $ln_resumo)"
fi

chamadas_sec="$(chamadas secondary.sh)"
n_sec="$(printf '%s\n' "$chamadas_sec" | grep -c .)"
if [ "$n_sec" -eq 2 ]; then
  ok "secondary.sh: só a opção 96 e o dispatcher chamam instalar_protecao_ssh"
else
  falha "secondary.sh: $n_sec chamadas de instalar_protecao_ssh (esperado 2: opção 96 + dispatcher) — $(printf '%s' "$chamadas_sec" | tr '\n' ';')"
fi
for fn_infra in ferramenta_traefik_e_portainer instalar_traefik_e_portainer ferramenta_encha_panel; do
  if extrair_funcao "$fn_infra" | grep -qE '(^|[^_[:alnum:]])instalar_protecao_ssh([^_[:alnum:](]|$)'; then
    falha "$fn_infra chama instalar_protecao_ssh — dispararia numa reinstalação pelo menu"
  else
    ok "$fn_infra não chama instalar_protecao_ssh"
  fi
done

# ============================================================
# 9. Se disponível no ambiente, validação com o fail2ban DE VERDADE (fora
#    do PATH falso). Nunca falha o teste por ausência — mas, quando roda,
#    precisa provar alguma coisa (auditoria C10: a versão anterior rodava
#    `fail2ban-client -t -c <dir só com os .local>`, que diz "OK" até com
#    backend/banaction inexistentes — sem jail.conf não há jail nenhuma pra
#    testar; e casava uma linha SEM hostname, que o `_daemon = sshd` puro do
#    upstream também casa pelo slot de hostname — não pegava o override
#    removido).
# ============================================================
if command -v fail2ban-client >/dev/null 2>&1 && command -v fail2ban-regex >/dev/null 2>&1 \
   && [ -f /etc/fail2ban/jail.conf ] && [ -f /etc/fail2ban/filter.d/sshd.conf ]; then
  # Árvore real do pacote + nossos dois arquivos por cima, num diretório
  # temporário (nunca escreve em /etc/fail2ban) — é exatamente o merge
  # .conf/.local que o fail2ban faz em produção.
  TMP_F2B="$(mktemp -d)"
  cp -r /etc/fail2ban/. "$TMP_F2B/"
  cp "$ETC1/jail.d/encha-sshd.local" "$TMP_F2B/jail.d/encha-sshd.local"
  cp "$ETC1/filter.d/sshd.local" "$TMP_F2B/filter.d/sshd.local"

  if fail2ban-client -c "$TMP_F2B" -t >/dev/null 2>&1; then
    ok "fail2ban-client -t sobre a árvore real + nossos .local: configuração válida"
  else
    falha "fail2ban-client -t sobre a árvore real + nossos .local: configuração INVÁLIDA"
  fi

  # O -t acima só vale se detectar config quebrada: prova com uma cópia
  # estragada de propósito.
  TMP_RUIM="$(mktemp -d)"
  cp -r "$TMP_F2B/." "$TMP_RUIM/"
  sed -i.bak 's/^backend = systemd$/backend = naoexiste/' "$TMP_RUIM/jail.d/encha-sshd.local"
  if fail2ban-client -c "$TMP_RUIM" -t >/dev/null 2>&1; then
    falha "fail2ban-client -t aceitou 'backend = naoexiste' — a checagem de sintaxe acima não prova nada"
  else
    ok "fail2ban-client -t recusa config quebrada (a checagem acima é de verdade)"
  fi
  rm -rf "$TMP_RUIM"

  # Config EFETIVA da jail, depois do merge (-d): nossos valores vencem os
  # do pacote — o defaults-debian.conf do Debian 13 põe
  # "banaction = nftables" no [DEFAULT] e outro journalmatch no [sshd].
  dump="$(fail2ban-client -c "$TMP_F2B" -d 2>/dev/null)"
  if printf '%s\n' "$dump" | grep -qF "['add', 'sshd', 'systemd']"; then
    ok "config efetiva: jail sshd com backend systemd"
  else
    falha "config efetiva: jail sshd não está com backend systemd"
  fi
  if printf '%s\n' "$dump" | grep -qF "['set', 'sshd', 'addaction', 'iptables-multiport']" \
     && ! printf '%s\n' "$dump" | grep -qE "\['set', 'sshd', 'addaction', 'nftables"; then
    ok "config efetiva: ação iptables-multiport (nunca nftables) na jail sshd"
  else
    falha "config efetiva: a jail sshd não ficou só com iptables-multiport: $(printf '%s\n' "$dump" | grep "'sshd', 'addaction'")"
  fi
  if printf '%s\n' "$dump" | grep -F "['set', 'sshd', 'addignoreip'" | grep -qF "'127.0.0.1/8', '::1'"; then
    ok "config efetiva: ignoreip com loopback"
  else
    falha "config efetiva: ignoreip sem loopback"
  fi

  # Linhas COM hostname, no formato que o backend systemd reconstrói
  # (hostname + SYSLOG_IDENTIFIER[pid]: MESSAGE) e com logtype=journal, como
  # a jail real usa. "sshd-auth" é o que só o nosso override cobre (o pacote
  # Debian 1.1.0-8 traz "sshd(?:-session)?") — é a linha que pega o
  # override removido ou encurtado.
  for linha in \
    'encha sshd-session[1234]: Invalid user naoexiste123 from 198.51.100.7 port 22' \
    'encha sshd-auth[1234]: Invalid user naoexiste123 from 198.51.100.7 port 22' \
    'encha sshd-session[1234]: Failed password for root from 198.51.100.7 port 22 ssh2'; do
    saida_regex="$(fail2ban-regex "$linha" "$TMP_F2B/filter.d/sshd.conf[logtype=journal]" 2>&1)" || true
    if printf '%s' "$saida_regex" | grep -q "1 matched"; then
      ok "fail2ban-regex (journal) casa: $linha"
    else
      falha "fail2ban-regex (journal) NÃO casa: $linha — $(printf '%s' "$saida_regex" | grep -E '^Lines:')"
    fi
  done
  rm -rf "$TMP_F2B"
else
  echo "ℹ️  fail2ban real indisponível neste ambiente — pulando a validação real (as seções 1-8 acima já cobrem a geração de config)."
fi

[ "$falhas" -eq 0 ] || exit 1
