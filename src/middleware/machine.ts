import { Request, Response, NextFunction } from "express";
import { createHash } from "crypto";

declare global {
  namespace Express {
    interface Request {
      machine?: { hash: string; os: string };
    }
  }
}

/**
 * Lee la huella del terminal que el cliente envía por headers:
 *   X-Machine-Hash : SHA-256 del fingerprint del equipo (generado en el navegador)
 *   X-Machine-OS   : sistema operativo legible (ej. "Windows 10", "Ubuntu")
 *
 * Si no llega (ej. llamadas server-to-server), genera una huella de respaldo
 * a partir de la IP + user-agent para que el campo nunca quede vacío.
 */
export function machineContext(req: Request, _res: Response, next: NextFunction) {
  const headerHash = (req.headers["x-machine-hash"] as string)?.trim();
  const headerOs = (req.headers["x-machine-os"] as string)?.trim();

  if (headerHash && headerHash.length === 64) {
    req.machine = { hash: headerHash, os: headerOs || "desconocido" };
  } else {
    const raw = `${req.ip || "0.0.0.0"}|${req.headers["user-agent"] || "server"}`;
    req.machine = {
      hash: createHash("sha256").update("fallback|" + raw).digest("hex"),
      os: headerOs || "servidor",
    };
  }
  next();
}
