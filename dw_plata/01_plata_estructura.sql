-- =====================================================================
-- 01_plata_estructura.sql
-- CAPA PLATA - Estructura
-- Datos limpios, estandarizados, anonimizados y validados, listos para
-- construir el modelo dimensional (oro).
--
-- Ejecutar en pgAdmin (Query Tool) sobre la base delivery_oltp.
-- OJO: borra y vuelve a crear el esquema plata (no toca public ni bronce).
-- =====================================================================

DROP SCHEMA IF EXISTS plata CASCADE;
CREATE SCHEMA plata;
COMMENT ON SCHEMA plata IS 'Capa plata: datos limpios, estandarizados, anonimizados y validados con las reglas del EDA';

-- ---------------------------------------------------------------------
-- 1. CATÁLOGO DE REGLAS (resultado del EDA sobre bronce)
--    tipo: CAL = calidad/limpieza     SEG = seguridad/anonimización
--          DER = campo derivado       DOM = dominio
--          NEG = regla de negocio     INT = integridad referencial
-- ---------------------------------------------------------------------
CREATE TABLE plata.regla_calidad (
    codigo        VARCHAR(10)  PRIMARY KEY,
    tipo          VARCHAR(3)   NOT NULL,
    tipo_regla    VARCHAR(30)  NOT NULL,      -- como aparece en la tabla del documento
    tabla         VARCHAR(40)  NOT NULL,
    campo         VARCHAR(60)  NOT NULL,
    problema      VARCHAR(250) NOT NULL,
    accion        VARCHAR(250) NOT NULL
);

