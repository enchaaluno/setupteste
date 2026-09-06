#!/bin/bash

# Versão do Encha Setup. Mantenha em sincronia com encha-setup-panel/src/lib/version.ts
# e package.json. Fluxo de publicação documentado em encha-setup-panel/CLAUDE.md.
ENCHA_VERSION="0.2.13"

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
TERMS_VERSION="2"
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

# Função para animação de loading
loading_animation() {
    local duration=${1:-2}
    local chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local end_time=$((SECONDS + duration))
    
    while [ $SECONDS -lt $end_time ]; do
        for (( i=0; i<${#chars}; i++ )); do
            printf "\r${amarelo}%s Processando...${reset}" "${chars:$i:1}"
            sleep 0.1
        done
    done
    printf "\r${verde}✓ Concluído!         ${reset}\n"
}

centralizar() {
    local texto="$1"
    local largura_terminal=$(tput cols)
    local espacos=$(( (largura_terminal - ${#texto}) / 2 ))
    printf "%*s%s\n" "$espacos" "" "$texto"
}

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
    centralizar "INFORMAÇÕES DO SISTEMA"
    echo -e "${reset}"
    echo -e "${azul}   Sistema: ${verde}$(uname -s)${reset}"
    echo -e "${azul}   Kernel: ${verde}$(uname -r)${reset}"
    echo -e "${azul}   Arquitetura: ${verde}$(uname -m)${reset}"
    echo -e "${azul}   Uptime: ${verde}$(uptime -p 2>/dev/null || echo "N/A")${reset}"
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
    centralizar "                             🤖 Conectando você ao poder da IA                 "
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

aviso_legal(){
    clear
centralizar " █████╗ ██╗   ██╗██╗███████╗ ██████╗"
centralizar "██╔══██╗██║   ██║██║██╔════╝██╔═══██╗"
centralizar "███████║██║   ██║██║███████╗██║   ██║"
centralizar "██╔══██║╚██╗ ██╔╝██║╚════██║██║   ██║"
centralizar "██║  ██║ ╚████╔╝ ██║███████║╚██████╔╝"
centralizar "╚═╝  ╚═╝  ╚═══╝  ╚═╝╚══════╝ ╚═════╝"
    echo ""
    echo -e "${vermelho}${negrito}⚠ Aviso Legal — leia antes de prosseguir:${reset}"
    echo -e "${amarelo}O Encha Setup e o Encha Setup Panel são cedidos GRATUITAMENTE para ajudar a${reset}"
    echo -e "${amarelo}comunidade a instalar suas aplicações na própria VPS. O uso é facultativo —${reset}"
    echo -e "${amarelo}existem outras opções no mercado, como Orion e EasyPanel.${reset}"
    echo ""
    echo -e "${vermelho}${negrito}⚠⚠⚠ Cupom de desconto: ${reset}${amarelo}acesse ${ciano}hostinger.com.br/encha${amarelo} e use o${reset}"
    echo -e "${amarelo}cupom ${negrito}ENCHA${reset}${amarelo} e veja o quanto você economiza na sua nova VPS ⚠⚠⚠${reset}"
    echo ""
    echo -e "${ciano}${negrito}O QUE ESTE INSTALADOR VAI FAZER NA SUA VPS:${reset}"
    echo -e "${amarelo} • Rodar 'apt upgrade' no sistema inteiro, como root${reset}"
    echo -e "${amarelo} • Trocar o hostname e editar o /etc/hosts do servidor${reset}"
    echo -e "${amarelo} • Instalar Docker, iniciar o Swarm e abrir as portas 80 e 443 — necessárias${reset}"
    echo -e "${amarelo}   para a comunicação externa. Se você instalar outras stacks, elas podem${reset}"
    echo -e "${amarelo}   abrir portas adicionais obrigatórias — consulte a documentação de cada uma.${reset}"
    echo -e "${amarelo} • Emitir certificado SSL (Let's Encrypt), enviando seu e-mail a ela${reset}"
    echo ""
    echo -e "${amarelo}Fornecido \"no estado em que se encontra\", sem garantia. Use uma VPS nova${reset}"
    echo -e "${amarelo}ou faça backup antes. Termos completos: ${ciano}${TERMS_URL}${amarelo} (versão ${TERMS_VERSION}).${reset}"
    echo -e "${amarelo}Script original da ${ciano}OrionDesign${amarelo}, melhorado pela ${verde}Encha LTDA${amarelo}.${reset}"
    echo ""

    while true; do
        echo -en "${ciano}Li o aviso acima, aceito os Termos de Uso e desejo prosseguir? (Y/N): ${reset}"
        if ! read -r confirmacao; then
            echo ""
            echo -e "${vermelho}✖ Sem entrada interativa (EOF). Instalação cancelada.${reset}"
            exit 1
        fi

        case "$confirmacao" in
            [Yy])
                echo -e "${verde}✔ Termos aceitos. um momento...${reset}"
                sleep 2

                # Seção de agradecimentos
                clear
                banner_agradecimento
                echo ""

                echo -e "${amarelo}==================================================================================================
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

                echo ""
                echo ""
                echo -e "${ciano}Prosseguindo com a instalação em 5 segundos...${reset}"
                sleep 5
                break
                ;;
            [Nn])
                echo -e "${vermelho}✖ Instalação cancelada pelo usuário.${reset}"
                exit 1
                ;;
            *)
                echo -e "${amarelo}Por favor, responda com 'Y' para sim ou 'N' para não.${reset}"
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

obter_ip_publico() {
    status_info "Obtendo o IP público do servidor..."
    ip_publico=$(curl -s --max-time 10 https://icanhazip.com || hostname -I | awk '{print $1}')
    if [ -n "$ip_publico" ]; then
        status_ok "IP público identificado com sucesso: ${negrito}$ip_publico${reset}"
    else
        status_warning "Falha ao obter IP público. Será usado o IP local como alternativa."
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
checar_dns_e_portas() {
    echo ""
    barra_meio
    echo -e "${ciano}${negrito}🔎 PRÉ-CHECAGEM (informativa — não bloqueia)${reset}"
    barra_meio

    local ip_atual
    ip_atual=$(curl -s --max-time 10 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')
    if [ -z "$ip_atual" ]; then
        ip_atual=$(hostname -I | awk '{print $1}')
    fi
    status_info "IP público desta VPS: ${negrito}${ip_atual:-desconhecido}${reset}"

    local dominio resolvido
    for dominio in "$url_portainer" "$url_painel"; do
        [ -z "$dominio" ] && continue
        resolvido=$(getent ahostsv4 "$dominio" 2>/dev/null | awk '{print $1}' | head -n1)
        if [ -z "$resolvido" ]; then
            status_warning "DNS de '${dominio}' não resolveu ainda. Se acabou de criar o registro, aguarde a propagação — o Let's Encrypt vai falhar até resolver."
        elif [ -n "$ip_atual" ] && [ "$resolvido" != "$ip_atual" ]; then
            status_warning "DNS de '${dominio}' aponta para ${resolvido}, não para o IP desta VPS (${ip_atual}). Confirme o registro A antes de seguir."
        else
            status_ok "DNS de '${dominio}' já aponta para esta VPS."
        fi
    done

    local ocupadas
    ocupadas=$(ss -ltn 2>/dev/null | awk '{print $4}' | grep -E ':(80|443)$')
    if [ -n "$ocupadas" ]; then
        status_warning "Porta 80 e/ou 443 já está em uso por outro processo nesta VPS — o Traefik pode falhar ao subir. Rode 'ss -ltnp | grep -E \":(80|443)\"' para identificar."
    else
        status_ok "Portas 80 e 443 livres."
    fi
}

executar_instalacoes() {
    echo ""
    barra_meio
    echo -e "${verde}${negrito}📦 Iniciando a instalação dos pacotes necessários...${reset}"
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
        
        mostrar_progresso $atual $total_pacotes "Instalando $pacote..."
        
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$pacote" > /dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            printf "\n"
            status_ok "[$atual/$total_pacotes] $pacote instalado com sucesso"
        else
            printf "\n"
            status_fail "[$atual/$total_pacotes] Falha na instalação de $pacote"
        fi
    done
    
    echo ""
    status_ok "Instalação de pacotes concluída! 📋"
}

# Função para verificar e exibir recursos do sistema
mostrar_recursos() {
    echo ""
    barra_meio
    echo -e "${ciano}${negrito}💻 RECURSOS DO SISTEMA${reset}"
    barra_meio
    
    echo -e "${azul}RAM Total:${reset} ${verde}$(free -h | awk '/^Mem:/ {print $2}')${reset}"
    echo -e "${azul}RAM Livre:${reset} ${verde}$(free -h | awk '/^Mem:/ {print $7}')${reset}"
    echo -e "${azul}Espaço em Disco:${reset} ${verde}$(df -h / | awk 'NR==2 {print $4}') livre de $(df -h / | awk 'NR==2 {print $2}')${reset}"
    echo -e "${azul}CPU:${reset} ${verde}$(nproc) núcleos${reset}"
    echo -e "${azul}Load Average:${reset} ${verde}$(uptime | awk -F'load average:' '{print $2}')${reset}"
}

# ====== INÍCIO DO SCRIPT PRINCIPAL ======
clear
aviso_legal
banner
log_encha

sleep 2

echo -e "${amarelo}${negrito}🚀 Iniciando processo de configuração...${reset}"
sleep 1

# Verificação de privilégios
if [ "$(id -u)" -ne 0 ]; then
    echo ""
    status_fail "Este script deve ser executado como root!"
    echo -e "${amarelo}Execute: ${negrito}sudo $0${reset}"
    exit 1
fi

# Mudar para diretório root
cd /root || { 
    status_fail "Erro ao acessar diretório /root"
    exit 1
}

mostrar_recursos

# Update inicial do sistema
echo ""
barra_meio
echo -e "${amarelo}${negrito}🔄 ATUALIZAÇÃO DO SISTEMA${reset}"
barra_meio

status_info "Atualizando lista de pacotes..."
DEBIAN_FRONTEND=noninteractive apt update > /dev/null 2>&1 && status_ok "Lista de pacotes atualizada"

status_info "Atualizando pacotes do sistema..."
echo -e "${amarelo}${negrito}⚠ O processo pode demorar um pouco. Agradecemos a sua paciência.${reset}"
DEBIAN_FRONTEND=noninteractive apt upgrade -y > /dev/null 2>&1 && status_ok "Sistema atualizado com sucesso"

# Executar instalações
executar_instalacoes


# ─────────────────────────────────────────────────────────────────────────────
# FLUXO LINEAR — instala Traefik+Portainer + Encha Setup Panel automaticamente
# ─────────────────────────────────────────────────────────────────────────────

banner_instalacao_completa() {
    clear
    echo -e "${negrito}${roxo}"
    centralizar "╔══════════════════════════════════════════════════════════════════╗"
    centralizar "║          🚀 INSTALAÇÃO AUTOMÁTICA DO ENCHA SETUP                 ║"
    centralizar "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${reset}"
    echo ""
    echo -e "${ciano}Serão instalados nesta sequência:${reset}"
    echo -e "  ${verde}1.${reset} Docker Swarm + rede overlay"
    echo -e "  ${verde}2.${reset} Traefik (proxy reverso com SSL automático)"
    echo -e "  ${verde}3.${reset} Portainer (interface de gerenciamento Docker)"
    echo -e "  ${verde}4.${reset} Encha Setup Panel (painel visual para instalar stacks)"
    echo ""
    echo -e "${amarelo}⚠ Aponte os subdomínios para o IP da VPS ANTES de continuar:${reset}"
    echo -e "  • portainer.seudominio.com  →  IP_DA_VPS"
    echo -e "  • painel.seudominio.com     →  IP_DA_VPS"
    echo ""
    echo -ne "${ciano}Pressione ENTER para iniciar...${reset}" && read -r _
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
coletar_inputs_so_painel() {
    clear
    echo -e "${negrito}${roxo}📝 INSTALAR APENAS O PAINEL${reset}"
    echo ""
    echo -e "${verde}✓ Traefik + Portainer detectados — serão reaproveitados.${reset}"
    echo -e "  ${azul}Rede interna:${reset} ${verde}${nome_rede_interna}${reset}"
    echo ""
    echo -e "${amarelo}⚠ Aponte o subdomínio do painel para o IP da VPS ANTES de continuar.${reset}"
    echo ""

    while true; do
        echo -ne "${ciano}1/4 Subdomínio do Encha Setup Panel (ex: painel.encha.ai): ${reset}" && read -r url_painel
        [[ "$url_painel" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] && break
        echo -e "${vermelho}✖ Domínio inválido.${reset}"
    done

    # 2) Credenciais de serviço do Portainer — o painel usa para se
    #    autenticar sozinho na API. Tenta detectar em /root/dados_vps/dados_portainer
    #    (gravado na instalação do Portainer) antes de pedir.
    user_portainer=""
    pass_portainer=""
    arquivo_portainer="/root/dados_vps/dados_portainer"
    if [ -f "$arquivo_portainer" ]; then
        detectado_user=$(grep "Usuario: " "$arquivo_portainer" | awk -F"Usuario: " '{print $2}' | tr -d '\r')
        detectado_senha=$(grep "Senha: " "$arquivo_portainer" | awk -F"Senha: " '{print $2}' | tr -d '\r')
        if [[ -n "$detectado_user" && -n "$detectado_senha" && "$detectado_user" != *"criar"* ]]; then
            echo -e "${verde}✓ Credenciais do Portainer detectadas — usuário: ${detectado_user}${reset}"
            echo -ne "${ciano}2/4 Usar essas credenciais? (Y/n): ${reset}" && read -r usar_detectado
            if [[ ! "$usar_detectado" =~ ^[Nn]$ ]]; then
                user_portainer="$detectado_user"
                pass_portainer="$detectado_senha"
            fi
        fi
    fi
    if [ -z "$user_portainer" ]; then
        echo -ne "${ciano}2/4 Usuário do Portainer: ${reset}" && read -r user_portainer
        echo -ne "${ciano}    Senha do Portainer: ${reset}" && read -rs pass_portainer && echo ""
    fi

    # Valida de verdade contra o Portainer, para não gerar uma stack do
    # painel com credenciais de serviço erradas.
    echo -e "${ciano}Validando credenciais do Portainer...${reset}"
    resp=$(sudo docker run --rm --network "$nome_rede_interna" curlimages/curl:latest \
        -s -o /dev/null -w "%{http_code}" -X POST http://portainer_portainer:9000/api/auth \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$user_portainer\",\"password\":\"$pass_portainer\"}" 2>/dev/null)
    if [ "$resp" != "200" ]; then
        echo -e "${vermelho}✖ Falha ao autenticar no Portainer com essas credenciais (HTTP $resp).${reset}"
        coletar_inputs_so_painel; return
    fi
    echo -e "${verde}✓ Credenciais do Portainer válidas.${reset}"

    # 3) Usuário admin do painel
    echo -e "${amarelo}--> 4-40 caracteres, minúsculas/números/_/-, começando com letra. Evite \"admin\".${reset}"
    while true; do
        echo -ne "${ciano}3/4 Usuário admin do Painel: ${reset}" && read -r user_painel
        if type validar_usuario &> /dev/null; then
            validar_usuario "$user_painel" && break
        else
            [[ "$user_painel" =~ ^[a-z][a-z0-9_-]{3,39}$ ]] && [[ "${user_painel,,}" != "admin" ]] && break
            echo -e "${vermelho}✖ Usuário inválido.${reset}"
        fi
    done

    # 4) Senha admin do painel
    while true; do
        echo -e "${amarelo}--> Mínimo 12 caracteres com MAIÚSCULAS, minúsculas, números e @ ou _${reset}"
        echo -ne "${ciano}4/4 Senha admin do Painel: ${reset}" && read -rs pass_painel && echo ""
        if type validar_senha &> /dev/null; then
            validar_senha "$pass_painel" 12 && break
        elif [[ ${#pass_painel} -ge 12 ]] \
            && [[ "$pass_painel" =~ [A-Z] ]] \
            && [[ "$pass_painel" =~ [a-z] ]] \
            && [[ "$pass_painel" =~ [0-9] ]] \
            && [[ "$pass_painel" =~ [@_] ]]; then
            break
        else
            echo -e "${vermelho}✖ Senha não atende aos requisitos.${reset}"
        fi
    done

    clear
    echo -e "${roxo}${negrito}🔍 CONFIRA OS DADOS:${reset}"
    echo -e "  ${azul}Painel:${reset}          https://${verde}${url_painel}${reset}"
    echo -e "  ${azul}Rede (reuso):${reset}    ${verde}${nome_rede_interna}${reset}"
    echo -e "  ${azul}Serviço Portainer:${reset} ${verde}${user_portainer}${reset}"
    echo -e "  ${azul}Usuário Painel:${reset}   ${verde}${user_painel}${reset}"
    echo ""
    while true; do
        echo -ne "${verde}✅ Confirma? (Y/N): ${reset}" && read -r confirmacao
        case "$confirmacao" in
            [Yy]) break ;;
            [Nn]) coletar_inputs_so_painel; return ;;
            *)   echo -e "${amarelo}Responda Y ou N.${reset}" ;;
        esac
    done

    export url_painel nome_rede_interna
    export user_portainer pass_portainer user_painel pass_painel
    export ENCHA_NONINTERACTIVE=1
    export ENCHA_MAX_RETRIES=10
    export ENCHA_SLEEP=60
}

coletar_inputs_instalacao() {
    clear
    echo -e "${negrito}${roxo}📝 COLETA DE DADOS${reset}"
    echo ""

    # 1) Subdomínio Portainer
    while true; do
        echo -ne "${ciano}1/7 Subdomínio do Portainer (ex: portainer.encha.ai): ${reset}" && read -r url_portainer
        [[ "$url_portainer" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] && break
        echo -e "${vermelho}✖ Domínio inválido.${reset}"
    done

    # 2) Usuário do Portainer — sem default: "admin" deixa metade da
    #    credencial pública. O usuário digitado é aplicado por renomeação
    #    logo após o bootstrap (ver ferramenta_traefik_e_portainer).
    echo -e "${amarelo}--> 4-40 caracteres, minúsculas/números/_/-, começando com letra. Evite \"admin\".${reset}"
    while true; do
        echo -ne "${ciano}2/7 Usuário do Portainer: ${reset}" && read -r user_portainer
        if type validar_usuario &> /dev/null; then
            validar_usuario "$user_portainer" && break
        else
            [[ "$user_portainer" =~ ^[a-z][a-z0-9_-]{3,39}$ ]] && [[ "${user_portainer,,}" != "admin" ]] && break
            echo -e "${vermelho}✖ Usuário inválido.${reset}"
        fi
    done

    # 3) Senha Portainer (12+ chars, maiús, minús, dígito, especial)
    while true; do
        echo -e "${amarelo}--> Mínimo 12 caracteres com MAIÚSCULAS, minúsculas, números e @ ou _${reset}"
        echo -ne "${ciano}3/7 Senha do Portainer: ${reset}" && read -rs pass_portainer && echo ""
        if type validar_senha &> /dev/null; then
            validar_senha "$pass_portainer" 12 && break
        elif [[ ${#pass_portainer} -ge 12 ]] \
            && [[ "$pass_portainer" =~ [A-Z] ]] \
            && [[ "$pass_portainer" =~ [a-z] ]] \
            && [[ "$pass_portainer" =~ [0-9] ]] \
            && [[ "$pass_portainer" =~ [@_] ]]; then
            break
        else
            echo -e "${vermelho}✖ Senha não atende aos requisitos.${reset}"
        fi
    done

    # 4) Email SSL
    while true; do
        echo -ne "${ciano}4/7 Email para certificados SSL: ${reset}" && read -r email_ssl
        [[ "$email_ssl" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
        echo -e "${vermelho}✖ Email inválido.${reset}"
    done

    # 5) Subdomínio do Painel
    while true; do
        echo -ne "${ciano}5/7 Subdomínio do Encha Setup Panel (ex: painel.encha.ai): ${reset}" && read -r url_painel
        [[ "$url_painel" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] && break
        echo -e "${vermelho}✖ Domínio inválido.${reset}"
    done

    # 6) Usuário admin do painel — identidade separada da do Portainer (pode
    #    repetir o mesmo usuário, se o operador preferir).
    echo -e "${amarelo}--> Mesmas regras do usuário do Portainer.${reset}"
    while true; do
        echo -ne "${ciano}6/7 Usuário admin do Painel: ${reset}" && read -r user_painel
        if type validar_usuario &> /dev/null; then
            validar_usuario "$user_painel" && break
        else
            [[ "$user_painel" =~ ^[a-z][a-z0-9_-]{3,39}$ ]] && [[ "${user_painel,,}" != "admin" ]] && break
            echo -e "${vermelho}✖ Usuário inválido.${reset}"
        fi
    done

    # 7) Senha admin do painel
    while true; do
        echo -e "${amarelo}--> Mínimo 12 caracteres com MAIÚSCULAS, minúsculas, números e @ ou _${reset}"
        echo -ne "${ciano}7/7 Senha admin do Painel: ${reset}" && read -rs pass_painel && echo ""
        if type validar_senha &> /dev/null; then
            validar_senha "$pass_painel" 12 && break
        elif [[ ${#pass_painel} -ge 12 ]] \
            && [[ "$pass_painel" =~ [A-Z] ]] \
            && [[ "$pass_painel" =~ [a-z] ]] \
            && [[ "$pass_painel" =~ [0-9] ]] \
            && [[ "$pass_painel" =~ [@_] ]]; then
            break
        else
            echo -e "${vermelho}✖ Senha não atende aos requisitos.${reset}"
        fi
    done

    # Defaults fixos (combinam com docker-stack.yaml do painel)
    nome_servidor="encha"
    nome_rede_interna="enchanet"

    # Confirmação — nunca exibir as senhas.
    clear
    echo -e "${roxo}${negrito}🔍 CONFIRA OS DADOS:${reset}"
    echo -e "  ${azul}Portainer:${reset}       https://${verde}${url_portainer}${reset}"
    echo -e "  ${azul}Usuário Portainer:${reset} ${verde}${user_portainer}${reset}"
    echo -e "  ${azul}Email SSL:${reset}       ${verde}${email_ssl}${reset}"
    echo -e "  ${azul}Painel:${reset}          https://${verde}${url_painel}${reset}"
    echo -e "  ${azul}Usuário Painel:${reset}   ${verde}${user_painel}${reset}"
    echo ""
    while true; do
        echo -ne "${verde}✅ Confirma? (Y/N): ${reset}" && read -r confirmacao
        case "$confirmacao" in
            [Yy]) break ;;
            [Nn]) coletar_inputs_instalacao; return ;;
            *)   echo -e "${amarelo}Responda Y ou N.${reset}" ;;
        esac
    done

    export url_portainer user_portainer pass_portainer email_ssl url_painel
    export user_painel pass_painel
    export nome_servidor nome_rede_interna
    export ENCHA_NONINTERACTIVE=1
    export ENCHA_MAX_RETRIES=10
    export ENCHA_SLEEP=60
}

download_secondary() {
    echo ""
    barra_meio
    echo -e "${roxo}${negrito}📥 BAIXANDO SCRIPT DE INSTALAÇÃO${reset}"
    barra_meio

    [ -f SetupEnchaAI ] && rm -f SetupEnchaAI

    status_info "Baixando secondary.sh da fonte oficial..."
    if curl -fsSL --retry 3 --connect-timeout 10 \
        https://raw.githubusercontent.com/enchaaluno/setupteste/main/secondary.sh \
        -o SetupEnchaAI; then
        chmod +x SetupEnchaAI
        status_ok "Script baixado com sucesso"
    else
        status_fail "Falha no download. Verifique a conexão."
        exit 1
    fi
}

preparar_fonte_painel() {
    echo ""
    barra_meio
    echo -e "${roxo}${negrito}📦 PREPARANDO FONTE DO PAINEL${reset}"
    barra_meio

    status_info "Garantindo git..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y git >/dev/null 2>&1

    # Tenta atualizar in-place com fetch --depth 1 + reset FETCH_HEAD (robusto a
    # reescrita de histórico: não depende de ancestral comum nem de origin/main).
    # Se qualquer passo falhar, cai no re-clone fresco abaixo.
    if [[ -d /root/encha-setup-panel/.git ]] \
        && git -C /root/encha-setup-panel fetch --depth 1 origin main >/dev/null 2>&1 \
        && git -C /root/encha-setup-panel reset --hard FETCH_HEAD >/dev/null 2>&1; then
        status_info "Repositório atualizado (fetch --depth 1 + reset)."
    else
        status_info "Clonando enchaaluno/setupteste..."
        rm -rf /root/encha-setup-panel /tmp/_setupteste_clone
        git clone --depth 1 \
            https://github.com/enchaaluno/setupteste.git \
            /tmp/_setupteste_clone >/dev/null 2>&1 \
            || { status_fail "Falha no git clone"; exit 1; }
        if [[ ! -d /tmp/_setupteste_clone/encha-setup-panel ]]; then
            status_fail "Diretório encha-setup-panel não encontrado no repositório."
            exit 1
        fi
        mv /tmp/_setupteste_clone/encha-setup-panel /root/encha-setup-panel
        rm -rf /tmp/_setupteste_clone
    fi
    status_ok "Fonte do painel pronta em /root/encha-setup-panel"
}

mostrar_resumo_final() {
    clear
    echo -e "${negrito}${verde}"
    centralizar "╔══════════════════════════════════════════════════════════════════╗"
    centralizar "║                                                                  ║"
    centralizar "║                  🎉 INSTALAÇÃO CONCLUÍDA! 🎉                    ║"
    centralizar "║                                                                  ║"
    centralizar "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${reset}"
    echo ""
    echo -e "${ciano}${negrito}Acesse seus serviços:${reset}"
    echo -e "  ${verde}▸ Portainer:${reset}  https://${negrito}${url_portainer}${reset}"
    echo -e "    ${cinza}usuário: ${user_portainer}${reset}"
    echo -e "  ${verde}▸ Painel Encha:${reset} https://${negrito}${url_painel}${reset}"
    echo -e "    ${cinza}usuário: ${user_painel}${reset}"
    echo ""
    echo -e "${amarelo}💡 O Encha Setup Panel já está pronto para instalar as demais stacks.${reset}"
    echo ""
    echo -e "${ciano}${negrito}Esqueceu a senha do painel?${reset}"
    echo -e "  ${cinza}Portainer → Stacks → encha-panel → Environment variables →${reset}"
    echo -e "  ${cinza}PANEL_ADMIN_PASSWORD → editar → Update the stack.${reset}"
    echo ""
    echo -e "${ciano}${negrito}Suporte:${reset}"
    echo -e "  ${azul}📧 atendimento@encha.ai${reset}"
    echo -e "  ${azul}🌐 https://encha.ai${reset}"
    echo -e "  ${azul}📱 WhatsApp: +55 61 99159-2205${reset}"
    echo ""
}

# ───────── EXECUÇÃO ─────────

banner_instalacao_completa

# Baixa e carrega o secondary.sh ANTES de coletar dados, para ter os helpers do
# instalador disponíveis e poder decidir o fluxo (instalar tudo x só painel).
download_secondary

status_info "Carregando funções do instalador..."
# shellcheck source=/dev/null
source ./SetupEnchaAI
status_ok "Funções carregadas (modo biblioteca)"

# Por padrão instala Traefik+Portainer. Se já existirem, pergunta ao usuário.
INSTALAR_INFRA=1

if infra_ja_instalada; then
    rede_detectada="$(descobrir_rede_painel)" || rede_detectada=""
    nome_rede_interna="${rede_detectada:-enchanet}"
    nome_servidor="encha"

    clear
    echo -e "${negrito}${roxo}🔎 INFRAESTRUTURA DETECTADA${reset}"
    echo ""
    echo -e "${verde}✓ Traefik + Portainer já estão instalados nesta VPS.${reset}"
    echo -e "  ${azul}Rede interna detectada:${reset} ${verde}${nome_rede_interna}${reset}"
    echo ""
    echo -e "${ciano}O que você deseja fazer?${reset}"
    echo -e "  ${verde}1.${reset} Instalar ${negrito}APENAS o Encha Setup Panel${reset} ${cinza}(recomendado — não mexe no resto)${reset}"
    echo -e "  ${verde}2.${reset} Reinstalar tudo ${cinza}(Docker + Traefik + Portainer + Painel)${reset}"
    echo ""
    while true; do
        echo -ne "${ciano}Escolha (1/2): ${reset}" && read -r escolha_infra
        case "$escolha_infra" in
            1) INSTALAR_INFRA=0; break ;;
            2) INSTALAR_INFRA=1; break ;;
            *) echo -e "${amarelo}Responda 1 ou 2.${reset}" ;;
        esac
    done
fi

if [ "$INSTALAR_INFRA" -eq 1 ]; then
    coletar_inputs_instalacao
    checar_dns_e_portas
    echo ""
    barra_meio
    echo -e "${roxo}${negrito}🐳 INSTALANDO TRAEFIK + PORTAINER${reset}"
    barra_meio
    if ! ferramenta_traefik_e_portainer; then
        status_fail "Falha ao instalar Traefik/Portainer (Docker ausente ou stack não subiu). Verifique 'docker service ls' e 'journalctl -u docker'."
        exit 1
    fi
else
    coletar_inputs_so_painel
    status_info "Reaproveitando Traefik+Portainer existentes (rede: ${nome_rede_interna})."
fi

preparar_fonte_painel

echo ""
barra_meio
echo -e "${roxo}${negrito}📦 INSTALANDO ENCHA SETUP PANEL${reset}"
barra_meio
if ! ferramenta_encha_panel; then
    status_fail "Falha ao instalar o painel. Verifique 'docker service ls' e 'docker stack ps encha-panel'."
    exit 1
fi

mostrar_resumo_final
echo ""
