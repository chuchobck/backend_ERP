-- ████████████████████████████████████████████████████████████████████████
-- ██                                                                    ██
-- ██   COMERCIAL — SCRIPT DE ÍNDICES  (PostgreSQL 16)                  ██
-- ██   Sistema de Comercialización de Productos                         ██
-- ██   JW Cóndor | diciembre 2025                                       ██
-- ██                                                                    ██
-- ████████████████████████████████████████████████████████████████████████
--
--  PREREQUISITO: COMERCIAL_DDL_PG16.sql ejecutado completamente.
--
--  DIFERENCIAS vs. versión MySQL:
--  ─────────────────────────────
--  USING BTREE → sigue siendo válido en PG (es el default)
--  COMMENT '...' en CREATE INDEX → NO existe en PG.
--    Se reemplaza por: COMMENT ON INDEX idx_name IS '...';
--
--  AGRUPACIÓN:
--    Sección 1 — Compras       (7 índices)
--    Sección 2 — Contabilidad  (2 índices)
--    Sección 3 — Inventarios  (17 índices)
--    Sección 4 — Ventas       (14 índices)
--    Sección 5 — TTHH         (14 índices)
--    Sección 6 — Auditoría     (2 índices)
--                              ──────────
--                   TOTAL      56 índices
-- ████████████████████████████████████████████████████████████████████████

SET search_path TO comercial;


-- ════════════════════════════════════════════════════════════════════════
--  SECCIÓN 1 — MÓDULO COMPRAS
-- ════════════════════════════════════════════════════════════════════════

-- IDX-C01: Proveedores por ciudad y estado
-- Req #4: proveedores de Pichincha excluyendo Machachi.
CREATE INDEX idx_prv_ciudad_estado
    ON proveedores USING BTREE (id_ciudad ASC, estado_prv ASC);
COMMENT ON INDEX idx_prv_ciudad_estado IS
    'Req Compras #4: proveedores filtrados por ciudad y estado activo/inactivo';


-- IDX-C02: Historial de OC por proveedor, estado y valor total
-- Req #10: proveedores con más órdenes, clasificados por estado y valor.
CREATE INDEX idx_oc_proveedor_estado_fecha
    ON compras USING BTREE (id_proveedor ASC, estado_oc ASC, oc_fecha DESC);
COMMENT ON INDEX idx_oc_proveedor_estado_fecha IS
    'Req Compras #10: ranking de proveedores por OC, estado y valor';


-- IDX-C03: OC por empleado y fecha
-- Req #3: solicitudes de un empleado específico en un período.
CREATE INDEX idx_oc_empleado_fecha
    ON compras USING BTREE (id_empleado ASC, oc_fecha ASC);
COMMENT ON INDEX idx_oc_empleado_fecha IS
    'Req Compras #3: OC por empleado filtradas por período de fecha';


-- IDX-C04: OC por departamento y estado
-- Req #7: comparar total OC vs presupuesto del departamento.
-- Req #8: OC abiertas con productos inactivos.
CREATE INDEX idx_oc_departamento_estado
    ON compras USING BTREE (id_departamento ASC, estado_oc ASC);
COMMENT ON INDEX idx_oc_departamento_estado IS
    'Req Compras #7 #8: OC por departamento y estado para control presupuestal';


-- IDX-C05: Detalle de OC por producto y estado
-- Req #8: OC abiertas con productos INACTIVOS.
-- Req #9: OC con listado completo de productos comprados.
CREATE INDEX idx_pxoc_producto_estado
    ON proxoc USING BTREE (id_producto ASC, estado_pxoc ASC);
COMMENT ON INDEX idx_pxoc_producto_estado IS
    'Req Compras #8 #9: detalle de OC filtrado por producto y estado';


-- IDX-C06: Recepciones pendientes de una OC
-- Req #6: OC que no han sido totalmente recibidas.
CREATE INDEX idx_rec_compra_estado
    ON recepciones USING BTREE (id_compra ASC, estado_rec ASC);
COMMENT ON INDEX idx_rec_compra_estado IS
    'Req Compras #6: recepciones por OC y estado para detectar faltantes';


-- IDX-C07: Detalle de recepción por producto
-- Req #6: cantidades pendientes de recibir por producto.
CREATE INDEX idx_pxrec_producto_estado
    ON proxrec USING BTREE (id_producto ASC, estado_pxrec ASC);
