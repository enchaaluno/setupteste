import { z } from "zod";
import { type StackDefinition, fqdn } from "./types";
import { randomBytes } from "node:crypto";
import { ENCHAT_APP_HOSTNAME } from "../enchat-fingerprint";

// Imagem do Pinfy (WhatsApp não-oficial, bundled). Antes fixa em
// "ghcr.io/enchainterno/pinfy-api:1.0.0" (uma republicação manual,
// mesmo digest do upstream ghcr.io/octavioEncha/pinfy, feita só pra ficar
// sob o mesmo owner do enchat-free — "Manage access" cross-conta no GHCR
// não governa `docker pull` de verdade, só a fronteira de CONTA isola,
// ver [[ghcr-isolamento-pacotes]] na memória do repo ENCHAT). Isso ficou
// obsoleto: o commit 6a2bf7f (repo ENCHAT) vendorizou o Pinfy como
// submodule e passou a publicá-lo pelo MESMO CI/release do enchat-free,
// sob "ghcr.io/enchainterno/pinfy" (nome do repo mudou de "pinfy-api" pra
// "pinfy") e com a MESMA tag de versão do app, nunca mais "1.0.0" fixo.
// Deriva do release resolvido pelo Console em vez de hardcode, no mesmo
// padrão de updaterRepoFrom logo abaixo.
function pinfyRepoFrom(imageRepo: string): string {
  const idx = imageRepo.lastIndexOf("/");
  if (idx === -1) {
    throw new Error(`image_repo do Console ("${imageRepo}") sem "/" — não dá pra derivar o repo do Pinfy.`);
  }
  return `${imageRepo.slice(0, idx)}/pinfy`;
}
// A edição Grátis do EnchaT (e o Pinfy embutido) vivem num owner GHCR
// SEPARADO do da edição MAX — de propósito, é o que permite a credencial de
// pull entregue por registryAuth.exchangeUrl alcançar só as imagens do
// Grátis, nunca a MAX.
const CONSOLE_BASE_URL = "https://console.enchat.pro";

// COMPATIBILIDADE (temporário). O Pinfy virou nativo do EnchaT e a imagem
// nova IGNORA esta URL — mas enquanto a tag publicada como `:stable` for a
// anterior à remoção do licenciamento, uma instalação NOVA ainda ativa
// licença, e sem esta variável ela cai no default morto do upstream do Pinfy
// (licenca.pinfy.com.br, domínio que nunca existiu) e o canal nunca conecta.
// Hardcoded, não env: roda na VPS do cliente, e uma env aqui seria vetor de
// sequestro de domínio (mesmo raciocínio do CONSOLE_BASE_URL acima). SEM
// barra final — o backend do Pinfy concatena "${LICENSE_SERVER_URL}/api/..."
// sem normalizar, e a barra dupla dava 404 (achado no primeiro onboarding
// real). Remover — junto com o `hostname` fixo do serviço enchat_pinfy —
// quando a frota tiver migrado para a imagem nativa.
const PINFY_LICENSE_SERVER_URL = "https://app.pinfy.fun";

// Deriva o repo do sidecar enchat-updater a partir do repo resolvido pelo
// Console para a imagem principal — os dois são publicados sob o mesmo owner
// (ver ENCHAT GRÁTIS/README.md), então "enchat-free" -> "enchat-updater" é
// estável. Lança se o formato mudar, em vez de silenciosamente montar uma
// referência de imagem errada.
function updaterRepoFrom(imageRepo: string): string {
  if (!imageRepo.endsWith("/enchat-free")) {
    throw new Error(
      `image_repo do Console ("${imageRepo}") não termina em "/enchat-free" — não dá pra derivar o repo do sidecar enchat-updater com segurança.`
    );
  }
  return imageRepo.replace(/\/enchat-free$/, "/enchat-updater");
}

