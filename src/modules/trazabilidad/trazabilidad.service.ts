/**
 * ═══════════════════════════════════════════════════════════════
 *  trazabilidad.service.ts
 *  Registra eventos en la cadena y consulta/verifica integridad.
 *  El ENCADENAMIENTO de hashes lo hace PostgreSQL (trigger), aquí
 *  solo insertamos los datos del bloque + la huella del terminal.
 *
 *  Usa SQL crudo (la tabla trazabilidad_cadena no está en el schema
 *  Prisma, así no te obliga a regenerar el cliente).
 * ═══════════════════════════════════════════════════════════════
 */
import { prisma } from "../../shared/prisma.js";

export type TipoEvento =
  | "REGISTRO" | "COMPRA" | "INGRESO" | "EGRESO"
  | "AJUSTE" | "VENTA" | "DEVOLUCION" | "TRANSFER";

export interface EventoInput {
  id_producto: string;
  tipo_evento: TipoEvento;
  id_referencia?: string | null;
  id_proveedor?: string | null;
  id_bodega?: string | null;
  cantidad?: number | null;
  costo_unit?: number | null;
  datos?: Record<string, unknown>;
  id_empleado?: string | null;
  machine: { hash: string; os: string };
}

/** Inserta un bloque. El trigger calcula secuencia + hash_anterior + hash_actual. */
export async function registrarEvento(ev: EventoInput) {
  // Si es COMPRA y viene proveedor, adjuntamos su huella (prv_hash)
  let hashProveedor: string | null = null;
  if (ev.id_proveedor) {
    const rows = await prisma.$queryRawUnsafe<{ prv_hash: string }[]>(
      `SELECT prv_hash FROM comercial.proveedores WHERE id_proveedor = $1`,
      ev.id_proveedor
    );
    hashProveedor = rows[0]?.prv_hash ?? null;
  }

  const rows = await prisma.$queryRawUnsafe<
    { id_evento: bigint; secuencia: number; hash_actual: string; hash_anterior: string }[]
  >(
    `INSERT INTO comercial.trazabilidad_cadena
       (id_producto, tipo_evento, id_referencia, id_proveedor, hash_proveedor,
        id_bodega, cantidad, costo_unit, datos, id_empleado, hash_maquina, so_terminal,
        secuencia, hash_actual)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb,$10,$11,$12, 0, '')
     RETURNING id_evento, secuencia, hash_actual, hash_anterior`,
    ev.id_producto,
    ev.tipo_evento,
    ev.id_referencia ?? null,
    ev.id_proveedor ?? null,
    hashProveedor,
    ev.id_bodega ?? null,
    ev.cantidad ?? null,
    ev.costo_unit ?? null,
    JSON.stringify(ev.datos ?? {}),
    ev.id_empleado ?? null,
    ev.machine.hash,
    ev.machine.os
  );

  const r = rows[0];
  return {
    id_evento: Number(r.id_evento),
    secuencia: r.secuencia,
    hash_actual: r.hash_actual,
    hash_anterior: r.hash_anterior,
  };
}

/** Registra el mismo tipo de evento para varios productos (ej. líneas de una venta). */
export async function registrarLote(eventos: EventoInput[]) {
  const out = [];
  for (const ev of eventos) out.push(await registrarEvento(ev));
  return out;
}

/** Cadena completa de un producto (para mostrar la línea de tiempo). */
export async function getCadena(id_producto: string) {
  return prisma.$queryRawUnsafe(
    `SELECT t.id_evento, t.secuencia, t.tipo_evento, t.id_referencia,
            t.id_proveedor, pv.prv_nombre, t.hash_proveedor,
            t.id_bodega, t.cantidad, t.costo_unit, t.datos,
            t.id_empleado, t.hash_maquina, t.so_terminal, t.evento_ts,
            t.hash_anterior, t.hash_actual
     FROM comercial.trazabilidad_cadena t
     LEFT JOIN comercial.proveedores pv ON pv.id_proveedor = t.id_proveedor
     WHERE t.id_producto = $1
     ORDER BY t.secuencia ASC`,
    id_producto
  );
}

/** Verifica la integridad de la cadena de un producto. */
export async function verificar(id_producto: string) {
  const rows = await prisma.$queryRawUnsafe<
    { hash_valido: boolean; encadenado_ok: boolean }[]
  >(`SELECT * FROM comercial.fn_verificar_trazabilidad($1)`, id_producto);

  const total = rows.length;
  const rotos = rows.filter((r) => !r.hash_valido || !r.encadenado_ok);
  return {
    id_producto,
    total_bloques: total,
    integra: rotos.length === 0 && total > 0,
    bloques_alterados: rotos.length,
    detalle: rows,
  };
}

/** Trazabilidad por proveedor: qué productos se le compraron. */
export async function porProveedor(id_proveedor: string) {
  return prisma.$queryRawUnsafe(
    `SELECT * FROM comercial.v_trazabilidad_proveedor
     WHERE id_proveedor = $1 ORDER BY evento_ts DESC LIMIT 500`,
    id_proveedor
  );
}
