import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { requireSessionToken } from "@/lib/auth/require-token";
import { verifyCsrf, verifyOrigin, getClientIp } from "@/lib/csrf";
import { installStack, listInstalledStacks } from "@/lib/installer";
import { discoverContext, listSwarmStackStatuses, type SwarmStackStatus } from "@/lib/portainer";
import { getStack, getPublicCatalog } from "@/lib/stacks/registry";
import { expectedStackNames, isStackReady } from "@/lib/stacks/types";
import { stackDescription, stackNotes, secretLabel } from "@/lib/stacks/i18n-resolve";
import { computePendingUpdates, computeReleaseBasedPendingUpdates } from "@/lib/stacks/updates";
import { checkRateLimit } from "@/lib/security/rate-limit";
import { resolveLocale } from "@/lib/locale";
import { apiError, unauthenticatedResponse } from "@/lib/api-error";
import type { Locale } from "@/lib/locale-shared";

const ERROS = {
  origem_invalida: { pt: "Origem inválida", en: "Invalid origin", es: "Origen inválido" },
  csrf_invalido: { pt: "CSRF inválido", en: "Invalid CSRF", es: "CSRF inválido" },
  payload_invalido: { pt: "Payload inválido", en: "Invalid payload", es: "Payload inválido" },
  payload_invalido_generico: { pt: "Inválido", en: "Invalid", es: "Inválido" },
  stack_desconhecida: { pt: "Stack desconhecida", en: "Unknown stack", es: "Stack desconocida" },
  stack_ja_instalada: { pt: "Stack já está instalada", en: "Stack is already installed", es: "El stack ya está instalado" },
} satisfies Record<string, Record<Locale, string>>;

function msgMuitasTentativas(segundos: number, locale: Locale): string {
  const t = {
    pt: `Muitas tentativas — aguarde ${segundos}s`,
    en: `Too many attempts — wait ${segundos}s`,
    es: `Demasiados intentos — espere ${segundos}s`,
  };
  return t[locale] ?? t.pt;
}

function msgDependenciaPendente(dependencia: string, alvo: string, locale: Locale): string {
  const t = {
    pt: `Dependência pendente: instale "${dependencia}" antes de "${alvo}".`,
    en: `Pending dependency: install "${dependencia}" before "${alvo}".`,
    es: `Dependencia pendiente: instale "${dependencia}" antes de "${alvo}".`,
  };
  return t[locale] ?? t.pt;
}

const installSchema = z.object({
  stackId: z.string().min(1).max(60),
  values: z.record(z.unknown()),
  swarmCtx: z.object({
    networkName: z.string().min(1),
    serverName: z.string().min(1),
    // Vazio é um valor LEGÍTIMO aqui, não ausência de validação: vem de
    // /root/dados_vps/dados_vps (vps-context.ts), que pode não ter a linha
    // de e-mail numa VPS reaproveitada ou provisionada fora do fluxo padrão.
    // Rejeitar string vazia derrubava TODA instalação de TODA stack (só
    // dify.ts e traefik-portainer.ts realmente usam este campo).
    email: z.union([z.literal(""), z.string().email()]),
  }),
});

export async function GET() {
  const locale = await resolveLocale();
  const auth = await requireSessionToken();
  if (!auth) return unauthenticatedResponse(locale);
  const { token } = auth;

  const catalog = getPublicCatalog();
  let portainerOnline = true;

  const [installed, swarmStatuses] = await Promise.all([
    listInstalledStacks(token).catch((err) => {
      portainerOnline = false;
      console.error("[api/stacks] Falha listando stacks do Portainer:", err);
      return [];
    }),
    discoverContext(token)
      .then(({ endpointId }) => listSwarmStackStatuses(token, endpointId))
      .catch((err) => {
        portainerOnline = false;
        console.error("[api/stacks] Falha listando serviços Docker:", err);
        return [] as SwarmStackStatus[];
      }),
  ]);

  const statusByName = new Map(swarmStatuses.map((s) => [s.name, s]));
  const installedNames = new Set([
    ...installed.map((s) => s.Name),
    ...swarmStatuses.map((s) => s.name),
  ]);

  const readyDetails = swarmStatuses
    .map((s) => `${s.name}=${s.running}/${s.desired}`)
    .join(", ");
  console.log(
    "[api/stacks] Portainer:", installed.length || "(nenhuma)",
    "| Swarm:", readyDetails || "(nenhuma)",
    "| online:", portainerOnline
  );

  const catalogPayload = await Promise.all(
    catalog.map(async (s) => {
      const expected = expectedStackNames(s);
      const present = expected.every((n) => installedNames.has(n));
      const ready = isStackReady(s, installedNames, statusByName);
      // Só oferece atualização quando a stack já subiu por completo — trocar
      // a imagem no meio de um deploy ainda em andamento só embaralharia o
      // estado. updatableImages/updateViaRelease são mutuamente exclusivos
      // por stack (nunca coexistem) — a condicional escolhe qual mecanismo
      // usar, nunca soma os dois.
      const pendingUpdates = ready
        ? s.updateViaRelease
          ? await computeReleaseBasedPendingUpdates(s, swarmStatuses)
          : computePendingUpdates(s, swarmStatuses)
        : [];
      return {
        id: s.id,
        name: s.name,
        // Fase 3 de i18n — resolvida no locale da requisição, ver
        // src/lib/stacks/i18n-resolve.ts.
        description: stackDescription(s, locale),
        category: s.category,
        icon: s.icon,
        dependsOn: s.dependsOn,
        repoUrl: s.repoUrl,
        logoUrl: s.logoUrl,
        installVia: s.installVia ?? "panel",
        optionNumber: s.optionNumber,
        installed: present,
        ready,
        updateAvailable: pendingUpdates.length > 0,
        pendingUpdates,
      };
    })
  );

  const knownNames = new Set<string>();
  for (const s of catalog) {
    for (const n of expectedStackNames(s)) knownNames.add(n);
  }

  for (const s of catalog) {
    const expected = expectedStackNames(s);
    const missing = expected.filter((n) => !installedNames.has(n));
    if (missing.length && missing.length < expected.length) {
      console.warn(
        `[api/stacks] '${s.id}': detecção parcial — esperado=[${expected.join(",")}] faltando=[${missing.join(",")}]`
      );
    }
  }

  const readyCount = catalogPayload.filter((c) => c.installed && c.ready).length;
  const deployingCount = catalogPayload.filter((c) => c.installed && !c.ready).length;

  return NextResponse.json(
    {
      catalog: catalogPayload,
      portainerOnline,
      installed: installed.map((s) => ({
        id: s.Id,
        name: s.Name,
        createdAt: s.CreationDate,
        external: !knownNames.has(s.Name),
      })),
    },
    {
      headers: {
        "x-stack-detection": `portainer=${installed.length};swarm=${swarmStatuses.length};ready=${readyCount};deploying=${deployingCount};online=${portainerOnline ? 1 : 0}`,
      },
    }
  );
}