const schema = z
  .object({
    url_enchat: fqdn,
    // Opcional agora — o caminho principal é o pareamento self-service
    // (StackDefinition.pairing abaixo), que preenche licenca_pareamento_id.
    // Este campo continua existindo como fallback pra quem já tem uma chave
    // emitida (ex.: por um admin, ou de uma instalação anterior).
    chave_licenca: z.string().min(8, "Chave de licença inválida").max(200).optional(),
    // Preenchido pelo componente LicensePairing (wizard) quando o
    // pareamento confirma — nunca digitado pelo usuário. 32 hex = mesmo
    // formato de id de license_pairings (pairing-store.ts).
    licenca_pareamento_id: z.string().regex(/^[0-9a-f]{32}$/).optional(),
  })
  .refine((v) => !!v.chave_licenca || !!v.licenca_pareamento_id, {
    message: "Gere sua licença EnchaT Grátis pelo pareamento acima, ou informe uma chave existente.",
    path: ["chave_licenca"],
  });

export const enchat: StackDefinition = {
  id: "enchat",
  name: "EnchaT Grátis",
  description: "CRM conversacional (WhatsApp) — edição gratuita do EnchaT, com Pinfy embutido.",
  category: "crm",
  icon: "headphones",
  dependsOn: ["traefik-portainer"], // Postgres é dedicado a esta stack, não o compartilhado.
  optionNumber: 84,
  installVia: "panel",
  // Ciclo 20: OBRIGATÓRIO em toda stack com registryAuth/pairing — ver o
  // comentário do campo em stacks/types.ts. Este é o valor que já estava
  // implícito (o default de fingerprintEnchat) — agora explícito.
  appHostname: ENCHAT_APP_HOSTNAME,
  // media: dono 1000:1000 pra bater com `USER enchat` do Dockerfile (uid
  // fixado em -u 1000) — sem isso o bind mount nasce root:root e o app não
  // consegue escrever nele (achado real: upload de mídia sempre falhava com
  // "permission denied", em toda instalação já feita). postgres: SEM owner
  // — o próprio entrypoint da imagem ajusta o dono dele no boot.
  // updater: SEM owner — o sidecar roda como root (sem USER no Dockerfile
  // de cmd/enchat-updater). É onde fica o STATE_FILE dele (ver
  // enchat_updater no generateYaml).
  hostDirs: [{ path: "/var/enchat/media", owner: "1000:1000" }, "/var/enchat/postgres", "/var/enchat/updater"],
  // licenca_pareamento_id também nunca deve ser persistido — é só uma
  // referência a uma linha de license_pairings (que já guarda a chave
  // CIFRADA); persisti-lo em stack_secrets seria redundante e aumentaria a
  // superfície de coisas a proteger.
  transientFields: ["chave_licenca", "licenca_pareamento_id"],
  // Sem `updatableImages` DE PROPÓSITO — não é omissão, é decisão. Dois
  // motivos reais impedem um botão de update in-place funcionar hoje:
  //   1. updateServiceImage() (portainer.ts) não manda X-Registry-Auth; só o
  //      pré-pull do install (pullImageWithRegistry, usado em installer.ts)
  //      é autenticado. Um update trocaria a imagem sem credencial —
  //      enchat_app/enchat_pinfy ficariam presas em "pending" sem erro claro.
  //   2. `chave_licenca` é transientField e nunca é persistida (decisão de
  //      segurança). No momento do update não há como refazer o exchange, e
  //      o token GHCR já registrado no Portainer é de curta duração.
  // A atualização de versão E o upgrade de plano (free -> full) passam pelo
  // sidecar enchat_updater (ver generateYaml), não por este botão do painel.
  // Para habilitar update in-place: dar suporte a registry auth no caminho de
  // update (pedir a chave de novo num modal dedicado, refazer o exchange,
  // então pullImageWithRegistry antes do updateServiceImage).

  release: {
    baseUrl: CONSOLE_BASE_URL,
    app: "enchat",
    edicao: "free",
    canal: "stable",
  },

  // Pareamento self-service de licença — ver LicensePairing (wizard) e
  // /api/license/pair/* (rotas do painel, license-pairing.ts). O cliente
  // gera a própria licença sem precisar de uma chave criada por admin.
  pairing: {
    consoleBaseUrl: CONSOLE_BASE_URL,
    edicao: "free",
    targetField: "chave_licenca",
    sessionField: "licenca_pareamento_id",
    group: "Licença",
  },

  registryAuth: {
    registryHost: "ghcr.io",
    registryName: "GHCR EnchaT",
    exchangeUrl: `${CONSOLE_BASE_URL}/api/v1/installs/registry-auth`,
    licenseField: "chave_licenca",
    images: (_v, release) => {
      if (!release) throw new Error("release não resolvida antes de registryAuth.images — bug no installer.");
      return [
        `${release.imageRepo}:${release.imageTag}`,
        `${updaterRepoFrom(release.imageRepo)}:${release.imageTag}`,
        `${pinfyRepoFrom(release.imageRepo)}:${release.imageTag}`,
      ];
    },
  },
  fields: [
    {
      name: "url_enchat",
      label: "Domínio do painel EnchaT",
      kind: "domain",
      placeholder: "crm.suaempresa.com",
      group: "Domínios",
      helpText: "O DNS já deve apontar para esta VPS antes de instalar.",
    },
    {
      name: "chave_licenca",
      label: "Já tenho uma chave de licença",
      kind: "password",
      sensitive: true,
      optional: true,
      group: "Licença",
      helpText: "Só preencha se já tiver uma chave emitida — pule esta se estiver usando o pareamento acima. Não é gravada em disco.",
    },
  ],
  schema,
  generateSecrets: () => [
    { name: "enchat_master_key", value: randomBytes(32).toString("base64"), reveal: true },
    { name: "postgres_password", value: randomBytes(24).toString("hex") },
    { name: "pinfy_master_key", value: randomBytes(24).toString("hex") },
    { name: "pinfy_webhook_token", value: randomBytes(24).toString("hex") },
    { name: "pinfy_panel_password", value: randomBytes(24).toString("hex") },
    // Senha do papel restrito "pinfy" no Postgres (plano de segurança do
    // EnchaT, S12 C1/C2): o app cria/mantém esse papel no boot com ela, e o
    // Pinfy conecta com a MESMA senha (DATABASE_URL, abaixo) — nunca mais o
    // superusuário "enchat". Como todo segredo daqui, sai direto na fase B
    // (a release deste painel só sai depois de uma release ESTÁVEL do
    // EnchaT com o C1 publicada — ver docs/SEGURANCA-RELEASE.md do repo
    // ENCHAT, seção 5), então não existe uma "fase A" aqui.
    { name: "pinfy_db_password", value: randomBytes(24).toString("hex") },
    // Cifra (AES-256-GCM) a sessão do WhatsApp guardada pelo Pinfy no
    // Postgres (S12 C3). GUARDE como a enchat_master_key: perdê-la faz toda
    // instância pedir QR code de novo (leads e conversas não se perdem).
    { name: "pinfy_session_key", value: randomBytes(32).toString("hex"), reveal: true },
    // Compartilhado entre enchat_app e enchat_updater (Authorization: Bearer) —
    // ver cmd/enchat-updater/README.md no repo do EnchaT.
    { name: "updater_token", value: randomBytes(24).toString("hex") },
    // Token de primeiro acesso (ENCHAT_SETUP_TOKEN, S-03 do plano de
    // segurança do EnchaT): o app só cria o primeiro Super Admin para quem
    // abrir https://<domínio>/?setup=<token>. Sem esta env o app gera um
    // token sozinho e o escreve só no log do contêiner — o dono teria de
    // caçar o link no Portainer. base64url: vai numa URL e dentro de aspas
    // duplas no YAML, sem nada a escapar; 24 bytes = 32 caracteres (o app
    // recusa menos de 20). Não é `reveal`: sai pronto no setupUrl do
    // pós-instalação. Como todo segredo daqui, um reinstall reaproveita o
    // valor gravado em stack_secrets (loadStackOwnSecrets, installer.ts), e
    // a atualização pelo sidecar só troca a imagem do serviço — o env fica.
    { name: "enchat_setup_token", value: randomBytes(24).toString("base64url") },
  ],
  generateYaml(values, secrets, ctx) {
    const v = values as z.infer<typeof schema>;
    if (!ctx.release) throw new Error("ctx.release ausente em generateYaml — bug no installer.");
    const net = ctx.networkName;
    const san = (x: unknown) => String(x ?? "").replace(/[`"\n\r]/g, "");
    const domain = san(v.url_enchat);
    const { imageRepo, imageTag } = ctx.release;
    const updaterRepo = updaterRepoFrom(imageRepo);
    const pinfyRepo = pinfyRepoFrom(imageRepo);
    return `version: "3.7"
services:

  enchat_app:
    image: ${imageRepo}:${imageTag}
    hostname: enchat-app
    networks:
      - ${net}
      - enchat_net
    volumes:
      - /var/enchat/media:/data/media
    environment:
      DATABASE_URL: "postgresql://enchat:${secrets.postgres_password}@enchat_postgres:5432/enchat?sslmode=disable"
      WHATSAPP_APP_SECRET: ""
      WHATSAPP_VERIFY_TOKEN: ""
      WHATSAPP_API_VERSION: "v21.0"
      INSTAGRAM_APP_ID: ""
      INSTAGRAM_APP_SECRET: ""
      INSTAGRAM_REDIRECT_URI: "https://${domain}/api/instagram/oauth/callback"
      INSTAGRAM_VERIFY_TOKEN: ""
      INSTAGRAM_API_VERSION: "v21.0"
      PINFY_BASE_URL: "http://enchat_pinfy:3000"
      PINFY_MASTER_KEY: "${secrets.pinfy_master_key}"
      PINFY_WEBHOOK_URL: "http://enchat_app:8080/api/webhooks/pinfy"
      PINFY_WEBHOOK_TOKEN: "${secrets.pinfy_webhook_token}"
      PINFY_DB_PASSWORD: "${secrets.pinfy_db_password}"
      MAUTIC_BASE_URL: ""
      MAUTIC_USER: ""
      MAUTIC_PASSWORD: ""
      MAUTIC_WEBHOOK_TOKEN: ""
      SMS_GATEWAY_ENABLED: "false"
      SMS_GATEWAY_WEBHOOK_TOKEN: ""
      WORDPRESS_WEBHOOK_TOKEN: ""
      PUBLIC_BASE_URL: "https://${domain}"
      MEDIA_DIR: "/data/media"
      LICENSE_SERVER_URL: "${CONSOLE_BASE_URL}"
      ENCHAT_CANAL: "stable"
      ENCHAT_MASTER_KEY: "${secrets.enchat_master_key}"
      ENCHAT_SETUP_TOKEN: "${secrets.enchat_setup_token}"
      ENCHAT_MACHINE_ID: "${san(ctx.machineId ?? "")}"
      LICENSE_KEY: "${san(String(values.chave_licenca ?? ""))}"
      TZ: "America/Sao_Paulo"
      UPDATER_URL: "http://enchat_updater:9000"
      UPDATER_TOKEN: "${secrets.updater_token}"
      UPDATE_MODE: ""
    deploy:
      replicas: 1
      update_config:
        order: start-first
      # Sem max_attempts DE PROPÓSITO (igual enchat_pinfy/enchat_postgres
      # abaixo) — o Swarm não tem depends_on com condição de saúde, então
      # num boot a frio o app precisa poder tentar reconectar ao Postgres
      # indefinidamente. Com max_attempts:5/delay:5s, uma VPS lenta o
      # bastante (~25s+ pro Postgres aceitar conexão) esgotava as tentativas
      # e derrubava a instalação de vez, sem auto-recuperação — achado em
      # teste de instalação ponta-a-ponta (2026-08-07).
      restart_policy:
        condition: on-failure
        delay: 5s
      placement:
        constraints:
          - node.role == manager
      labels:
        - "traefik.enable=true"
        - "traefik.docker.network=${net}"
        - "traefik.http.routers.enchat-free.rule=Host(\`${domain}\`)"
        - "traefik.http.routers.enchat-free.entrypoints=websecure"
        - "traefik.http.routers.enchat-free.tls=true"
        - "traefik.http.routers.enchat-free.tls.certresolver=letsencryptresolver"
        - "traefik.http.routers.enchat-free-http.rule=Host(\`${domain}\`)"
        - "traefik.http.routers.enchat-free-http.entrypoints=web"
        - "traefik.http.routers.enchat-free-http.middlewares=enchat-free-https-redirect"
        - "traefik.http.middlewares.enchat-free-https-redirect.redirectscheme.scheme=https"
        - "traefik.http.middlewares.enchat-free-https-redirect.redirectscheme.permanent=true"
        - "traefik.http.services.enchat-free.loadbalancer.server.port=8080"

  # Sidecar de atualização em um clique (docker.sock) — necessário tanto para
  # "atualizar versão" quanto para o upgrade de plano (free -> full). Sem
  # arquivo .env no host (Swarm/Portainer), então as âncoras de confiança
  # (ver repoConfiavel em cmd/enchat-updater/main.go, no repo do EnchaT) vão
  # como env var explícita — nunca escolhidas pelo Console.
  enchat_updater:
    image: ${updaterRepo}:${imageTag}
    hostname: enchat-updater
    networks:
      - enchat_net
    # /data guarda o STATE_FILE: progresso do update em andamento (a conexão
    # de quem disparou morre junto com o app sendo trocado) e o histórico
    # de versões aplicadas que o sidecar usa para recusar versão MENOR que
    # a já aplicada. Sem volume, tudo isso sumia a cada restart do
    # contêiner. Bind no mesmo diretório que ENCHAT GRÁTIS/swarm/
    # docker-stack.yaml usa (/var/enchat/updater, criado via hostDirs).
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/enchat/updater:/data
    environment:
      UPDATER_TOKEN: "${secrets.updater_token}"
      LICENSE_SERVER_URL: "${CONSOLE_BASE_URL}"
      ENCHAT_EDICAO: "free"
      ENCHAT_CANAL: "stable"
      ENCHAT_IMAGEM_PADRAO: "${imageRepo}"
      ENCHAT_IMAGEM_UPGRADE: "ghcr.io/carlosmaximiliano-cloud/enchat"
      DEPLOY_MODE: "swarm"
      SWARM_SERVICE: "enchat_enchat_app"
      STATE_FILE: "/data/estado.json"
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure
      placement:
        constraints:
          - node.role == manager

  # Pinfy é nativo do EnchaT, sem licença própria — o limite de instâncias
  # por plano é entitlement do Console imposto pelo app. O hostname fixo e o
  # LICENSE_SERVER_URL abaixo são compatibilidade temporária com a imagem
  # anterior à remoção do licenciamento (ver PINFY_LICENSE_SERVER_URL).
  enchat_pinfy:
    image: ${pinfyRepo}:${imageTag}
    hostname: enchat-pinfy
    networks:
      - enchat_net
    environment:
      # Usuário restrito "pinfy" (papel criado pelo enchat_app no boot, S12
      # C1) — nunca mais o superusuário "enchat".
      DATABASE_URL: "postgresql://pinfy:${secrets.pinfy_db_password}@enchat_postgres:5432/enchat?schema=pinfy&sslmode=disable"
      MASTER_KEY: "${secrets.pinfy_master_key}"
      PANEL_PASSWORD: "${secrets.pinfy_panel_password}"
      SESSION_KEY: "${secrets.pinfy_session_key}"
      LICENSE_SERVER_URL: "${PINFY_LICENSE_SERVER_URL}"
      TZ: "America/Sao_Paulo"
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure
      placement:
        constraints:
          - node.role == manager

  enchat_postgres:
    image: pgvector/pgvector:pg16
    networks:
      - enchat_net
    volumes:
      - /var/enchat/postgres:/var/lib/postgresql/data
    environment:
      POSTGRES_USER: "enchat"
      POSTGRES_PASSWORD: "${secrets.postgres_password}"
      POSTGRES_DB: "enchat"
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure
      placement:
        constraints:
          - node.role == manager

networks:
  ${net}:
    external: true
    name: ${net}
  enchat_net:
    driver: overlay
    attachable: true
`;
  },
  postInstall: {
    // accessUrl fica LIMPO de propósito: installer.ts o usa para conferir o
    // fingerprint em /api/license depois do deploy.
    accessUrl: (v) => `https://${(v as z.infer<typeof schema>).url_enchat}`,
    // O token vai como query (?setup=): é o formato que o app lê na SPA e
    // tira da barra de endereço assim que cria o administrador. Domínio já
    // validado pelo schema (fqdn); token é base64url, nada a codificar.
    setupUrl: (v, secrets) =>
      `https://${(v as z.infer<typeof schema>).url_enchat}/?setup=${secrets.enchat_setup_token}`,
    // Função, não lista fixa: a primeira nota muda dependendo de como a
    // licença chegou. `values` aqui é o que o BROWSER submeteu (antes do
    // installer injetar a chave do pareamento) — licenca_pareamento_id
    // preenchido é o sinal de que o LicensePairing confirmou e o app já
    // nasce ativado (LICENSE_KEY semeada, ver generateYaml acima).
    notes: (values) => {
      const pareado = !!(values as Record<string, unknown>).licenca_pareamento_id;
      return [
        pareado
          ? "Licença já vinculada pelo pareamento — o app deve subir ativado, sem passar pela tela de ativação."
          : "Ativação: abra o domínio e pareie pelo WhatsApp (ou digite o CPF, fluxo legado) no primeiro acesso.",
        "Primeiro acesso: use o link de criação do administrador exibido acima, uma única vez. Se esta licença já tinha um administrador, o link abre o login normal.",
        "Guarde a ENCHAT_MASTER_KEY exibida — sem ela, os segredos gravados no banco são irrecuperáveis.",
        "Guarde a PINFY_SESSION_KEY exibida também — sem ela, toda instância do WhatsApp pede QR code de novo (leads e conversas não se perdem).",
        "O painel do Pinfy não é exposto por domínio — diagnóstico só via docker exec no container enchat_pinfy.",
      ];
    },
  },
  // Fase 3 de i18n — postInstall.notes acima é FUNÇÃO (varia por `values`),
  // então fica de fora do overlay de propósito (ver StackTextOverlay em
  // types.ts) — continua em pt-BR até uma tradução dedicada.
  i18n: {
    en: {
      description: "Conversational CRM (WhatsApp) — EnchaT Free edition, with Pinfy built in.",
      fields: {
        url_enchat: {
          label: "EnchaT Panel Domain",
          placeholder: "crm.yourcompany.com",
          group: "Domains",
          helpText: "DNS must already point to this VPS before installing.",
        },
        chave_licenca: {
          label: "I already have a license key",
          group: "License",
          helpText:
            "Only fill this in if you already have an issued key — skip it if you're using the pairing above. It isn't saved to disk.",
        },
      },
    },
    es: {
      description: "CRM conversacional (WhatsApp) — edición EnchaT Free, con Pinfy integrado.",
      fields: {
        url_enchat: {
          label: "Dominio del panel EnchaT",
          placeholder: "crm.suempresa.com",
          group: "Dominios",
          helpText: "El DNS ya debe apuntar a esta VPS antes de instalar.",
        },
        chave_licenca: {
          label: "Ya tengo una clave de licencia",
          group: "Licencia",
          helpText:
            "Complete esto solo si ya tiene una clave emitida — omítalo si está usando el emparejamiento de arriba. No se guarda en disco.",
        },
      },
    },
  },
};
