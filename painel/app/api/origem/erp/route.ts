import {
  CONTRATO_ORIGEM,
  extrairIdsErp,
  lerCorpoLimitado,
  lerJsonObjeto,
  lerTokenBearer,
  idsAceitaveis,
  registrarEvento,
  respostaEvento,
  statusDoRegistro,
} from "@/lib/eventos-origem";
import { lerIpCliente } from "@/lib/registro-requisicao";

// O corpo é só aviso: grava os IDs na fila e responde logo; o dado vem da API na carga seguinte.
export async function POST(request: Request) {
  const token = lerTokenBearer(request.headers.get("authorization"));
  if (!token) return respostaEvento(401);

  const idEvento = request.headers.get(CONTRATO_ORIGEM.erp.cabecalhoIdEvento);
  const tipoEvento = request.headers.get(CONTRATO_ORIGEM.erp.cabecalhoTipoEvento);
  if (!idEvento || !tipoEvento) return respostaEvento(400);

  const texto = await lerCorpoLimitado(request);
  const corpo = texto === null ? null : lerJsonObjeto(texto);
  if (!corpo) return respostaEvento(400);

  const ids = extrairIdsErp(corpo);
  if (!idsAceitaveis(ids)) return respostaEvento(400);

  try {
    const resultado = await registrarEvento({ token, origem: "erp", idEvento, tipoEvento, ids, ip: lerIpCliente(request.headers) });
    // Limite responde 429 para a origem tentar de novo; 401 fica só para token, tipo ou formato inválido.
    return respostaEvento(statusDoRegistro(resultado));
  } catch {
    // 503 faz a origem tentar de novo; a fila é idempotente pelo id do evento.
    return respostaEvento(503);
  }
}
