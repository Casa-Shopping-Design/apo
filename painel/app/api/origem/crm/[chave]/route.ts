import {
  canonicalizar,
  extrairIdsCrm,
  lerCorpoLimitado,
  lerJsonObjeto,
  idsAceitaveis,
  registrarEvento,
  respostaEvento,
  statusDoRegistro,
  sha256Hex,
  tipoEventoCrm,
} from "@/lib/eventos-origem";
import { lerIpCliente } from "@/lib/registro-requisicao";

// O CRM não autentica o disparo nem manda id do evento: o token vem na URL e o id é o hash do corpo.
export async function POST(request: Request, contexto: { params: Promise<{ chave: string }> }) {
  const { chave } = await contexto.params;
  if (!chave) return respostaEvento(401);

  const texto = await lerCorpoLimitado(request);
  const corpo = texto === null ? null : lerJsonObjeto(texto);
  if (!corpo) return respostaEvento(400);

  const tipoEvento = tipoEventoCrm(corpo, new URL(request.url).searchParams);
  const ids = extrairIdsCrm(corpo);
  if (!tipoEvento || !idsAceitaveis(ids)) return respostaEvento(400);

  try {
    const resultado = await registrarEvento({
      token: chave,
      origem: "crm",
      idEvento: sha256Hex(canonicalizar(corpo)),
      tipoEvento,
      ids,
      ip: lerIpCliente(request.headers),
    });
    return respostaEvento(statusDoRegistro(resultado));
  } catch {
    return respostaEvento(503);
  }
}
