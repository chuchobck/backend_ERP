-- 1️⃣ Crear usuarios
CREATE USER jefe_compras WITH PASSWORD 'Jefe2025#';
CREATE USER auxiliar_compras WITH PASSWORD 'Auxiliar2025#';
CREATE USER operativo_compras WITH PASSWORD 'Operativo2025#';

-- 2️⃣ Permisos de ejecución sobre los procedimientos
GRANT EXECUTE ON PROCEDURE comercial.sp_visualizar_compra(character, refcursor, refcursor) TO jefe_compras, auxiliar_compras, operativo_compras;
GRANT EXECUTE ON PROCEDURE comercial.sp_anular_compra(character, character, character varying) TO jefe_compras;
GRANT EXECUTE ON PROCEDURE comercial.sp_aprobar_compra(character, character, character, character, character, character) TO jefe_compras;
GRANT EXECUTE ON PROCEDURE comercial.sp_crear_compra(character, character, character, date, character, json) TO auxiliar_compras;

-- 3️⃣ Permisos SELECT sobre las tablas usadas en sp_visualizar_compra (y demás SP)
GRANT SELECT ON comercial.compras, comercial.proveedores, comercial.empleados, 
            comercial.departamentos, comercial.th_descuentos, comercial.proxoc,
            comercial.productos, comercial.unidades_medidas
TO jefe_compras, auxiliar_compras, operativo_compras;

