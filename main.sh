#!/bin/bash

# Versão do Encha Setup. Mantenha em sincronia com encha-setup-panel/src/lib/version.ts
# e package.json. Fluxo de publicação documentado em encha-setup-panel/CLAUDE.md.
ENCHA_VERSION="0.3.5"

# Branch de onde este instalador baixa secondary.sh e a fonte do painel
# (download_secondary, preparar_fonte_painel). SEMPRE "main" em produção —
# nunca mude o padrão aqui. Existe só para permitir testar uma branch de
# desenvolvimento numa VPS real antes de publicar: exporte
# ENCHA_SRC_BRANCH=minha-branch antes de rodar o curl. Não afeta
# atualizar_fonte_painel() em secondary.sh, que usa a tag da versão já
# publicada (ver ali).
ENCHA_SRC_BRANCH="${ENCHA_SRC_BRANCH:-main}"

# Tag da imagem do Encha Setup Panel a puxar/buildar em
# ferramenta_encha_panel (secondary.sh). SEMPRE vazia em produção — nunca
# mude o padrão aqui. Existe só pra testar uma imagem específica (ex.: uma
# "sha-<12>" já publicada pelo CI de uma branch) numa VPS real antes de
# publicar: exporte ENCHA_PANEL_IMAGE_TAG=sha-xxxxxxxxxxxx antes de rodar o
# curl (ou antes de chamar a opção do menu). Vazia -> usa $ENCHA_VERSION,
# igual sempre foi.
ENCHA_PANEL_IMAGE_TAG="${ENCHA_PANEL_IMAGE_TAG:-}"

# Exportado ANTES de qualquer apt/docker-ce install, inclusive dentro de
# secondary.sh (é `source`ado neste mesmo shell — main.sh:710 — então herda
# estas env vars sem precisar prefixar cada chamada individualmente). Sem
# NEEDRESTART_MODE=a, o `needrestart` do Ubuntu 22/24 pode abrir um prompt
# whiptail que fica invisível numa sessão não-interativa (curl | bash) e
# parece travamento — DEBIAN_FRONTEND já cobre os prompts do dpkg/apt em si.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Versão e URL dos Termos de Uso (texto integral em legal/TERMOS-DE-USO.md).
# Ao publicar uma revisão material do texto, atualize TERMS_VERSION em conjunto
# com a versão publicada em /admin/setup/terms no Monitor — os dois precisam bater.
TERMS_VERSION="3"
TERMS_URL="https://encha.ai/termos"

# Redireciona stdin para o terminal — necessário quando o script é executado
# via "curl | bash", onde stdin é o pipe (o próprio script) e não o teclado.
# Sem isso, todos os "read" ficam sem input e o script trava ou entra em loop.
# Se /dev/tty não estiver acessível (ex.: sem TTY de controle), aborta com aviso
# em vez de cair em loop infinito de "read" recebendo EOF.
if [ ! -t 0 ]; then
    if [ -e /dev/tty ] && exec </dev/tty; then
        :
    else
        echo "ERRO: este instalador precisa de um terminal interativo." >&2
        echo "Rode com um TTY, por exemplo:" >&2
        echo "  bash <(curl -fsSL https://raw.githubusercontent.com/enchaaluno/setupteste/main/main.sh)" >&2
        exit 1
    fi
fi

# Cores melhoradas
roxo="\033[95m"
roxo_escuro="\033[35m"
amarelo="\033[93m"
amarelo_escuro="\033[33m"
verde="\033[92m"
verde_escuro="\033[32m"
vermelho="\033[91m"
vermelho_escuro="\033[31m"
azul="\033[94m"
azul_escuro="\033[34m"
ciano="\033[96m"
branco="\033[97m"
cinza="\033[90m"
negrito="\033[1m"
reset="\033[0m"

# Sem "=()" de propósito: main.sh fica em memória junto com secondary.sh (é
# `source`ado no mesmo shell, main.sh:~815) — se os dois usassem "declare -A
# MSG_PT=()", o segundo `declare` apagaria tudo que o primeiro já tivesse
# posto no catálogo. "declare -A NOME" sem atribuição é idempotente: cria se
# não existir, não mexe se já existir.
#
# PRECISA vir antes de qualquer "MSG_PT[chave]=..." no arquivo — bash cria
# a variável como array INDEXADO na primeira atribuição desse tipo se ainda
# não foi declarada, e depois um "declare -A" tarde demais falha em
# silêncio ("cannot convert indexed to associative array"), corrompendo o
# catálogo inteiro pro resto do script. Achado ao vivo numa VPS de teste:
# um lote de tradução da Fase 4 tinha inserido chaves (banner_*,
# loading_animation_*) acima de onde este bloco ficava antes.
declare -A MSG_PT
declare -A MSG_EN
declare -A MSG_ES

# Função para criar gradientes visuais
barra_gradiente() {
    echo -e "${roxo}╔═══════════════════════════════════════════════════════════════════════════════╗${reset}"
}

barra_final() {
    echo -e "${roxo}╚═══════════════════════════════════════════════════════════════════════════════╝${reset}"
}

barra_meio() {
    echo -e "${roxo}╠═══════════════════════════════════════════════════════════════════════════════╣${reset}"
}

MSG_PT[loading_animation_processando]="\r${amarelo}%s Processando...${reset}"
MSG_EN[loading_animation_processando]="\r${amarelo}%s Processing...${reset}"
MSG_ES[loading_animation_processando]="\r${amarelo}%s Procesando...${reset}"

MSG_PT[loading_animation_concluido]="\r${verde}✓ Concluído!         ${reset}\n"
MSG_EN[loading_animation_concluido]="\r${verde}✓ Done!              ${reset}\n"
MSG_ES[loading_animation_concluido]="\r${verde}✓ ¡Completado!       ${reset}\n"

