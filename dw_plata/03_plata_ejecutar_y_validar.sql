-- =====================================================================
-- 03_plata_ejecutar_y_validar.sql
-- En pgAdmin: seleccionar UNA consulta a la vez y presionar F5.
-- Requisito: bronce ya cargado (CALL bronce.sp_cargar_bronce()).
-- =====================================================================

-- (A) Ejecutar la transformación (~2-3 min; los avances salen en la pestaña "Messages")
CALL plata.sp_cargar_plata();

-- (B) Conciliación bronce vs. plata: "diferencia" debe ser igual a "en_cuarentena" (0 si todo pasó)
SELECT tabla, bronce, plata, bronce - plata AS diferencia,
       (SELECT count(*) FROM plata.cuarentena q
         WHERE q.lote_id = (SELECT max(lote_id) FROM plata.control_lote) AND q.tabla = x.tabla) AS en_cuarentena
FROM (
  SELECT 'zona' tabla, (SELECT count(*) FROM bronce.zona) bronce, (SELECT count(*) FROM plata.zona) plata UNION ALL
  SELECT 'categoria_cocina', (SELECT count(*) FROM bronce.categoria_cocina), (SELECT count(*) FROM plata.categoria_cocina) UNION ALL
  SELECT 'metodo_pago',      (SELECT count(*) FROM bronce.metodo_pago),      (SELECT count(*) FROM plata.metodo_pago) UNION ALL
  SELECT 'promocion',        (SELECT count(*) FROM bronce.promocion),        (SELECT count(*) FROM plata.promocion) UNION ALL
  SELECT 'cliente',          (SELECT count(*) FROM bronce.cliente),          (SELECT count(*) FROM plata.cliente) UNION ALL
  SELECT 'restaurante',      (SELECT count(*) FROM bronce.restaurante),      (SELECT count(*) FROM plata.restaurante) UNION ALL
  SELECT 'producto',         (SELECT count(*) FROM bronce.producto),         (SELECT count(*) FROM plata.producto) UNION ALL
  SELECT 'repartidor',       (SELECT count(*) FROM bronce.repartidor),       (SELECT count(*) FROM plata.repartidor) UNION ALL
  SELECT 'pedido',           (SELECT count(*) FROM bronce.pedido),           (SELECT count(*) FROM plata.pedido) UNION ALL
  SELECT 'detalle_pedido',   (SELECT count(*) FROM bronce.detalle_pedido),   (SELECT count(*) FROM plata.detalle_pedido) UNION ALL
  SELECT 'pago',             (SELECT count(*) FROM bronce.pago),             (SELECT count(*) FROM plata.pago) UNION ALL
  SELECT 'calificacion',     (SELECT count(*) FROM bronce.calificacion),     (SELECT count(*) FROM plata.calificacion)
) x ORDER BY bronce DESC;

-- (C) REPORTE DE CALIDAD: cada regla del EDA con cuántos registros afectó en el último lote
SELECT r.codigo, r.tipo_regla, r.tabla, r.campo, r.problema, r.accion,
       c.filas_evaluadas, c.filas_afectadas,
       round(100.0 * c.filas_afectadas / nullif(c.filas_evaluadas, 0), 2) AS pct
FROM plata.regla_calidad r
JOIN plata.control_calidad c ON c.codigo_regla = r.codigo
WHERE c.lote_id = (SELECT max(lote_id) FROM plata.control_lote)
ORDER BY r.codigo;

-- (D) Límite de atípicos calculado en cada lote (IQR)
SELECT lote_id, q1_entrega, q3_entrega, q3_entrega - q1_entrega AS iqr, limite_atipico,
       fecha_inicio, fecha_fin, estado
FROM plata.control_lote ORDER BY lote_id;

-- (E) ANTES vs. DESPUÉS en cliente (evidencia para el documento)
SELECT b.id_cliente,
       b.nombre   AS nombre_bronce,   p.nombre AS nombre_plata,
       b.email    AS email_bronce,    p.email_hash, p.dominio_email, p.email_valido,
       b.telefono AS telefono_bronce, p.telefono_hash, p.telefono_valido,
       b.genero   AS genero_bronce,   p.genero, p.genero_desc,
       b.fecha_nacimiento,            p.edad, p.rango_edad
