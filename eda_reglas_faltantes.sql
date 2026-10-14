-- =====================================================================
-- eda_reglas_faltantes.sql
-- EDA sobre la capa BRONCE: las 10 reglas que faltaban en la tabla.
-- Cada regla tiene (a) un CONTEO para el documento y (b) una MUESTRA de
-- los registros que la incumplen / necesitan la corrección.
-- Solo hace SELECT: no modifica nada.
-- En pgAdmin: seleccionar una consulta a la vez y F5.
-- =====================================================================


-- ---------------------------------------------------------------------
-- R1. PAGOS: solo los aprobados cuentan como venta
--     Hallazgo: hay pagos rechazados, reembolsados y anulados que
--     inflarían las ventas si se suman.
-- ---------------------------------------------------------------------
-- (a) Conteo por estado
SELECT estado,
       count(*)                                         AS pagos,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct,
       sum(monto)                                       AS monto_total
FROM bronce.pago
GROUP BY estado
ORDER BY pagos DESC;

-- (b) Cuánto se inflarían las ventas si se suman todos los pagos
SELECT sum(monto)                                    AS suma_todos_los_pagos,
       sum(monto) FILTER (WHERE estado = 'aprobado') AS ventas_reales,
       sum(monto) FILTER (WHERE estado <> 'aprobado') AS sobrestimacion
FROM bronce.pago;


-- ---------------------------------------------------------------------
-- R2. COMENTARIO con emojis
-- ---------------------------------------------------------------------
-- (a) Conteo
SELECT count(*) FILTER (WHERE comentario ~ '[\U0001F300-\U0001FAFF☀-➿]') AS con_emoji,
       count(*) FILTER (WHERE comentario IS NOT NULL)                              AS con_comentario,
       round(100.0 * count(*) FILTER (WHERE comentario ~ '[\U0001F300-\U0001FAFF☀-➿]')
             / count(*) FILTER (WHERE comentario IS NOT NULL), 2)                  AS pct
FROM bronce.calificacion;

-- (b) Muestra: original vs. limpio
SELECT id_calificacion,
       '[' || comentario || ']' AS original,
       '[' || btrim(regexp_replace(comentario, '[\U0001F300-\U0001FAFF☀-➿️]', '', 'g')) || ']' AS limpio
FROM bronce.calificacion
WHERE comentario ~ '[\U0001F300-\U0001FAFF☀-➿]'
LIMIT 20;


-- ---------------------------------------------------------------------
-- R3. DIRECCIÓN: dato personal sin uso analítico -> se excluye
-- ---------------------------------------------------------------------
SELECT 'cliente' AS tabla, count(*) AS registros, count(direccion) AS con_direccion FROM bronce.cliente
UNION ALL
SELECT 'restaurante', count(*), count(direccion) FROM bronce.restaurante;


-- ---------------------------------------------------------------------
-- R4. MINUTOS DE ENTREGA: no existe en la fuente -> se deriva
--     (base para la regla de atípicos por IQR)
-- ---------------------------------------------------------------------
-- (a) Por estado: solo los entregados pueden tener tiempo de entrega
SELECT estado, count(*) AS pedidos, count(fecha_hora_entrega) AS con_fecha_entrega
FROM bronce.pedido
GROUP BY estado
ORDER BY pedidos DESC;

-- (b) Estadísticos del tiempo derivado (pedidos entregados)
SELECT count(*)                                                                  AS entregados,
       round(min(m), 1) AS minimo,
       round(percentile_cont(0.25) WITHIN GROUP (ORDER BY m)::numeric, 1)        AS q1,
       round(percentile_cont(0.50) WITHIN GROUP (ORDER BY m)::numeric, 1)        AS mediana,
       round(avg(m), 1)                                                          AS promedio,
       round(percentile_cont(0.75) WITHIN GROUP (ORDER BY m)::numeric, 1)        AS q3,
       round(max(m), 1) AS maximo
FROM (SELECT extract(epoch FROM fecha_hora_entrega - fecha_hora_pedido) / 60 AS m
      FROM bronce.pedido WHERE estado = 'entregado') t;


-- ---------------------------------------------------------------------
-- R5. ZONA: cliente, restaurante y repartidor del pedido en la misma zona (RN-02/05)
-- ---------------------------------------------------------------------
-- (a) Conteo de pedidos que incumplen
SELECT count(*) AS pedidos_evaluados,
       count(*) FILTER (WHERE c.id_zona <> r.id_zona)                       AS cliente_otra_zona,
       count(*) FILTER (WHERE rp.id_zona IS NOT NULL AND rp.id_zona <> r.id_zona) AS repartidor_otra_zona
FROM bronce.pedido p
JOIN bronce.cliente c       USING (id_cliente)
JOIN bronce.restaurante r   USING (id_restaurante)
LEFT JOIN bronce.repartidor rp USING (id_repartidor);

-- (b) Muestra de los que incumplen (debe salir vacía)
SELECT p.id_pedido, c.id_zona AS zona_cliente, r.id_zona AS zona_restaurante, rp.id_zona AS zona_repartidor
FROM bronce.pedido p
JOIN bronce.cliente c       USING (id_cliente)
JOIN bronce.restaurante r   USING (id_restaurante)
LEFT JOIN bronce.repartidor rp USING (id_repartidor)
WHERE c.id_zona <> r.id_zona OR rp.id_zona <> r.id_zona
LIMIT 20;