COMMENT ON INDEX idx_pxrec_producto_estado IS
    'Req Compras #6: diferencias por producto en cada recepción de bodega';


-- ════════════════════════════════════════════════════════════════════════
--  SECCIÓN 2 — MÓDULO CONTABILIDAD
-- ════════════════════════════════════════════════════════════════════════

-- IDX-CO01: Asientos por estado y fecha (diario general)
-- Req Contabilidad #1: consulta de diario general por período.
CREATE INDEX idx_asi_estado_fecha
    ON asientos USING BTREE (estado_asi ASC, asi_fecha_hora DESC);
COMMENT ON INDEX idx_asi_estado_fecha IS
    'Req Contabilidad #1: diario general por período y estado del asiento';


-- IDX-CO02: Partidas por cuenta contable
-- Req Contabilidad #2: todos los asientos que afectan una cuenta específica.
CREATE INDEX idx_cxa_cuenta_estado
    ON ctaxasi USING BTREE (id_cuenta ASC, estado_cxa ASC);
COMMENT ON INDEX idx_cxa_cuenta_estado IS
    'Req Contabilidad #2 #9-#11: movimientos de una cuenta por estado y período';


-- ════════════════════════════════════════════════════════════════════════
--  SECCIÓN 3 — MÓDULO INVENTARIOS
-- ════════════════════════════════════════════════════════════════════════

