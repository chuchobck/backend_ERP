import { Router, Request, Response, NextFunction } from "express";
import { crudRouter, callSP } from "../../shared/crud.factory.js";
import { requireRolGroup } from "../../middleware/auth.js";
import { prisma } from "../../shared/prisma.js";
import * as s from "../../schemas/index.js";

const router = Router();

// ── Clientes ────────────────────────────────────────────────────
router.use("/clientes", crudRouter("clientes", {
  pkField: "id_cliente",
  searchFields: ["cli_nombre", "cli_ruc_ced"],
  statusField: "estado_cli",
  defaultInclude: { ciudad: true },
  createSchema: s.clienteCreate,
}));

// ── Vendedores ──────────────────────────────────────────────────
router.use("/vendedores", crudRouter("vendedores", {
  pkField: "id_vendedor",
  statusField: "estado_ven",
  defaultInclude: { empleado: true },
  createSchema: s.vendedorCreate,
}));

// ── Formas de Pago ──────────────────────────────────────────────
router.use("/formas-pago", crudRouter("formas_pago", {
  pkField: "id_forma_pago",
  searchFields: ["fpa_descripcion"],
}));

// ── Facturas ────────────────────────────────────────────────────
router.use("/facturas", crudRouter("facturas", {
  pkField: "id_factura",
  searchFields: ["fac_numero_sri", "fac_descripcion"],
  defaultInclude: { cliente: true, vendedor: true, forma_pago: true, detalle: true, pagos: true },
  createSchema: s.facturaCreate,
  defaultOrderBy: { fac_fecha: "desc" },
}));

// ── Factura Det ─────────────────────────────────────────────────
router.use("/factura-det", crudRouter("factura_det", {
  compositeKey: ["id_factura", "fad_linea"],
  defaultInclude: { producto: true },
  createSchema: s.facturaDetCreate,
}));

// ── Factura Pago ────────────────────────────────────────────────
router.use("/factura-pago", crudRouter("factura_pago", {
  compositeKey: ["id_factura", "id_forma_pago"],
}));

// ── Cuotas Crédito ──────────────────────────────────────────────
router.use("/cuotas-credito", crudRouter("cuotas_credito", {
  compositeKey: ["id_factura", "cuo_numero"],
}));

// ── Vista v_cuotas_mora (solo lectura) ──────────────────────────
router.get("/cuotas-mora", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const rows = await prisma.$queryRaw`
      SELECT * FROM comercial.v_cuotas_mora
      ORDER BY cuo_dias_mora DESC
      LIMIT 100
    `;
    res.json(rows);
  } catch (err) { next(err); }
});

// ── Devoluciones ────────────────────────────────────────────────
router.use("/devoluciones", crudRouter("devoluciones", {
  pkField: "id_devolucion",
  defaultInclude: { factura: true, empleado: true, detalle: true },
  createSchema: s.devolucionCreate,
}));

// ── Devolucion Det ──────────────────────────────────────────────
router.use("/devoluciones-det", crudRouter("devolucion_det", {
  compositeKey: ["id_devolucion", "dvd_linea"],
  defaultInclude: { producto: true },
}));

export default router;
