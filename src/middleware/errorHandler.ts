import { Request, Response, NextFunction } from "express";
import { Prisma } from "@prisma/client";

export function errorHandler(err: any, _req: Request, res: Response, _next: NextFunction) {
  console.error("❌", err);

  // Prisma: registro no encontrado
  if (err instanceof Prisma.PrismaClientKnownRequestError) {
    if (err.code === "P2025") {
      return res.status(404).json({ error: "Registro no encontrado", code: err.code });
    }
    if (err.code === "P2002") {
      return res.status(409).json({
        error: "Registro duplicado (constraint UNIQUE)",
        code: err.code,
        fields: (err.meta as any)?.target,
      });
    }
    if (err.code === "P2003") {
      return res.status(400).json({
        error: "Violación de FK — el registro referenciado no existe",
        code: err.code,
        field: (err.meta as any)?.field_name,
      });
    }
    return res.status(400).json({ error: err.message, code: err.code });
  }

  // Prisma: error de validación
  if (err instanceof Prisma.PrismaClientValidationError) {
    return res.status(400).json({ error: "Datos inválidos para el modelo", detail: err.message.slice(0, 300) });
  }

  // Error genérico de PG (ej: CHECK constraint, RAISE EXCEPTION desde SP)
  if (err?.code && typeof err.code === "string" && err.code.length === 5) {
    return res.status(400).json({
      error: err.message ?? "Error de base de datos",
      pgCode: err.code,
    });
  }

  res.status(500).json({ error: "Error interno del servidor" });
}
