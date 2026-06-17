import { Router } from "express";
import { crudRouter } from "../../shared/crud.factory.js";
import { requireRolGroup } from "../../middleware/auth.js";
import * as s from "../../schemas/index.js";

const router = Router();

// ── Tipo Cuenta ─────────────────────────────────────────────────
router.use("/tipo-cuenta", crudRouter("tipo_cuenta", {
  pkField: "id_tipo_cta",
  searchFields: ["tip_descripcion"],
}));

// ── Cuentas ─────────────────────────────────────────────────────
router.use("/cuentas", crudRouter("cuentas", {
  pkField: "id_cuenta",
  searchFields: ["cue_descripcion"],
  statusField: "estado_cue",
  defaultInclude: { tipo: true },
  createSchema: s.cuentaCreate,
}));

// ── Asientos ────────────────────────────────────────────────────
router.use("/asientos", crudRouter("asientos", {
  pkField: "id_asiento",
  searchFields: ["asi_descripcion"],
  defaultInclude: { ctaxasi: { include: { cuenta: true } } },
  createSchema: s.asientoCreate,
  defaultOrderBy: { asi_fecha_hora: "desc" },
}));

// ── Cuentas por Asiento (partidas) ──────────────────────────────
router.use("/ctaxasi", crudRouter("ctaxasi", {
  compositeKey: ["id_asiento", "id_cuenta"],
  defaultInclude: { cuenta: true },
}));

// ── Auditoría (solo lectura) ────────────────────────────────────
router.use("/auditoria", crudRouter("auditoria_sistema", {
  pkField: "id_auditoria",
  searchFields: ["tabla_afectada", "id_registro"],
  defaultOrderBy: { fecha_hora: "desc" },
}));

export default router;
