import { Request, Response, NextFunction, RequestHandler } from "express";
import * as jwt from "jsonwebtoken";
import { env } from "../config/env.js";

export interface JwtPayload {
  sub: string;          // id_empleado
  rol: string;          // id_rol
  departamento: string; // id_departamento
}

export const ROLE_GROUPS = {
  JEFE: ["R01", "R02", "R11", "R12"] as const,
  AUXILIAR: ["R04", "R10", "R14", "R20"] as const,
  OPERATIVO: ["R03", "R05", "R06", "R07", "R08", "R09", "R13", "R15", "R16", "R17", "R18", "R19"] as const,
};

export type RoleGroup = keyof typeof ROLE_GROUPS;
export type RoleId = typeof ROLE_GROUPS[RoleGroup][number];

export function requireRolGroup(group: RoleGroup) {
  return requireRol(...ROLE_GROUPS[group]);
}

declare global {
  namespace Express {
    interface Request {
      user?: JwtPayload;
    }
  }
}

export function authGuard(req: Request, res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  if (!header?.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Token requerido" });
  }
  try {
    const payload = jwt.verify(header.slice(7), env.JWT_SECRET) as JwtPayload;
    req.user = payload;
    next();
  } catch {
    return res.status(401).json({ error: "Token inválido o expirado" });
  }
}

export function requireRol(...roles: string[]) {
  return (req: Request, res: Response, next: NextFunction) => {
    if (!req.user) return res.status(401).json({ error: "No autenticado" });
    if (!roles.includes(req.user.rol)) {
      return res.status(403).json({ error: "Rol insuficiente" });
    }
    next();
  };
}

export function signToken(payload: JwtPayload): string {
  const secret = env.JWT_SECRET as string;
  return jwt.sign(payload, secret, {
    expiresIn: (env.JWT_EXPIRES_IN as string) || "30d",
  } as jwt.SignOptions);
}
