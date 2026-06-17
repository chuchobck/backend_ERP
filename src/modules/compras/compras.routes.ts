import { Router, Request, Response, NextFunction } from "express";
import { crudRouter, callSP } from "../../shared/crud.factory.js";
import { requireRolGroup } from "../../middleware/auth.js";
import { prisma } from "../../shared/prisma.js";
import * as s from "../../schemas/index.js";

const router = Router();

// ── Proveedores ─────────────────────────────────────────────────
router.use("/proveedores", crudRouter("proveedores", {
  pkField: "id_proveedor",
  searchFields: ["prv_nombre", "prv_ruc_ced"],
  statusField: "estado_prv",
  defaultInclude: { ciudad: true },
  createSchema: s.proveedorCreate,
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Productos ───────────────────────────────────────────────────
router.use("/productos", crudRouter("productos", {
  pkField: "id_producto",
  searchFields: ["pro_nombre", "pro_descripcion"],
  statusField: "estado_prod",
  defaultInclude: { categoria: true, um_compra: true, um_venta: true },
  createSchema: s.productoCreate,
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Proveedor ↔ Producto (N:M) ─────────────────────────────────
router.use("/proveedor-producto", crudRouter("proveedor_producto", {
  compositeKey: ["id_proveedor", "id_producto"],
  defaultInclude: { proveedor: true, producto: true },
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Compras (cabecera OC) ───────────────────────────────────────
router.use("/compras", crudRouter("compras", {
  pkField: "id_compra",
  searchFields: [],
  defaultInclude: { proveedor: true, empleado: true, proxoc: true },
  createSchema: s.compraCreate,
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Proxoc (detalle OC) ─────────────────────────────────────────
router.use("/proxoc", crudRouter("proxoc", {
  compositeKey: ["id_compra", "id_producto"],
  defaultInclude: { producto: true },
  createSchema: s.proxocCreate,
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Recepciones ─────────────────────────────────────────────────
router.use("/recepciones", crudRouter("recepciones", {
  pkField: "id_recibo",
  defaultInclude: { compra: true, proxrec: true },
  createSchema: s.recepcionCreate,
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Proxrec (detalle recepción) ─────────────────────────────────
router.use("/proxrec", crudRouter("proxrec", {
  compositeKey: ["id_recibo", "id_producto"],
  defaultInclude: { producto: true },
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Stored Procedures del módulo Compras ────────────────────────
router.post("/sp/crear-compra", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const result = await callSP("sp_crear_compra",
      req.body.p_id_compra,
      req.body.p_id_proveedor,
      req.body.p_id_empleado,
      req.body.p_id_departamento,
      req.body.p_fecha_entrega,
      req.body.p_id_descuento ?? null
    );
    res.json({ message: "Compra creada", result });
  } catch (err) { next(err); }
});

router.post("/sp/aprobar-compra", requireRolGroup("JEFE"), async (req: Request, res: Response, next: NextFunction) => {
  try {
    const result = await callSP("sp_aprobar_compra", req.body.p_id_compra);
    res.json({ message: "Compra aprobada", result });
  } catch (err) { next(err); }
});

router.post("/sp/anular-compra", requireRolGroup("JEFE"), async (req: Request, res: Response, next: NextFunction) => {
  try {
    const result = await callSP("sp_anular_compra", req.body.p_id_compra);
    res.json({ message: "Compra anulada", result });
  } catch (err) { next(err); }
});

export default router;
