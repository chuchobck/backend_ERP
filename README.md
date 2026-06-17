# COMERCIAL API — Backend Express + Prisma + PG16

Sistema de Comercialización de Productos — JW Cóndor 2025
50 tablas | 7 módulos | CRUD genérico + SPs + Analítica

---

## 🚀 Arranque rápido

```bash
# 1. Instalar dependencias
npm install

# 2. Copiar y configurar .env
cp .env.example .env
# Editar DATABASE_URL con tu conexión a Neon o PG local

# 3. Ejecutar el DDL en tu base PostgreSQL 16
# (usa pgAdmin, psql, o HeidiSQL — ya tienes los scripts)
psql -U postgres -d comercial -f COMERCIAL_DDL_PG16.sql
psql -U postgres -d comercial -f COMERCIAL_INDEXES_PG16.sql

# 4. Generar el cliente Prisma
npx prisma generate

# 5. Arrancar en dev
npm run dev
```

> **IMPORTANTE**: Este backend asume que el DDL ya está ejecutado en PG16.
> Prisma **NO** crea las tablas — solo las mapea. El DDL es la fuente de verdad.

---

## 📁 Estructura

```
comercial-api/
├── prisma/schema.prisma          ← 50 modelos mapeados del DDL
├── src/
│   ├── index.ts                  ← Entry point
│   ├── app.ts                    ← Express app + montaje de rutas
│   ├── config/env.ts             ← Variables de entorno
│   ├── middleware/
│   │   ├── auth.ts               ← JWT guard + signToken
│   │   ├── errorHandler.ts       ← Manejo global de errores Prisma/PG
│   │   └── validate.ts           ← Middleware Zod genérico
│   ├── shared/
│   │   ├── prisma.ts             ← Singleton PrismaClient
│   │   └── crud.factory.ts       ← CRUD genérico + callSP helper
│   ├── schemas/index.ts          ← Todos los schemas Zod
│   └── modules/
│       ├── auth/                 ← Login con cédula
│       ├── core/                 ← Catálogos globales
│       ├── compras/              ← OC, proveedores, recepciones
│       ├── inventarios/          ← Bodegas, stock, ajustes, movimientos
│       ├── ventas/               ← Facturas, clientes, devoluciones
│       ├── contabilidad/         ← Asientos, cuentas, auditoría
│       ├── talento-humano/       ← Empleados, rol pagos, asistencias
│       └── reportes/             ← 4 analíticas + dashboard
```

---

## 🗺️ Mapa de Endpoints

Todos los endpoints CRUD soportan:
- `GET /`          → Lista paginada (`?page=1&limit=25&q=buscar&estado=ACT`)
- `GET /:id`       → Detalle
- `POST /`         → Crear
- `PUT /:id`       → Actualizar
- `DELETE /:id`    → Soft delete (desactiva) o hard delete

### Módulo 0 — Core
| Método | Ruta | Descripción |
|--------|------|-------------|
| CRUD | `/api/core/provincias` | Catálogo de provincias |
| CRUD | `/api/core/ciudades` | Catálogo de ciudades |
| CRUD | `/api/core/departamentos` | Departamentos internos |
| CRUD | `/api/core/roles` | Roles del personal |
| CRUD | `/api/core/categorias` | Categorías de productos |
| CRUD | `/api/core/unidades-medidas` | Unidades de medida |

### Módulo 1 — Compras
| Método | Ruta | Descripción |
|--------|------|-------------|
| CRUD | `/api/compras/proveedores` | Proveedores |
| CRUD | `/api/compras/productos` | Productos |
| CRUD | `/api/compras/proveedor-producto` | Relación N:M |
| CRUD | `/api/compras/compras` | Órdenes de Compra |
| CRUD | `/api/compras/proxoc` | Detalle de OC |
| CRUD | `/api/compras/recepciones` | Recepciones de bodega |
| CRUD | `/api/compras/proxrec` | Detalle de recepción |
| POST | `/api/compras/sp/crear-compra` | SP: crear compra |
| POST | `/api/compras/sp/aprobar-compra` | SP: aprobar compra |
| POST | `/api/compras/sp/anular-compra` | SP: anular compra |

