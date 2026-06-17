import { Router, Request, Response, NextFunction } from "express";
import { crudRouter, callSP } from "../../shared/crud.factory.js";
import { requireRolGroup } from "../../middleware/auth.js";
import * as s from "../../schemas/index.js";

const router = Router();

// ── Bodegas ─────────────────────────────────────────────────────
router.use("/bodegas", crudRouter("bodegas", {
  pkField: "id_bodega",
  searchFields: ["bod_nombre"],
  statusField: "estado_bod",
  defaultInclude: { responsable: true },
  createSchema: s.bodegaCreate,
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Perchas ─────────────────────────────────────────────────────
router.use("/perchas", crudRouter("perchas", {
  pkField: "id_percha",
  statusField: "estado_per",
  defaultInclude: { bodega: true },
  createSchema: s.perchaCreate,
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Factor de Conversión ────────────────────────────────────────
router.use("/factor-conversion", crudRouter("factor_conversion", {
  pkField: "id_producto",
  defaultInclude: { producto: true },
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Ubicación Percha ────────────────────────────────────────────
router.use("/ubicacion-percha", crudRouter("ubicacion_percha", {
  compositeKey: ["id_producto", "id_percha"],
  defaultInclude: { producto: true, percha: true },
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Stock Bodega ───────────────────────────────────────────────
router.use("/stock-bodega", crudRouter("stock_bodega", {
  compositeKey: ["id_producto", "id_bodega"],
  defaultInclude: { producto: true, bodega: true },
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Ajustes de Inventario ───────────────────────────────────────
router.use("/ajustes", crudRouter("ajustes_inv", {
  pkField: "id_ajuste",
  defaultInclude: { bodega: true, empleado: true, detalle: true },
  createSchema: s.ajusteInvCreate,
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Ajuste Inv Det ──────────────────────────────────────────────
router.use("/ajustes-det", crudRouter("ajuste_inv_det", {
  compositeKey: ["id_ajuste", "ajd_linea"],
  defaultInclude: { producto: true },
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Entregas ───────────────────────────────────────────────────
router.use("/entregas", crudRouter("entregas", {
  pkField: "id_entrega",
  defaultInclude: { bodega: true, empleado: true, detalle: true },
  createSchema: s.entregaCreate,
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Entrega Det ─────────────────────────────────────────────────
router.use("/entregas-det", crudRouter("entrega_det", {
  compositeKey: ["id_entrega", "etd_linea"],
  defaultInclude: { producto: true },
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Movimientos Inv (ledger — solo lectura) ─────────────────────
router.use("/movimientos", crudRouter("movimientos_inv", {
  pkField: "id_movimiento",
  defaultInclude: { producto: true, bodega: true },
  defaultOrderBy: { mvi_fecha: "desc" },
}));

// ── Inventario Físico ───────────────────────────────────────────
router.use("/inventario-fisico", crudRouter("inventario_fisico", {
  pkField: "id_inv_fisico",
  defaultInclude: { bodega: true, empleado: true, detalle: true },
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Inventario Físico Det ───────────────────────────────────────
router.use("/inventario-fisico-det", crudRouter("inventario_fisico_det", {
  compositeKey: ["id_inv_fisico", "ivd_linea"],
  defaultInclude: { producto: true, percha: true },
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── SPs Inventarios ─────────────────────────────────────────────
router.post("/sp/aprobar-ajuste", requireRolGroup("JEFE"), async (req: Request, res: Response, next: NextFunction) => {
  try {
    const result = await callSP("sp_aprobar_ajuste_inv", req.body.p_id_ajuste, req.body.p_id_aprobador);
    res.json({ message: "Ajuste aprobado", result });
  } catch (err) { next(err); }
});

export default router;
