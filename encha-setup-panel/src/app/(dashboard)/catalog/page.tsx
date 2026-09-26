"use client";
import { useEffect, useState, useMemo, useCallback, useRef, Suspense } from "react";
import { useSearchParams, useRouter } from "next/navigation";
import { StackCard, type CatalogEntry } from "@/components/stack-card";
import { InstallWizard } from "@/components/wizard/install-wizard";
import { SshInstallHint } from "@/components/ssh-install-hint";
import { SshProtectionWarning, protecaoSshDaResposta } from "@/components/ssh-protection-warning";
import { Input } from "@/components/ui/input";
import { getCategoryLabel } from "@/lib/category-labels";
import { Search, Boxes, X, AlertTriangle } from "lucide-react";
import { useDict } from "@/lib/i18n/use-dict";
import { useLocale } from "@/components/locale-provider";
import { catalogPageText } from "./page.i18n";

const MAX_DEPLOY_MS = 10 * 60 * 1000;

type Field = {
  name: string;
  label: string;
  kind: string;
  placeholder?: string;
  helpText?: string;
  sensitive?: boolean;
  optional?: boolean;
  default?: string | boolean;
  group?: string;
};

type PairingSpecUI = { targetField: string; sessionField: string };

type FullStack = CatalogEntry & { fields?: Field[]; pairing?: PairingSpecUI | null };

export default function CatalogPage() {
  const t = useDict(catalogPageText);
  return (
    <Suspense fallback={<div className="text-center text-muted-foreground py-12">{t.loading}</div>}>
      <CatalogPageInner />
    </Suspense>
  );
}

