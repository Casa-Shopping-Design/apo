import type { ClienteCarga } from "@/lib/carga-pedido";
import {
  direcoes,
  faixas,
  rotuloDirecao,
  rotuloFaixa,
  rotuloSistema,
  sistemas,
  type FiltroMonitor as Filtro,
} from "@/lib/monitor";

const classeCampo =
  "min-h-11 rounded-lg border border-borda bg-superficie px-3 text-[15px] text-texto focus-visible:border-texto";

function Campo({ id, rotulo, children }: { id: string; rotulo: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-1.5">
      <label htmlFor={id} className="text-sm font-medium">
        {rotulo}
      </label>
      {children}
    </div>
  );
}

// Formulário GET: o filtro fica na URL e a página refaz as consultas no servidor. Mudar o filtro volta para a
// primeira página, porque a chave de paginação não entra nos campos.
export function FiltroMonitor({ filtro, clientes }: { filtro: Filtro; clientes: ClienteCarga[] | null }) {
  return (
    <form method="get" action="/monitor" className="flex flex-wrap items-end gap-4">
      <Campo id="de" rotulo="De">
        <input id="de" name="de" type="date" defaultValue={filtro.de} className={classeCampo} />
      </Campo>
      <Campo id="ate" rotulo="Até">
        <input id="ate" name="ate" type="date" defaultValue={filtro.ate} className={classeCampo} />
      </Campo>
      <Campo id="sistema" rotulo="Sistema">
        <select id="sistema" name="sistema" defaultValue={filtro.sistema ?? ""} className={classeCampo}>
          <option value="">Todos</option>
          {sistemas.map((sistema) => (
            <option key={sistema} value={sistema}>
              {rotuloSistema(sistema)}
            </option>
          ))}
        </select>
      </Campo>
      <Campo id="direcao" rotulo="Direção">
        <select id="direcao" name="direcao" defaultValue={filtro.direcao ?? ""} className={classeCampo}>
          <option value="">Todas</option>
          {direcoes.map((direcao) => (
            <option key={direcao} value={direcao}>
              {rotuloDirecao(direcao)}
            </option>
          ))}
        </select>
      </Campo>
      <Campo id="faixa" rotulo="Resultado">
        <select id="faixa" name="faixa" defaultValue={filtro.faixa ?? ""} className={classeCampo}>
          <option value="">Todos</option>
          {faixas.map((faixa) => (
            <option key={faixa} value={faixa}>
              {rotuloFaixa(faixa)}
            </option>
          ))}
        </select>
      </Campo>
      {clientes && (
        <Campo id="cliente" rotulo="Cliente">
          <select id="cliente" name="cliente" defaultValue={filtro.cliente ?? ""} className={classeCampo}>
            <option value="">Todos</option>
            {clientes.map((cliente) => (
              <option key={cliente.id} value={cliente.id}>
                {cliente.razaoSocial}
              </option>
            ))}
          </select>
        </Campo>
      )}
      <button type="submit" className="min-h-11 cursor-pointer rounded-lg bg-menu px-5 text-base font-semibold text-menu-texto">
        Filtrar
      </button>
    </form>
  );
}