-- ---------------------------------------------------------------------
-- R6. PROMOCIÓN usada dentro de su vigencia (RN-08)
-- ---------------------------------------------------------------------
-- (a) Conteo
SELECT count(*) AS pedidos_con_promocion,
       count(*) FILTER (WHERE p.fecha_hora_pedido::date NOT BETWEEN pm.fecha_inicio AND pm.fecha_fin) AS fuera_de_vigencia
FROM bronce.pedido p
JOIN bronce.promocion pm USING (id_promocion);

-- (b) Muestra (debe salir vacía)
SELECT p.id_pedido, p.fecha_hora_pedido::date AS fecha_pedido, pm.codigo, pm.fecha_inicio, pm.fecha_fin
FROM bronce.pedido p
JOIN bronce.promocion pm USING (id_promocion)
WHERE p.fecha_hora_pedido::date NOT BETWEEN pm.fecha_inicio AND pm.fecha_fin
LIMIT 20;


-- ---------------------------------------------------------------------
-- R7. PRODUCTO del detalle pertenece al restaurante del pedido
-- ---------------------------------------------------------------------
-- (a) Conteo
SELECT count(*) AS lineas_evaluadas,
       count(*) FILTER (WHERE pr.id_restaurante <> p.id_restaurante) AS producto_de_otro_restaurante
FROM bronce.detalle_pedido d
JOIN bronce.pedido p    USING (id_pedido)
JOIN bronce.producto pr USING (id_producto);

-- (b) Muestra (debe salir vacía)
SELECT d.id_detalle, d.id_pedido, d.id_producto,
       p.id_restaurante AS restaurante_pedido, pr.id_restaurante AS restaurante_producto
FROM bronce.detalle_pedido d
JOIN bronce.pedido p    USING (id_pedido)
JOIN bronce.producto pr USING (id_producto)
WHERE pr.id_restaurante <> p.id_restaurante
LIMIT 20;


-- ---------------------------------------------------------------------
-- R8. CALIFICACIÓN solo de pedidos entregados y posterior a la entrega (RN-09)
-- ---------------------------------------------------------------------
-- (a) Conteo
SELECT count(*) AS calificaciones,
       count(*) FILTER (WHERE p.estado <> 'entregado')          AS de_pedido_no_entregado,
       count(*) FILTER (WHERE c.fecha <= p.fecha_hora_entrega)  AS antes_de_la_entrega
FROM bronce.calificacion c
JOIN bronce.pedido p USING (id_pedido);

-- (b) Muestra (debe salir vacía)
SELECT c.id_calificacion, c.id_pedido, p.estado, p.fecha_hora_entrega, c.fecha AS fecha_calificacion
FROM bronce.calificacion c
JOIN bronce.pedido p USING (id_pedido)
WHERE p.estado <> 'entregado' OR c.fecha <= p.fecha_hora_entrega
LIMIT 20;


-- ---------------------------------------------------------------------
-- R9. DOMINIOS: puntajes 1-5, cantidad > 0, precios > 0, montos >= 0
-- ---------------------------------------------------------------------
SELECT 'calificacion: puntaje fuera de 1-5' AS chequeo, count(*) AS incumplen
FROM bronce.calificacion
WHERE puntaje_restaurante NOT BETWEEN 1 AND 5 OR puntaje_repartidor NOT BETWEEN 1 AND 5
UNION ALL
SELECT 'detalle: cantidad <= 0 o precio <= 0', count(*)
FROM bronce.detalle_pedido WHERE cantidad <= 0 OR precio_unitario <= 0
UNION ALL
SELECT 'detalle: subtotal_linea <> cantidad * precio', count(*)
FROM bronce.detalle_pedido WHERE subtotal_linea <> cantidad * precio_unitario
UNION ALL
SELECT 'pedido: algún monto negativo', count(*)
FROM bronce.pedido WHERE subtotal < 0 OR costo_envio < 0 OR descuento < 0 OR total < 0
UNION ALL
SELECT 'pago: monto negativo', count(*)
FROM bronce.pago WHERE monto < 0
UNION ALL
SELECT 'producto: precio <= 0', count(*)
FROM bronce.producto WHERE precio <= 0;


-- ---------------------------------------------------------------------
-- R10. MÉTODO DE PAGO: agrupar en tipo (campo derivado)
-- ---------------------------------------------------------------------
SELECT m.id_metodo, m.nombre,
       CASE WHEN m.nombre ILIKE 'tarjeta%'         THEN 'Tarjeta'
            WHEN m.nombre ILIKE 'efectivo%'        THEN 'Efectivo'
            WHEN m.nombre IN ('Nequi','Daviplata') THEN 'Billetera digital'
            WHEN m.nombre = 'PSE'                  THEN 'Transferencia'
            ELSE 'Otro' END AS tipo_metodo,
       count(g.id_pago) AS pagos,
       round(100.0 * count(*) FILTER (WHERE g.estado = 'rechazado') / count(g.id_pago), 2) AS pct_rechazo
FROM bronce.metodo_pago m
LEFT JOIN bronce.pago g USING (id_metodo)
GROUP BY m.id_metodo, m.nombre
ORDER BY m.id_metodo;