function CatalogPageInner() {
  const t = useDict(catalogPageText);
  const { locale } = useLocale();
  const search_params = useSearchParams();
  const router = useRouter();
  const category = search_params.get("category");

  const [data, setData] = useState<{ catalog: CatalogEntry[]; portainerOnline?: boolean } | null>(null);
  const deployStartedAt = useRef<Map<string, number>>(new Map());
  const [search, setSearch] = useState("");
  const [openStack, setOpenStack] = useState<FullStack | null>(null);
  const [sshHint, setSshHint] = useState<CatalogEntry | null>(null);
  const [csrf, setCsrf] = useState<string>("");
  const [swarmCtx, setSwarmCtx] = useState({ networkName: "enchanet", serverName: "encha", email: "" });
  const [vpsDefaults, setVpsDefaults] = useState<Record<string, string>>({});
  // null enquanto /api/vps-context não respondeu — ver deveExibirAvisoProtecaoSsh.
  const [sshProtected, setSshProtected] = useState<boolean | null>(null);

  // Só a resposta da requisição mais recente é aplicada: com o refetch por
  // troca de locale (abaixo) + polling de deploy, duas chamadas podem voar
  // juntas, e uma resposta atrasada do idioma anterior sobrescreveria a nova.
  const stacksReqSeq = useRef(0);
  const refetchStacks = useCallback(() => {
    const seq = ++stacksReqSeq.current;
    fetch("/api/stacks")
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => {
        if (seq !== stacksReqSeq.current) return;
        if (d && Array.isArray(d.catalog)) setData(d);
        else console.warn("[stacks] resposta inesperada:", d);
      })
      .catch((e) => console.error("[stacks]", e));
  }, []);

  // Refaz o fetch do catálogo quando o locale muda: description/fields/notes
  // (Fase 3) são resolvidos no servidor a partir do cookie de locale, então
  // trocar o idioma no toggle (que só dá router.refresh(), efeito em Server
  // Components) não invalidava sozinho este fetch client-side — achado ao
  // vivo no teste end-to-end (descrições ficavam presas no idioma anterior
  // até um reload manual da página).
  useEffect(() => {
    refetchStacks();
  }, [locale, refetchStacks]);

  useEffect(() => {
    fetch("/api/csrf")
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => d?.token && setCsrf(d.token))
      .catch((e) => console.error("[csrf]", e));

    fetch("/api/vps-context")
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => {
        if (!d) return;
        setSwarmCtx({
          networkName: d.nome_rede_interna || "enchanet",
          serverName: d.nome_servidor || "encha",
          email: d.email_ssl || "",
        });
        setVpsDefaults({
          nome_servidor: d.nome_servidor ?? "",
          nome_rede_interna: d.nome_rede_interna ?? "",
          email_ssl: d.email_ssl ?? "",
          url_portainer: d.url_portainer ?? "",
        });
        // Campo ausente fica no default "protegido" — ver protecaoSshDaResposta.
        setSshProtected(protecaoSshDaResposta(d));
      })
      .catch((e) => console.error("[vps-context]", e));
  }, []);

  useEffect(() => {
    if (!data) return;
    const now = Date.now();
    const stillDeploying = data.catalog.some((s) => {
      if (!s.installed || s.ready) {
        deployStartedAt.current.delete(s.id);
        return false;
      }
      const started = deployStartedAt.current.get(s.id);
      if (started === undefined) {
        deployStartedAt.current.set(s.id, now);
        return true;
      }
      return now - started < MAX_DEPLOY_MS;
    });
    if (!stillDeploying) return;
    const id = setInterval(refetchStacks, 5000);
    return () => clearInterval(id);
  }, [data, refetchStacks]);

  const readySet = useMemo(() => {
    if (!data) return new Set<string>();
    return new Set(
      data.catalog.filter((s) => s.installed && s.ready).map((s) => s.id)
    );
  }, [data]);

  const filtered = useMemo(() => {
    if (!data) return [];
    const q = search.toLowerCase().trim();
    let list = data.catalog;
    if (category) list = list.filter((s) => s.category === category);
    if (q) list = list.filter(
      (s) => s.name.toLowerCase().includes(q) || s.description.toLowerCase().includes(q)
    );
    return list;
  }, [data, search, category]);

  const [updatingId, setUpdatingId] = useState<string | null>(null);
  const [updateErrors, setUpdateErrors] = useState<Record<string, string>>({});

  async function handleUpdate(id: string) {
    if (updatingId) return; // já tem uma atualização em voo
    setUpdatingId(id);
    setUpdateErrors((prev) => ({ ...prev, [id]: "" }));
    try {
      const res = await fetch(`/api/stacks/${id}/update`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-csrf-token": csrf },
      });
      const j = await res.json().catch(() => null);
      if (!res.ok) {
        // Prefere j.message (já traduzida pelo servidor — ver
        // src/lib/api-error.ts) a j.error (o código estável).
        setUpdateErrors((prev) => ({ ...prev, [id]: j?.message ?? j?.error ?? t.updateFailedDefault }));
        return;
      }
      refetchStacks();
    } catch (e) {
      console.error("[update]", e);
      setUpdateErrors((prev) => ({ ...prev, [id]: t.updateFailedConsole }));
    } finally {
      setUpdatingId(null);
    }
  }

  async function openInstall(id: string) {
    const stack = data?.catalog.find((s) => s.id === id);
    if (!stack) return;

    if (stack.installVia === "bash") {
      setSshHint(stack);
      return;
    }

    const fullRes = await fetch(`/api/stacks/${id}/schema`).catch(() => null);
    let full: FullStack | null = stack;
    if (fullRes?.ok) {
      const j = await fullRes.json();
      full = { ...stack, fields: j.fields, pairing: j.pairing };
    }
    if (full) setOpenStack(full);
  }

  function clearCategory() {
    router.push("/catalog");
  }

  const categoryLabel = category ? getCategoryLabel(category, locale) : null;

  return (
    <div className="space-y-6">
      <header className="space-y-1">
        <h1 className="text-2xl font-semibold flex items-center gap-2 flex-wrap">
          <Boxes className="h-6 w-6 text-primary" />
          {t.title}
          {categoryLabel && (
            <>
              <span className="text-muted-foreground/60 font-normal">·</span>
              <span className="text-coral-600 dark:text-coral-400">{categoryLabel}</span>
              <button
                onClick={clearCategory}
                className="ml-1 p-1 rounded-md hover:bg-glass-strong text-muted-foreground hover:text-foreground transition-colors"
                title={t.clearFilterTitle}
                aria-label={t.clearFilterAriaLabel}
              >
                <X className="h-4 w-4" />
              </button>
            </>
          )}
        </h1>
        <p className="text-sm text-muted-foreground">
          {categoryLabel
            ? t.stacksInCategory(filtered.length, categoryLabel)
            : t.subtitle}
        </p>
      </header>

      {data && data.portainerOnline === false && (
        <div className="flex items-start gap-2 p-3 rounded-md bg-warning-soft text-warning-foreground text-sm">
          <AlertTriangle className="h-4 w-4 shrink-0 mt-0.5" />
          <span>
            {t.portainerOffline}
          </span>
        </div>
      )}

      <SshProtectionWarning protecaoInstalada={sshProtected} />

      <div className="relative max-w-md">
        <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
        <Input
          placeholder={t.searchPlaceholder}
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="pl-9"
        />
      </div>

      {!data ? (
        <div className="text-center text-muted-foreground py-12">{t.loading}</div>
      ) : filtered.length === 0 ? (
        <div className="text-center text-muted-foreground py-12">
          {t.noStacksFound(categoryLabel)}
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          {filtered.map((s) => (
            <StackCard
              key={s.id}
              stack={s}
              readySet={readySet}
              onInstall={openInstall}
              onUpdate={handleUpdate}
              updating={updatingId === s.id}
              updateError={updateErrors[s.id]}
            />
          ))}
        </div>
      )}

      {openStack?.fields && (
        <InstallWizard
          stack={{
            id: openStack.id,
            name: openStack.name,
            description: openStack.description,
            fields: openStack.fields.map((f) => ({
              ...f,
              default: f.default ?? vpsDefaults[f.name] ?? undefined,
            })),
            pairing: openStack.pairing,
          }}
          open
          onClose={() => setOpenStack(null)}
          onInstalled={refetchStacks}
          csrfToken={csrf}
          swarmCtx={swarmCtx}
        />
      )}

      {sshHint && (
        <SshInstallHint
          stackName={sshHint.name}
          optionNumber={sshHint.optionNumber}
          open
          onClose={() => setSshHint(null)}
        />
      )}
    </div>
  );
}
