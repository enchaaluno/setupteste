"use client";
import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Eye, EyeOff, CheckCircle2, Loader2, AlertCircle } from "lucide-react";
import { LicensePairing } from "./license-pairing";
import { SuportePanel } from "./suporte-panel";
import { useDict } from "@/lib/i18n/use-dict";
import { installWizardText } from "./install-wizard.i18n";

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

type PairingSpecUI = { targetField: string; sessionField: string; group?: string };

type StackMeta = {
  id: string;
  name: string;
  description: string;
  fields: Field[];
  postInstallNotes?: string[];
  pairing?: PairingSpecUI | null;
};

type Props = {
  stack: StackMeta;
  open: boolean;
  onClose: () => void;
  onInstalled?: () => void;
  csrfToken: string;
  swarmCtx: { networkName: string; serverName: string; email: string };
};

type RevealSecret = { name: string; label?: string; value: string };

type ErrorState = { kind: "error"; message: string; reason?: string; httpStatus?: number };

type InstallState =
  | { kind: "form" }
  | { kind: "installing" }
  | {
      kind: "success";
      accessUrl?: string;
      setupUrl?: string;
      notes: string[];
      revealSecrets: RevealSecret[];
      aviso?: string;
    }
  | ErrorState
  // Suporte embutido no wizard (ver suporte-panel.tsx) — `voltarPara` guarda
  // pra onde "Voltar"/"Fechar" devem devolver o usuário: o formulário (link
  // do rodapé, sem erro ainda) ou a MESMA tela de erro que o trouxe aqui
  // (botão "Falar com o suporte"), com a mensagem intacta.
  | { kind: "suporte"; contextoErro?: string; voltarPara: { kind: "form" } | ErrorState };