INSERT INTO plata.regla_calidad VALUES
 -- Calidad
 ('CAL-01','CAL','Formato','cliente','nombre','Espacios extra o escrito en mayúsculas/minúsculas','TRIM, un solo espacio entre palabras e inicial mayúscula (INITCAP)'),
 ('CAL-02','CAL','Completitud / dominio','cliente','genero','Valores nulos; dominio observado M, F, O','Nulo -> N; dominio {M, F, O, N} y genero_desc'),
 ('CAL-03','CAL','Completitud','cliente','fecha_nacimiento','Fecha nula (o edad fuera de 14-100 años)','edad = NULL y rango_edad = ''Sin dato'''),
 ('CAL-04','CAL','Texto libre','calificacion','comentario','Espacios al inicio o al final','TRIM'),
 ('CAL-05','CAL','Texto libre','calificacion','comentario','Emojis dentro del texto','Se quitan del texto y se marca tiene_emoji = TRUE'),
 ('CAL-06','CAL','Texto libre','calificacion','comentario','Nulo (el cliente no dejó comentario)','Comentario = ''Sin comentario'' y tiene_comentario = FALSE'),
 -- Seguridad
 ('SEG-01','SEG','Formato / seguridad','cliente','email','Dato personal; parte en MAYÚSCULAS','Minúsculas, TRIM, validar patrón (email_valido); luego hash MD5. Solo se conserva el dominio'),
 ('SEG-02','SEG','Unicidad','cliente','email','Emails repetidos entre clientes','Se conserva el cliente más antiguo; los repetidos van a cuarentena'),
 ('SEG-03','SEG','Formato / seguridad','cliente','telefono','Dato personal en 3 formatos (3001234567, +57 300 123 4567, 300-123-4567)','Dejar 10 dígitos que empiecen en 3 (telefono_valido); luego hash MD5'),
 ('SEG-04','SEG','Completitud','cliente','telefono','Teléfono nulo','telefono_hash = NULL y telefono_valido = FALSE'),
 ('SEG-05','SEG','Seguridad','cliente / restaurante','direccion','Dato personal sin uso analítico','Se excluye de plata'),
 -- Derivados
 ('DER-01','DER','Derivado','pedido','minutos_entrega','No existe en la fuente','Se calcula entrega - pedido, solo para pedidos entregados'),
 ('DER-02','DER','Atípicos (IQR)','pedido','minutos_entrega','Tiempos de entrega atípicos','Límite = Q3 + 1,5·IQR (se recalcula en cada lote); se marca es_atipico, NO se elimina'),
 ('DER-03','DER','Dominio / negocio','pago','estado','Pagos rechazados, reembolsados o anulados inflarían las ventas','es_venta = TRUE solo si estado = aprobado'),
 ('DER-04','DER','Derivado','metodo_pago','nombre','6 métodos sin agrupar','tipo_metodo: Tarjeta, Efectivo, Billetera digital, Transferencia'),
 ('DER-05','DER','Consistencia histórica','detalle_pedido','precio_unitario','El precio de la línea difiere del precio actual del catálogo','Se usa el precio del detalle (precio histórico), no el del catálogo'),
 -- Dominio
 ('DOM-01','DOM','Dominio','pedido','estado','Pedidos abiertos al corte (en camino, en preparación)','es_abierto = TRUE; se excluyen de los cálculos de tiempo; se actualizan en la siguiente recarga'),
 -- Negocio
 ('NEG-01','NEG','Consistencia','pedido','total','total <> subtotal + costo_envio - descuento','Pedido a cuarentena'),
 ('NEG-02','NEG','Consistencia','pedido','subtotal','subtotal <> suma del detalle','Pedido a cuarentena'),
 ('NEG-03','NEG','Consistencia','pedido','zona','Cliente, restaurante y repartidor en zonas distintas (RN-02/05)','Pedido a cuarentena'),
 ('NEG-04','NEG','Consistencia temporal','pedido','fecha_hora_entrega','Entregado sin fecha de entrega o con entrega antes del pedido','Pedido a cuarentena'),
 ('NEG-05','NEG','Consistencia','pedido','id_promocion','Promoción usada fuera de su vigencia (RN-08)','Pedido a cuarentena'),
 ('NEG-06','NEG','Consistencia temporal','pedido','fecha_hora_pedido','Pedido antes del registro del cliente o del alta del restaurante/repartidor','Pedido a cuarentena'),
 ('NEG-07','NEG','Integridad','detalle_pedido','id_producto','Producto de un restaurante distinto al del pedido','Pedido a cuarentena'),
 ('NEG-08','NEG','Consistencia','calificacion','id_pedido','Calificación de pedido no entregado o anterior a la entrega (RN-09)','Calificación a cuarentena'),
 ('NEG-09','NEG','Validez','varias','montos / puntajes','Montos negativos, cantidad o precio <= 0, puntaje fuera de 1-5','Registro a cuarentena'),
 -- Integridad
 ('INT-01','INT','Integridad','pedido','llaves foráneas','Cliente, restaurante, repartidor o promoción inexistente','Pedido a cuarentena'),
 ('INT-02','INT','Integridad','detalle / pago','llaves foráneas','Producto o método de pago inexistente','Registro a cuarentena'),
 ('INT-03','INT','Integridad','pedido','id_repartidor / id_promocion','Nulos válidos: pedidos sin repartidor asignado o sin promoción','Se conservan NULL en plata; en oro apuntan al miembro -1 ''No aplica''');

-- ---------------------------------------------------------------------
-- 2. CONTROL Y AUDITORÍA
-- ---------------------------------------------------------------------
CREATE TABLE plata.control_lote (
    lote_id         SERIAL PRIMARY KEY,
    lote_bronce     INT,                         -- lote de bronce del que se alimentó
    q1_entrega      NUMERIC(6,1),                -- DER-02: cuartiles del tiempo de entrega
    q3_entrega      NUMERIC(6,1),
    limite_atipico  NUMERIC(6,1),                -- Q3 + 1,5·IQR
    fecha_inicio    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    fecha_fin       TIMESTAMPTZ,
    usuario         VARCHAR(60) NOT NULL DEFAULT current_user,
    estado          VARCHAR(12) NOT NULL DEFAULT 'en curso'
);

-- Resultado de cada regla en cada lote (cuántos registros afectó)
CREATE TABLE plata.control_calidad (
    lote_id          INT         NOT NULL REFERENCES plata.control_lote,
    codigo_regla     VARCHAR(10) NOT NULL REFERENCES plata.regla_calidad,
    filas_evaluadas  BIGINT      NOT NULL,
    filas_afectadas  BIGINT      NOT NULL,
    PRIMARY KEY (lote_id, codigo_regla)
);

