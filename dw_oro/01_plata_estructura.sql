-- =====================================================================
-- 01_oro_estructura.sql
-- CAPA ORO - Estructura Dimensional (Modelo Estrella / Constelación)
--
-- Crea el esquema oro con las 8 dimensiones, 2 tablas de hechos,
-- índices de rendimiento y las vistas materializadas para Grafana.
-- =====================================================================

DROP SCHEMA IF EXISTS oro CASCADE;
CREATE SCHEMA oro;
COMMENT ON SCHEMA oro IS 'Capa Oro: Modelo dimensional listo para consultas BI y tableros en Grafana';

-- ---------------------------------------------------------------------
-- 1. DIMENSIONES (Con Llaves Sustitutas SK y miembro -1 "No aplica")
-- ---------------------------------------------------------------------

-- Dimensión Tiempo
CREATE TABLE oro.dim_tiempo (
    sk_tiempo      INT PRIMARY KEY,              -- AAAAMMDD
    fecha          DATE NOT NULL UNIQUE,
    anio           SMALLINT NOT NULL,
    trimestre      SMALLINT NOT NULL,
    mes            SMALLINT NOT NULL,
    nombre_mes     VARCHAR(15) NOT NULL,
    dia            SMALLINT NOT NULL,
    dia_semana     SMALLINT NOT NULL,
    nombre_dia     VARCHAR(15) NOT NULL,
    es_fin_semana  BOOLEAN NOT NULL
);

-- Dimensión Cliente
CREATE TABLE oro.dim_cliente (
    sk_cliente     SERIAL PRIMARY KEY,
    id_cliente     INT NOT NULL,                 -- Llave de negocio
    nombre         VARCHAR(100) NOT NULL,
    dominio_email  VARCHAR(60) NOT NULL,
    email_valido   BOOLEAN NOT NULL,
    telefono_valido BOOLEAN NOT NULL,
    edad           SMALLINT,
    rango_edad     VARCHAR(12) NOT NULL,
    genero         CHAR(1) NOT NULL,
    genero_desc    VARCHAR(15) NOT NULL,
    id_zona        INT NOT NULL,
    fecha_registro TIMESTAMP NOT NULL
);

-- Dimensión Zona
CREATE TABLE oro.dim_zona (
    sk_zona           SERIAL PRIMARY KEY,
    id_zona           INT NOT NULL,
    ciudad            VARCHAR(60) NOT NULL,
    nombre_zona       VARCHAR(80) NOT NULL,
    codigo_postal     VARCHAR(10),
    tarifa_base_envio NUMERIC(10,2) NOT NULL
);

-- Dimensión Categoria Cocina / Restaurante
CREATE TABLE oro.dim_restaurante (
    sk_restaurante   SERIAL PRIMARY KEY,
    id_restaurante   INT NOT NULL,
    nombre           VARCHAR(100) NOT NULL,
    categoria_cocina VARCHAR(50) NOT NULL,
    id_zona          INT NOT NULL,
    fecha_alta       DATE NOT NULL,
    estado           VARCHAR(15) NOT NULL
);

-- Dimensión Repartidor
CREATE TABLE oro.dim_repartidor (
    sk_repartidor    SERIAL PRIMARY KEY,
    id_repartidor    INT NOT NULL,
    nombre           VARCHAR(100) NOT NULL,
    tipo_vehiculo    VARCHAR(20) NOT NULL,
    id_zona          INT NOT NULL,
    fecha_ingreso    DATE NOT NULL,
    estado           VARCHAR(15) NOT NULL
);

-- Dimensión Promoción
CREATE TABLE oro.dim_promocion (
    sk_promocion     SERIAL PRIMARY KEY,
    id_promocion     INT NOT NULL,
    codigo           VARCHAR(20) NOT NULL,
    tipo_descuento   VARCHAR(15) NOT NULL,
    valor            NUMERIC(10,2) NOT NULL,
    fecha_inicio     DATE NOT NULL,
    fecha_fin        DATE NOT NULL,
    duracion_dias    INT NOT NULL
);

-- Dimensión Método de Pago
CREATE TABLE oro.dim_metodo_pago (
    sk_metodo_pago   SERIAL PRIMARY KEY,
    id_metodo        INT NOT NULL,
    nombre           VARCHAR(30) NOT NULL,
    tipo_metodo      VARCHAR(20) NOT NULL
);

