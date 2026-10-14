-- =====================================================================
-- 03_oro_ejecutar_y_validar.sql
-- Carga y Verificación de Resultados
-- =====================================================================

-- 1. EJECUTAR EL PROCEDIMIENTO DE ORO
CALL oro.sp_cargar_oro();

-- 2. CONCILIACIÓN DE CIFRAS (PLATA VS ORO)
SELECT 'Pedidos' AS entidad,
       (SELECT count(*) FROM plata.pedido) AS plata,
       (SELECT count(*) FROM oro.fact_pedido) AS oro,
       (SELECT count(*) FROM plata.pedido) - (SELECT count(*) FROM oro.fact_pedido) AS diferencia
UNION ALL
SELECT 'Ventas Totales',
       (SELECT sum(total) FROM plata.pedido WHERE estado = 'entregado'),
       (SELECT sum(total) FROM oro.fact_pedido WHERE es_entregado = 1),
       (SELECT sum(total) FROM plata.pedido WHERE estado = 'entregado') - (SELECT sum(total) FROM oro.fact_pedido WHERE es_entregado = 1)
UNION ALL
SELECT 'Detalle Pedido',
       (SELECT count(*) FROM plata.detalle_pedido),
       (SELECT count(*) FROM oro.fact_detalle_pedido),
       (SELECT count(*) FROM plata.detalle_pedido) - (SELECT count(*) FROM oro.fact_detalle_pedido);

-- 3. VALIDACIÓN DE REQUERIMIENTOS DE NEGOCIO (RN)

-- RN-01: Ventas por Mes
SELECT t.anio, t.nombre_mes, sum(f.total) AS total_ventas
FROM oro.fact_pedido f
JOIN oro.dim_tiempo t ON f.sk_tiempo = t.sk_tiempo
WHERE f.es_entregado = 1
GROUP BY t.anio, t.mes, t.nombre_mes ORDER BY t.anio, t.mes;

-- RN-02: Ventas por Zona
SELECT z.nombre_zona, count(f.id_pedido) AS pedidos, sum(f.total) AS ventas
FROM oro.fact_pedido f
JOIN oro.dim_zona z ON f.sk_zona = z.sk_zona
WHERE f.es_entregado = 1
GROUP BY z.nombre_zona ORDER BY ventas DESC;

-- RN-05: Tiempos de Entrega por Zona y Vehículo
SELECT z.nombre_zona, r.tipo_vehiculo, round(avg(f.tiempo_entrega_min), 2) AS tiempo_promedio_min
FROM oro.fact_pedido f
JOIN oro.dim_zona z ON f.sk_zona = z.sk_zona
JOIN oro.dim_repartidor r ON f.sk_repartidor = r.sk_repartidor
WHERE f.es_entregado = 1
GROUP BY z.nombre_zona, r.tipo_vehiculo;