### Módulo 2 — Inventarios
| Método | Ruta | Descripción |
|--------|------|-------------|
| CRUD | `/api/inventarios/bodegas` | Almacenes |
| CRUD | `/api/inventarios/perchas` | Perchas y niveles |
| CRUD | `/api/inventarios/factor-conversion` | Factor UM compra↔venta |
| CRUD | `/api/inventarios/ubicacion-percha` | Producto×percha |
| CRUD | `/api/inventarios/stock-bodega` | Stock materializado |
| CRUD | `/api/inventarios/ajustes` | Ajustes de inventario |
| CRUD | `/api/inventarios/ajustes-det` | Detalle ajustes |
| CRUD | `/api/inventarios/entregas` | Entregas a cliente |
| CRUD | `/api/inventarios/entregas-det` | Detalle entregas |
| CRUD | `/api/inventarios/movimientos` | Ledger (solo lectura) |
| CRUD | `/api/inventarios/inventario-fisico` | Constatación física |
| CRUD | `/api/inventarios/inventario-fisico-det` | Detalle constatación |
| POST | `/api/inventarios/sp/aprobar-ajuste` | SP: aprobar ajuste |

### Módulo 3 — Ventas
| Método | Ruta | Descripción |
|--------|------|-------------|
| CRUD | `/api/ventas/clientes` | Clientes |
| CRUD | `/api/ventas/vendedores` | Vendedores (ext. empleados) |
| CRUD | `/api/ventas/formas-pago` | Formas de pago |
| CRUD | `/api/ventas/facturas` | Facturas |
| CRUD | `/api/ventas/factura-det` | Detalle factura |
| CRUD | `/api/ventas/factura-pago` | Split payment |
| CRUD | `/api/ventas/cuotas-credito` | Cuotas de crédito |
| GET  | `/api/ventas/cuotas-mora` | Vista v_cuotas_mora |
| CRUD | `/api/ventas/devoluciones` | Devoluciones |
| CRUD | `/api/ventas/devoluciones-det` | Detalle devolución |

### Módulo 4 — Contabilidad
| Método | Ruta | Descripción |
|--------|------|-------------|
| CRUD | `/api/contabilidad/tipo-cuenta` | Tipos de cuenta |
| CRUD | `/api/contabilidad/cuentas` | Plan de cuentas |
| CRUD | `/api/contabilidad/asientos` | Asientos contables |
| CRUD | `/api/contabilidad/ctaxasi` | Partidas por asiento |
| CRUD | `/api/contabilidad/auditoria` | Log de auditoría |

### Módulo 5 — Talento Humano
| Método | Ruta | Descripción |
|--------|------|-------------|
| CRUD | `/api/th/empleados` | Empleados (base + TTHH) |
| CRUD | `/api/th/tipo-contrato` | Tipos de contrato |
| CRUD | `/api/th/centros-costo` | Centros de costo |
| CRUD | `/api/th/conceptos-nomina` | Conceptos de nómina |
| CRUD | `/api/th/rol-pagos` | Rol de pagos |
| CRUD | `/api/th/rol-pagos-det` | Detalle rol pagos |
| CRUD | `/api/th/cargas-familiares` | Cargas familiares |
| CRUD | `/api/th/historial-cargo` | Historial (append-only) |
| CRUD | `/api/th/asistencias` | Asistencias diarias |

### Módulo 6 — Reportes y Analítica
| Método | Ruta | Descripción |
|--------|------|-------------|
| GET | `/api/reportes/dashboard` | Resumen general |
| GET | `/api/reportes/top-ventas` | 📊 Barras: top por categoría |
| GET | `/api/reportes/top-vendedores` | 📊 Barras: rendimiento vendedores |
| GET | `/api/reportes/stock-distribucion` | 🥧 Pastel: stock por bodega |
| GET | `/api/reportes/flujo-caja` | 📈 Líneas: ingresos vs egresos |
| GET | `/api/reportes/densidad-regional` | 🗺️ Mapa: facturación regional |
| GET | `/api/reportes/cuotas-mora` | Cartera en mora |

---

## 🔧 SPs existentes

Los Stored Procedures que ya tienes guardados se invocan via:

```typescript
import { callSP } from "./shared/crud.factory.js";

// Ejemplo
await callSP("sp_crear_compra", id_compra, id_proveedor, ...);
```

Solo necesitas crear los endpoints POST en el módulo correspondiente
(ya hay ejemplos en `compras.routes.ts` y `inventarios.routes.ts`).

---

## 🔐 Autenticación

```bash
# Login
POST /api/auth/login
{ "emp_cedula": "1712345678", "password": "1712345678" }

# → { token: "eyJ...", empleado: { ... } }
# Usar token en Header: Authorization: Bearer <token>
```

> En dev, el password = cédula (no hay campo password en el DDL original).
> Para producción: agregar `emp_password_hash VARCHAR(100)` a empleados.

---

## ⚙️ Comandos útiles

```bash
npm run dev              # Arrancar con hot-reload (tsx watch)
npm run build            # Compilar TypeScript
npx prisma generate      # Regenerar cliente después de cambios al schema
npx prisma db pull       # Introspección desde la DB existente
npx prisma studio        # UI visual de la base
```