export function InstallWizard({ stack, open, onClose, onInstalled, csrfToken, swarmCtx }: Props) {
  const t = useDict(installWizardText);
  const [state, setState] = useState<InstallState>({ kind: "form" });
  const [showSecrets, setShowSecrets] = useState<Record<string, boolean>>({});
  const form = useForm<Record<string, unknown>>({
    defaultValues: Object.fromEntries(
      stack.fields.map((f) => [f.name, f.default ?? (f.kind === "checkbox" ? false : "")])
    ),
  });

  useEffect(() => {
    if (!open) setState({ kind: "form" });
  }, [open]);

  const groups = Array.from(new Set(stack.fields.map((f) => f.group ?? t.defaultGroup)));

  async function onSubmit(rawValues: Record<string, unknown>) {
    setState({ kind: "installing" });
    // Campos opcionais deixados em branco chegam como "" (default do form),
    // não undefined — e "" falha validação de z.string().email().optional()
    // ou z.coerce.number().optional() no schema da stack (email vira
    // "Invalid email", port vira "Number must be greater than or equal to
    // 1", mesmo sendo opcional). JSON.stringify omite chaves `undefined`,
    // então convertê-las aqui faz o campo realmente sumir do payload.
    const values = { ...rawValues };
    for (const f of stack.fields) {
      if (f.optional && values[f.name] === "") {
        values[f.name] = undefined;
      }
    }
    try {
      const res = await fetch("/api/stacks", {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-csrf-token": csrfToken },
        body: JSON.stringify({ stackId: stack.id, values, swarmCtx }),
      });
      const data = await res.json();
      if (!res.ok) {
        // reason vem de statusForCause (installer.ts) quando a falha é do
        // lado do EnchaT (chave errada, Console fora do ar, timeout) —
        // ausente só em erro de validação/dependência do próprio painel.
        // Sem isto o card mostrava só a frase crua, sem nada pra copiar
        // pro suporte ou pra bater com o que apareceu nos logs do serviço.
        // Prefere data.message (já traduzida pelo servidor — ver
        // src/lib/api-error.ts) a data.error (o código estável).
        setState({
          kind: "error",
          message: data.message ?? data.error ?? t.falhaNaInstalacao,
          reason: data.reason,
          httpStatus: res.status,
        });
        return;
      }
      setState({
        kind: "success",
        accessUrl: data.accessUrl,
        setupUrl: data.setupUrl,
        notes: data.notes ?? [],
        revealSecrets: data.revealSecrets ?? [],
        aviso: data.aviso,
      });
      onInstalled?.();
    } catch (e) {
      setState({ kind: "error", message: e instanceof Error ? e.message : "Erro de rede" });
    }
  }

  return (
    <Dialog open={open} onOpenChange={(v) => !v && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t.instalarStack(stack.name)}</DialogTitle>
          <DialogDescription>{stack.description}</DialogDescription>
        </DialogHeader>

        {state.kind === "form" && (
          <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-6">
            {groups.map((g) => (
              <div key={g} className="space-y-3">
                <div className="text-xs uppercase tracking-wide text-muted-foreground font-semibold">{g}</div>
                {stack.pairing && (stack.pairing.group ?? t.defaultGroup) === g && (
                  <LicensePairing stackId={stack.id} csrfToken={csrfToken} spec={stack.pairing} form={form} />
                )}
                {stack.fields
                  .filter((f) => (f.group ?? t.defaultGroup) === g)
                  .map((f) => {
                    const isCheckbox = f.kind === "checkbox";
                    if (isCheckbox) {
                      return (
                        <label key={f.name} className="flex items-center gap-2 cursor-pointer">
                          <input type="checkbox" {...form.register(f.name)} className="h-4 w-4 rounded border-input" />
                          <span className="text-sm">{f.label}</span>
                        </label>
                      );
                    }
                    const isPwd = f.kind === "password";
                    const show = showSecrets[f.name];
                    return (
                      <div key={f.name} className="space-y-1.5">
                        <div className="flex items-center justify-between">
                          <Label htmlFor={f.name}>
                            {f.label}
                            {f.sensitive && <Badge variant="warning" className="ml-2">{t.sensivel}</Badge>}
                          </Label>
                          {isPwd && (
                            <button
                              type="button"
                              onClick={() => setShowSecrets((s) => ({ ...s, [f.name]: !s[f.name] }))}
                              className="text-muted-foreground hover:text-foreground"
                              aria-label={show ? t.esconder : t.mostrar}
                            >
                              {show ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                            </button>
                          )}
                        </div>
                        <Input
                          id={f.name}
                          type={isPwd && !show ? "password" : f.kind === "email" ? "email" : f.kind === "port" ? "number" : "text"}
                          placeholder={f.placeholder}
                          autoComplete={isPwd ? "new-password" : "off"}
                          {...form.register(f.name)}
                        />
                        {f.helpText && <p className="text-xs text-muted-foreground">{f.helpText}</p>}
                      </div>
                    );
                  })}
              </div>
            ))}
            <div className="flex justify-end gap-2 pt-4 border-t">
              <Button type="button" variant="outline" onClick={onClose}>{t.cancelar}</Button>
              <Button type="submit">{t.instalar}</Button>
            </div>
            <button
              type="button"
              onClick={() => setState({ kind: "suporte", voltarPara: { kind: "form" } })}
              className="text-xs text-muted-foreground hover:text-foreground underline block mx-auto"
            >
              {t.ajudaAntesDeInstalar}
            </button>
          </form>
        )}

        {state.kind === "installing" && (
          <div className="py-12 flex flex-col items-center gap-3 text-center">
            <Loader2 className="h-12 w-12 animate-spin text-primary" />
            <p className="text-sm text-muted-foreground">{t.implantandoNoSwarm}</p>
          </div>
        )}

        {state.kind === "success" && (
          <div className="py-8 space-y-4 text-center">
            <CheckCircle2 className="h-14 w-14 text-emerald-400 mx-auto" />
            <h3 className="text-xl font-semibold">{t.stackImplantada}</h3>
            {state.accessUrl && (
              <a
                href={state.accessUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-block text-primary hover:underline"
              >
                {state.accessUrl}
              </a>
            )}
            {/* Link de primeiro acesso (ex.: EnchaT ?setup=<token>) — cria o
                administrador. Carrega segredo, então só vive neste useState,
                igual aos revealSecrets abaixo. */}
            {state.setupUrl && (
              <div className="max-w-md mx-auto text-left space-y-2 rounded-md border border-primary/40 bg-primary/10 p-3">
                <Label className="text-xs font-semibold">{t.linkPrimeiroAcesso}</Label>
                <div className="flex gap-2">
                  <Input
                    readOnly
                    value={state.setupUrl}
                    className="font-mono text-xs"
                    onFocus={(e) => e.currentTarget.select()}
                  />
                  <Button
                    type="button"
                    variant="outline"
                    onClick={() => navigator.clipboard.writeText(state.setupUrl!)}
                  >
                    {t.copiar}
                  </Button>
                </div>
                <p className="text-xs text-muted-foreground">{t.linkPrimeiroAcessoNota}</p>
              </div>
            )}
            {state.revealSecrets.length > 0 && (
              <div className="max-w-md mx-auto text-left space-y-2 rounded-md border border-amber-500/40 bg-amber-500/10 p-3">
                <p className="text-xs font-semibold text-amber-500">
                  {t.copiarAgoraAviso}
                </p>
                {state.revealSecrets.map((s) => (
                  <div key={s.name} className="space-y-1">
                    <Label className="text-xs">{s.label ?? s.name}</Label>
                    <div className="flex gap-2">
                      <Input readOnly value={s.value} className="font-mono text-xs" onFocus={(e) => e.currentTarget.select()} />
                      <Button
                        type="button"
                        variant="outline"
                        onClick={() => navigator.clipboard.writeText(s.value)}
                      >
                        {t.copiar}
                      </Button>
                    </div>
                  </div>
                ))}
              </div>
            )}
            {state.notes.length > 0 && (
              <ul className="text-sm text-muted-foreground space-y-1 max-w-md mx-auto text-left">
                {state.notes.map((n, i) => (
                  <li key={i}>• {n}</li>
                ))}
              </ul>
            )}
            {state.aviso && (
              <div className="max-w-md mx-auto text-left rounded-md border border-amber-500/40 bg-amber-500/10 p-3 flex gap-2">
                <AlertCircle className="h-4 w-4 shrink-0 text-amber-500 mt-0.5" />
                <p className="text-xs text-amber-500">{state.aviso}</p>
              </div>
            )}
            <div className="flex gap-2 justify-center">
              {state.accessUrl ? (
                <>
                  {/* Abre em nova aba SEM fechar o modal — os segredos acima
                      (ex.: enchat_master_key) só existem neste useState e
                      somem quando o componente desmonta; fechar junto do
                      clique destruiria o que o aviso pede pra copiar antes.
                      "Fechar" continua disponível ao lado, e Esc/clique fora/✕
                      já cobrem quem só quer sair. */}
                  <Button asChild>
                    <a href={state.accessUrl} target="_blank" rel="noopener noreferrer">
                      {t.abrirStack(stack.name)}
                    </a>
                  </Button>
                  <Button variant="outline" onClick={onClose}>{t.fechar}</Button>
                </>
              ) : (
                // 3 stacks (postgres/mysql/redis) não expõem accessUrl —
                // headless, sem porta pública. Fallback pro botão único de sempre.
                <Button onClick={onClose}>{t.fechar}</Button>
              )}
            </div>
          </div>
        )}

        {state.kind === "error" && (
          <div className="py-8 space-y-4 text-center">
            <AlertCircle className="h-14 w-14 text-destructive mx-auto" />
            <h3 className="text-xl font-semibold">{t.falhaNaInstalacao}</h3>
            <p className="text-sm text-muted-foreground">{state.message}</p>
            {state.reason && (
              <Badge variant="outline" className="font-mono text-xs">
                {state.reason}
                {state.httpStatus ? ` · HTTP ${state.httpStatus}` : ""}
              </Badge>
            )}
            <div className="flex gap-2 justify-center">
              <Button
                variant="outline"
                onClick={() =>
                  navigator.clipboard.writeText(
                    [
                      `${t.detalheStack}: ${stack.id}`,
                      `${t.detalheMensagem}: ${state.message}`,
                      state.reason ? `${t.detalheCausa}: ${state.reason}` : null,
                      state.httpStatus ? `HTTP: ${state.httpStatus}` : null,
                    ]
                      .filter(Boolean)
                      .join("\n")
                  )
                }
              >
                {t.copiarDetalhes}
              </Button>
              <Button variant="outline" onClick={() => setState({ kind: "form" })}>{t.tentarDeNovo}</Button>
              <Button
                variant="outline"
                onClick={() =>
                  setState({
                    kind: "suporte",
                    contextoErro: [
                      `${t.detalheStack}: ${stack.id}`,
                      `${t.detalheMensagem}: ${state.message}`,
                      state.reason ? `${t.detalheCausa}: ${state.reason}` : null,
                      state.httpStatus ? `HTTP: ${state.httpStatus}` : null,
                    ]
                      .filter(Boolean)
                      .join("\n"),
                    voltarPara: state,
                  })
                }
              >
                {t.falarComSuporte}
              </Button>
              <Button onClick={onClose}>{t.fechar}</Button>
            </div>
          </div>
        )}

        {state.kind === "suporte" && (
          <SuportePanel
            stackId={stack.id}
            csrfToken={csrfToken}
            contextoErro={state.contextoErro}
            onVoltar={() => setState(state.voltarPara)}
          />
        )}
      </DialogContent>
    </Dialog>
  );
}
