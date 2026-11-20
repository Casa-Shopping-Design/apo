import "server-only";
import { redirect } from "next/navigation";
import { clienteAtual, lerClientesUsuario, nomePerfil, type ClienteUsuario } from "@/lib/cliente-ativo";
import { criarClienteServidor } from "@/lib/supabase/servidor";

export type Identidade = { usuarioId: string; perfil: string; construtora: string; clientes: ClienteUsuario[] };

// getUser valida o token no servidor do Auth; getSession só leria o cookie. A lista de clientes e qual está
// ativo vêm de app.listar_clientes_usuario, que filtra por app.tenant_atual(): o nome no menu é sempre o mesmo
// tenant das consultas, e nunca um limit 1 sem ordem.
export async function exigirIdentidade(): Promise<Identidade> {
  const supabase = await criarClienteServidor();
  const { data: dadosUsuario } = await supabase.auth.getUser();
  if (!dadosUsuario.user) redirect("/entrar");

  const { data } = await supabase.schema("app").rpc("listar_clientes_usuario");
  const clientes = lerClientesUsuario(data);
  const atual = clienteAtual(clientes);

  return {
    usuarioId: dadosUsuario.user.id,
    perfil: nomePerfil(atual?.perfil),
    construtora: atual?.razaoSocial ?? "",
    clientes,
  };
}
