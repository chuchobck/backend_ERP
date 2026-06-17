import { Router } from "express";
import { crudRouter } from "../../shared/crud.factory.js";
import { authGuard, requireRolGroup } from "../../middleware/auth.js";
import * as s from "../../schemas/index.js";

const router = Router();

router.use("/provincias", crudRouter("provincias", {
  pkField: "id_provincia",
  searchFields: ["prv_descripcion"],
  createSchema: s.provinciaCreate,
  createMiddleware: [authGuard, requireRolGroup("AUXILIAR")],
  updateMiddleware: [authGuard, requireRolGroup("AUXILIAR")],
  deleteMiddleware: [authGuard, requireRolGroup("AUXILIAR")],
}));

router.use("/ciudades", crudRouter("ciudades", {
  pkField: "id_ciudad",
  searchFields: ["ciu_descripcion"],
  defaultInclude: { provincia: true },
  createSchema: s.ciudadCreate,
  createMiddleware: [authGuard, requireRolGroup("AUXILIAR")],
  updateMiddleware: [authGuard, requireRolGroup("AUXILIAR")],
  deleteMiddleware: [authGuard, requireRolGroup("AUXILIAR")],
}));

router.use("/departamentos", crudRouter("departamentos", {
  pkField: "id_departamento",
  searchFields: ["dep_descripcion"],
  createSchema: s.departamentoCreate,
  createMiddleware: [authGuard, requireRolGroup("AUXILIAR")],
  updateMiddleware: [authGuard, requireRolGroup("AUXILIAR")],
  deleteMiddleware: [authGuard, requireRolGroup("AUXILIAR")],
}));

router.use("/roles", crudRouter("roles", {
  pkField: "id_rol",
  searchFields: ["rol_descripcion"],
  createSchema: s.rolCreate,
  createMiddleware: [authGuard, requireRolGroup("JEFE")],
  updateMiddleware: [authGuard, requireRolGroup("JEFE")],
  deleteMiddleware: [authGuard, requireRolGroup("JEFE")],
}));

router.use("/categorias", crudRouter("categorias", {
  pkField: "id_categoria",
  searchFields: ["cat_descripcion"],
  createSchema: s.categoriaCreate,
  createMiddleware: [authGuard, requireRolGroup("AUXILIAR")],
  updateMiddleware: [authGuard, requireRolGroup("AUXILIAR")],
  deleteMiddleware: [authGuard, requireRolGroup("AUXILIAR")],
}));

router.use("/unidades-medidas", crudRouter("unidades_medidas", {
  pkField: "id_unidad_medida",
  searchFields: ["um_descripcion"],
  createSchema: s.unidadMedidaCreate,
  createMiddleware: [authGuard, requireRolGroup("AUXILIAR")],
  updateMiddleware: [authGuard, requireRolGroup("AUXILIAR")],
  deleteMiddleware: [authGuard, requireRolGroup("AUXILIAR")],
}));

export default router;
