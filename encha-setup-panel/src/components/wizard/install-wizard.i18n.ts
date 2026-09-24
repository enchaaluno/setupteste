import type { Locale } from "@/lib/locale-shared";

export type InstallWizardText = {
  defaultGroup: string;
  instalarStack: (nome: string) => string;
  sensivel: string;
  esconder: string;
  mostrar: string;
  cancelar: string;
  instalar: string;
  ajudaAntesDeInstalar: string;
  implantandoNoSwarm: string;
  stackImplantada: string;
  copiarAgoraAviso: string;
  copiar: string;
  linkPrimeiroAcesso: string;
  linkPrimeiroAcessoNota: string;
  fechar: string;
  abrirStack: (nome: string) => string;
  falhaNaInstalacao: string;
  copiarDetalhes: string;
  tentarDeNovo: string;
  falarComSuporte: string;
  detalheStack: string;
  detalheMensagem: string;
  detalheCausa: string;
};

export const installWizardText: Record<Locale, InstallWizardText> = {
  pt: {
    defaultGroup: "Configuração",
    instalarStack: (nome) => `Instalar ${nome}`,
    sensivel: "sensível",
    esconder: "Esconder",
    mostrar: "Mostrar",
    cancelar: "Cancelar",
    instalar: "Instalar",
    ajudaAntesDeInstalar: "Precisa de ajuda antes de instalar? Fale com o suporte",
    implantandoNoSwarm: "Implantando no Swarm via Portainer API...",
    stackImplantada: "Stack implantada!",
    copiarAgoraAviso: "⚠ Copie agora — não será mostrado de novo nesta tela.",
    copiar: "Copiar",
    linkPrimeiroAcesso: "Link de primeiro acesso (criar o administrador)",
    linkPrimeiroAcessoNota:
      "Use uma vez para criar o administrador; se esta licença já tinha um administrador, o link abre o login.",
    fechar: "Fechar",
    abrirStack: (nome) => `Abrir ${nome}`,
    falhaNaInstalacao: "Falha na instalação",
    copiarDetalhes: "Copiar detalhes",
    tentarDeNovo: "Tentar de novo",
    falarComSuporte: "Falar com o suporte",
    detalheStack: "Stack",
    detalheMensagem: "Mensagem",
    detalheCausa: "Causa",
  },
  en: {
    defaultGroup: "Settings",
    instalarStack: (nome) => `Install ${nome}`,
    sensivel: "sensitive",
    esconder: "Hide",
    mostrar: "Show",
    cancelar: "Cancel",
    instalar: "Install",
    ajudaAntesDeInstalar: "Need help before installing? Talk to support",
    implantandoNoSwarm: "Deploying to Swarm via Portainer API...",
    stackImplantada: "Stack deployed!",
    copiarAgoraAviso: "⚠ Copy now — it won't be shown again on this screen.",
    copiar: "Copy",
    linkPrimeiroAcesso: "First-access link (create the administrator)",
    linkPrimeiroAcessoNota:
      "Use it once to create the administrator; if this license already had an administrator, the link opens the login page.",
    fechar: "Close",
    abrirStack: (nome) => `Open ${nome}`,
    falhaNaInstalacao: "Installation failed",
    copiarDetalhes: "Copy details",
    tentarDeNovo: "Try again",
    falarComSuporte: "Talk to support",
    detalheStack: "Stack",
    detalheMensagem: "Message",
    detalheCausa: "Cause",
  },
  es: {
    defaultGroup: "Configuración",
    instalarStack: (nome) => `Instalar ${nome}`,
    sensivel: "sensible",
    esconder: "Ocultar",
    mostrar: "Mostrar",
    cancelar: "Cancelar",
    instalar: "Instalar",
    ajudaAntesDeInstalar: "¿Necesita ayuda antes de instalar? Hable con soporte",
    implantandoNoSwarm: "Implementando en Swarm vía Portainer API...",
    stackImplantada: "¡Stack implementado!",
    copiarAgoraAviso: "⚠ Copie ahora — no se mostrará de nuevo en esta pantalla.",
    copiar: "Copiar",
    linkPrimeiroAcesso: "Enlace de primer acceso (crear el administrador)",
    linkPrimeiroAcessoNota:
      "Úselo una vez para crear el administrador; si esta licencia ya tenía un administrador, el enlace abre el inicio de sesión.",
    fechar: "Cerrar",
    abrirStack: (nome) => `Abrir ${nome}`,
    falhaNaInstalacao: "Error en la instalación",
    copiarDetalhes: "Copiar detalles",
    tentarDeNovo: "Intentar de nuevo",
    falarComSuporte: "Hablar con soporte",
    detalheStack: "Stack",
    detalheMensagem: "Mensaje",
    detalheCausa: "Causa",
  },
};