-- Dimensión Producto
CREATE TABLE oro.dim_producto (
    sk_producto      SERIAL PRIMARY KEY,
    id_producto      INT NOT NULL,
    nombre           VARCHAR(100) NOT NULL,
    tipo_producto    VARCHAR(30) NOT NULL,
    precio_actual    NUMERIC(10,2) NOT NULL,
    id_restaurante   INT NOT NULL,
    restaurante_nombre VARCHAR(100) NOT NULL,
    activo           BOOLEAN NOT NULL
);

-- ---------------------------------------------------------------------
-- 2. TABLAS DE HECHOS (Fact Tables)
-- ---------------------------------------------------------------------

-- Fact Pedido (Grano: 1 fila por pedido)
CREATE TABLE oro.fact_pedido (
    id_pedido          BIGINT PRIMARY KEY,        -- Llave degenerada
    sk_tiempo          INT NOT NULL REFERENCES oro.dim_tiempo(sk_tiempo),
    sk_cliente         INT NOT NULL REFERENCES oro.dim_cliente(sk_cliente),
    sk_restaurante     INT NOT NULL REFERENCES oro.dim_restaurante(sk_restaurante),
    sk_repartidor      INT NOT NULL REFERENCES oro.dim_repartidor(sk_repartidor),
    sk_promocion       INT NOT NULL REFERENCES oro.dim_promocion(sk_promocion),
    sk_zona            INT NOT NULL REFERENCES oro.dim_zona(sk_zona),
    sk_metodo_pago     INT NOT NULL REFERENCES oro.dim_metodo_pago(sk_metodo_pago),
    -- Medidas
    subtotal           NUMERIC(10,2) NOT NULL,
    costo_envio        NUMERIC(10,2) NOT NULL,
    descuento          NUMERIC(10,2) NOT NULL,
    total              NUMERIC(10,2) NOT NULL,
    cantidad_productos INT NOT NULL,
    tiempo_entrega_min NUMERIC(6,1),
    puntaje_restaurante SMALLINT,
    puntaje_repartidor  SMALLINT,
    pagos_rechazados   SMALLINT NOT NULL DEFAULT 0,
    es_cancelado       SMALLINT NOT NULL DEFAULT 0,
    es_entregado       SMALLINT NOT NULL DEFAULT 0,
    es_atipico         BOOLEAN NOT NULL DEFAULT FALSE
);

-- Fact Detalle Pedido (Grano: 1 fila por producto dentro del pedido)
CREATE TABLE oro.fact_detalle_pedido (
    id_detalle       BIGINT PRIMARY KEY,
    id_pedido        BIGINT NOT NULL,
    sk_producto      INT NOT NULL REFERENCES oro.dim_producto(sk_producto),
    sk_tiempo        INT NOT NULL REFERENCES oro.dim_tiempo(sk_tiempo),
    sk_cliente       INT NOT NULL REFERENCES oro.dim_cliente(sk_cliente),
    sk_restaurante   INT NOT NULL REFERENCES oro.dim_restaurante(sk_restaurante),
    sk_zona          INT NOT NULL REFERENCES oro.dim_zona(sk_zona),
    -- Medidas
    cantidad         SMALLINT NOT NULL,
    precio_unitario  NUMERIC(10,2) NOT NULL,
    subtotal_linea   NUMERIC(10,2) NOT NULL
);

-- ---------------------------------------------------------------------
-- 3. ÍNDICES DE RENDIMIENTO
-- ---------------------------------------------------------------------
CREATE INDEX idx_fact_pedido_tiempo ON oro.fact_pedido(sk_tiempo);
CREATE INDEX idx_fact_pedido_zona ON oro.fact_pedido(sk_zona);
CREATE INDEX idx_fact_pedido_restaurante ON oro.fact_pedido(sk_restaurante);
CREATE INDEX idx_fact_pedido_cliente ON oro.fact_pedido(sk_cliente);

CREATE INDEX idx_fact_detalle_producto ON oro.fact_detalle_pedido(sk_producto);
CREATE INDEX idx_fact_detalle_pedido ON oro.fact_detalle_pedido(id_pedido);