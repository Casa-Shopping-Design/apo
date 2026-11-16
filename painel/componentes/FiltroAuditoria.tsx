import type { ClienteCarga } from "@/lib/carga-pedido";
import { eventosTrilha, rotuloEvento, type FiltroAuditoria as Filtro, type Pessoa } from "@/lib/trilha-auditoria";

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

// Dois formulários: o do filtro é GET e deixa tudo na URL; o da exportação é POST, porque exportar grava um
// evento na trilha, e leva o filtro que está na tela em campos ocultos.
export function FiltroAuditoria({
  filtro,
  pessoas,
  clientes,
}: {
  filtro: Filtro;
  pessoas: Pessoa[] | null;
  clientes: ClienteCarga[] | null;
}) {
  return (
    <div className="flex flex-wrap items-end gap-4">
      <form method="get" action="/auditoria" className="flex flex-wrap items-end gap-4">
        <Campo id="de" rotulo="De">
          <input id="de" name="de" type="date" defaultValue={filtro.de} className={classeCampo} />
        </Campo>
        <Campo id="ate" rotulo="Até">
          <input id="ate" name="ate" type="date" defaultValue={filtro.ate} className={classeCampo} />
        </Campo>
        <Campo id="evento" rotulo="Evento">
          <select id="evento" name="evento" defaultValue={filtro.evento ?? ""} className={classeCampo}>
            <option value="">Todos</option>
            {eventosTrilha.map((evento) => (
              <option key={evento} value={evento}>
                {rotuloEvento(evento)}
              </option>
            ))}
          </select>
        </Campo>
        {pessoas && pessoas.length > 0 && (
          <Campo id="pessoa" rotulo="Pessoa">
            <select id="pessoa" name="pessoa" defaultValue={filtro.pessoa ?? ""} className={classeCampo}>
              <option value="">Todas</option>
              {pessoas.map((pessoa) => (
                <option key={pessoa.id} value={pessoa.id}>
                  {pessoa.email}
                </option>
              ))}
            </select>
          </Campo>
        )}
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
      <form method="post" action="/auditoria/exportar">
        <input type="hidden" name="de" value={filtro.de} />
        <input type="hidden" name="ate" value={filtro.ate} />
        {filtro.evento && <input type="hidden" name="evento" value={filtro.evento} />}
        {filtro.pessoa && <input type="hidden" name="pessoa" value={filtro.pessoa} />}
        {filtro.cliente && <input type="hidden" name="cliente" value={filtro.cliente} />}
        <button
          type="submit"
          className="min-h-11 cursor-pointer rounded-lg border border-borda px-5 text-[15px] font-semibold hover:border-texto"
        >
          Exportar CSV
        </button>
      </form>
    </div>
  );
}
