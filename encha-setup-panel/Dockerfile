# --- deps stage ---
FROM node:20-alpine AS deps
WORKDIR /app
RUN apk add --no-cache python3 make g++ libc6-compat
# package-lock.json também é copiado e npm ci (não npm install) é usado de
# propósito: sem lockfile, o build de release podia resolver dependências
# diferentes das que rodaram no build testado do mesmo commit — o log de
# builds passaria uma sensação de rastreabilidade que o pipeline não entregava.
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

# --- build stage ---
FROM node:20-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# --- runtime ---
FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs

# Pull standalone build + assets
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --from=builder --chown=nextjs:nodejs /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/node_modules/better-sqlite3 ./node_modules/better-sqlite3

# Persistent data dir + cache dir (tmpfs mount-point para read_only: true)
RUN mkdir -p /app/data /app/.next/cache && chown -R nextjs:nodejs /app/data /app/.next/cache

# nftables + o script do serviço encha-guard (ciclo C4 — achado A1: portas
# internas do Swarm expostas à Internet). Esta MESMA imagem é reaproveitada
# pelo serviço Swarm `encha-guard` (criado no C5/C6, fora deste ciclo), só
# que com User "0", Healthcheck NONE e Command diferentes via override no
# spec do serviço — nunca mudar USER/HEALTHCHECK/CMD abaixo por causa disso,
# o painel continua rodando como "nextjs" normalmente.
RUN apk add --no-cache nftables
COPY guard/encha-guard.sh /usr/local/bin/encha-guard
# Dois passos (COPY + RUN chmod) em vez de "COPY --chmod": um build local
# sem BuildKit pode não suportar a flag — mesmo padrão já usado no resto
# deste arquivo (nada de atalho que dependa de um builder específico).
RUN chmod 0755 /usr/local/bin/encha-guard

# Usado por um ciclo futuro (C9) para decidir se uma instalação pode migrar
# para segredos do Docker — não pula nenhuma lógica agora, só o rótulo.
LABEL com.encha.painel.recursos="credenciais-arquivo guarda-swarm"

USER nextjs
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://127.0.0.1:3000/api/health || exit 1
CMD ["node", "server.js"]