-- IDX-I01: Recorrido físico de bodega (req #7)
-- Ordena perchas A-Z, estante 1-99, nivel 1-9 para el formulario de inventario.
CREATE INDEX idx_per_bodega_ubicacion
    ON perchas USING BTREE (id_bodega ASC, per_letra ASC, per_numero ASC, per_nivel ASC);
COMMENT ON INDEX idx_per_bodega_ubicacion IS
    'Req Inv #7: recorrido de inventario ordenado por posición física en bodega';


-- IDX-I02: Todos los productos de una percha (req #2)
-- Req Inv #2: artículos por línea de producto para reorganización de bodega.
CREATE INDEX idx_ubp_percha
    ON ubicacion_percha USING BTREE (id_percha ASC);
COMMENT ON INDEX idx_ubp_percha IS
    'Req Inv #2: todos los productos ubicados en una percha específica';


-- IDX-I03: Stock completo de una bodega ordenado por cantidad
-- Req Inv #7: reporte de inventario general de una bodega.
CREATE INDEX idx_stk_bodega
    ON stock_bodega USING BTREE (id_bodega ASC, stk_cantidad ASC);
COMMENT ON INDEX idx_stk_bodega IS
    'Req Inv #7: inventario completo de una bodega ordenado por cantidad';


-- IDX-I04: Ajustes por impacto económico descendente (req #6)
-- Req Inv #6: gerencia investiga ajustes — ordenar por monto mayor a menor.
CREATE INDEX idx_aji_total_desc
    ON ajustes_inv USING BTREE (aji_total DESC);
COMMENT ON INDEX idx_aji_total_desc IS
    'Req Inv #6: ranking de ajustes por impacto económico (mayor a menor)';


-- IDX-I05: Ajustes por aprobador y fecha (req #6)
-- Req Inv #6: quién autorizó cada ajuste y en qué fecha del año en curso.
CREATE INDEX idx_aji_aprobador_fecha
    ON ajustes_inv USING BTREE (id_aprobador ASC, aji_fecha DESC);
COMMENT ON INDEX idx_aji_aprobador_fecha IS
    'Req Inv #6: quién autorizó los ajustes y cuándo — investigación gerencial';


-- IDX-I06: Ajustes abiertos por bodega (operativo)
CREATE INDEX idx_aji_bodega_estado_fecha
    ON ajustes_inv USING BTREE (id_bodega ASC, estado_aji ASC, aji_fecha DESC);
COMMENT ON INDEX idx_aji_bodega_estado_fecha IS
    'Ajustes activos por bodega ordenados cronológicamente — uso operativo diario';


-- IDX-I07: Historial de ajustes por producto (req #8 rotación)
CREATE INDEX idx_ajd_producto_estado
    ON ajuste_inv_det USING BTREE (id_producto ASC, estado_ajd ASC);
COMMENT ON INDEX idx_ajd_producto_estado IS
    'Req Inv #8: historial de ajustes por producto para análisis de rotación';


-- IDX-I08: Entregas por estado y fecha (req #3 #9)
-- Req Inv #3: artículos entregados ordenados por fecha y destinatario.
-- Req Inv #9: pedidos pendientes (estado PEN).
CREATE INDEX idx_ent_estado_fecha
    ON entregas USING BTREE (estado_ent ASC, ent_fecha DESC);
COMMENT ON INDEX idx_ent_estado_fecha IS
    'Req Inv #3 #9: entregas pendientes y recientes primero — vista operativa';


-- IDX-I09: Entregas por bodega y fecha (operativo)
CREATE INDEX idx_ent_bodega_fecha
    ON entregas USING BTREE (id_bodega ASC, ent_fecha DESC);
COMMENT ON INDEX idx_ent_bodega_fecha IS
    'Operaciones de bodega por fecha para seguimiento diario del despachador';


-- IDX-I10: Entregas por cliente y fecha (req #3)
-- Req Inv #3: historial de entregas a un cliente específico.
CREATE INDEX idx_ent_cliente_fecha
    ON entregas USING BTREE (ent_cli_ci ASC, ent_fecha DESC);
COMMENT ON INDEX idx_ent_cliente_fecha IS
    'Req Inv #3: historial de entregas por cliente y fecha cronológica';


-- IDX-I11: Detalle de entregas por producto
CREATE INDEX idx_etd_producto_estado
    ON entrega_det USING BTREE (id_producto ASC, estado_etd ASC);
COMMENT ON INDEX idx_etd_producto_estado IS
    'Historial de entregas por producto y estado para análisis de salidas';


-- IDX-I12: Líneas de entrega con diferencia (req #9)
-- Req Inv #9: pedidos con diferencia entre solicitado y entregado.
CREATE INDEX idx_etd_diferencia
    ON entrega_det USING BTREE (id_entrega ASC, etd_diferencia DESC);
COMMENT ON INDEX idx_etd_diferencia IS
    'Req Inv #9: líneas con entrega incompleta (etd_diferencia ≠ 0)';


-- IDX-I13: Rotación de inventario por producto y período (req #8)
-- Req Inv #8: ingresos, salidas y ajustes de cada producto en un período.
CREATE INDEX idx_mvi_producto_fecha
    ON movimientos_inv USING BTREE (id_producto ASC, mvi_fecha DESC);
COMMENT ON INDEX idx_mvi_producto_fecha IS
    'Req Inv #8: cantidades ingresadas/egresadas/ajustadas por producto y fecha';


-- IDX-I14: Movimientos de una bodega por tipo y fecha (req #12)
-- Req Inv #12: reporte completo de movimientos de inventario.
CREATE INDEX idx_mvi_bodega_tipo_fecha
    ON movimientos_inv USING BTREE (id_bodega ASC, mvi_tipo ASC, mvi_fecha DESC);
COMMENT ON INDEX idx_mvi_bodega_tipo_fecha IS
    'Req Inv #12: movimientos de bodega filtrados por tipo (ING/EGR/AJU/TRF) y período';


-- IDX-I15: Mermas — movimientos AJU por período (req #11)
-- Req Inv #11: reporte de mermas (mvi_tipo=AJU con mvi_cantidad < 0).
CREATE INDEX idx_mvi_tipo_fecha
    ON movimientos_inv USING BTREE (mvi_tipo ASC, mvi_fecha DESC);
COMMENT ON INDEX idx_mvi_tipo_fecha IS
    'Req Inv #11: mermas y ajustes de pérdida filtrados por tipo y período';


-- IDX-I16: Trazabilidad inversa — movimientos por documento origen
CREATE INDEX idx_mvi_referencia_origen
    ON movimientos_inv USING BTREE (id_referencia ASC, mvi_origen ASC);
COMMENT ON INDEX idx_mvi_referencia_origen IS
    'Trazabilidad: todos los movimientos generados por una OC/entrega/ajuste';


-- IDX-I17: Constataciones físicas activas por bodega (req #5 #7)
-- Req Inv #5: verificación por personas distintas a bodegueros.
-- Req Inv #7: reporte de inventario ordenado por percha.
CREATE INDEX idx_ivf_bodega_estado_fecha
    ON inventario_fisico USING BTREE (id_bodega ASC, estado_ivf ASC, ivf_fecha DESC);
COMMENT ON INDEX idx_ivf_bodega_estado_fecha IS
    'Req Inv #5 #7: constataciones activas (ABI) o recientes por bodega';


-- IDX-I18: Inventario físico ordenado por percha y producto (req #7)
-- Req Inv #7: reporte ordenado por percha → nivel → producto.
CREATE INDEX idx_ivd_percha_producto
    ON inventario_fisico_det USING BTREE (id_percha ASC, id_producto ASC);
COMMENT ON INDEX idx_ivd_percha_producto IS
    'Req Inv #7: inventario físico ordenado por percha y producto para reporte';


-- IDX-I19: Verificaciones por empleado (auditoría req #5)
-- Req Inv #5: líneas verificadas por persona distinta al bodeguero.
CREATE INDEX idx_ivd_verificador
    ON inventario_fisico_det USING BTREE (id_verificador ASC);
COMMENT ON INDEX idx_ivd_verificador IS
    'Req Inv #5: líneas verificadas por cada empleado verificador externo';


-- IDX-I20: Sobrantes y faltantes para generar ajuste posterior
CREATE INDEX idx_ivd_diferencia
    ON inventario_fisico_det USING BTREE (id_inv_fisico ASC, ivd_diferencia ASC);
COMMENT ON INDEX idx_ivd_diferencia IS
    'Detectar sobrantes (+) / faltantes (-) para generar ajuste de inventario';


-- ════════════════════════════════════════════════════════════════════════
--  SECCIÓN 4 — MÓDULO VENTAS
-- ════════════════════════════════════════════════════════════════════════

-- IDX-V01: Clientes por estado y ciudad (req #6 segmentación)
-- Req Ventas #6: cuentas por cobrar agrupadas por región y ciudad.
CREATE INDEX idx_cli_estado_ciudad
    ON clientes USING BTREE (estado_cli ASC, id_ciudad ASC);
COMMENT ON INDEX idx_cli_estado_ciudad IS
    'Req Ventas #6: segmentación de clientes por estado y ciudad para cobranza';


-- IDX-V02: Auditoría de RUC/cédula por tipo (req #1)
-- Req Ventas #1: detectar clientes sin RUC o con formato incorrecto.
CREATE INDEX idx_cli_ruc_tipo
    ON clientes USING BTREE (cli_tipo ASC, cli_ruc_ced ASC);
COMMENT ON INDEX idx_cli_ruc_tipo IS
    'Req Ventas #1: auditoría de RUC/cédula por tipo de cliente (JUR/NAT)';


-- IDX-V03: Facturas por cliente y estado (req #2 #8)
-- Req Ventas #2: 10 mejores clientes por monto de compras.
-- Req Ventas #8: facturas APR de clientes INACTIVOS.
CREATE INDEX idx_fac_cliente_estado
    ON facturas USING BTREE (id_cliente ASC, estado_fac ASC);
COMMENT ON INDEX idx_fac_cliente_estado IS
    'Req Ventas #2 #8: facturas por cliente; detecta clientes INA con facturas APR';


-- IDX-V04: Facturas por estado y fecha (req #9)
-- Req Ventas #9: listado de facturas ordenadas por estado.
CREATE INDEX idx_fac_estado_fecha
    ON facturas USING BTREE (estado_fac ASC, fac_fecha DESC);
COMMENT ON INDEX idx_fac_estado_fecha IS
    'Req Ventas #9: facturas ordenadas por estado y fecha cronológica';


-- IDX-V05: Comisiones de vendedores por período
-- Cálculo de comisiones al cierre mensual (% fijo sobre venta neta).
CREATE INDEX idx_fac_vendedor_fecha
    ON facturas USING BTREE (id_vendedor ASC, fac_fecha DESC);
COMMENT ON INDEX idx_fac_vendedor_fecha IS
    'Cálculo de comisiones: facturas por vendedor y período mensual';


-- IDX-V06: Flujo de caja proyectado por forma de pago (req #7)
-- Req Ventas #7: valores a recibir en los próximos 6 meses.
CREATE INDEX idx_fac_fecha_forma_estado
    ON facturas USING BTREE (fac_fecha ASC, id_forma_pago ASC, estado_fac ASC);
COMMENT ON INDEX idx_fac_fecha_forma_estado IS
    'Req Ventas #7: proyección de cobros por forma de pago y fecha';


-- IDX-V07: Artículos menos vendidos (req #4)
-- Req Ventas #4: productos con menor volumen de ventas (SUM de fad_cantidad).
CREATE INDEX idx_fad_producto_estado
    ON factura_det USING BTREE (id_producto ASC, estado_fad ASC);
COMMENT ON INDEX idx_fad_producto_estado IS
    'Req Ventas #4: ranking de artículos por volumen de ventas (menos vendidos)';


-- IDX-V08: Cruce ventas vs devoluciones por factura/producto (req #5)
-- Req Ventas #5: ventas efectivas = factura_det − devolucion_det.
CREATE INDEX idx_fad_factura_producto
    ON factura_det USING BTREE (id_factura ASC, id_producto ASC);
COMMENT ON INDEX idx_fad_factura_producto IS
    'Req Ventas #5: cruce ventas/devoluciones por factura y producto';


-- IDX-V09: Cartera por cobrar ordenada por vencimiento (req #6)
-- Req Ventas #6: cuotas PEN ordenadas por fecha de vencimiento.
CREATE INDEX idx_cuo_estado_vencimiento
    ON cuotas_credito USING BTREE (estado_cuo ASC, cuo_fecha_vence ASC);
COMMENT ON INDEX idx_cuo_estado_vencimiento IS
    'Req Ventas #6: cartera por cobrar ordenada por fecha de vencimiento';


-- IDX-V10: Proyección de cobros por factura y período (req #7)
-- Req Ventas #7: flujo de caja 6 meses — cuotas PEN agrupadas por mes.
-- NOTA: usar v_cuotas_mora para calcular cuo_dias_mora en los reportes.
CREATE INDEX idx_cuo_factura_estado_fecha
    ON cuotas_credito USING BTREE (id_factura ASC, estado_cuo ASC, cuo_fecha_vence ASC);
COMMENT ON INDEX idx_cuo_factura_estado_fecha IS
    'Req Ventas #7: proyección de cobros por factura y período mensual';


-- IDX-V11: Clientes que más tardan en pagar (req #3)
-- Req Ventas #3: 10 mejores clientes por tiempo de pago.
-- NOTA: cuo_dias_mora está en la VISTA v_cuotas_mora; este índice
-- acelera el filtro por estado y vencimiento para derivar la mora.
CREATE INDEX idx_cuo_vencimiento_estado
    ON cuotas_credito USING BTREE (cuo_fecha_vence ASC, estado_cuo ASC);
COMMENT ON INDEX idx_cuo_vencimiento_estado IS
    'Req Ventas #3: base para calcular mora desde v_cuotas_mora (días de retraso)';


-- IDX-V12: Devoluciones por factura, estado y fecha (req #5)
-- Req Ventas #5: cruzar ventas con devoluciones en fechas subsiguientes.
CREATE INDEX idx_dev_factura_estado_fecha
    ON devoluciones USING BTREE (id_factura ASC, estado_dev ASC, dev_fecha ASC);
COMMENT ON INDEX idx_dev_factura_estado_fecha IS
    'Req Ventas #5: devoluciones por factura y fecha para cruce con ventas';


-- IDX-V13: Devoluciones por estado y fecha (operativo)
CREATE INDEX idx_dev_estado_fecha
    ON devoluciones USING BTREE (estado_dev ASC, dev_fecha DESC);
COMMENT ON INDEX idx_dev_estado_fecha IS
    'Listado operativo de devoluciones recientes ordenadas por estado';


-- IDX-V14: Devoluciones por producto (req #5 ventas netas)
-- Req Ventas #5: historial de devoluciones para calcular ventas netas por producto.
CREATE INDEX idx_dvd_producto
    ON devolucion_det USING BTREE (id_producto ASC);
COMMENT ON INDEX idx_dvd_producto IS
    'Req Ventas #5: devoluciones por producto para calcular ventas netas';


-- ════════════════════════════════════════════════════════════════════════
--  SECCIÓN 5 — MÓDULO TALENTO HUMANO
-- ════════════════════════════════════════════════════════════════════════

-- IDX-TH01: Empleados por departamento con su jefe (req #2)
-- Req TTHH #2: listado por departamento indicando quién es el responsable.
CREATE INDEX idx_emp_dpto_jefe
    ON empleados USING BTREE (id_departamento ASC, id_jefe ASC, estado_emp ASC);
COMMENT ON INDEX idx_emp_dpto_jefe IS
    'Req TTHH #2: listado de empleados por departamento con jefe responsable';


-- IDX-TH02: Sueldo mínimo, máximo y promedio por departamento (req #3)
-- Req TTHH #3: MIN/MAX/AVG sueldo agrupado por departamento.
CREATE INDEX idx_emp_dpto_sueldo
    ON empleados USING BTREE (id_departamento ASC, emp_sueldo ASC);
COMMENT ON INDEX idx_emp_dpto_sueldo IS
    'Req TTHH #3: MIN/MAX/AVG de sueldo por departamento';


-- IDX-TH03: Empleados por sexo y fecha nacimiento (req #4)
-- Req TTHH #4: niños para el Día del Niño — hijos por ciudad y sexo.
CREATE INDEX idx_emp_ciudad_sexo_nacimiento
    ON empleados USING BTREE (id_departamento ASC, emp_sexo ASC, emp_fecha_nacimiento ASC);
COMMENT ON INDEX idx_emp_ciudad_sexo_nacimiento IS
    'Req TTHH #4: eventos por ciudad/sexo — empleados con hijos menores';


-- IDX-TH04: Centros de costo de un departamento
CREATE INDEX idx_cco_departamento
    ON centros_costo USING BTREE (id_departamento ASC, estado_cco ASC);
COMMENT ON INDEX idx_cco_departamento IS
    'Todos los centros de costo activos de un departamento';


-- IDX-TH05: Historial de pagos por empleado y estado (req #8 #10)
-- Req TTHH #8/#10: pagos de empleados activos/inactivos en depts activos.
CREATE INDEX idx_rpl_empleado_estado_fecha
    ON rol_pagos USING BTREE (id_empleado ASC, estado_rpl ASC, rpl_fecha_pago DESC);
COMMENT ON INDEX idx_rpl_empleado_estado_fecha IS
    'Req TTHH #8 #10: historial de pagos por empleado ordenado por fecha';


-- IDX-TH06: Cierre de nómina por período
CREATE INDEX idx_rpl_anio_mes_estado
    ON rol_pagos USING BTREE (rpl_anio ASC, rpl_mes ASC, estado_rpl ASC);
COMMENT ON INDEX idx_rpl_anio_mes_estado IS
    'Cierre de nómina: todos los roles de un período y su estado (ABI/APR/ANU)';


-- IDX-TH07: Nómina por centro de costo y período (req #6)
-- Req TTHH #6: sueldo bruto y beneficios agrupados por cargo/centro.
CREATE INDEX idx_rpl_centro_periodo
    ON rol_pagos USING BTREE (id_centro ASC, rpl_anio ASC, rpl_mes ASC);
COMMENT ON INDEX idx_rpl_centro_periodo IS
    'Req TTHH #6: nómina agrupada por centro de costo y período mensual';


-- IDX-TH08: Detalle de rol por tipo ING/DES (req #9)
-- Req TTHH #9: separar bonificaciones y descuentos en columnas separadas.
CREATE INDEX idx_rpd_tipo_concepto
    ON rol_pagos_det USING BTREE (id_rol_pago ASC, rpd_tipo ASC, id_concepto ASC);
COMMENT ON INDEX idx_rpd_tipo_concepto IS
    'Req TTHH #9: agrupar ING/DES por rol para desglose en columnas separadas';


-- IDX-TH09: Cargas familiares por parentesco y edad (req #1)
-- Req TTHH #1: hijos menores de edad para regalo navideño.
CREATE INDEX idx_car_empleado_parentesco_nacimiento
    ON cargas_familiares USING BTREE (id_empleado ASC, car_parentesco ASC, car_fecha_nacimiento ASC);
COMMENT ON INDEX idx_car_empleado_parentesco_nacimiento IS
    'Req TTHH #1: cargas por parentesco y fecha nacimiento (menores para regalo)';


-- IDX-TH10: Hijos clasificados por sexo para eventos (req #4)
-- Req TTHH #4: Día del Niño — número de niños por ciudad y sexo.
CREATE INDEX idx_car_parentesco_sexo_estado
    ON cargas_familiares USING BTREE (car_parentesco ASC, car_sexo ASC, estado_car ASC);
COMMENT ON INDEX idx_car_parentesco_sexo_estado IS
    'Req TTHH #4: hijos clasificados por sexo para eventos del Día del Niño';


-- IDX-TH11: Trayectoria profesional del empleado (req crecimiento)
-- Req PDF Sección 6: historial de cargos, traslados, ascensos, aumentos.
CREATE INDEX idx_hca_empleado_fecha
    ON historial_cargo USING BTREE (id_empleado ASC, hca_fecha DESC);
COMMENT ON INDEX idx_hca_empleado_fecha IS
    'Crecimiento profesional del empleado ordenado cronológicamente';


-- IDX-TH12: Movilidad organizacional por tipo y período
CREATE INDEX idx_hca_tipo_fecha
    ON historial_cargo USING BTREE (hca_tipo ASC, hca_fecha DESC);
COMMENT ON INDEX idx_hca_tipo_fecha IS
    'Análisis de movilidad: cuántos ascensos, traslados, aumentos en un período';


-- IDX-TH13: Inasistencias por empleado (req #7)
-- Req TTHH #7: listado del mes en curso — fecha y tipo de inasistencia.
CREATE INDEX idx_asi_empleado_tipo_fecha
    ON asistencias USING BTREE (id_empleado ASC, asi_tipo ASC, asi_fecha DESC);
COMMENT ON INDEX idx_asi_empleado_tipo_fecha IS
    'Req TTHH #7: inasistencias por empleado filtradas por tipo y mes';


-- IDX-TH14: Faltas del mes para ranking de mayor a menor (req #7)
-- Req TTHH #7: faltas injustificadas — ordenar de mayor a menor número de faltas.
CREATE INDEX idx_asi_fecha_tipo_justificada
    ON asistencias USING BTREE (asi_fecha DESC, asi_tipo ASC, asi_justificada ASC);
COMMENT ON INDEX idx_asi_fecha_tipo_justificada IS
    'Req TTHH #7: todas las faltas del mes para construir ranking descendente';


-- ════════════════════════════════════════════════════════════════════════
--  SECCIÓN 6 — INFRAESTRUCTURA DE AUDITORÍA
-- ════════════════════════════════════════════════════════════════════════

-- IDX-AUD01: Auditoría por tabla y fecha
-- Historial completo de cambios sobre una tabla en un período específico.
CREATE INDEX idx_aud_tabla_fecha
    ON auditoria_sistema USING BTREE (tabla_afectada ASC, fecha_hora DESC);
COMMENT ON INDEX idx_aud_tabla_fecha IS
    'Historial de cambios de una tabla en un período — soporte para auditorías';


-- IDX-AUD02: Auditoría por usuario y operación
-- Rastrear todas las operaciones DML de un usuario de BD específico.
CREATE INDEX idx_aud_usuario_operacion_fecha
    ON auditoria_sistema USING BTREE (usuario_db ASC, operacion ASC, fecha_hora DESC);
COMMENT ON INDEX idx_aud_usuario_operacion_fecha IS
    'Trazabilidad: todas las operaciones (INSERT/UPDATE/DELETE) de un usuario de BD';


-- ████████████████████████████████████████████████████████████████████████
--  FIN DEL SCRIPT DE ÍNDICES — PostgreSQL 16
-- ────────────────────────────────────────────────────────────────────────
--  RESUMEN:
--    Sección 1 — Compras        :  7 índices
--    Sección 2 — Contabilidad   :  2 índices
--    Sección 3 — Inventarios    : 17 índices
--    Sección 4 — Ventas         : 14 índices
--    Sección 5 — TTHH           : 14 índices
--    Sección 6 — Auditoría      :  2 índices
--                               ─────────────
--                     TOTAL     : 56 índices
--
--  Cada índice incluye su COMMENT ON INDEX con el requerimiento cubierto.
-- ████████████████████████████████████████████████████████████████████████