-- Registros que NO pasan a plata por incumplir una regla
CREATE TABLE plata.cuarentena (
    lote_id       INT          NOT NULL REFERENCES plata.control_lote,
    tabla         VARCHAR(40)  NOT NULL,
    id_registro   BIGINT       NOT NULL,
    codigo_regla  VARCHAR(10)  NOT NULL REFERENCES plata.regla_calidad,
    detalle       TEXT,
    fecha         TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 3. TABLAS PLATA (con PK y CHECK: aquí ya se exige calidad)
--    Todas llevan _lote_id y _fecha_proceso para trazabilidad.
-- ---------------------------------------------------------------------
CREATE TABLE plata.zona (
    id_zona            INT PRIMARY KEY,
    ciudad             VARCHAR(60)   NOT NULL,
    nombre_zona        VARCHAR(80)   NOT NULL,
    codigo_postal      VARCHAR(10),
    tarifa_base_envio  NUMERIC(10,2) NOT NULL CHECK (tarifa_base_envio >= 0),
    _lote_id           INT NOT NULL,
    _fecha_proceso     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE plata.categoria_cocina (
    id_categoria   INT PRIMARY KEY,
    nombre         VARCHAR(50) NOT NULL,
    _lote_id       INT NOT NULL,
    _fecha_proceso TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE plata.metodo_pago (
    id_metodo      INT PRIMARY KEY,
    nombre         VARCHAR(30) NOT NULL,
    tipo_metodo    VARCHAR(20) NOT NULL,                            -- DER-04
    _lote_id       INT NOT NULL,
    _fecha_proceso TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE plata.promocion (
    id_promocion   INT PRIMARY KEY,
    codigo         VARCHAR(20)   NOT NULL,
    tipo_descuento VARCHAR(15)   NOT NULL CHECK (tipo_descuento IN ('porcentaje','valor fijo','envío gratis')),
    valor          NUMERIC(10,2) NOT NULL CHECK (valor >= 0),
    fecha_inicio   DATE NOT NULL,
    fecha_fin      DATE NOT NULL CHECK (fecha_fin >= fecha_inicio),
    duracion_dias  INT  NOT NULL,
    _lote_id       INT NOT NULL,
    _fecha_proceso TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE plata.cliente (
    id_cliente       INT PRIMARY KEY,
    nombre           VARCHAR(100) NOT NULL,                         -- CAL-01
    email_hash       CHAR(32)     NOT NULL UNIQUE,                  -- SEG-01 / SEG-02
    dominio_email    VARCHAR(60)  NOT NULL,                         -- SEG-01
    email_valido     BOOLEAN      NOT NULL,                         -- SEG-01
    telefono_hash    CHAR(32),                                      -- SEG-03
    telefono_valido  BOOLEAN      NOT NULL,                         -- SEG-03 / SEG-04
    fecha_nacimiento DATE,
    edad             SMALLINT CHECK (edad BETWEEN 14 AND 100),      -- CAL-03
    rango_edad       VARCHAR(12)  NOT NULL,                         -- CAL-03
    genero           CHAR(1)      NOT NULL CHECK (genero IN ('F','M','O','N')),  -- CAL-02
    genero_desc      VARCHAR(15)  NOT NULL,
    id_zona          INT          NOT NULL,
    fecha_registro   TIMESTAMP    NOT NULL,
    _lote_id         INT NOT NULL,
    _fecha_proceso   TIMESTAMPTZ NOT NULL DEFAULT now()
    -- SEG-05: sin dirección
);

CREATE TABLE plata.restaurante (
    id_restaurante INT PRIMARY KEY,
    nombre         VARCHAR(100) NOT NULL,
    id_categoria   INT          NOT NULL,
    id_zona        INT          NOT NULL,
    fecha_alta     DATE         NOT NULL,
    estado         VARCHAR(15)  NOT NULL CHECK (estado IN ('activo','inactivo')),
    _lote_id       INT NOT NULL,
    _fecha_proceso TIMESTAMPTZ NOT NULL DEFAULT now()
    -- SEG-05: sin dirección
);

CREATE TABLE plata.producto (
    id_producto    INT PRIMARY KEY,
    id_restaurante INT           NOT NULL,
    nombre         VARCHAR(100)  NOT NULL,
    tipo_producto  VARCHAR(30)   NOT NULL CHECK (tipo_producto IN ('plato','bebida','postre','combo')),
    precio_actual  NUMERIC(10,2) NOT NULL CHECK (precio_actual > 0),  -- precio de catálogo HOY (DER-05)
    activo         BOOLEAN       NOT NULL,
    _lote_id       INT NOT NULL,
    _fecha_proceso TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE plata.repartidor (
    id_repartidor  INT PRIMARY KEY,
    nombre         VARCHAR(100) NOT NULL,
    tipo_vehiculo  VARCHAR(20)  NOT NULL CHECK (tipo_vehiculo IN ('moto','bicicleta','carro')),
    id_zona        INT          NOT NULL,
    fecha_ingreso  DATE         NOT NULL,
    estado         VARCHAR(15)  NOT NULL CHECK (estado IN ('activo','inactivo')),
    _lote_id       INT NOT NULL,
    _fecha_proceso TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE plata.pedido (
    id_pedido          BIGINT PRIMARY KEY,
    id_cliente         INT       NOT NULL,
    id_restaurante     INT       NOT NULL,
    id_repartidor      INT,                          -- INT-03: NULL válido
    id_promocion       INT,                          -- INT-03: NULL válido
    id_zona            INT       NOT NULL,           -- zona del pedido (validada por NEG-03)
    fecha_hora_pedido  TIMESTAMP NOT NULL,
    fecha_pedido       DATE      NOT NULL,           -- llave hacia dim_tiempo en oro
    hora_pedido        SMALLINT  NOT NULL CHECK (hora_pedido BETWEEN 0 AND 23),
    fecha_hora_entrega TIMESTAMP,
    minutos_entrega    NUMERIC(6,1),                 -- DER-01
    estado             VARCHAR(15) NOT NULL CHECK (estado IN ('entregado','cancelado','en camino','en preparacion')),
    es_cancelado       BOOLEAN   NOT NULL,
    es_abierto         BOOLEAN   NOT NULL,           -- DOM-01
    es_atipico         BOOLEAN   NOT NULL,           -- DER-02
    tiene_repartidor   BOOLEAN   NOT NULL,
    tiene_promocion    BOOLEAN   NOT NULL,
    subtotal           NUMERIC(10,2) NOT NULL,
    costo_envio        NUMERIC(10,2) NOT NULL,
    descuento          NUMERIC(10,2) NOT NULL,
    total              NUMERIC(10,2) NOT NULL,
    _lote_id           INT NOT NULL,
    _fecha_proceso     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE plata.detalle_pedido (
    id_detalle      BIGINT PRIMARY KEY,
    id_pedido       BIGINT        NOT NULL,
    id_producto     INT           NOT NULL,
    cantidad        SMALLINT      NOT NULL CHECK (cantidad > 0),
    precio_unitario NUMERIC(10,2) NOT NULL CHECK (precio_unitario > 0),   -- DER-05: precio histórico
    subtotal_linea  NUMERIC(10,2) NOT NULL,
    _lote_id        INT NOT NULL,
    _fecha_proceso  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE plata.pago (
    id_pago        BIGINT PRIMARY KEY,
    id_pedido      BIGINT        NOT NULL,
    id_metodo      INT           NOT NULL,
    monto          NUMERIC(10,2) NOT NULL CHECK (monto >= 0),
    fecha_pago     TIMESTAMP     NOT NULL,
    estado         VARCHAR(15)   NOT NULL CHECK (estado IN ('aprobado','rechazado','reembolsado','anulado')),
    es_venta       BOOLEAN       NOT NULL,           -- DER-03
    _lote_id       INT NOT NULL,
    _fecha_proceso TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE plata.calificacion (
    id_calificacion     BIGINT PRIMARY KEY,
    id_pedido           BIGINT       NOT NULL UNIQUE,
    puntaje_restaurante SMALLINT     NOT NULL CHECK (puntaje_restaurante BETWEEN 1 AND 5),
    puntaje_repartidor  SMALLINT     NOT NULL CHECK (puntaje_repartidor  BETWEEN 1 AND 5),
    comentario          VARCHAR(300) NOT NULL,       -- CAL-04 / CAL-05 / CAL-06
    tiene_comentario    BOOLEAN      NOT NULL,
    tiene_emoji         BOOLEAN      NOT NULL,
    fecha               TIMESTAMP    NOT NULL,
    _lote_id            INT NOT NULL,
    _fecha_proceso      TIMESTAMPTZ NOT NULL DEFAULT now()
);