# Função para animação de loading
loading_animation() {
    local duration=${1:-2}
    local chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local end_time=$((SECONDS + duration))
    
    while [ $SECONDS -lt $end_time ]; do
        for (( i=0; i<${#chars}; i++ )); do
            printf '%s' "$(t loading_animation_processando "${chars:$i:1}")"
            sleep 0.1
        done
    done
    printf '%s' "$(t loading_animation_concluido)"
}

centralizar() {
    local texto="$1"
    local largura_terminal=$(tput cols)
    local espacos=$(( (largura_terminal - ${#texto}) / 2 ))
    printf "%*s%s\n" "$espacos" "" "$texto"
}

MSG_PT[banner_titulo_info]="INFORMAÇÕES DO SISTEMA"
MSG_EN[banner_titulo_info]="SYSTEM INFORMATION"
MSG_ES[banner_titulo_info]="INFORMACIÓN DEL SISTEMA"

MSG_PT[banner_sistema]="${azul}   Sistema: ${verde}%s${reset}"
MSG_EN[banner_sistema]="${azul}   System: ${verde}%s${reset}"
MSG_ES[banner_sistema]="${azul}   Sistema: ${verde}%s${reset}"

MSG_PT[banner_kernel]="${azul}   Kernel: ${verde}%s${reset}"
MSG_EN[banner_kernel]="${azul}   Kernel: ${verde}%s${reset}"
MSG_ES[banner_kernel]="${azul}   Kernel: ${verde}%s${reset}"

MSG_PT[banner_arquitetura]="${azul}   Arquitetura: ${verde}%s${reset}"
MSG_EN[banner_arquitetura]="${azul}   Architecture: ${verde}%s${reset}"
MSG_ES[banner_arquitetura]="${azul}   Arquitectura: ${verde}%s${reset}"

MSG_PT[banner_uptime]="${azul}   Uptime: ${verde}%s${reset}"
MSG_EN[banner_uptime]="${azul}   Uptime: ${verde}%s${reset}"
MSG_ES[banner_uptime]="${azul}   Uptime: ${verde}%s${reset}"

# Banner principal melhorado
banner() {
    clear
    echo -e "${negrito}${roxo}"
    centralizar "╔══════════════════════════════════════════════════════════════════╗"
    centralizar "║                                                                  ║"
    centralizar "║   ███████ ███    ██  ██████ ██   ██  █████      █████  ██        ║"
    centralizar "║   ██      ████   ██ ██      ██   ██ ██   ██    ██   ██ ██        ║"
    centralizar "║   █████   ██ ██  ██ ██      ███████ ███████    ███████ ██        ║"
    centralizar "║   ██      ██  ██ ██ ██      ██   ██ ██   ██    ██   ██ ██        ║"
    centralizar "║   ███████ ██   ████  ██████ ██   ██ ██   ██ ██ ██   ██ ██        ║"
    centralizar "║                                                                  ║"
    centralizar "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${reset}"
    
    # Informações do sistema
    echo -e "${ciano}${negrito}"
    centralizar "$(t banner_titulo_info)"
    echo -e "${reset}"
    echo -e "$(t banner_sistema "$(uname -s)")"
    echo -e "$(t banner_kernel "$(uname -r)")"
    echo -e "$(t banner_arquitetura "$(uname -m)")"
    echo -e "$(t banner_uptime "$(uptime -p 2>/dev/null || echo "N/A")")"
    echo -e "${ciano}${negrito}"
    echo -e "${reset}"
    echo ""
    sleep 5
}

# Status melhorados com ícones
status_ok() { 
    echo -e "${verde}${negrito}✅ SUCCESS${reset} ${verde}│${reset} $1"
}

status_fail() { 
    echo -e "${vermelho}${negrito}❌ ERROR${reset} ${vermelho}│${reset} $1"
}

status_info() {
    echo -e "${azul}${negrito}ℹ️  INFO${reset} ${azul}│${reset} $1"
}

status_warning() {
    echo -e "${amarelo}${negrito}⚠️  WARNING${reset} ${amarelo}│${reset} $1"
}

################################################################################
# i18n — infraestrutura de tradução (Fases 0-1)
#
# Fase 0: a camada abaixo existe, mas as ~1.500 linhas de echo/read -p do
# instalador continuam com o texto em português embutido, sem passar por
# t() — isso é trabalho da Fase 4. Fase 1 (aqui): a pergunta de idioma
# (escolher_idioma, chamada no início do script principal, antes do aviso
# legal) e a persistência em /root/dados_vps/encha_locale.
#
# ENCHA_LANG: "pt" (default), "en" ou "es". Não confundir com ENCHA_SRC_BRANCH
# acima (aquele escolhe DE ONDE baixar o código; este escolhe EM QUE IDIOMA
# falar).
#
# ENCHA_LANG_VEIO_DO_AMBIENTE guarda se ENCHA_LANG já chegou setado de fora
# (export ENCHA_LANG=en antes do curl, usado pra automação/teste) ANTES do
# "${ENCHA_LANG:-pt}" abaixo aplicar o default — sem isso não dava pra saber
# se "pt" é escolha explícita do ambiente ou só o valor-padrão, e
# escolher_idioma() não saberia quando pular a pergunta interativa.
if [ -n "${ENCHA_LANG:-}" ]; then
    ENCHA_LANG_VEIO_DO_AMBIENTE=1
else
    ENCHA_LANG_VEIO_DO_AMBIENTE=0
fi
ENCHA_LANG="${ENCHA_LANG:-pt}"

# t chave [args...] — resolve `chave` no catálogo de ENCHA_LANG, caindo para
# MSG_PT e por fim para a própria chave se não encontrar em lugar nenhum
# (nunca quebra por chave faltando — mostra algo em vez de nada). args viram
# argumentos posicionais de `printf`, então uma entrada do catálogo com "%s"
# recebe variáveis sem depender de interpolação de string do bash — o mesmo
# texto serve pt/en/es mesmo quando a ordem das palavras muda.
#
# Exemplo de entrada no catálogo (Fase 1 em diante):
#   MSG_PT[prompt_escolher_idioma]="Escolha o idioma (1=Português, 2=English, 3=Español): "
#   MSG_EN[prompt_escolher_idioma]="Choose your language (1=Português, 2=English, 3=Español): "
# Uso: echo -ne "$(t prompt_escolher_idioma)"
t() {
    local chave="$1"; shift
    local template
    # case explícito, não nameref dinâmico: um ENCHA_LANG não catalogado
    # (typo, idioma futuro ainda sem catálogo) tem que cair em pt sempre,
    # mesmo que o script rode sob `set -u` em algum ponto.
    case "$ENCHA_LANG" in
        en) template="${MSG_EN[$chave]:-${MSG_PT[$chave]:-$chave}}" ;;
        es) template="${MSG_ES[$chave]:-${MSG_PT[$chave]:-$chave}}" ;;
        *)  template="${MSG_PT[$chave]:-$chave}" ;;
    esac
    if [ "$#" -gt 0 ]; then
        printf -- "$template" "$@"
    else
        printf '%s' "$template"
    fi
}

# escolher_idioma — pergunta o idioma ANTES de qualquer texto legal/traduzível
# (chamada logo no início da seção EXECUÇÃO, antes de aviso_legal). Não usa
# t() para o texto da própria pergunta: o usuário ainda não escolheu nada,
# então ela é mostrada nos 3 idiomas ao mesmo tempo — não dá pra saber qual
# catálogo usar antes da resposta.
escolher_idioma() {
    if [ "$ENCHA_LANG_VEIO_DO_AMBIENTE" = "1" ]; then
        return
    fi
    echo ""
    echo -e "${negrito}${roxo}Escolha o idioma / Choose your language / Elija su idioma:${reset}"
    echo -e "  ${ciano}1${reset}) Português (padrão / default)"
    echo -e "  ${ciano}2${reset}) English"
    echo -e "  ${ciano}3${reset}) Español"
    echo -ne "${ciano}> ${reset}"
    read -r escolha_idioma
    case "$escolha_idioma" in
        2) ENCHA_LANG="en" ;;
        3) ENCHA_LANG="es" ;;
        *) ENCHA_LANG="pt" ;;
    esac
}

# salvar_idioma_escolhido — grava /root/dados_vps/encha_locale, o formato de
# fio que secondary.sh (rodando sozinho depois, via `bash /root/SetupEnchaAI`)
# e o painel (mesmo diretório bind-montado em /app/vps-context) leem para
# saber o idioma escolhido nesta instalação. Passo próprio — não depende de
# coletar_inputs_so_painel, que nunca escreve em dados_vps (ver
# i18n/GLOSSARY.md e o plano).
salvar_idioma_escolhido() {
    mkdir -p /root/dados_vps
    echo "$ENCHA_LANG" > /root/dados_vps/encha_locale
}

MSG_PT[log_encha_subtitulo]="🤖 Conectando você ao poder da IA"
MSG_EN[log_encha_subtitulo]="🤖 Connecting you to the power of AI"
MSG_ES[log_encha_subtitulo]="🤖 Conectándote al poder de la IA"

# Logo animado do Encha AI
log_encha() {
    clear
    echo ""
    echo -e "${negrito}${roxo}"
    centralizar "               ╔══════════════════════════════════════════════════════════════════╗"
    centralizar "                                                                                "
    centralizar "                    ███████╗███╗   ██╗ ██████╗██╗  ██╗ █████╗     █████╗ ██╗    " 
    centralizar "                    ██╔════╝████╗  ██║██╔════╝██║  ██║██╔══██╗   ██╔══██╗██║    "
    centralizar "                    █████╗  ██╔██╗ ██║██║     ███████║███████║   ███████║██║    "
    centralizar "                    ██╔══╝  ██║╚██╗██║██║     ██╔══██║██╔══██║   ██╔══██║██║    " 
    centralizar "                    ███████╗██║ ╚████║╚██████╗██║  ██║██║  ██║██╗██║  ██║██║    "
    centralizar "                    ╚══════╝╚═╝  ╚═══╝ ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝╚═╝    "                    
    centralizar "                                                                                " 
    centralizar "                             $(t log_encha_subtitulo)                 "
    centralizar "               ║                                                                  ║"
    centralizar "               ╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${reset}"
    echo ""
}


banner_agradecimento() {
    echo -e "${roxo}"
    centralizar " █████╗  ██████╗ ██████╗  █████╗ ██████╗ ███████╗ ██████╗██╗███╗   ███╗███████╗███╗   ██╗████████╗ ██████╗ ███████╗"
    centralizar "██╔══██╗██╔════╝ ██╔══██╗██╔══██╗██╔══██╗██╔════╝██╔════╝██║████╗ ████║██╔════╝████╗  ██║╚══██╔══╝██╔═══██╗██╔════╝"
    centralizar "███████║██║  ███╗██████╔╝███████║██║  ██║█████╗  ██║     ██║██╔████╔██║█████╗  ██╔██╗ ██║   ██║   ██║   ██║███████╗"
    centralizar "██╔══██║██║   ██║██╔══██╗██╔══██║██║  ██║██╔══╝  ██║     ██║██║╚██╔╝██║██╔══╝  ██║╚██╗██║   ██║   ██║   ██║╚════██║"
    centralizar "██║  ██║╚██████╔╝██║  ██║██║  ██║██████╔╝███████╗╚██████╗██║██║ ╚═╝ ██║███████╗██║ ╚████║   ██║   ╚██████╔╝███████║"
    centralizar "╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ ╚══════╝ ╚═════╝╚═╝╚═╝     ╚═╝╚══════╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚══════╝"
    echo -e "${reset}"
    echo ""
}

MSG_PT[aviso_legal_titulo]="${vermelho}${negrito}⚠ Aviso Legal — leia antes de prosseguir:${reset}"
MSG_EN[aviso_legal_titulo]="${vermelho}${negrito}⚠ Legal Notice — read before continuing:${reset}"
MSG_ES[aviso_legal_titulo]="${vermelho}${negrito}⚠ Aviso Legal — lea antes de continuar:${reset}"

MSG_PT[aviso_legal_intro1]="${amarelo}O Encha Setup e o Encha Setup Panel são cedidos GRATUITAMENTE para ajudar a${reset}"
MSG_EN[aviso_legal_intro1]="${amarelo}Encha Setup and Encha Setup Panel are provided FREE OF CHARGE to help the${reset}"
MSG_ES[aviso_legal_intro1]="${amarelo}Encha Setup y Encha Setup Panel se ofrecen GRATUITAMENTE para ayudar a la${reset}"

MSG_PT[aviso_legal_intro2]="${amarelo}comunidade a instalar suas aplicações na própria VPS. O uso é facultativo —${reset}"
MSG_EN[aviso_legal_intro2]="${amarelo}community install their applications on their own VPS. Use is optional —${reset}"
MSG_ES[aviso_legal_intro2]="${amarelo}comunidad a instalar sus aplicaciones en su propia VPS. El uso es opcional —${reset}"

MSG_PT[aviso_legal_intro3]="${amarelo}existem outras opções no mercado, como Orion e EasyPanel.${reset}"
MSG_EN[aviso_legal_intro3]="${amarelo}there are other options on the market, such as Orion and EasyPanel.${reset}"
MSG_ES[aviso_legal_intro3]="${amarelo}existen otras opciones en el mercado, como Orion y EasyPanel.${reset}"

MSG_PT[aviso_legal_cupom1]="${vermelho}${negrito}⚠⚠⚠ Cupom de desconto: ${reset}${amarelo}acesse ${ciano}hostinger.com.br/encha${amarelo} e use o${reset}"
MSG_EN[aviso_legal_cupom1]="${vermelho}${negrito}⚠⚠⚠ Discount coupon: ${reset}${amarelo}go to ${ciano}hostinger.com.br/encha${amarelo} and use the${reset}"
MSG_ES[aviso_legal_cupom1]="${vermelho}${negrito}⚠⚠⚠ Cupón de descuento: ${reset}${amarelo}acceda a ${ciano}hostinger.com.br/encha${amarelo} y use el${reset}"

MSG_PT[aviso_legal_cupom2]="${amarelo}cupom ${negrito}ENCHA${reset}${amarelo} e veja o quanto você economiza na sua nova VPS ⚠⚠⚠${reset}"
MSG_EN[aviso_legal_cupom2]="${amarelo}coupon ${negrito}ENCHA${reset}${amarelo} and see how much you save on your new VPS ⚠⚠⚠${reset}"
MSG_ES[aviso_legal_cupom2]="${amarelo}cupón ${negrito}ENCHA${reset}${amarelo} y vea cuánto ahorra en su nueva VPS ⚠⚠⚠${reset}"

MSG_PT[aviso_legal_titulo_acoes]="${ciano}${negrito}O QUE ESTE INSTALADOR VAI FAZER NA SUA VPS:${reset}"
MSG_EN[aviso_legal_titulo_acoes]="${ciano}${negrito}WHAT THIS INSTALLER WILL DO ON YOUR VPS:${reset}"
MSG_ES[aviso_legal_titulo_acoes]="${ciano}${negrito}LO QUE ESTE INSTALADOR HARÁ EN SU VPS:${reset}"

MSG_PT[aviso_legal_acao_apt]="${amarelo} • Rodar 'apt upgrade' no sistema inteiro, como root${reset}"
MSG_EN[aviso_legal_acao_apt]="${amarelo} • Run 'apt upgrade' on the entire system, as root${reset}"
MSG_ES[aviso_legal_acao_apt]="${amarelo} • Ejecutar 'apt upgrade' en todo el sistema, como root${reset}"

MSG_PT[aviso_legal_acao_hostname]="${amarelo} • Trocar o hostname e editar o /etc/hosts do servidor${reset}"
MSG_EN[aviso_legal_acao_hostname]="${amarelo} • Change the hostname and edit the server's /etc/hosts${reset}"
MSG_ES[aviso_legal_acao_hostname]="${amarelo} • Cambiar el hostname y editar el /etc/hosts del servidor${reset}"

MSG_PT[aviso_legal_acao_docker1]="${amarelo} • Instalar Docker, iniciar o Swarm e abrir as portas 80 e 443 — necessárias${reset}"
MSG_EN[aviso_legal_acao_docker1]="${amarelo} • Install Docker, start Swarm and open ports 80 and 443 — required${reset}"
MSG_ES[aviso_legal_acao_docker1]="${amarelo} • Instalar Docker, iniciar el Swarm y abrir los puertos 80 y 443 — necesarios${reset}"

MSG_PT[aviso_legal_acao_docker2]="${amarelo}   para a comunicação externa. Se você instalar outras stacks, elas podem${reset}"
MSG_EN[aviso_legal_acao_docker2]="${amarelo}   for external communication. If you install other stacks, they may${reset}"
MSG_ES[aviso_legal_acao_docker2]="${amarelo}   para la comunicación externa. Si instala otros stacks, pueden${reset}"

MSG_PT[aviso_legal_acao_docker3]="${amarelo}   abrir portas adicionais obrigatórias — consulte a documentação de cada uma.${reset}"
MSG_EN[aviso_legal_acao_docker3]="${amarelo}   open additional required ports — check each one's documentation.${reset}"
MSG_ES[aviso_legal_acao_docker3]="${amarelo}   abrir puertos adicionales obligatorios — consulte la documentación de cada una.${reset}"

MSG_PT[aviso_legal_acao_ssl]="${amarelo} • Emitir certificado SSL (Let's Encrypt), enviando seu e-mail a ela${reset}"
MSG_EN[aviso_legal_acao_ssl]="${amarelo} • Issue an SSL certificate (Let's Encrypt), sending your email to it${reset}"
MSG_ES[aviso_legal_acao_ssl]="${amarelo} • Emitir certificado SSL (Let's Encrypt), enviando su correo a ella${reset}"

MSG_PT[aviso_legal_acao_guarda]="${amarelo} • Bloquear, automaticamente, as portas internas do cluster e limitar tentativas${reset}"
MSG_EN[aviso_legal_acao_guarda]="${amarelo} • Automatically block the cluster's internal ports and limit connection${reset}"
MSG_ES[aviso_legal_acao_guarda]="${amarelo} • Bloquear, automáticamente, los puertos internos del cluster y limitar los${reset}"

MSG_PT[aviso_legal_acao_guarda2]="${amarelo}   de conexão SSH — não é um firewall completo (Cláusula 6.1 dos Termos)${reset}"
MSG_EN[aviso_legal_acao_guarda2]="${amarelo}   attempts via SSH — this is not a full firewall (Terms, Clause 6.1)${reset}"
MSG_ES[aviso_legal_acao_guarda2]="${amarelo}   intentos de conexión SSH — no es un firewall completo (Cláusula 6.1)${reset}"

MSG_PT[aviso_legal_garantia]="${amarelo}Fornecido \"no estado em que se encontra\", sem garantia. Use uma VPS nova${reset}"
MSG_EN[aviso_legal_garantia]="${amarelo}Provided \"as is\", with no warranty. Use a fresh VPS${reset}"
MSG_ES[aviso_legal_garantia]="${amarelo}Proporcionado \"tal cual\", sin garantía. Use una VPS nueva${reset}"

MSG_PT[aviso_legal_backup]="${amarelo}ou faça backup antes. Termos completos: ${ciano}%s${amarelo} (versão %s).${reset}"
MSG_EN[aviso_legal_backup]="${amarelo}or back up beforehand. Full terms: ${ciano}%s${amarelo} (version %s).${reset}"
MSG_ES[aviso_legal_backup]="${amarelo}o haga una copia de seguridad antes. Términos completos: ${ciano}%s${amarelo} (versión %s).${reset}"

MSG_PT[aviso_legal_creditos]="${amarelo}Script original da ${ciano}OrionDesign${amarelo}, melhorado pela ${verde}Encha LTDA${amarelo}.${reset}"
MSG_EN[aviso_legal_creditos]="${amarelo}Original script by ${ciano}OrionDesign${amarelo}, improved by ${verde}Encha LTDA${amarelo}.${reset}"
MSG_ES[aviso_legal_creditos]="${amarelo}Script original de ${ciano}OrionDesign${amarelo}, mejorado por ${verde}Encha LTDA${amarelo}.${reset}"

MSG_PT[aviso_legal_pergunta]="${ciano}Li o aviso acima, aceito os Termos de Uso e desejo prosseguir? (Y/N): ${reset}"
MSG_EN[aviso_legal_pergunta]="${ciano}I have read the notice above, I accept the Terms of Use and wish to proceed? (Y/N): ${reset}"
MSG_ES[aviso_legal_pergunta]="${ciano}Leí el aviso anterior, acepto los Términos de Uso y deseo continuar? (Y/N): ${reset}"

MSG_PT[aviso_legal_sem_tty]="${vermelho}✖ Sem entrada interativa (EOF). Instalação cancelada.${reset}"
MSG_EN[aviso_legal_sem_tty]="${vermelho}✖ No interactive input (EOF). Installation cancelled.${reset}"
MSG_ES[aviso_legal_sem_tty]="${vermelho}✖ Sin entrada interactiva (EOF). Instalación cancelada.${reset}"

MSG_PT[aviso_legal_aceito]="${verde}✔ Termos aceitos. um momento...${reset}"
MSG_EN[aviso_legal_aceito]="${verde}✔ Terms accepted. one moment...${reset}"
MSG_ES[aviso_legal_aceito]="${verde}✔ Términos aceptados. un momento...${reset}"

MSG_PT[aviso_legal_paragrafo]="${amarelo}==================================================================================================
Este auto-instalador foi desenvolvido para auxiliar na instalação das principais aplicações
disponíveis no mercado open source. Os créditos originais de cada aplicação pertencem
aos respectivos desenvolvedores.
Este script foi criado originalmente pela ${ciano}OrionDesign${amarelo} (contato@oriondesign.art.br | https://oriondesign.art.br/setup)
e posteriormente refatorado pela ${verde}Encha AI${amarelo} (instalador@encha.ai | https://encha.ai), uma ferramenta
de IA para automação de tarefas e otimização de processos.
Este Setup é licenciado sob a Licença MIT Modificada. Você pode usar, copiar, modificar,
integrar, publicar, distribuir e/ou vender cópias dos produtos finais, desde que mantenha
este aviso e declare, de forma visível, que ${ciano}OrionDesign${amarelo} é o autor original e que foi refatorado
pela ${verde}Encha AI${amarelo}, incluindo os links para https://oriondesign.art.br/setup e https://encha.ai.
==================================================================================================${reset}"
MSG_EN[aviso_legal_paragrafo]="${amarelo}==================================================================================================
This auto-installer was developed to help install the main applications
available on the open source market. Original credit for each application belongs
to its respective developers.
This script was originally created by ${ciano}OrionDesign${amarelo} (contato@oriondesign.art.br | https://oriondesign.art.br/setup)
and later refactored by ${verde}Encha AI${amarelo} (instalador@encha.ai | https://encha.ai), an
AI tool for task automation and process optimization.
This Setup is licensed under the Modified MIT License. You may use, copy, modify,
integrate, publish, distribute and/or sell copies of the final products, as long as you keep
this notice and visibly state that ${ciano}OrionDesign${amarelo} is the original author and that it was refactored
by ${verde}Encha AI${amarelo}, including links to https://oriondesign.art.br/setup and https://encha.ai.
==================================================================================================${reset}"
MSG_ES[aviso_legal_paragrafo]="${amarelo}==================================================================================================
Este auto-instalador fue desarrollado para ayudar a instalar las principales aplicaciones
disponibles en el mercado open source. Los créditos originales de cada aplicación pertenecen
a sus respectivos desarrolladores.
Este script fue creado originalmente por ${ciano}OrionDesign${amarelo} (contato@oriondesign.art.br | https://oriondesign.art.br/setup)
y posteriormente refactorizado por ${verde}Encha AI${amarelo} (instalador@encha.ai | https://encha.ai), una herramienta
de IA para automatización de tareas y optimización de procesos.
Este Setup está licenciado bajo la Licencia MIT Modificada. Puede usar, copiar, modificar,
integrar, publicar, distribuir y/o vender copias de los productos finales, siempre que mantenga
este aviso y declare, de forma visible, que ${ciano}OrionDesign${amarelo} es el autor original y que fue refactorizado
por ${verde}Encha AI${amarelo}, incluyendo los enlaces a https://oriondesign.art.br/setup y https://encha.ai.
==================================================================================================${reset}"

MSG_PT[aviso_legal_cancelado]="${vermelho}✖ Instalação cancelada pelo usuário.${reset}"
MSG_EN[aviso_legal_cancelado]="${vermelho}✖ Installation cancelled by user.${reset}"
MSG_ES[aviso_legal_cancelado]="${vermelho}✖ Instalación cancelada por el usuario.${reset}"

MSG_PT[aviso_legal_invalido]="${amarelo}Por favor, responda com 'Y' para sim ou 'N' para não.${reset}"
MSG_EN[aviso_legal_invalido]="${amarelo}Please answer with 'Y' for yes or 'N' for no.${reset}"
MSG_ES[aviso_legal_invalido]="${amarelo}Por favor, responda con 'Y' para sí o 'N' para no.${reset}"

MSG_PT[aviso_legal_prosseguindo]="${ciano}Prosseguindo com a instalação em 5 segundos...${reset}"
MSG_EN[aviso_legal_prosseguindo]="${ciano}Proceeding with installation in 5 seconds...${reset}"
MSG_ES[aviso_legal_prosseguindo]="${ciano}Continuando con la instalación en 5 segundos...${reset}"

aviso_legal(){
    clear
centralizar " █████╗ ██╗   ██╗██╗███████╗ ██████╗"
centralizar "██╔══██╗██║   ██║██║██╔════╝██╔═══██╗"
centralizar "███████║██║   ██║██║███████╗██║   ██║"
centralizar "██╔══██║╚██╗ ██╔╝██║╚════██║██║   ██║"
centralizar "██║  ██║ ╚████╔╝ ██║███████║╚██████╔╝"
centralizar "╚═╝  ╚═╝  ╚═══╝  ╚═╝╚══════╝ ╚═════╝"
    echo ""
    echo -e "$(t aviso_legal_titulo)"
    echo -e "$(t aviso_legal_intro1)"
    echo -e "$(t aviso_legal_intro2)"
    echo -e "$(t aviso_legal_intro3)"
    echo ""
    echo -e "$(t aviso_legal_cupom1)"
    echo -e "$(t aviso_legal_cupom2)"
    echo ""
    echo -e "$(t aviso_legal_titulo_acoes)"
    echo -e "$(t aviso_legal_acao_apt)"
    echo -e "$(t aviso_legal_acao_hostname)"
    echo -e "$(t aviso_legal_acao_docker1)"
    echo -e "$(t aviso_legal_acao_docker2)"
    echo -e "$(t aviso_legal_acao_docker3)"
    echo -e "$(t aviso_legal_acao_ssl)"
    echo -e "$(t aviso_legal_acao_guarda)"
    echo -e "$(t aviso_legal_acao_guarda2)"
    echo ""
    echo -e "$(t aviso_legal_garantia)"
    echo -e "$(t aviso_legal_backup "$TERMS_URL" "$TERMS_VERSION")"
    echo -e "$(t aviso_legal_creditos)"
    echo ""

    while true; do
        echo -en "$(t aviso_legal_pergunta)"
        if ! read -r confirmacao; then
            echo ""
            echo -e "$(t aviso_legal_sem_tty)"
            exit 1
        fi

        case "$confirmacao" in
            [Yy])
                echo -e "$(t aviso_legal_aceito)"
                sleep 2

                # Seção de agradecimentos
                clear
                banner_agradecimento
                echo ""

                echo -e "$(t aviso_legal_paragrafo)"

                echo ""
                echo ""
                echo -e "$(t aviso_legal_prosseguindo)"
                sleep 5
                break
                ;;
            [Nn])
                echo -e "$(t aviso_legal_cancelado)"
                exit 1
                ;;
            *)
                echo -e "$(t aviso_legal_invalido)"
                ;;
        esac
    done
}


# Função para mostrar progresso
mostrar_progresso() {
    local atual=$1
    local total=$2
    local descricao=$3
    local porcentagem=$((atual * 100 / total))
    local preenchido=$((porcentagem / 5))
    local vazio=$((20 - preenchido))
    
    printf "\r${azul}${negrito}[${reset}"
    printf "${verde}%*s${reset}" $preenchido | tr ' ' '█'
    printf "${cinza}%*s${reset}" $vazio | tr ' ' '░'
    printf "${azul}${negrito}]${reset} ${branco}%d%%${reset} ${amarelo}%s${reset}" $porcentagem "$descricao"
}

MSG_PT[obter_ip_publico_obtendo]="Obtendo o IP público do servidor..."
MSG_EN[obter_ip_publico_obtendo]="Getting the server's public IP..."
MSG_ES[obter_ip_publico_obtendo]="Obteniendo la IP pública del servidor..."

MSG_PT[obter_ip_publico_ok]="IP público identificado com sucesso: ${negrito}%s${reset}"
MSG_EN[obter_ip_publico_ok]="Public IP identified successfully: ${negrito}%s${reset}"
MSG_ES[obter_ip_publico_ok]="IP pública identificada con éxito: ${negrito}%s${reset}"

MSG_PT[obter_ip_publico_falha]="Falha ao obter IP público. Será usado o IP local como alternativa."
MSG_EN[obter_ip_publico_falha]="Failed to get public IP. The local IP will be used instead."
MSG_ES[obter_ip_publico_falha]="Error al obtener la IP pública. Se usará la IP local como alternativa."

obter_ip_publico() {
    status_info "$(t obter_ip_publico_obtendo)"
    ip_publico=$(curl -s --max-time 10 https://icanhazip.com || hostname -I | awk '{print $1}')
    if [ -n "$ip_publico" ]; then
        status_ok "$(t obter_ip_publico_ok "$ip_publico")"
    else
        status_warning "$(t obter_ip_publico_falha)"
        ip_publico=$(hostname -I | awk '{print $1}')
    fi
    echo "$ip_publico"
}

# Checagem de pré-requisito ANTES de subir Traefik: DNS errado faz o Let's
# Encrypt falhar em silêncio (docker stack deploy do Traefik já manda tudo
# pra /dev/null) e o painel sobe sem HTTPS — e sem HTTPS o login nem
# funciona, porque o cookie de sessão exige `Secure` (__Host-). Isto é só
# AVISO, nunca bloqueia: DNS em propagação é um caso legítimo, e forçar
# abort aqui travaria instalação de quem sabe o que está fazendo.
MSG_PT[checar_dns_titulo]="🔎 PRÉ-CHECAGEM (informativa — não bloqueia)"
MSG_EN[checar_dns_titulo]="🔎 PRE-CHECK (informational — does not block)"
MSG_ES[checar_dns_titulo]="🔎 PRECOMPROBACIÓN (informativa — no bloquea)"

MSG_PT[checar_dns_ip_atual]="IP público desta VPS: ${negrito}%s${reset}"
MSG_EN[checar_dns_ip_atual]="This VPS's public IP: ${negrito}%s${reset}"
MSG_ES[checar_dns_ip_atual]="IP pública de esta VPS: ${negrito}%s${reset}"

MSG_PT[checar_dns_desconhecido]="desconhecido"
MSG_EN[checar_dns_desconhecido]="unknown"
MSG_ES[checar_dns_desconhecido]="desconocida"

MSG_PT[checar_dns_nao_resolveu]="DNS de '%s' não resolveu ainda. Se acabou de criar o registro, aguarde a propagação — o Let's Encrypt vai falhar até resolver."
MSG_EN[checar_dns_nao_resolveu]="DNS for '%s' hasn't resolved yet. If you just created the record, wait for propagation — Let's Encrypt will fail until it resolves."
MSG_ES[checar_dns_nao_resolveu]="El DNS de '%s' aún no resolvió. Si acaba de crear el registro, espere la propagación — Let's Encrypt fallará hasta que resuelva."

MSG_PT[checar_dns_aponta_errado]="DNS de '%s' aponta para %s, não para o IP desta VPS (%s). Confirme o registro A antes de seguir."
MSG_EN[checar_dns_aponta_errado]="DNS for '%s' points to %s, not to this VPS's IP (%s). Confirm the A record before continuing."
MSG_ES[checar_dns_aponta_errado]="El DNS de '%s' apunta a %s, no a la IP de esta VPS (%s). Confirme el registro A antes de continuar."

MSG_PT[checar_dns_ok]="DNS de '%s' já aponta para esta VPS."
MSG_EN[checar_dns_ok]="DNS for '%s' already points to this VPS."
MSG_ES[checar_dns_ok]="El DNS de '%s' ya apunta a esta VPS."

MSG_PT[checar_dns_portas_ocupadas]="Porta 80 e/ou 443 já está em uso por outro processo nesta VPS — o Traefik pode falhar ao subir. Rode 'ss -ltnp | grep -E \":(80|443)\"' para identificar."
MSG_EN[checar_dns_portas_ocupadas]="Port 80 and/or 443 is already in use by another process on this VPS — Traefik may fail to start. Run 'ss -ltnp | grep -E \":(80|443)\"' to identify it."
MSG_ES[checar_dns_portas_ocupadas]="El puerto 80 y/o 443 ya está en uso por otro proceso en esta VPS — Traefik puede fallar al iniciar. Ejecute 'ss -ltnp | grep -E \":(80|443)\"' para identificarlo."

MSG_PT[checar_dns_portas_livres]="Portas 80 e 443 livres."
MSG_EN[checar_dns_portas_livres]="Ports 80 and 443 are free."
MSG_ES[checar_dns_portas_livres]="Puertos 80 y 443 libres."

checar_dns_e_portas() {
    echo ""
    barra_meio
    echo -e "${ciano}${negrito}$(t checar_dns_titulo)${reset}"
    barra_meio

    local ip_atual
    ip_atual=$(curl -s --max-time 10 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')
    if [ -z "$ip_atual" ]; then
        ip_atual=$(hostname -I | awk '{print $1}')
    fi
    status_info "$(t checar_dns_ip_atual "${ip_atual:-$(t checar_dns_desconhecido)}")"

    local dominio resolvido
    for dominio in "$url_portainer" "$url_painel"; do
        [ -z "$dominio" ] && continue
        resolvido=$(getent ahostsv4 "$dominio" 2>/dev/null | awk '{print $1}' | head -n1)
        if [ -z "$resolvido" ]; then
            status_warning "$(t checar_dns_nao_resolveu "$dominio")"
        elif [ -n "$ip_atual" ] && [ "$resolvido" != "$ip_atual" ]; then
            status_warning "$(t checar_dns_aponta_errado "$dominio" "$resolvido" "$ip_atual")"
        else
            status_ok "$(t checar_dns_ok "$dominio")"
        fi
    done

    local ocupadas
    ocupadas=$(ss -ltn 2>/dev/null | awk '{print $4}' | grep -E ':(80|443)$')
    if [ -n "$ocupadas" ]; then
        status_warning "$(t checar_dns_portas_ocupadas)"
    else
        status_ok "$(t checar_dns_portas_livres)"
    fi
}

MSG_PT[executar_instalacoes_titulo]="📦 Iniciando a instalação dos pacotes necessários..."
MSG_EN[executar_instalacoes_titulo]="📦 Starting installation of required packages..."
MSG_ES[executar_instalacoes_titulo]="📦 Iniciando la instalación de los paquetes necesarios..."

MSG_PT[executar_instalacoes_pacote_instalando]="Instalando %s..."
MSG_EN[executar_instalacoes_pacote_instalando]="Installing %s..."
MSG_ES[executar_instalacoes_pacote_instalando]="Instalando %s..."

MSG_PT[executar_instalacoes_pacote_ok]="[%s/%s] %s instalado com sucesso"
MSG_EN[executar_instalacoes_pacote_ok]="[%s/%s] %s installed successfully"
MSG_ES[executar_instalacoes_pacote_ok]="[%s/%s] %s instalado con éxito"

MSG_PT[executar_instalacoes_pacote_falha]="[%s/%s] Falha na instalação de %s"
MSG_EN[executar_instalacoes_pacote_falha]="[%s/%s] Failed to install %s"
MSG_ES[executar_instalacoes_pacote_falha]="[%s/%s] Falló la instalación de %s"

MSG_PT[executar_instalacoes_concluido]="Instalação de pacotes concluída! 📋"
MSG_EN[executar_instalacoes_concluido]="Package installation complete! 📋"
MSG_ES[executar_instalacoes_concluido]="¡Instalación de paquetes completada! 📋"

executar_instalacoes() {
    echo ""
    barra_meio
    echo -e "${verde}${negrito}$(t executar_instalacoes_titulo)${reset}"
    barra_meio

    # neofetch foi removido do Debian trixie (13) e não tem substituto direto
    # nos repos oficiais nesta lista — cada tentativa de instalá-lo falhava
    # com "❌ ERROR" no meio da instalação em VPS trixie, mesmo sem nunca ser
    # de fato invocado em lugar nenhum do script (grep confirma: só aparece
    # aqui). Puramente cosmético, então tirado em vez de trocado.
    pacotes=(sudo apt-utils dialog jq apache2-utils git python3 curl wget htop vim nano)
    total_pacotes=${#pacotes[@]}

    for i in "${!pacotes[@]}"; do
        pacote="${pacotes[$i]}"
        atual=$((i + 1))

        mostrar_progresso $atual $total_pacotes "$(t executar_instalacoes_pacote_instalando "$pacote")"

        DEBIAN_FRONTEND=noninteractive apt-get install -y "$pacote" > /dev/null 2>&1

        if [ $? -eq 0 ]; then
            printf "\n"
            status_ok "$(t executar_instalacoes_pacote_ok "$atual" "$total_pacotes" "$pacote")"
        else
            printf "\n"
            status_fail "$(t executar_instalacoes_pacote_falha "$atual" "$total_pacotes" "$pacote")"
        fi
    done

    echo ""
    status_ok "$(t executar_instalacoes_concluido)"
}

MSG_PT[mostrar_recursos_titulo]="💻 RECURSOS DO SISTEMA"
MSG_EN[mostrar_recursos_titulo]="💻 SYSTEM RESOURCES"
MSG_ES[mostrar_recursos_titulo]="💻 RECURSOS DEL SISTEMA"

MSG_PT[mostrar_recursos_ram_total]="${azul}RAM Total:${reset} ${verde}%s${reset}"
MSG_EN[mostrar_recursos_ram_total]="${azul}Total RAM:${reset} ${verde}%s${reset}"
MSG_ES[mostrar_recursos_ram_total]="${azul}RAM Total:${reset} ${verde}%s${reset}"

MSG_PT[mostrar_recursos_ram_livre]="${azul}RAM Livre:${reset} ${verde}%s${reset}"
MSG_EN[mostrar_recursos_ram_livre]="${azul}Free RAM:${reset} ${verde}%s${reset}"
MSG_ES[mostrar_recursos_ram_livre]="${azul}RAM Libre:${reset} ${verde}%s${reset}"

MSG_PT[mostrar_recursos_disco]="${azul}Espaço em Disco:${reset} ${verde}%s livre de %s${reset}"
MSG_EN[mostrar_recursos_disco]="${azul}Disk Space:${reset} ${verde}%s free of %s${reset}"
MSG_ES[mostrar_recursos_disco]="${azul}Espacio en Disco:${reset} ${verde}%s libre de %s${reset}"

MSG_PT[mostrar_recursos_cpu]="${azul}CPU:${reset} ${verde}%s núcleos${reset}"
MSG_EN[mostrar_recursos_cpu]="${azul}CPU:${reset} ${verde}%s cores${reset}"
MSG_ES[mostrar_recursos_cpu]="${azul}CPU:${reset} ${verde}%s núcleos${reset}"

MSG_PT[mostrar_recursos_load]="${azul}Load Average:${reset} ${verde}%s${reset}"
MSG_EN[mostrar_recursos_load]="${azul}Load Average:${reset} ${verde}%s${reset}"
MSG_ES[mostrar_recursos_load]="${azul}Load Average:${reset} ${verde}%s${reset}"

# Função para verificar e exibir recursos do sistema
mostrar_recursos() {
    echo ""
    barra_meio
    echo -e "${ciano}${negrito}$(t mostrar_recursos_titulo)${reset}"
    barra_meio

    echo -e "$(t mostrar_recursos_ram_total "$(free -h | awk '/^Mem:/ {print $2}')")"
    echo -e "$(t mostrar_recursos_ram_livre "$(free -h | awk '/^Mem:/ {print $7}')")"
    echo -e "$(t mostrar_recursos_disco "$(df -h / | awk 'NR==2 {print $4}')" "$(df -h / | awk 'NR==2 {print $2}')")"
    echo -e "$(t mostrar_recursos_cpu "$(nproc)")"
    echo -e "$(t mostrar_recursos_load "$(uptime | awk -F'load average:' '{print $2}')")"
}

MSG_PT[main_iniciando_config]="${amarelo}${negrito}🚀 Iniciando processo de configuração...${reset}"
MSG_EN[main_iniciando_config]="${amarelo}${negrito}🚀 Starting configuration process...${reset}"
MSG_ES[main_iniciando_config]="${amarelo}${negrito}🚀 Iniciando proceso de configuración...${reset}"

MSG_PT[main_precisa_root]="Este script deve ser executado como root!"
MSG_EN[main_precisa_root]="This script must be run as root!"
MSG_ES[main_precisa_root]="¡Este script debe ejecutarse como root!"

MSG_PT[main_execute_sudo]="${amarelo}Execute: ${negrito}sudo %s${reset}"
MSG_EN[main_execute_sudo]="${amarelo}Run: ${negrito}sudo %s${reset}"
MSG_ES[main_execute_sudo]="${amarelo}Ejecute: ${negrito}sudo %s${reset}"

MSG_PT[main_erro_cd_root]="Erro ao acessar diretório /root"
MSG_EN[main_erro_cd_root]="Error accessing the /root directory"
MSG_ES[main_erro_cd_root]="Error al acceder al directorio /root"

MSG_PT[main_titulo_atualizacao]="🔄 ATUALIZAÇÃO DO SISTEMA"
MSG_EN[main_titulo_atualizacao]="🔄 SYSTEM UPDATE"
MSG_ES[main_titulo_atualizacao]="🔄 ACTUALIZACIÓN DEL SISTEMA"

MSG_PT[main_atualizando_lista]="Atualizando lista de pacotes..."
MSG_EN[main_atualizando_lista]="Updating package list..."
MSG_ES[main_atualizando_lista]="Actualizando lista de paquetes..."

MSG_PT[main_lista_atualizada]="Lista de pacotes atualizada"
MSG_EN[main_lista_atualizada]="Package list updated"
MSG_ES[main_lista_atualizada]="Lista de paquetes actualizada"

MSG_PT[main_atualizando_pacotes]="Atualizando pacotes do sistema..."
MSG_EN[main_atualizando_pacotes]="Updating system packages..."
MSG_ES[main_atualizando_pacotes]="Actualizando paquetes del sistema..."

MSG_PT[main_processo_demorado]="${amarelo}${negrito}⚠ O processo pode demorar um pouco. Agradecemos a sua paciência.${reset}"
MSG_EN[main_processo_demorado]="${amarelo}${negrito}⚠ The process may take a while. Thank you for your patience.${reset}"
MSG_ES[main_processo_demorado]="${amarelo}${negrito}⚠ El proceso puede tardar un poco. Agradecemos su paciencia.${reset}"

MSG_PT[main_sistema_atualizado]="Sistema atualizado com sucesso"
MSG_EN[main_sistema_atualizado]="System updated successfully"
MSG_ES[main_sistema_atualizado]="Sistema actualizado con éxito"

# ====== INÍCIO DO SCRIPT PRINCIPAL ======

# Idioma primeiro — tem que decidir antes do aviso legal e dos Termos de Uso
# (aviso_legal, logo abaixo), senão eles aparecem em português pra quem
# acabou de escolher outro idioma.
escolher_idioma
salvar_idioma_escolhido

clear
aviso_legal
banner
log_encha

sleep 2

echo -e "$(t main_iniciando_config)"
sleep 1

# Verificação de privilégios
if [ "$(id -u)" -ne 0 ]; then
    echo ""
    status_fail "$(t main_precisa_root)"
    echo -e "$(t main_execute_sudo "$0")"
    exit 1
fi

# Mudar para diretório root
cd /root || {
    status_fail "$(t main_erro_cd_root)"
    exit 1
}

mostrar_recursos

# Update inicial do sistema
echo ""
barra_meio
echo -e "${amarelo}${negrito}$(t main_titulo_atualizacao)${reset}"
barra_meio

status_info "$(t main_atualizando_lista)"
DEBIAN_FRONTEND=noninteractive apt update > /dev/null 2>&1 && status_ok "$(t main_lista_atualizada)"

status_info "$(t main_atualizando_pacotes)"
echo -e "$(t main_processo_demorado)"
DEBIAN_FRONTEND=noninteractive apt upgrade -y > /dev/null 2>&1 && status_ok "$(t main_sistema_atualizado)"

# Executar instalações
executar_instalacoes


# ─────────────────────────────────────────────────────────────────────────────
# FLUXO LINEAR — instala Traefik+Portainer + Encha Setup Panel automaticamente
# ─────────────────────────────────────────────────────────────────────────────

MSG_PT[banner_instalacao_titulo]="║          🚀 INSTALAÇÃO AUTOMÁTICA DO ENCHA SETUP                 ║"
MSG_EN[banner_instalacao_titulo]="║           🚀 ENCHA SETUP AUTOMATIC INSTALLATION                  ║"
MSG_ES[banner_instalacao_titulo]="║        🚀 INSTALACIÓN AUTOMÁTICA DE ENCHA SETUP                  ║"

MSG_PT[banner_instalacao_sequencia]="${ciano}Serão instalados nesta sequência:${reset}"
MSG_EN[banner_instalacao_sequencia]="${ciano}The following will be installed in this order:${reset}"
MSG_ES[banner_instalacao_sequencia]="${ciano}Se instalarán en esta secuencia:${reset}"

MSG_PT[banner_instalacao_item1]="  ${verde}1.${reset} Docker Swarm + rede overlay"
MSG_EN[banner_instalacao_item1]="  ${verde}1.${reset} Docker Swarm + overlay network"
MSG_ES[banner_instalacao_item1]="  ${verde}1.${reset} Docker Swarm + red overlay"

MSG_PT[banner_instalacao_item2]="  ${verde}2.${reset} Traefik (proxy reverso com SSL automático)"
MSG_EN[banner_instalacao_item2]="  ${verde}2.${reset} Traefik (reverse proxy with automatic SSL)"
MSG_ES[banner_instalacao_item2]="  ${verde}2.${reset} Traefik (proxy inverso con SSL automático)"

MSG_PT[banner_instalacao_item3]="  ${verde}3.${reset} Portainer (interface de gerenciamento Docker)"
MSG_EN[banner_instalacao_item3]="  ${verde}3.${reset} Portainer (Docker management interface)"
MSG_ES[banner_instalacao_item3]="  ${verde}3.${reset} Portainer (interfaz de gestión de Docker)"

MSG_PT[banner_instalacao_item4]="  ${verde}4.${reset} Encha Setup Panel (painel visual para instalar stacks)"
MSG_EN[banner_instalacao_item4]="  ${verde}4.${reset} Encha Setup Panel (visual panel for installing stacks)"
MSG_ES[banner_instalacao_item4]="  ${verde}4.${reset} Encha Setup Panel (panel visual para instalar stacks)"

MSG_PT[banner_instalacao_aponte]="${amarelo}⚠ Aponte os subdomínios para o IP da VPS ANTES de continuar:${reset}"
MSG_EN[banner_instalacao_aponte]="${amarelo}⚠ Point the subdomains to the VPS IP BEFORE continuing:${reset}"
MSG_ES[banner_instalacao_aponte]="${amarelo}⚠ Apunte los subdominios a la IP de la VPS ANTES de continuar:${reset}"

MSG_PT[banner_instalacao_dominio_portainer]="  • portainer.seudominio.com  →  IP_DA_VPS"
MSG_EN[banner_instalacao_dominio_portainer]="  • portainer.yourdomain.com  →  VPS_IP"
MSG_ES[banner_instalacao_dominio_portainer]="  • portainer.sudominio.com  →  IP_DE_LA_VPS"

MSG_PT[banner_instalacao_dominio_painel]="  • painel.seudominio.com     →  IP_DA_VPS"
MSG_EN[banner_instalacao_dominio_painel]="  • panel.yourdomain.com      →  VPS_IP"
MSG_ES[banner_instalacao_dominio_painel]="  • panel.sudominio.com      →  IP_DE_LA_VPS"

MSG_PT[banner_instalacao_pressione_enter]="${ciano}Pressione ENTER para iniciar...${reset}"
MSG_EN[banner_instalacao_pressione_enter]="${ciano}Press ENTER to start...${reset}"
MSG_ES[banner_instalacao_pressione_enter]="${ciano}Presione ENTER para comenzar...${reset}"

banner_instalacao_completa() {
    clear
    echo -e "${negrito}${roxo}"
    centralizar "╔══════════════════════════════════════════════════════════════════╗"
    centralizar "$(t banner_instalacao_titulo)"
    centralizar "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${reset}"
    echo ""
    echo -e "$(t banner_instalacao_sequencia)"
    echo -e "$(t banner_instalacao_item1)"
    echo -e "$(t banner_instalacao_item2)"
    echo -e "$(t banner_instalacao_item3)"
    echo -e "$(t banner_instalacao_item4)"
    echo ""
    echo -e "$(t banner_instalacao_aponte)"
    echo -e "$(t banner_instalacao_dominio_portainer)"
    echo -e "$(t banner_instalacao_dominio_painel)"
    echo ""
    echo -ne "$(t banner_instalacao_pressione_enter)" && read -r _
}

# Descobre a overlay network onde o Portainer já está conectado, para que o
# painel suba na MESMA rede (e assim alcance o Portainer e seja roteado pelo
# Traefik existentes). Imprime o nome da rede em stdout; retorna 1 se não achar.
descobrir_rede_painel() {
    local svc nets net name driver ingress
    for svc in portainer_portainer $(docker service ls --format '{{.Name}}' 2>/dev/null | grep -i portainer); do
        nets=$(docker service inspect "$svc" \
            --format '{{range .Spec.TaskTemplate.Networks}}{{.Target}} {{end}}' 2>/dev/null)
        [ -n "$nets" ] && break
    done
    for net in $nets; do
        read -r name driver ingress <<<"$(docker network inspect "$net" \
            --format '{{.Name}} {{.Driver}} {{.Ingress}}' 2>/dev/null)"
        if [ "$driver" = "overlay" ] && [ "$ingress" != "true" ]; then
            echo "$name"
            return 0
        fi
    done
    return 1
}

# Detecta se Traefik + Portainer já estão instalados e rodando nesta VPS.
# Retorna 0 (instalado) ou 1 (ausente). Silenciosa — só verifica.
infra_ja_instalada() {
    command -v docker &> /dev/null || return 1
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "portainer" || return 1
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "traefik"   || return 1
    return 0
}

# Coleta os dados do painel (modo "instalar só o painel"). Reaproveita a rede
# overlay já existente. Diferente da versão anterior, o painel agora tem
# admin próprio e precisa das credenciais de serviço do Portainer (para se
# autenticar sozinho na API) — então essas credenciais são lidas/confirmadas
# aqui, não mais deixadas para a tela de login.
MSG_PT[coletar_so_painel_titulo]="${negrito}${roxo}📝 INSTALAR APENAS O PAINEL${reset}"
MSG_EN[coletar_so_painel_titulo]="${negrito}${roxo}📝 INSTALL PANEL ONLY${reset}"
MSG_ES[coletar_so_painel_titulo]="${negrito}${roxo}📝 INSTALAR SOLO EL PANEL${reset}"

MSG_PT[coletar_so_painel_detectado]="${verde}✓ Traefik + Portainer detectados — serão reaproveitados.${reset}"
MSG_EN[coletar_so_painel_detectado]="${verde}✓ Traefik + Portainer detected — they will be reused.${reset}"
MSG_ES[coletar_so_painel_detectado]="${verde}✓ Traefik + Portainer detectados — se reutilizarán.${reset}"

MSG_PT[coletar_so_painel_rede_interna]="  ${azul}Rede interna:${reset} ${verde}%s${reset}"
MSG_EN[coletar_so_painel_rede_interna]="  ${azul}Internal network:${reset} ${verde}%s${reset}"
MSG_ES[coletar_so_painel_rede_interna]="  ${azul}Red interna:${reset} ${verde}%s${reset}"

MSG_PT[coletar_so_painel_aponte]="${amarelo}⚠ Aponte o subdomínio do painel para o IP da VPS ANTES de continuar.${reset}"
MSG_EN[coletar_so_painel_aponte]="${amarelo}⚠ Point the panel subdomain to the VPS IP BEFORE continuing.${reset}"
MSG_ES[coletar_so_painel_aponte]="${amarelo}⚠ Apunte el subdominio del panel a la IP de la VPS ANTES de continuar.${reset}"

MSG_PT[coletar_so_painel_pergunta_subdominio]="${ciano}1/4 Subdomínio do Encha Setup Panel (ex: painel.encha.ai): ${reset}"
MSG_EN[coletar_so_painel_pergunta_subdominio]="${ciano}1/4 Encha Setup Panel subdomain (e.g.: panel.encha.ai): ${reset}"
MSG_ES[coletar_so_painel_pergunta_subdominio]="${ciano}1/4 Subdominio del Encha Setup Panel (ej: panel.encha.ai): ${reset}"

MSG_PT[coletar_so_painel_dominio_invalido]="${vermelho}✖ Domínio inválido.${reset}"
MSG_EN[coletar_so_painel_dominio_invalido]="${vermelho}✖ Invalid domain.${reset}"
MSG_ES[coletar_so_painel_dominio_invalido]="${vermelho}✖ Dominio inválido.${reset}"

MSG_PT[coletar_so_painel_cred_detectada]="${verde}✓ Credenciais do Portainer detectadas — usuário: %s${reset}"
MSG_EN[coletar_so_painel_cred_detectada]="${verde}✓ Portainer credentials detected — user: %s${reset}"
MSG_ES[coletar_so_painel_cred_detectada]="${verde}✓ Credenciales de Portainer detectadas — usuario: %s${reset}"

MSG_PT[coletar_so_painel_usar_detectado]="${ciano}2/4 Usar essas credenciais? (Y/n): ${reset}"
MSG_EN[coletar_so_painel_usar_detectado]="${ciano}2/4 Use these credentials? (Y/n): ${reset}"
MSG_ES[coletar_so_painel_usar_detectado]="${ciano}2/4 ¿Usar estas credenciales? (Y/n): ${reset}"

MSG_PT[coletar_so_painel_user_portainer]="${ciano}2/4 Usuário do Portainer: ${reset}"
MSG_EN[coletar_so_painel_user_portainer]="${ciano}2/4 Portainer username: ${reset}"
MSG_ES[coletar_so_painel_user_portainer]="${ciano}2/4 Usuario de Portainer: ${reset}"

MSG_PT[coletar_so_painel_pass_portainer]="${ciano}    Senha do Portainer: ${reset}"
MSG_EN[coletar_so_painel_pass_portainer]="${ciano}    Portainer password: ${reset}"
MSG_ES[coletar_so_painel_pass_portainer]="${ciano}    Contraseña de Portainer: ${reset}"

MSG_PT[coletar_so_painel_validando]="${ciano}Validando credenciais do Portainer...${reset}"
MSG_EN[coletar_so_painel_validando]="${ciano}Validating Portainer credentials...${reset}"
MSG_ES[coletar_so_painel_validando]="${ciano}Validando credenciales de Portainer...${reset}"

MSG_PT[coletar_so_painel_auth_falhou]="${vermelho}✖ Falha ao autenticar no Portainer com essas credenciais (HTTP %s).${reset}"
MSG_EN[coletar_so_painel_auth_falhou]="${vermelho}✖ Failed to authenticate with Portainer using these credentials (HTTP %s).${reset}"
MSG_ES[coletar_so_painel_auth_falhou]="${vermelho}✖ Fallo al autenticar en Portainer con estas credenciales (HTTP %s).${reset}"

MSG_PT[coletar_so_painel_cred_validas]="${verde}✓ Credenciais do Portainer válidas.${reset}"
MSG_EN[coletar_so_painel_cred_validas]="${verde}✓ Portainer credentials are valid.${reset}"
MSG_ES[coletar_so_painel_cred_validas]="${verde}✓ Credenciales de Portainer válidas.${reset}"

MSG_PT[coletar_so_painel_regras_usuario]="${amarelo}--> 4-40 caracteres, minúsculas/números/_/-, começando com letra. Evite \"admin\".${reset}"
MSG_EN[coletar_so_painel_regras_usuario]="${amarelo}--> 4-40 characters, lowercase/numbers/_/-, starting with a letter. Avoid \"admin\".${reset}"
MSG_ES[coletar_so_painel_regras_usuario]="${amarelo}--> 4-40 caracteres, minúsculas/números/_/-, empezando con letra. Evite \"admin\".${reset}"

MSG_PT[coletar_so_painel_user_painel]="${ciano}3/4 Usuário admin do Painel: ${reset}"
MSG_EN[coletar_so_painel_user_painel]="${ciano}3/4 Panel admin username: ${reset}"
MSG_ES[coletar_so_painel_user_painel]="${ciano}3/4 Usuario admin del Panel: ${reset}"

MSG_PT[coletar_so_painel_usuario_invalido]="${vermelho}✖ Usuário inválido.${reset}"
MSG_EN[coletar_so_painel_usuario_invalido]="${vermelho}✖ Invalid username.${reset}"
MSG_ES[coletar_so_painel_usuario_invalido]="${vermelho}✖ Usuario inválido.${reset}"

MSG_PT[coletar_so_painel_regras_senha]="${amarelo}--> Mínimo 12 caracteres com MAIÚSCULAS, minúsculas, números e @ ou _${reset}"
MSG_EN[coletar_so_painel_regras_senha]="${amarelo}--> Minimum 12 characters with UPPERCASE, lowercase, numbers and @ or _${reset}"
MSG_ES[coletar_so_painel_regras_senha]="${amarelo}--> Mínimo 12 caracteres con MAYÚSCULAS, minúsculas, números y @ o _${reset}"

MSG_PT[coletar_so_painel_pass_painel]="${ciano}4/4 Senha admin do Painel: ${reset}"
MSG_EN[coletar_so_painel_pass_painel]="${ciano}4/4 Panel admin password: ${reset}"
MSG_ES[coletar_so_painel_pass_painel]="${ciano}4/4 Contraseña admin del Panel: ${reset}"

MSG_PT[coletar_so_painel_senha_invalida]="${vermelho}✖ Senha não atende aos requisitos.${reset}"
MSG_EN[coletar_so_painel_senha_invalida]="${vermelho}✖ Password does not meet the requirements.${reset}"
MSG_ES[coletar_so_painel_senha_invalida]="${vermelho}✖ La contraseña no cumple los requisitos.${reset}"

MSG_PT[coletar_so_painel_confira]="${roxo}${negrito}🔍 CONFIRA OS DADOS:${reset}"
MSG_EN[coletar_so_painel_confira]="${roxo}${negrito}🔍 REVIEW THE DATA:${reset}"
MSG_ES[coletar_so_painel_confira]="${roxo}${negrito}🔍 REVISE LOS DATOS:${reset}"

MSG_PT[coletar_so_painel_resumo_painel]="  ${azul}Painel:${reset}          https://${verde}%s${reset}"
MSG_EN[coletar_so_painel_resumo_painel]="  ${azul}Panel:${reset}           https://${verde}%s${reset}"
MSG_ES[coletar_so_painel_resumo_painel]="  ${azul}Panel:${reset}           https://${verde}%s${reset}"

MSG_PT[coletar_so_painel_resumo_rede]="  ${azul}Rede (reuso):${reset}    ${verde}%s${reset}"
MSG_EN[coletar_so_painel_resumo_rede]="  ${azul}Network (reused):${reset} ${verde}%s${reset}"
MSG_ES[coletar_so_painel_resumo_rede]="  ${azul}Red (reutilizada):${reset} ${verde}%s${reset}"

MSG_PT[coletar_so_painel_resumo_servico]="  ${azul}Serviço Portainer:${reset} ${verde}%s${reset}"
MSG_EN[coletar_so_painel_resumo_servico]="  ${azul}Portainer service:${reset} ${verde}%s${reset}"
MSG_ES[coletar_so_painel_resumo_servico]="  ${azul}Servicio Portainer:${reset} ${verde}%s${reset}"

MSG_PT[coletar_so_painel_resumo_usuario]="  ${azul}Usuário Painel:${reset}   ${verde}%s${reset}"
MSG_EN[coletar_so_painel_resumo_usuario]="  ${azul}Panel user:${reset}      ${verde}%s${reset}"
MSG_ES[coletar_so_painel_resumo_usuario]="  ${azul}Usuario Panel:${reset}   ${verde}%s${reset}"

MSG_PT[coletar_so_painel_confirma]="${verde}✅ Confirma? (Y/N): ${reset}"
MSG_EN[coletar_so_painel_confirma]="${verde}✅ Confirm? (Y/N): ${reset}"
MSG_ES[coletar_so_painel_confirma]="${verde}✅ ¿Confirma? (Y/N): ${reset}"

MSG_PT[coletar_so_painel_responda]="${amarelo}Responda Y ou N.${reset}"
MSG_EN[coletar_so_painel_responda]="${amarelo}Answer Y or N.${reset}"
MSG_ES[coletar_so_painel_responda]="${amarelo}Responda Y o N.${reset}"

coletar_inputs_so_painel() {
    clear
    echo -e "$(t coletar_so_painel_titulo)"
    echo ""
    echo -e "$(t coletar_so_painel_detectado)"
    echo -e "$(t coletar_so_painel_rede_interna "$nome_rede_interna")"
    echo ""
    echo -e "$(t coletar_so_painel_aponte)"
    echo ""

    while true; do
        echo -ne "$(t coletar_so_painel_pergunta_subdominio)" && read -r url_painel
        [[ "$url_painel" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] && break
        echo -e "$(t coletar_so_painel_dominio_invalido)"
    done

    # 2) Credenciais de serviço do Portainer — o painel usa para se
    #    autenticar sozinho na API. Tenta detectar em /root/dados_vps/dados_portainer
    #    (gravado na instalação do Portainer) antes de pedir.
    user_portainer=""
    pass_portainer=""
    arquivo_portainer="/root/dados_vps/dados_portainer"
    if [ -f "$arquivo_portainer" ]; then
        # Chave nova (inglês) ou antiga (português) — ver i18n/GLOSSARY.md.
        detectado_user=$(grep -E "^(Username|Usuario): " "$arquivo_portainer" | head -1 | awk -F': ' '{print $2}' | tr -d '\r')
        detectado_senha=$(grep -E "^(Password|Senha): " "$arquivo_portainer" | head -1 | awk -F': ' '{print $2}' | tr -d '\r')
        if [[ -n "$detectado_user" && -n "$detectado_senha" && "$detectado_user" != *"criar"* ]]; then
            echo -e "$(t coletar_so_painel_cred_detectada "$detectado_user")"
            echo -ne "$(t coletar_so_painel_usar_detectado)" && read -r usar_detectado
            if [[ ! "$usar_detectado" =~ ^[Nn]$ ]]; then
                user_portainer="$detectado_user"
                pass_portainer="$detectado_senha"
            fi
        fi
    fi
    if [ -z "$user_portainer" ]; then
        echo -ne "$(t coletar_so_painel_user_portainer)" && read -r user_portainer
        echo -ne "$(t coletar_so_painel_pass_portainer)" && read -rs pass_portainer && echo ""
    fi

    # Valida de verdade contra o Portainer, para não gerar uma stack do
    # painel com credenciais de serviço erradas.
    echo -e "$(t coletar_so_painel_validando)"
    resp=$(sudo docker run --rm --network "$nome_rede_interna" "${ENCHA_CURL_IMAGE}" \
        -s -o /dev/null -w "%{http_code}" -X POST http://portainer_portainer:9000/api/auth \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$user_portainer\",\"password\":\"$pass_portainer\"}" 2>/dev/null)
    if [ "$resp" != "200" ]; then
        echo -e "$(t coletar_so_painel_auth_falhou "$resp")"
        coletar_inputs_so_painel; return
    fi
    echo -e "$(t coletar_so_painel_cred_validas)"

    # 3) Usuário admin do painel
    echo -e "$(t coletar_so_painel_regras_usuario)"
    while true; do
        echo -ne "$(t coletar_so_painel_user_painel)" && read -r user_painel
        if type validar_usuario &> /dev/null; then
            validar_usuario "$user_painel" && break
        else
            [[ "$user_painel" =~ ^[a-z][a-z0-9_-]{3,39}$ ]] && [[ "${user_painel,,}" != "admin" ]] && break
            echo -e "$(t coletar_so_painel_usuario_invalido)"
        fi
    done

    # 4) Senha admin do painel
    while true; do
        echo -e "$(t coletar_so_painel_regras_senha)"
        echo -ne "$(t coletar_so_painel_pass_painel)" && read -rs pass_painel && echo ""
        if type validar_senha &> /dev/null; then
            validar_senha "$pass_painel" 12 && break
        elif [[ ${#pass_painel} -ge 12 ]] \
            && [[ "$pass_painel" =~ [A-Z] ]] \
            && [[ "$pass_painel" =~ [a-z] ]] \
            && [[ "$pass_painel" =~ [0-9] ]] \
            && [[ "$pass_painel" =~ [@_] ]]; then
            break
        else
            echo -e "$(t coletar_so_painel_senha_invalida)"
        fi
    done

    clear
    echo -e "$(t coletar_so_painel_confira)"
    echo -e "$(t coletar_so_painel_resumo_painel "$url_painel")"
    echo -e "$(t coletar_so_painel_resumo_rede "$nome_rede_interna")"
    echo -e "$(t coletar_so_painel_resumo_servico "$user_portainer")"
    echo -e "$(t coletar_so_painel_resumo_usuario "$user_painel")"
    echo ""
    while true; do
        echo -ne "$(t coletar_so_painel_confirma)" && read -r confirmacao
        case "$confirmacao" in
            [Yy]) break ;;
            [Nn]) coletar_inputs_so_painel; return ;;
            *)   echo -e "$(t coletar_so_painel_responda)" ;;
        esac
    done

    export url_painel nome_rede_interna
    export user_portainer pass_portainer user_painel pass_painel
    export ENCHA_NONINTERACTIVE=1
    export ENCHA_MAX_RETRIES=10
    export ENCHA_SLEEP=60
}

MSG_PT[coletar_instalacao_titulo]="${negrito}${roxo}📝 COLETA DE DADOS${reset}"
MSG_EN[coletar_instalacao_titulo]="${negrito}${roxo}📝 DATA COLLECTION${reset}"
MSG_ES[coletar_instalacao_titulo]="${negrito}${roxo}📝 RECOLECCIÓN DE DATOS${reset}"

MSG_PT[coletar_instalacao_pergunta_subdominio_portainer]="${ciano}1/7 Subdomínio do Portainer (ex: portainer.encha.ai): ${reset}"
MSG_EN[coletar_instalacao_pergunta_subdominio_portainer]="${ciano}1/7 Portainer subdomain (e.g.: portainer.encha.ai): ${reset}"
MSG_ES[coletar_instalacao_pergunta_subdominio_portainer]="${ciano}1/7 Subdominio de Portainer (ej: portainer.encha.ai): ${reset}"

MSG_PT[coletar_instalacao_dominio_invalido]="${vermelho}✖ Domínio inválido.${reset}"
MSG_EN[coletar_instalacao_dominio_invalido]="${vermelho}✖ Invalid domain.${reset}"
MSG_ES[coletar_instalacao_dominio_invalido]="${vermelho}✖ Dominio inválido.${reset}"

MSG_PT[coletar_instalacao_regras_usuario]="${amarelo}--> 4-40 caracteres, minúsculas/números/_/-, começando com letra. Evite \"admin\".${reset}"
MSG_EN[coletar_instalacao_regras_usuario]="${amarelo}--> 4-40 characters, lowercase/numbers/_/-, starting with a letter. Avoid \"admin\".${reset}"
MSG_ES[coletar_instalacao_regras_usuario]="${amarelo}--> 4-40 caracteres, minúsculas/números/_/-, empezando con letra. Evite \"admin\".${reset}"

MSG_PT[coletar_instalacao_user_portainer]="${ciano}2/7 Usuário do Portainer: ${reset}"
MSG_EN[coletar_instalacao_user_portainer]="${ciano}2/7 Portainer username: ${reset}"
MSG_ES[coletar_instalacao_user_portainer]="${ciano}2/7 Usuario de Portainer: ${reset}"

MSG_PT[coletar_instalacao_usuario_invalido]="${vermelho}✖ Usuário inválido.${reset}"
MSG_EN[coletar_instalacao_usuario_invalido]="${vermelho}✖ Invalid username.${reset}"
MSG_ES[coletar_instalacao_usuario_invalido]="${vermelho}✖ Usuario inválido.${reset}"

MSG_PT[coletar_instalacao_regras_senha]="${amarelo}--> Mínimo 12 caracteres com MAIÚSCULAS, minúsculas, números e @ ou _${reset}"
MSG_EN[coletar_instalacao_regras_senha]="${amarelo}--> Minimum 12 characters with UPPERCASE, lowercase, numbers and @ or _${reset}"
MSG_ES[coletar_instalacao_regras_senha]="${amarelo}--> Mínimo 12 caracteres con MAYÚSCULAS, minúsculas, números y @ o _${reset}"

MSG_PT[coletar_instalacao_pass_portainer]="${ciano}3/7 Senha do Portainer: ${reset}"
MSG_EN[coletar_instalacao_pass_portainer]="${ciano}3/7 Portainer password: ${reset}"
MSG_ES[coletar_instalacao_pass_portainer]="${ciano}3/7 Contraseña de Portainer: ${reset}"

MSG_PT[coletar_instalacao_senha_invalida]="${vermelho}✖ Senha não atende aos requisitos.${reset}"
MSG_EN[coletar_instalacao_senha_invalida]="${vermelho}✖ Password does not meet the requirements.${reset}"
MSG_ES[coletar_instalacao_senha_invalida]="${vermelho}✖ La contraseña no cumple los requisitos.${reset}"

MSG_PT[coletar_instalacao_email_ssl]="${ciano}4/7 Email para certificados SSL: ${reset}"
MSG_EN[coletar_instalacao_email_ssl]="${ciano}4/7 Email for SSL certificates: ${reset}"
MSG_ES[coletar_instalacao_email_ssl]="${ciano}4/7 Correo para certificados SSL: ${reset}"

MSG_PT[coletar_instalacao_email_invalido]="${vermelho}✖ Email inválido.${reset}"
MSG_EN[coletar_instalacao_email_invalido]="${vermelho}✖ Invalid email.${reset}"
MSG_ES[coletar_instalacao_email_invalido]="${vermelho}✖ Correo inválido.${reset}"

MSG_PT[coletar_instalacao_pergunta_subdominio_painel]="${ciano}5/7 Subdomínio do Encha Setup Panel (ex: painel.encha.ai): ${reset}"
MSG_EN[coletar_instalacao_pergunta_subdominio_painel]="${ciano}5/7 Encha Setup Panel subdomain (e.g.: panel.encha.ai): ${reset}"
MSG_ES[coletar_instalacao_pergunta_subdominio_painel]="${ciano}5/7 Subdominio del Encha Setup Panel (ej: panel.encha.ai): ${reset}"

MSG_PT[coletar_instalacao_mesmas_regras]="${amarelo}--> Mesmas regras do usuário do Portainer.${reset}"
MSG_EN[coletar_instalacao_mesmas_regras]="${amarelo}--> Same rules as the Portainer username.${reset}"
MSG_ES[coletar_instalacao_mesmas_regras]="${amarelo}--> Mismas reglas del usuario de Portainer.${reset}"

MSG_PT[coletar_instalacao_user_painel]="${ciano}6/7 Usuário admin do Painel: ${reset}"
MSG_EN[coletar_instalacao_user_painel]="${ciano}6/7 Panel admin username: ${reset}"
MSG_ES[coletar_instalacao_user_painel]="${ciano}6/7 Usuario admin del Panel: ${reset}"

MSG_PT[coletar_instalacao_pass_painel]="${ciano}7/7 Senha admin do Painel: ${reset}"
MSG_EN[coletar_instalacao_pass_painel]="${ciano}7/7 Panel admin password: ${reset}"
MSG_ES[coletar_instalacao_pass_painel]="${ciano}7/7 Contraseña admin del Panel: ${reset}"

MSG_PT[coletar_instalacao_confira]="${roxo}${negrito}🔍 CONFIRA OS DADOS:${reset}"
MSG_EN[coletar_instalacao_confira]="${roxo}${negrito}🔍 REVIEW THE DATA:${reset}"
MSG_ES[coletar_instalacao_confira]="${roxo}${negrito}🔍 REVISE LOS DATOS:${reset}"

MSG_PT[coletar_instalacao_resumo_portainer]="  ${azul}Portainer:${reset}       https://${verde}%s${reset}"
MSG_EN[coletar_instalacao_resumo_portainer]="  ${azul}Portainer:${reset}       https://${verde}%s${reset}"
MSG_ES[coletar_instalacao_resumo_portainer]="  ${azul}Portainer:${reset}       https://${verde}%s${reset}"

MSG_PT[coletar_instalacao_resumo_user_portainer]="  ${azul}Usuário Portainer:${reset} ${verde}%s${reset}"
MSG_EN[coletar_instalacao_resumo_user_portainer]="  ${azul}Portainer user:${reset}   ${verde}%s${reset}"
MSG_ES[coletar_instalacao_resumo_user_portainer]="  ${azul}Usuario Portainer:${reset} ${verde}%s${reset}"

MSG_PT[coletar_instalacao_resumo_email]="  ${azul}Email SSL:${reset}       ${verde}%s${reset}"
MSG_EN[coletar_instalacao_resumo_email]="  ${azul}SSL Email:${reset}       ${verde}%s${reset}"
MSG_ES[coletar_instalacao_resumo_email]="  ${azul}Correo SSL:${reset}      ${verde}%s${reset}"

MSG_PT[coletar_instalacao_resumo_painel]="  ${azul}Painel:${reset}          https://${verde}%s${reset}"
MSG_EN[coletar_instalacao_resumo_painel]="  ${azul}Panel:${reset}           https://${verde}%s${reset}"
MSG_ES[coletar_instalacao_resumo_painel]="  ${azul}Panel:${reset}           https://${verde}%s${reset}"

MSG_PT[coletar_instalacao_resumo_user_painel]="  ${azul}Usuário Painel:${reset}   ${verde}%s${reset}"
MSG_EN[coletar_instalacao_resumo_user_painel]="  ${azul}Panel user:${reset}      ${verde}%s${reset}"
MSG_ES[coletar_instalacao_resumo_user_painel]="  ${azul}Usuario Panel:${reset}   ${verde}%s${reset}"

MSG_PT[coletar_instalacao_confirma]="${verde}✅ Confirma? (Y/N): ${reset}"
MSG_EN[coletar_instalacao_confirma]="${verde}✅ Confirm? (Y/N): ${reset}"
MSG_ES[coletar_instalacao_confirma]="${verde}✅ ¿Confirma? (Y/N): ${reset}"

MSG_PT[coletar_instalacao_responda]="${amarelo}Responda Y ou N.${reset}"
MSG_EN[coletar_instalacao_responda]="${amarelo}Answer Y or N.${reset}"
MSG_ES[coletar_instalacao_responda]="${amarelo}Responda Y o N.${reset}"

coletar_inputs_instalacao() {
    clear
    echo -e "$(t coletar_instalacao_titulo)"
    echo ""

    # 1) Subdomínio Portainer
    while true; do
        echo -ne "$(t coletar_instalacao_pergunta_subdominio_portainer)" && read -r url_portainer
        [[ "$url_portainer" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] && break
        echo -e "$(t coletar_instalacao_dominio_invalido)"
    done

    # 2) Usuário do Portainer — sem default: "admin" deixa metade da
    #    credencial pública. O usuário digitado é aplicado por renomeação
    #    logo após o bootstrap (ver ferramenta_traefik_e_portainer).
    echo -e "$(t coletar_instalacao_regras_usuario)"
    while true; do
        echo -ne "$(t coletar_instalacao_user_portainer)" && read -r user_portainer
        if type validar_usuario &> /dev/null; then
            validar_usuario "$user_portainer" && break
        else
            [[ "$user_portainer" =~ ^[a-z][a-z0-9_-]{3,39}$ ]] && [[ "${user_portainer,,}" != "admin" ]] && break
            echo -e "$(t coletar_instalacao_usuario_invalido)"
        fi
    done

    # 3) Senha Portainer (12+ chars, maiús, minús, dígito, especial)
    while true; do
        echo -e "$(t coletar_instalacao_regras_senha)"
        echo -ne "$(t coletar_instalacao_pass_portainer)" && read -rs pass_portainer && echo ""
        if type validar_senha &> /dev/null; then
            validar_senha "$pass_portainer" 12 && break
        elif [[ ${#pass_portainer} -ge 12 ]] \
            && [[ "$pass_portainer" =~ [A-Z] ]] \
            && [[ "$pass_portainer" =~ [a-z] ]] \
            && [[ "$pass_portainer" =~ [0-9] ]] \
            && [[ "$pass_portainer" =~ [@_] ]]; then
            break
        else
            echo -e "$(t coletar_instalacao_senha_invalida)"
        fi
    done

    # 4) Email SSL
    while true; do
        echo -ne "$(t coletar_instalacao_email_ssl)" && read -r email_ssl
        [[ "$email_ssl" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
        echo -e "$(t coletar_instalacao_email_invalido)"
    done

    # 5) Subdomínio do Painel
    while true; do
        echo -ne "$(t coletar_instalacao_pergunta_subdominio_painel)" && read -r url_painel
        [[ "$url_painel" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] && break
        echo -e "$(t coletar_instalacao_dominio_invalido)"
    done

    # 6) Usuário admin do painel — identidade separada da do Portainer (pode
    #    repetir o mesmo usuário, se o operador preferir).
    echo -e "$(t coletar_instalacao_mesmas_regras)"
    while true; do
        echo -ne "$(t coletar_instalacao_user_painel)" && read -r user_painel
        if type validar_usuario &> /dev/null; then
            validar_usuario "$user_painel" && break
        else
            [[ "$user_painel" =~ ^[a-z][a-z0-9_-]{3,39}$ ]] && [[ "${user_painel,,}" != "admin" ]] && break
            echo -e "$(t coletar_instalacao_usuario_invalido)"
        fi
    done

    # 7) Senha admin do painel
    while true; do
        echo -e "$(t coletar_instalacao_regras_senha)"
        echo -ne "$(t coletar_instalacao_pass_painel)" && read -rs pass_painel && echo ""
        if type validar_senha &> /dev/null; then
            validar_senha "$pass_painel" 12 && break
        elif [[ ${#pass_painel} -ge 12 ]] \
            && [[ "$pass_painel" =~ [A-Z] ]] \
            && [[ "$pass_painel" =~ [a-z] ]] \
            && [[ "$pass_painel" =~ [0-9] ]] \
            && [[ "$pass_painel" =~ [@_] ]]; then
            break
        else
            echo -e "$(t coletar_instalacao_senha_invalida)"
        fi
    done

    # Defaults fixos (combinam com docker-stack.yaml do painel)
    nome_servidor="encha"
    nome_rede_interna="enchanet"

    # Confirmação — nunca exibir as senhas.
    clear
    echo -e "$(t coletar_instalacao_confira)"
    echo -e "$(t coletar_instalacao_resumo_portainer "$url_portainer")"
    echo -e "$(t coletar_instalacao_resumo_user_portainer "$user_portainer")"
    echo -e "$(t coletar_instalacao_resumo_email "$email_ssl")"
    echo -e "$(t coletar_instalacao_resumo_painel "$url_painel")"
    echo -e "$(t coletar_instalacao_resumo_user_painel "$user_painel")"
    echo ""
    while true; do
        echo -ne "$(t coletar_instalacao_confirma)" && read -r confirmacao
        case "$confirmacao" in
            [Yy]) break ;;
            [Nn]) coletar_inputs_instalacao; return ;;
            *)   echo -e "$(t coletar_instalacao_responda)" ;;
        esac
    done

    export url_portainer user_portainer pass_portainer email_ssl url_painel
    export user_painel pass_painel
    export nome_servidor nome_rede_interna
    export ENCHA_NONINTERACTIVE=1
    export ENCHA_MAX_RETRIES=10
    export ENCHA_SLEEP=60
}

MSG_PT[download_secondary_titulo]="📥 BAIXANDO SCRIPT DE INSTALAÇÃO"
MSG_EN[download_secondary_titulo]="📥 DOWNLOADING INSTALLATION SCRIPT"
MSG_ES[download_secondary_titulo]="📥 DESCARGANDO SCRIPT DE INSTALACIÓN"

MSG_PT[download_secondary_baixando]="Baixando secondary.sh da fonte oficial (branch %s)..."
MSG_EN[download_secondary_baixando]="Downloading secondary.sh from the official source (branch %s)..."
MSG_ES[download_secondary_baixando]="Descargando secondary.sh de la fuente oficial (branch %s)..."

MSG_PT[download_secondary_ok]="Script baixado com sucesso"
MSG_EN[download_secondary_ok]="Script downloaded successfully"
MSG_ES[download_secondary_ok]="Script descargado con éxito"

MSG_PT[download_secondary_falha]="Falha no download. Verifique a conexão."
MSG_EN[download_secondary_falha]="Download failed. Check your connection."
MSG_ES[download_secondary_falha]="Fallo en la descarga. Verifique la conexión."

download_secondary() {
    echo ""
    barra_meio
    echo -e "${roxo}${negrito}$(t download_secondary_titulo)${reset}"
    barra_meio

    [ -f SetupEnchaAI ] && rm -f SetupEnchaAI

    status_info "$(t download_secondary_baixando "$ENCHA_SRC_BRANCH")"
    if curl -fsSL --retry 3 --connect-timeout 10 \
        "https://raw.githubusercontent.com/enchaaluno/setupteste/${ENCHA_SRC_BRANCH}/secondary.sh" \
        -o SetupEnchaAI; then
        chmod +x SetupEnchaAI
        status_ok "$(t download_secondary_ok)"
    else
        status_fail "$(t download_secondary_falha)"
        exit 1
    fi
}

MSG_PT[preparar_fonte_titulo]="📦 PREPARANDO FONTE DO PAINEL"
MSG_EN[preparar_fonte_titulo]="📦 PREPARING PANEL SOURCE"
MSG_ES[preparar_fonte_titulo]="📦 PREPARANDO FUENTE DEL PANEL"

MSG_PT[preparar_fonte_git]="Garantindo git..."
MSG_EN[preparar_fonte_git]="Ensuring git is present..."
MSG_ES[preparar_fonte_git]="Asegurando git..."

MSG_PT[preparar_fonte_atualizado]="Repositório atualizado (fetch --depth 1 + reset)."
MSG_EN[preparar_fonte_atualizado]="Repository updated (fetch --depth 1 + reset)."
MSG_ES[preparar_fonte_atualizado]="Repositorio actualizado (fetch --depth 1 + reset)."

MSG_PT[preparar_fonte_clonando]="Clonando enchaaluno/setupteste (branch %s)..."
MSG_EN[preparar_fonte_clonando]="Cloning enchaaluno/setupteste (branch %s)..."
MSG_ES[preparar_fonte_clonando]="Clonando enchaaluno/setupteste (branch %s)..."

MSG_PT[preparar_fonte_falha_clone]="Falha no git clone"
MSG_EN[preparar_fonte_falha_clone]="git clone failed"
MSG_ES[preparar_fonte_falha_clone]="Fallo en git clone"

MSG_PT[preparar_fonte_dir_nao_encontrado]="Diretório encha-setup-panel não encontrado no repositório."
MSG_EN[preparar_fonte_dir_nao_encontrado]="The encha-setup-panel directory was not found in the repository."
MSG_ES[preparar_fonte_dir_nao_encontrado]="No se encontró el directorio encha-setup-panel en el repositorio."

MSG_PT[preparar_fonte_pronta]="Fonte do painel pronta em /root/encha-setup-panel"
MSG_EN[preparar_fonte_pronta]="Panel source ready at /root/encha-setup-panel"
MSG_ES[preparar_fonte_pronta]="Fuente del panel lista en /root/encha-setup-panel"

preparar_fonte_painel() {
    echo ""
    barra_meio
    echo -e "${roxo}${negrito}$(t preparar_fonte_titulo)${reset}"
    barra_meio

    status_info "$(t preparar_fonte_git)"
    DEBIAN_FRONTEND=noninteractive apt-get install -y git >/dev/null 2>&1

    # Tenta atualizar in-place com fetch --depth 1 + reset FETCH_HEAD (robusto a
    # reescrita de histórico: não depende de ancestral comum nem de origin/main).
    # Se qualquer passo falhar, cai no re-clone fresco abaixo.
    if [[ -d /root/encha-setup-panel/.git ]] \
        && git -C /root/encha-setup-panel fetch --depth 1 origin "$ENCHA_SRC_BRANCH" >/dev/null 2>&1 \
        && git -C /root/encha-setup-panel reset --hard FETCH_HEAD >/dev/null 2>&1; then
        status_info "$(t preparar_fonte_atualizado)"
    else
        status_info "$(t preparar_fonte_clonando "$ENCHA_SRC_BRANCH")"
        rm -rf /root/encha-setup-panel /tmp/_setupteste_clone
        git clone --depth 1 --branch "$ENCHA_SRC_BRANCH" \
            https://github.com/enchaaluno/setupteste.git \
            /tmp/_setupteste_clone >/dev/null 2>&1 \
            || { status_fail "$(t preparar_fonte_falha_clone)"; exit 1; }
        if [[ ! -d /tmp/_setupteste_clone/encha-setup-panel ]]; then
            status_fail "$(t preparar_fonte_dir_nao_encontrado)"
            exit 1
        fi
        mv /tmp/_setupteste_clone/encha-setup-panel /root/encha-setup-panel
        rm -rf /tmp/_setupteste_clone
    fi
    status_ok "$(t preparar_fonte_pronta)"
}

MSG_PT[mostrar_resumo_titulo]="║                  🎉 INSTALAÇÃO CONCLUÍDA! 🎉                    ║"
MSG_EN[mostrar_resumo_titulo]="║                 🎉 INSTALLATION COMPLETE! 🎉                    ║"
MSG_ES[mostrar_resumo_titulo]="║                🎉 ¡INSTALACIÓN COMPLETADA! 🎉                   ║"

MSG_PT[mostrar_resumo_acesse]="${ciano}${negrito}Acesse seus serviços:${reset}"
MSG_EN[mostrar_resumo_acesse]="${ciano}${negrito}Access your services:${reset}"
MSG_ES[mostrar_resumo_acesse]="${ciano}${negrito}Acceda a sus servicios:${reset}"

MSG_PT[mostrar_resumo_portainer]="  ${verde}▸ Portainer:${reset}  https://${negrito}%s${reset}"
MSG_EN[mostrar_resumo_portainer]="  ${verde}▸ Portainer:${reset}  https://${negrito}%s${reset}"
MSG_ES[mostrar_resumo_portainer]="  ${verde}▸ Portainer:${reset}  https://${negrito}%s${reset}"

MSG_PT[mostrar_resumo_usuario]="    ${cinza}usuário: %s${reset}"
MSG_EN[mostrar_resumo_usuario]="    ${cinza}user: %s${reset}"
MSG_ES[mostrar_resumo_usuario]="    ${cinza}usuario: %s${reset}"

MSG_PT[mostrar_resumo_painel]="  ${verde}▸ Painel Encha:${reset} https://${negrito}%s${reset}"
MSG_EN[mostrar_resumo_painel]="  ${verde}▸ Encha Panel:${reset} https://${negrito}%s${reset}"
MSG_ES[mostrar_resumo_painel]="  ${verde}▸ Panel Encha:${reset} https://${negrito}%s${reset}"

MSG_PT[mostrar_resumo_pronto]="${amarelo}💡 O Encha Setup Panel já está pronto para instalar as demais stacks.${reset}"
MSG_EN[mostrar_resumo_pronto]="${amarelo}💡 Encha Setup Panel is now ready to install the other stacks.${reset}"
MSG_ES[mostrar_resumo_pronto]="${amarelo}💡 El Encha Setup Panel ya está listo para instalar los demás stacks.${reset}"

MSG_PT[mostrar_resumo_esqueceu_senha]="${ciano}${negrito}Esqueceu a senha do painel?${reset}"
MSG_EN[mostrar_resumo_esqueceu_senha]="${ciano}${negrito}Forgot the panel password?${reset}"
MSG_ES[mostrar_resumo_esqueceu_senha]="${ciano}${negrito}¿Olvidó la contraseña del panel?${reset}"

MSG_PT[mostrar_resumo_passo1]="  ${cinza}Portainer → Stacks → encha-panel → Environment variables →${reset}"
MSG_EN[mostrar_resumo_passo1]="  ${cinza}Portainer → Stacks → encha-panel → Environment variables →${reset}"
MSG_ES[mostrar_resumo_passo1]="  ${cinza}Portainer → Stacks → encha-panel → Environment variables →${reset}"

MSG_PT[mostrar_resumo_passo2]="  ${cinza}PANEL_ADMIN_PASSWORD → editar → Update the stack.${reset}"
MSG_EN[mostrar_resumo_passo2]="  ${cinza}PANEL_ADMIN_PASSWORD → edit → Update the stack.${reset}"
MSG_ES[mostrar_resumo_passo2]="  ${cinza}PANEL_ADMIN_PASSWORD → editar → Update the stack.${reset}"

MSG_PT[mostrar_resumo_passo3]="  ${cinza}Depois, rode a opção 97 (Atualizar o painel) para voltar a guardar como segredo.${reset}"
MSG_EN[mostrar_resumo_passo3]="  ${cinza}Afterwards, run option 97 (Update panel) to go back to storing it as a secret.${reset}"
MSG_ES[mostrar_resumo_passo3]="  ${cinza}Después, ejecute la opción 97 (Actualizar panel) para volver a guardarla como secret.${reset}"

MSG_PT[mostrar_resumo_suporte]="${ciano}${negrito}Suporte:${reset}"
MSG_EN[mostrar_resumo_suporte]="${ciano}${negrito}Support:${reset}"
MSG_ES[mostrar_resumo_suporte]="${ciano}${negrito}Soporte:${reset}"

# C10 (achado A2 do plano de segurança): avisos de segurança do SSH no
# resumo final. O primeiro só aparece se instalar_protecao_ssh (chamada
# antes desta função) tiver falhado — nunca se PROTECAO_SSH_OK=1. O comando
# citado é IDÊNTICO a COMANDO_PROTEGER_SSH em
# encha-setup-panel/src/components/ssh-protection-warning.tsx (o aviso
# equivalente do painel, achado C8) — não mude um lado sem o outro. Os
# outros dois (senha/root) são independentes do fail2ban e checam
# `sshd -T` de novo aqui, porque a decisão de desabilitar é sempre manual
# (nunca automatizada — ver o comentário de instalar_protecao_ssh).
# O passo a passo grava num drop-in 00-encha.conf, nunca "edite o
# sshd_config" (auditoria C10): o sshd_config do Debian 13 faz Include de
# sshd_config.d/*.conf no topo e o sshd usa o PRIMEIRO valor lido — na VPS
# de teste o sshd_config já dizia "PasswordAuthentication no" e o
# 50-cloud-init.conf da imagem ligava a senha mesmo assim. O "00-" vence o
# "50-", e o `sshd -t` antes do restart evita derrubar o SSH por typo.
MSG_PT[mostrar_resumo_fail2ban_titulo]="${amarelo}${negrito}⚠ Proteção do SSH:${reset}"
MSG_EN[mostrar_resumo_fail2ban_titulo]="${amarelo}${negrito}⚠ SSH protection:${reset}"
MSG_ES[mostrar_resumo_fail2ban_titulo]="${amarelo}${negrito}⚠ Protección del SSH:${reset}"

MSG_PT[mostrar_resumo_fail2ban_aviso]="  ${amarelo}O fail2ban não pôde ser instalado automaticamente. O guarda do Swarm continua limitando novas conexões, mas para o banimento prolongado rode depois:${reset}"
MSG_EN[mostrar_resumo_fail2ban_aviso]="  ${amarelo}fail2ban could not be installed automatically. The Swarm guard keeps limiting new connections, but for extended banning run this later:${reset}"
MSG_ES[mostrar_resumo_fail2ban_aviso]="  ${amarelo}fail2ban no pudo instalarse automáticamente. El guarda del Swarm sigue limitando conexiones nuevas, pero para el bloqueo prolongado ejecute esto después:${reset}"

MSG_PT[mostrar_resumo_fail2ban_comando]="  ${cinza}bash /root/SetupEnchaAI proteger-ssh${reset}"
MSG_EN[mostrar_resumo_fail2ban_comando]="  ${cinza}bash /root/SetupEnchaAI proteger-ssh${reset}"
MSG_ES[mostrar_resumo_fail2ban_comando]="  ${cinza}bash /root/SetupEnchaAI proteger-ssh${reset}"

MSG_PT[mostrar_resumo_ssh_senha_aviso]="  ${amarelo}O SSH ainda aceita login por senha. Recomendado (só depois de confirmar que sua chave SSH funciona): echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config.d/00-encha.conf && sshd -t && systemctl restart ssh — editar só o /etc/ssh/sshd_config não basta quando outro arquivo de sshd_config.d/ (ex.: 50-cloud-init.conf) liga a senha.${reset}"
MSG_EN[mostrar_resumo_ssh_senha_aviso]="  ${amarelo}SSH still accepts password login. Recommended (only after confirming your SSH key works): echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config.d/00-encha.conf && sshd -t && systemctl restart ssh — editing only /etc/ssh/sshd_config is not enough when another file in sshd_config.d/ (e.g. 50-cloud-init.conf) turns passwords on.${reset}"
MSG_ES[mostrar_resumo_ssh_senha_aviso]="  ${amarelo}El SSH todavía acepta login por contraseña. Recomendado (solo después de confirmar que su clave SSH funciona): echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config.d/00-encha.conf && sshd -t && systemctl restart ssh — editar solo /etc/ssh/sshd_config no basta cuando otro archivo de sshd_config.d/ (ej.: 50-cloud-init.conf) activa la contraseña.${reset}"

MSG_PT[mostrar_resumo_ssh_root_aviso]="  ${amarelo}O SSH ainda aceita login como root por senha. Recomendado (só depois de confirmar que sua chave SSH funciona; o root continua entrando por chave): echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config.d/00-encha.conf && sshd -t && systemctl restart ssh${reset}"
MSG_EN[mostrar_resumo_ssh_root_aviso]="  ${amarelo}SSH still accepts root login by password. Recommended (only after confirming your SSH key works; root keeps logging in by key): echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config.d/00-encha.conf && sshd -t && systemctl restart ssh${reset}"
MSG_ES[mostrar_resumo_ssh_root_aviso]="  ${amarelo}El SSH todavía acepta login como root por contraseña. Recomendado (solo después de confirmar que su clave SSH funciona; root sigue entrando por clave): echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config.d/00-encha.conf && sshd -t && systemctl restart ssh${reset}"

mostrar_resumo_final() {
    clear
    echo -e "${negrito}${verde}"
    centralizar "╔══════════════════════════════════════════════════════════════════╗"
    centralizar "║                                                                  ║"
    centralizar "$(t mostrar_resumo_titulo)"
    centralizar "║                                                                  ║"
    centralizar "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${reset}"
    echo ""
    echo -e "$(t mostrar_resumo_acesse)"
    echo -e "$(t mostrar_resumo_portainer "$url_portainer")"
    echo -e "$(t mostrar_resumo_usuario "$user_portainer")"
    echo -e "$(t mostrar_resumo_painel "$url_painel")"
    echo -e "$(t mostrar_resumo_usuario "$user_painel")"
    echo ""
    echo -e "$(t mostrar_resumo_pronto)"
    echo ""
    echo -e "$(t mostrar_resumo_esqueceu_senha)"
    echo -e "$(t mostrar_resumo_passo1)"
    echo -e "$(t mostrar_resumo_passo2)"
    echo -e "$(t mostrar_resumo_passo3)"

    # C10 (achado A2): avisos de segurança do SSH — só aparecem quando há
    # algo pendente (nenhum aqui significa nenhuma linha extra no resumo).
    local avisos_ssh=0
    if [ "${PROTECAO_SSH_OK:-0}" != "1" ]; then
        echo ""
        echo -e "$(t mostrar_resumo_fail2ban_titulo)"
        echo -e "$(t mostrar_resumo_fail2ban_aviso)"
        echo -e "$(t mostrar_resumo_fail2ban_comando)"
        avisos_ssh=1
    fi
    if sshd -T 2>/dev/null | grep -qi '^passwordauthentication yes'; then
        [ "$avisos_ssh" -eq 0 ] && echo "" && echo -e "$(t mostrar_resumo_fail2ban_titulo)"
        echo -e "$(t mostrar_resumo_ssh_senha_aviso)"
        avisos_ssh=1
    fi
    if sshd -T 2>/dev/null | grep -qi '^permitrootlogin yes'; then
        [ "$avisos_ssh" -eq 0 ] && echo "" && echo -e "$(t mostrar_resumo_fail2ban_titulo)"
        echo -e "$(t mostrar_resumo_ssh_root_aviso)"
        avisos_ssh=1
    fi

    echo ""
    echo -e "$(t mostrar_resumo_suporte)"
    echo -e "  ${azul}📧 atendimento@encha.ai${reset}"
    echo -e "  ${azul}🌐 https://encha.ai${reset}"
    echo -e "  ${azul}📱 WhatsApp: +55 61 99159-2205${reset}"
    echo ""
}

MSG_PT[execucao_carregando_funcoes]="Carregando funções do instalador..."
MSG_EN[execucao_carregando_funcoes]="Loading installer functions..."
MSG_ES[execucao_carregando_funcoes]="Cargando funciones del instalador..."

MSG_PT[execucao_funcoes_carregadas]="Funções carregadas (modo biblioteca)"
MSG_EN[execucao_funcoes_carregadas]="Functions loaded (library mode)"
MSG_ES[execucao_funcoes_carregadas]="Funciones cargadas (modo biblioteca)"

MSG_PT[execucao_infra_detectada_titulo]="${negrito}${roxo}🔎 INFRAESTRUTURA DETECTADA${reset}"
MSG_EN[execucao_infra_detectada_titulo]="${negrito}${roxo}🔎 INFRASTRUCTURE DETECTED${reset}"
MSG_ES[execucao_infra_detectada_titulo]="${negrito}${roxo}🔎 INFRAESTRUCTURA DETECTADA${reset}"

MSG_PT[execucao_infra_ja_instalada]="${verde}✓ Traefik + Portainer já estão instalados nesta VPS.${reset}"
MSG_EN[execucao_infra_ja_instalada]="${verde}✓ Traefik + Portainer are already installed on this VPS.${reset}"
MSG_ES[execucao_infra_ja_instalada]="${verde}✓ Traefik + Portainer ya están instalados en esta VPS.${reset}"

MSG_PT[execucao_rede_detectada]="  ${azul}Rede interna detectada:${reset} ${verde}%s${reset}"
MSG_EN[execucao_rede_detectada]="  ${azul}Detected internal network:${reset} ${verde}%s${reset}"
MSG_ES[execucao_rede_detectada]="  ${azul}Red interna detectada:${reset} ${verde}%s${reset}"

MSG_PT[execucao_o_que_deseja]="${ciano}O que você deseja fazer?${reset}"
MSG_EN[execucao_o_que_deseja]="${ciano}What would you like to do?${reset}"
MSG_ES[execucao_o_que_deseja]="${ciano}¿Qué desea hacer?${reset}"

MSG_PT[execucao_opcao_so_painel]="  ${verde}1.${reset} Instalar ${negrito}APENAS o Encha Setup Panel${reset} ${cinza}(recomendado — não mexe no resto)${reset}"
MSG_EN[execucao_opcao_so_painel]="  ${verde}1.${reset} Install ${negrito}ONLY the Encha Setup Panel${reset} ${cinza}(recommended — leaves the rest untouched)${reset}"
MSG_ES[execucao_opcao_so_painel]="  ${verde}1.${reset} Instalar ${negrito}SOLO el Encha Setup Panel${reset} ${cinza}(recomendado — no toca el resto)${reset}"

MSG_PT[execucao_opcao_reinstalar]="  ${verde}2.${reset} Reinstalar tudo ${cinza}(Docker + Traefik + Portainer + Painel)${reset}"
MSG_EN[execucao_opcao_reinstalar]="  ${verde}2.${reset} Reinstall everything ${cinza}(Docker + Traefik + Portainer + Panel)${reset}"
MSG_ES[execucao_opcao_reinstalar]="  ${verde}2.${reset} Reinstalar todo ${cinza}(Docker + Traefik + Portainer + Panel)${reset}"

MSG_PT[execucao_escolha_1_2]="${ciano}Escolha (1/2): ${reset}"
MSG_EN[execucao_escolha_1_2]="${ciano}Choose (1/2): ${reset}"
MSG_ES[execucao_escolha_1_2]="${ciano}Elija (1/2): ${reset}"

MSG_PT[execucao_responda_1_2]="${amarelo}Responda 1 ou 2.${reset}"
MSG_EN[execucao_responda_1_2]="${amarelo}Answer 1 or 2.${reset}"
MSG_ES[execucao_responda_1_2]="${amarelo}Responda 1 o 2.${reset}"

MSG_PT[execucao_instalando_traefik]="🐳 INSTALANDO TRAEFIK + PORTAINER"
MSG_EN[execucao_instalando_traefik]="🐳 INSTALLING TRAEFIK + PORTAINER"
MSG_ES[execucao_instalando_traefik]="🐳 INSTALANDO TRAEFIK + PORTAINER"

MSG_PT[execucao_falha_traefik]="Falha ao instalar Traefik/Portainer (Docker ausente ou stack não subiu). Verifique 'docker service ls' e 'journalctl -u docker'."
MSG_EN[execucao_falha_traefik]="Failed to install Traefik/Portainer (Docker missing or stack did not come up). Check 'docker service ls' and 'journalctl -u docker'."
MSG_ES[execucao_falha_traefik]="Fallo al instalar Traefik/Portainer (Docker ausente o el stack no arrancó). Verifique 'docker service ls' y 'journalctl -u docker'."

MSG_PT[execucao_reaproveitando]="Reaproveitando Traefik+Portainer existentes (rede: %s)."
MSG_EN[execucao_reaproveitando]="Reusing existing Traefik+Portainer (network: %s)."
MSG_ES[execucao_reaproveitando]="Reutilizando Traefik+Portainer existentes (red: %s)."

MSG_PT[execucao_instalando_painel]="📦 INSTALANDO ENCHA SETUP PANEL"
MSG_EN[execucao_instalando_painel]="📦 INSTALLING ENCHA SETUP PANEL"
MSG_ES[execucao_instalando_painel]="📦 INSTALANDO ENCHA SETUP PANEL"

MSG_PT[execucao_falha_painel]="Falha ao instalar o painel. Verifique 'docker service ls' e 'docker stack ps encha-panel'."
MSG_EN[execucao_falha_painel]="Failed to install the panel. Check 'docker service ls' and 'docker stack ps encha-panel'."
MSG_ES[execucao_falha_painel]="Fallo al instalar el panel. Verifique 'docker service ls' y 'docker stack ps encha-panel'."

# C10 (achado A2 do plano de segurança): fail2ban de verdade pro SSH,
# instalado automaticamente em toda instalação NOVA (os dois caminhos acima
# — infra completa e só painel — convergem aqui antes do resumo final). Ver
# instalar_protecao_ssh em secondary.sh para o contrato completo; falha aqui
# NUNCA aborta a instalação (é uma camada a mais sobre o guarda automático
# do Swarm, A1/C4-C7) — só avisa no resumo final com o comando manual.
MSG_PT[execucao_protegendo_ssh]="🛡️ PROTEGENDO O SSH (fail2ban)"
MSG_EN[execucao_protegendo_ssh]="🛡️ PROTECTING SSH (fail2ban)"
MSG_ES[execucao_protegendo_ssh]="🛡️ PROTEGIENDO EL SSH (fail2ban)"

# ───────── EXECUÇÃO ─────────

banner_instalacao_completa

# Baixa e carrega o secondary.sh ANTES de coletar dados, para ter os helpers do
# instalador disponíveis e poder decidir o fluxo (instalar tudo x só painel).
download_secondary

status_info "$(t execucao_carregando_funcoes)"
# shellcheck source=/dev/null
source ./SetupEnchaAI
status_ok "$(t execucao_funcoes_carregadas)"

# Por padrão instala Traefik+Portainer. Se já existirem, pergunta ao usuário.
INSTALAR_INFRA=1

if infra_ja_instalada; then
    rede_detectada="$(descobrir_rede_painel)" || rede_detectada=""
    nome_rede_interna="${rede_detectada:-enchanet}"
    nome_servidor="encha"

    clear
    echo -e "$(t execucao_infra_detectada_titulo)"
    echo ""
    echo -e "$(t execucao_infra_ja_instalada)"
    echo -e "$(t execucao_rede_detectada "$nome_rede_interna")"
    echo ""
    echo -e "$(t execucao_o_que_deseja)"
    echo -e "$(t execucao_opcao_so_painel)"
    echo -e "$(t execucao_opcao_reinstalar)"
    echo ""
    while true; do
        echo -ne "$(t execucao_escolha_1_2)" && read -r escolha_infra
        case "$escolha_infra" in
            1) INSTALAR_INFRA=0; break ;;
            2) INSTALAR_INFRA=1; break ;;
            *) echo -e "$(t execucao_responda_1_2)" ;;
        esac
    done
fi

if [ "$INSTALAR_INFRA" -eq 1 ]; then
    coletar_inputs_instalacao
    checar_dns_e_portas
    echo ""
    barra_meio
    echo -e "${roxo}${negrito}$(t execucao_instalando_traefik)${reset}"
    barra_meio
    if ! ferramenta_traefik_e_portainer; then
        status_fail "$(t execucao_falha_traefik)"
        exit 1
    fi
else
    coletar_inputs_so_painel
    status_info "$(t execucao_reaproveitando "$nome_rede_interna")"
fi

preparar_fonte_painel

echo ""
barra_meio
echo -e "${roxo}${negrito}$(t execucao_instalando_painel)${reset}"
barra_meio
if ! ferramenta_encha_panel; then
    status_fail "$(t execucao_falha_painel)"
    exit 1
fi

echo ""
barra_meio
echo -e "${roxo}${negrito}$(t execucao_protegendo_ssh)${reset}"
barra_meio
if instalar_protecao_ssh; then
    PROTECAO_SSH_OK=1
else
    PROTECAO_SSH_OK=0
fi

mostrar_resumo_final
echo ""
