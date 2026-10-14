**Fecha De Nacimiento**

SELECT count(\*) AS clientes,

&#x20;      count(\*) FILTER (WHERE fecha\_nacimiento IS NULL) AS sin\_fecha,

&#x20;      round(100.0 \* count(\*) FILTER (WHERE fecha\_nacimiento IS NULL) / count(\*), 1) AS pct\_nula

FROM cliente;



**Genero**

SELECT coalesce(genero, '(nulo)') AS genero, count(\*) AS clientes,

&#x20;      round(100.0 \* count(\*) / sum(count(\*)) OVER (), 1) AS pct

FROM cliente GROUP BY genero ORDER BY clientes DESC;



**Telefono**

SELECT CASE WHEN telefono IS NULL               THEN '(nulo)'

&#x20;           WHEN telefono \~ '^3\\d{9}$'           THEN 'estándar: 3001234567'

&#x20;           WHEN telefono LIKE '+57%'            THEN 'con +57: +57 300 123 4567'

&#x20;           WHEN telefono \~ '^\\d{3}-\\d{3}-\\d{4}$' THEN 'con guiones: 300-123-4567'

&#x20;           ELSE 'otro' END AS formato,

&#x20;      count(\*) AS clientes,

&#x20;      round(100.0 \* count(\*) / sum(count(\*)) OVER (), 1) AS pct

FROM cliente GROUP BY 1 ORDER BY clientes DESC;



**Email**

SELECT count(\*) FILTER (WHERE email <> lower(email)) AS en\_mayusculas,

&#x20;      round(100.0 \* count(\*) FILTER (WHERE email <> lower(email)) / count(\*), 1) AS pct\_mayusculas,

&#x20;      count(\*) - count(DISTINCT lower(trim(email))) AS duplicados\_tras\_normalizar,

&#x20;      count(\*) FILTER (WHERE email !\~ '^\[^@\\s]+@\[^@\\s]+\\.\[^@\\s]+$') AS patron\_invalido

FROM cliente;



**Nombre**

SELECT count(\*) FILTER (WHERE nombre <> trim(nombre))  AS con\_espacios\_extra,

&#x20;      count(\*) FILTER (WHERE nombre = lower(nombre))  AS todo\_en\_minusculas,

&#x20;      round(100.0 \* count(\*) FILTER (WHERE nombre <> trim(nombre) OR nombre = lower(nombre)) / count(\*), 1) AS pct\_total

FROM cliente;



**Total Pedidos**

SELECT count(\*) FILTER (WHERE total <> subtotal + costo\_envio - descuento) AS total\_mal\_calculado,

&#x20;      (SELECT count(\*) FROM pedido p

&#x20;         JOIN (SELECT id\_pedido, sum(subtotal\_linea) s FROM detalle\_pedido GROUP BY 1) d USING (id\_pedido)

&#x20;        WHERE p.subtotal <> d.s) AS subtotal\_distinto\_al\_detalle

FROM pedido;



**Fechas**

SELECT (SELECT count(\*) FROM pedido WHERE fecha\_hora\_entrega <= fecha\_hora\_pedido) AS entrega\_antes\_del\_pedido,

&#x20;      (SELECT count(\*) FROM pedido p JOIN cliente c USING (id\_cliente)

&#x20;        WHERE p.fecha\_hora\_pedido < c.fecha\_registro)                            AS pedido\_antes\_del\_registro;



**Llaves foráneas**

SELECT count(\*) FILTER (WHERE id\_repartidor IS NULL) AS sin\_repartidor,

&#x20;      count(\*) FILTER (WHERE id\_repartidor IS NULL AND estado <> 'cancelado') AS sin\_repartidor\_no\_cancelado,

&#x20;      count(\*) FILTER (WHERE id\_promocion IS NULL) AS sin\_promocion,

&#x20;      round(100.0 \* count(\*) FILTER (WHERE id\_promocion IS NULL) / count(\*), 1) AS pct\_sin\_promocion

FROM pedido;



**Tiempo De Entrega**

WITH t AS (SELECT extract(epoch FROM fecha\_hora\_entrega - fecha\_hora\_pedido) / 60 AS m

&#x20;          FROM pedido WHERE estado = 'entregado'),

&#x20;    q AS (SELECT percentile\_cont(0.25) WITHIN GROUP (ORDER BY m) AS q1,

&#x20;                 percentile\_cont(0.75) WITHIN GROUP (ORDER BY m) AS q3 FROM t)

SELECT round(q1::numeric, 1) AS q1\_min,

&#x20;      round(q3::numeric, 1) AS q3\_min,

&#x20;      round((q3 - q1)::numeric, 1) AS iqr,

&#x20;      round((q3 + 1.5 \* (q3 - q1))::numeric, 1) AS limite\_min,

&#x20;      (SELECT count(\*) FROM t WHERE m > q3 + 1.5 \* (q3 - q1)) AS atipicos,

&#x20;      round(100.0 \* (SELECT count(\*) FROM t WHERE m > q3 + 1.5 \* (q3 - q1)) / (SELECT count(\*) FROM t), 2) AS pct\_atipicos,

&#x20;      (SELECT round(max(m)::numeric) FROM t) AS maximo\_min

FROM q;



**Estado Del Pedido**

SELECT estado, count(\*) AS pedidos FROM pedido GROUP BY 1 ORDER BY 2 DESC;

&#x20;

**Precio Unitario**

SELECT count(\*) AS lineas,

&#x20;      count(\*) FILTER (WHERE d.precio\_unitario <> p.precio) AS precio\_distinto\_al\_actual,

&#x20;      round(100.0 \* count(\*) FILTER (WHERE d.precio\_unitario <> p.precio) / count(\*), 1) AS pct

FROM detalle\_pedido d JOIN producto p USING (id\_producto);



**Comentario**

SELECT round(100.0 \* count(\*) FILTER (WHERE comentario IS NULL) / count(\*), 1) AS pct\_nulo,

&#x20;      count(\*) FILTER (WHERE comentario <> rtrim(comentario)) AS con\_espacios\_al\_final

FROM calificacion;

