import { Router } from "express";
import { crudRouter } from "../../shared/crud.factory.js";
import { requireRolGroup } from "../../middleware/auth.js";
import * as s from "../../schemas/index.js";

const router = Router();

// ── Empleados / Usuarios ──────────────────────────────────────────
const empleadosRouter = crudRouter("empleados", {
  pkField: "id_empleado",
  searchFields: ["emp_nombres", "emp_apellidos", "emp_cedula"],
  statusField: "estado_emp",
  defaultInclude: { departamento: true, rol: true, tipo_contrato: true },
  createSchema: s.empleadoCreate,
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
});

router.use("/empleados", empleadosRouter);
router.use("/usuarios", empleadosRouter);

// ── Tipo Contrato ───────────────────────────────────────────────
router.use("/tipo-contrato", crudRouter("tipo_contrato", {
  pkField: "id_tipo_contrato",
  searchFields: ["tco_descripcion"],
}));

// ── Centros de Costo ────────────────────────────────────────────
router.use("/centros-costo", crudRouter("centros_costo", {
  pkField: "id_centro",
  searchFields: ["cco_descripcion"],
  statusField: "estado_cco",
  defaultInclude: { departamento: true },
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Conceptos Nómina ────────────────────────────────────────────
router.use("/conceptos-nomina", crudRouter("conceptos_nomina", {
  pkField: "id_concepto",
  searchFields: ["con_descripcion"],
  statusField: "estado_con",
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Rol de Pagos ────────────────────────────────────────────────
router.use("/rol-pagos", crudRouter("rol_pagos", {
  pkField: "id_rol_pago",
  defaultInclude: { empleado: true, centro: true, detalle: true },
  createSchema: s.rolPagosCreate,
  defaultOrderBy: { rpl_anio: "desc" },
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Rol Pagos Det ───────────────────────────────────────────────
router.use("/rol-pagos-det", crudRouter("rol_pagos_det", {
  compositeKey: ["id_rol_pago", "rpd_linea"],
  defaultInclude: { concepto: true },
}));

// ── Cargas Familiares ───────────────────────────────────────────
router.use("/cargas-familiares", crudRouter("cargas_familiares", {
  pkField: "id_carga",
  searchFields: ["car_apellidos", "car_nombres"],
  statusField: "estado_car",
  defaultInclude: { empleado: true },
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
  deleteMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Historial Cargo (append-only → sin DELETE) ──────────────────
router.use("/historial-cargo", crudRouter("historial_cargo", {
  pkField: "id_historial",
  defaultInclude: { empleado: true, rol_anterior: true, rol_nuevo: true },
  defaultOrderBy: { hca_fecha: "desc" },
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
}));

// ── Asistencias (append-only) ───────────────────────────────────
router.use("/asistencias", crudRouter("asistencias", {
  pkField: "id_asistencia",
  defaultInclude: { empleado: true },
  createSchema: s.asistenciaCreate,
  defaultOrderBy: { asi_fecha: "desc" },
  createMiddleware: requireRolGroup("AUXILIAR"),
  updateMiddleware: requireRolGroup("AUXILIAR"),
}));

export default router;
