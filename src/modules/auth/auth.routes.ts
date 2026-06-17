import { Router, Request, Response, NextFunction } from "express";
import bcrypt from "bcryptjs";
import { prisma } from "../../shared/prisma.js";
import { authGuard, signToken } from "../../middleware/auth.js";
import { loginSchema } from "../../schemas/index.js";

const router = Router();

/**
 * POST /auth/login
 * Body: { emp_cedula, password }
 *
 * NOTA: El DDL original NO tiene campo password en empleados.
 * Para producción hay dos caminos:
 *   A) ALTER TABLE empleados ADD COLUMN emp_password_hash VARCHAR(100);
 *   B) Crear una tabla separada `auth_credentials` con FK a empleados.
 *
 * Por ahora este endpoint busca por cédula y devuelve un JWT.
 * En dev, si no hay password hash, se acepta con password === emp_cedula.
 */
router.post("/login", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { emp_cedula, password } = loginSchema.parse(req.body);

    const emp = await prisma.empleados.findUnique({
      where: { emp_cedula },
      include: { departamento: true, rol: true },
    });

    if (!emp || emp.estado_emp !== "ACT") {
      return res.status(401).json({ error: "Credenciales inválidas" });
    }

    // ── Verificar contraseña ──
    // TODO: Agregar campo emp_password_hash a empleados
    // Por ahora en dev: password === cédula
    const passwordOk =
      (emp as any).emp_password_hash
        ? await bcrypt.compare(password, (emp as any).emp_password_hash)
        : password === emp_cedula; // fallback dev

    if (!passwordOk) {
      return res.status(401).json({ error: "Credenciales inválidas" });
    }

    const token = signToken({
      sub: emp.id_empleado,
      rol: emp.id_rol,
      departamento: emp.id_departamento,
    });

    res.json({
      token,
      empleado: {
        id_empleado: emp.id_empleado,
        emp_nombres: emp.emp_nombres,
        emp_apellidos: emp.emp_apellidos,
        id_rol: emp.id_rol,
        rol_descripcion: emp.rol.rol_descripcion,
        id_departamento: emp.id_departamento,
        dep_descripcion: emp.departamento.dep_descripcion,
      },
    });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /auth/me  — devuelve el empleado autenticado
 */
router.get("/me", authGuard, async (req: Request, res: Response, next: NextFunction) => {
  try {
    const emp = await prisma.empleados.findUnique({
      where: { id_empleado: req.user!.sub },
      include: { departamento: true, rol: true, tipo_contrato: true },
    });

    if (!emp) return res.status(404).json({ error: "Empleado no encontrado" });
    res.json(emp);
  } catch (err) { next(err); }
});

export default router;
