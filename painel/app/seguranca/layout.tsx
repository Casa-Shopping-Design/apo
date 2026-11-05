import { redirect } from "next/navigation";
import { MolduraAcesso } from "@/componentes/MolduraAcesso";
import { registrarPaginaPainel } from "@/lib/registro-requisicao";
import { caminhosAcesso } from "@/lib/supabase/nivel-acesso";
import { criarClienteServidor } from "@/lib/supabase/servidor";

// Telas de segurança ficam fora do grupo (painel) para serem alcançáveis em aal1, mas exigem usuário entrado.
export default async function LayoutSeguranca({ children }: LayoutProps<"/seguranca">) {
  await registrarPaginaPainel();
  const supabase = await criarClienteServidor();
  const { data: dadosUsuario } = await supabase.auth.getUser();
  if (!dadosUsuario.user) redirect(caminhosAcesso.entrar);

  return (
    <MolduraAcesso nota="Diretor e financeiro confirmam a entrada com um código do aplicativo autenticador do celular, para que uma senha vazada não abra o caixa da construtora.">
      {children}
      <form action="/sair" method="post">
        <button type="submit" className="cursor-pointer text-sm text-suave underline underline-offset-4 hover:text-texto">
          Sair desta conta
        </button>
      </form>
    </MolduraAcesso>
  );
}