FROM bronce.cliente b JOIN plata.cliente p USING (id_cliente)
WHERE b.nombre <> p.nombre OR b.email <> lower(b.email) OR b.telefono !~ '^3[0-9]{9}$'
   OR b.telefono IS NULL OR b.genero IS NULL OR b.fecha_nacimiento IS NULL
LIMIT 50;

-- (F) ANTES vs. DESPUÉS en comentarios
SELECT b.id_calificacion, '[' || coalesce(b.comentario, 'NULL') || ']' AS comentario_bronce,
       '[' || p.comentario || ']' AS comentario_plata, p.tiene_comentario, p.tiene_emoji
FROM bronce.calificacion b JOIN plata.calificacion p USING (id_calificacion)
WHERE b.comentario IS DISTINCT FROM p.comentario
LIMIT 50;

-- (G) Campos derivados del pedido: atípicos, abiertos y cancelados
SELECT id_pedido, fecha_hora_pedido, estado, minutos_entrega,
       es_atipico, es_abierto, es_cancelado, tiene_repartidor, tiene_promocion
FROM plata.pedido
WHERE es_atipico OR es_abierto
ORDER BY es_abierto DESC, minutos_entrega DESC
LIMIT 50;

-- (H) Resumen de banderas en pedido
SELECT count(*)                                  AS pedidos,
       count(*) FILTER (WHERE es_atipico)        AS atipicos,
       count(*) FILTER (WHERE es_abierto)        AS abiertos,
       count(*) FILTER (WHERE es_cancelado)      AS cancelados,
       count(*) FILTER (WHERE NOT tiene_repartidor) AS sin_repartidor,
       round(100.0 * count(*) FILTER (WHERE NOT tiene_promocion) / count(*), 1) AS pct_sin_promocion
FROM plata.pedido;

-- (I) Ventas reales vs. suma de todos los pagos (DER-03)
SELECT sum(monto)                       AS suma_todos_los_pagos,
       sum(monto) FILTER (WHERE es_venta) AS ventas_reales,
       sum(monto) FILTER (WHERE NOT es_venta) AS no_son_venta
FROM plata.pago;

-- (J) Cuarentena del último lote (vacía si todos los registros cumplieron)
SELECT tabla, codigo_regla, count(*) AS registros
FROM plata.cuarentena
WHERE lote_id = (SELECT max(lote_id) FROM plata.control_lote)
GROUP BY 1, 2 ORDER BY 1, 2;

-- (K) Seguridad: en plata no debe existir ninguna columna con datos personales (debe dar 0 filas)
SELECT table_name, column_name
FROM information_schema.columns
WHERE table_schema = 'plata'
  AND column_name IN ('email', 'telefono', 'direccion');

-- (L) PRUEBA DE CUARENTENA (opcional, para la sustentación)
--     Daña a propósito 2 registros EN BRONCE (no toca public), corre plata y mira qué pasa.
--   1. Dañar: un pedido con total mal calculado y una calificación con puntaje 7
UPDATE bronce.pedido       SET total = total + 1000    WHERE id_pedido = 10;
UPDATE bronce.calificacion SET puntaje_restaurante = 7 WHERE id_calificacion = 5;
--   2. Volver a correr:  CALL plata.sp_cargar_plata();
--   3. Ver la consulta (J): pedido -> NEG-01 y calificacion -> NEG-09.
--      El pedido 10 NO está en plata, y tampoco su detalle ni su pago:
SELECT (SELECT count(*) FROM plata.pedido         WHERE id_pedido = 10) AS pedido,
       (SELECT count(*) FROM plata.detalle_pedido WHERE id_pedido = 10) AS detalle,
       (SELECT count(*) FROM plata.pago           WHERE id_pedido = 10) AS pago;
--   4. Reparar bronce y volver a correr CALL plata.sp_cargar_plata(); para dejar todo limpio:
UPDATE bronce.pedido       SET total = total - 1000 WHERE id_pedido = 10;
UPDATE bronce.calificacion
   SET puntaje_restaurante = (SELECT puntaje_restaurante FROM public.calificacion WHERE id_calificacion = 5)
 WHERE id_calificacion = 5;