export async function POST(req: NextRequest) {
  const locale = await resolveLocale();
  if (!verifyOrigin(req)) return apiError(ERROS, "origem_invalida", locale, 403);
  if (!(await verifyCsrf(req))) return apiError(ERROS, "csrf_invalido", locale, 403);

  const auth = await requireSessionToken();
  if (!auth) return unauthenticatedResponse(locale);
  const { session, token } = auth;

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return apiError(ERROS, "payload_invalido", locale, 400);
  }

  const parsed = installSchema.safeParse(body);
  if (!parsed.success) {
    const msg = parsed.error.errors[0]?.message ?? ERROS.payload_invalido_generico[locale];
    return NextResponse.json({ error: "payload_invalido", message: msg }, { status: 400 });
  }

  const ip = getClientIp(req);
  const rl = checkRateLimit(`install:${ip}:${parsed.data.stackId}`, 3, 60_000);
  if (!rl.allowed) {
    return NextResponse.json(
      { error: "muitas_tentativas", message: msgMuitasTentativas(Math.ceil(rl.resetMs / 1000), locale) },
      { status: 429 }
    );
  }

  const def = getStack(parsed.data.stackId);
  if (!def) return apiError(ERROS, "stack_desconhecida", locale, 404);

  // Idempotência (já instalada?) e dependsOn (pré-requisitos prontos?) — o
  // stack-card.tsx já desabilita o botão nesses casos, mas isso é só UI:
  // nada impede um POST direto pulando a checagem. Reusa a mesma consulta ao
  // Portainer para os dois, então não sai chamada extra por causa disso.
  try {
    const { endpointId } = await discoverContext(token);
    const swarmStatuses = await listSwarmStackStatuses(token, endpointId);
    const present = new Set(swarmStatuses.map((s) => s.name));
    const expected = expectedStackNames(def);
    if (expected.every((n) => present.has(n))) {
      return apiError(ERROS, "stack_ja_instalada", locale, 409);
    }

    const statusByName = new Map(swarmStatuses.map((s) => [s.name, s]));
    for (const depId of def.dependsOn) {
      const depDef = getStack(depId);
      // dependência desconhecida no catálogo: não há como validar, ignora
      // (não deveria acontecer — dependsOn deve sempre apontar pra um id real)
      if (!depDef) continue;
      if (!isStackReady(depDef, present, statusByName)) {
        return NextResponse.json(
          { error: "dependencia_pendente", message: msgDependenciaPendente(depDef.name, def.name, locale) },
          { status: 409 }
        );
      }
    }
  } catch (e) {
    console.warn("[api/stacks] pre-deploy idempotency/dependsOn check falhou:", e);
    // Se não conseguir verificar, prossegue com a instalação (Portainer dará erro se duplicado)
  }

  const result = await installStack({
    stackId: parsed.data.stackId,
    values: parsed.data.values,
    swarmCtx: parsed.data.swarmCtx,
    token,
    user: session.user,
    ip,
  });

  if (!result.ok) {
    // httpStatus vem de installer.ts (statusForCause) — falha do lado do
    // EnchaT (Console fora do ar, timeout, resposta malformada) devolve
    // 502/504/429, não 400. 400 fica só pra chave de licença errada ou bug
    // de validação. Ver plano de correção do Encha Setup para o motivo.
    return NextResponse.json(
      { error: result.error, reason: result.reason },
      { status: result.httpStatus ?? 400 }
    );
  }
  return NextResponse.json({
    ok: true,
    stackId: result.stack?.Id,
    accessUrl: def.postInstall?.accessUrl?.(parsed.data.values),
    // Link de primeiro acesso (contém o token de setup) — ver
    // postInstall.setupUrl em stacks/types.ts. Mesmo raciocínio de
    // revealSecrets abaixo: só sai nesta resposta.
    setupUrl: result.setupUrl,
    // Não-bloqueante — ver checarFingerprintPosDeploy em installer.ts.
    aviso: result.aviso,
    // Fase 3 de i18n — resolvidas no locale da requisição.
    notes: stackNotes(def, locale, parsed.data.values),
    // Só os segredos marcados `reveal: true` saem daqui — é a ÚNICA vez que
    // o operador consegue ver um valor como o enchat_master_key; o painel
    // guarda uma cópia criptografada para reinstalls, mas não a reexibe.
    revealSecrets: (result.generatedSecrets ?? [])
      .filter((s) => s.reveal)
      .map((s) => ({ name: s.name, label: secretLabel(def, s.name, s.label, locale), value: s.value })),
  });
}
