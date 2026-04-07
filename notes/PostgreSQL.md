# 1. 使用PG咨询锁替代Redis分布式锁

在 PostgreSQL（PG）中替代 Redis 实现分布式锁，最正统且高效的方式是利用其内置的**咨询锁（Advisory Locks）**。这种锁与数据库的表结构或行数据解耦，专门用于应用程序级别的并发控制。

## 1.1. 核心方案：PostgreSQL 咨询锁 (Advisory Locks)

PG 咨询锁允许你通过一个 64 位整数（或两个 32 位整数）作为锁的标识符。它不需要像 Redis 那样手动管理过期时间（TTL），因为它可以与数据库会话（Session）绑定。

A. 会话级锁 (Session-level)

锁与当前的数据库连接绑定。如果连接断开（如应用崩溃），PG 会**自动释放**该锁，天然避免了 Redis 中常见的死锁问题。

- **加锁**：`SELECT pg_advisory_lock(锁ID);`（阻塞直到获取）或 `SELECT pg_try_advisory_lock(锁ID);`（非阻塞，返回布尔值）。
- **解锁**：`SELECT pg_advisory_unlock(锁ID);`。

B. 事务级锁 (Transaction-level)

锁在事务结束（Commit 或 Rollback）时自动释放。

- **加锁**：`SELECT pg_advisory_xact_lock(锁ID);`。
- **释放**：无需手动释放，事务结束即消失。

------

## 1.2. PG 替代 Redis 的实现对比

| 特性           | Redis 实现 (SETNX + Lua)                                 | PostgreSQL 实现 (Advisory Lock)                  |
| :------------- | :------------------------------------------------------- | :----------------------------------------------- |
| **可靠性**     | 依赖过期时间防止死锁；极端情况下（如 Redlock）实现复杂。 | **高**。利用数据库连接状态，会话断开即自动释放。 |
| **复杂度**     | 需处理原子性、续期（Watchdog）和过期释放。               | **低**。内置函数，事务支持，语义清晰。           |
| **性能**       | 极高（内存操作）。                                       | 中高（磁盘 IO 较少，主要受限于连接池开销）。     |
| **数据一致性** | 最终一致性（异步复制）。                                 | **强一致性**。基于 WAL 日志和数据库 ACID 特性。  |

------

## 1.3. 具体操作示例

如果你想在 Java、Python 或 Go 等后端代码中使用，可以直接执行 SQL：

1.3.1. **非阻塞获取锁**：

   ```sql
   -- 尝试获取名为 12345 的锁，成功返回 true，失败立刻返回 false
   SELECT pg_try_advisory_lock(12345);
   ```

1.3.2. **获取锁并执行任务（推荐事务级）**：

   ```sql
   BEGIN;
   -- 获取事务级锁，如果已被占用则等待
   SELECT pg_advisory_xact_lock(12345);
   -- 执行你的业务逻辑...
   COMMIT; -- 提交后锁自动释放
   ```

1.3.3. 为什么选择 PG 替代 Redis？

- **简化架构**：如果你的应用已经在使用 PG，无需为了简单的分布式锁引入 Redis 这种额外的基础设施，降低运维压力。
- **安全性更高**：咨询锁不占用表行，不会导致表膨胀或索引问题，且由数据库内核保证原子性。
- **内置监控**：可以通过 `pg_locks` 视图实时监控哪些进程持有锁，排查问题非常方便。

------

## 1.4. **总结**

对于绝大多数业务场景，使用 PG 的 `pg_advisory_xact_lock` 是替代 Redis 分布式锁的最优选，它既保证了安全性，又简化了代码中的“续期”与“防死锁”逻辑。

咨询锁的问题：
1. 无法快速感知锁状态，不够直观，不能像 redis 锁一样查询 key 快速确认某项业务是否存在锁，而且吞吐量不如 redis 锁，并发数量上受限于数据库连接池。
2. 使用同一个业务锁的服务只能连接同一个库，否则会锁不住，因为咨询锁不会同步到其它节点，而且所连的库挂掉锁也会丢失，如果在事务中有耗时网络任务就无法立刻得到反馈。

扩展内容：pg_try_advisory_xact_lock 

# 2. 行锁与数据抢占

```sql
select * from xxx where condition for update skip locked limit 500;
```

待补充。

# 3. 时序库（TimescaleDB）

## 3.1. PG 扩展（Extension）的特性
- **非数据库独立**：扩展是深度绑定 PG 架构的（利用 C Hook、操作符等接口），无法直接在 MySQL/Oracle 运行。
- **数据库级安装**：在同一实例下，扩展需按数据库（Database）单独安装，哪个库需要就单独启用。
- **生态优势**：通过 PostGIS（地理）、PGVector（向量）、TimescaleDB（时序）等，PG 可实现“一专多能”。

```sql
# 查询 timescaledb 是否可用
SELECT name, default_version, installed_version 
FROM pg_available_extensions 
WHERE name = 'timescaledb';

# 查询 timescaledb 是否已启用
SELECT * FROM pg_extension WHERE extname = 'timescaledb';

# 查看共享库中是否已包含 timescaledb，没有的话要么启用不了，要么启用时会失败，共享库启用需要重启数据库
SHOW shared_preload_libraries;

# 启用 timescaledb 扩展
CREATE EXTENSION IF NOT EXISTS "timescaledb" CASCADE;
```
---

## 3.2. 时序库管理亿级数据的核心机制

面对亿级数据，传统 PG 单表会因索引过大导致 I/O 崩溃。TimescaleDB 通过以下手段解决：

1. **超表 (Hypertables)**：自动将大表按时间切分为物理分片（Chunks），可以让写入始终集中在新的 Chunk，保证索引始终能放入内存。
2. **列式压缩 (Compression)**：将行存转为列存，存储空间减少 90% 以上，显著提升历史数据的范围聚合速度。
3. **持续聚合 (Continuous Aggregates)**：可以自动预算汇总数据（如日均、月均），查询报表时无需扫描原始亿级行，亚秒级响应。

**相比于传统分区表，时序表的优点在于无须手动编写复杂的分区表创建与管理逻辑，只要数据是根据时间字段进行管理，那就能自动分片；但缺点也很明显，如果没有时间列就无法使用。**

<span style="color: red;">**注意：持续聚合特性需要2.x版本开始才能有较好的支持，在那之前的使用方式是有所不同的。**  </span>

超表的定义方式：
```sql
-- 首先，超表一定需要时间字段，配合 chunk_time_interval 参数对数据按时间周期进行分块存储，数据多可以一天一片，数据少可以一月一片
-- 其次，partitioning_column 和 number_partitions 可以指定额外的分块逻辑（空间分块），通常应指定为CPU核心倍数，和时间片是相乘关系
-- 最后，创建了超表会自动创建时间索引，如果有分区列还会创建分区列与时间列的复合索引。分区列不建议超过一个，否则分块数量爆炸也会影响查询
SELECT create_hypertable(
   '表名',
   '时间字段',
   partitioning_column => '额外的分片字段',
   number_partitions => 8,
   chunk_time_interval => INTERVAL '1 day'
);
```
> 假如原表有个 type 字段具有 12 种类型，被指定为分区列并设置了8个分区，那么这些类型就会被哈希算法分配到这8个分区里，有的保存 1 种类型，有的保存 2 种类型。因为物理上这些数据被分配到了不同块上，只要查询时能带上时间和分区条件，查询范围将会被限制到最小。

列式压缩的配置：
```sql
-- 首先选定超表指定要用于压缩的列，支持指定多个，但通常和分区列保持一致
-- 压缩的列可以用于代偿索引，如果有多个自由组合条件就可以通过列式压缩指定
-- 但列式压缩不支持动态补充新列到已压缩的块中，所以定义时根据业务提前确定
-- 如果无法保证旧数据不会再变化，那就不要用列式压缩，否则解压再压缩开销大
ALTER TABLE 超表的表名
SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = '字段1', '字段2'
);
-- 如果需要可重复执行那就用存储过程
-- DO
-- $$
--     BEGIN
--         -- 1. 检查超表是否已经开启了压缩
--         IF NOT EXISTS (SELECT 1
--                          FROM _timescaledb_catalog.hypertable
--                         WHERE table_name = 'data_transfer_record'
--                           AND compressed = TRUE) THEN
--             -- 2. 执行开启压缩的命令
--             ALTER TABLE data_transfer_record
--                 SET (
--                     timescaledb.compress,
--                     -- 指定压缩分组列（建议设为你的查询过滤字段，如 provider）
--                     timescaledb.compress_segmentby = 'provider',
--                     -- 指定压缩排序列（建议设为时间列降序）
--                     timescaledb.compress_orderby = 'data_time DESC'
--                     );
--             RAISE NOTICE 'Compress On';
--         ELSE
--             RAISE NOTICE 'Compress Exists';
--         END IF;
--     END
-- $$;

-- 加完压缩列还需要配置文件块的压缩周期

-- 这是 >=2.0 版本的方法
-- 删除现有的压缩策略，修改时应先删再加
-- SELECT remove_compression_policy('超表的表名');
-- 超过 7 天的数据自动转为列式压缩，极大节省空间并加速历史查询，默认为 1 天执行 1 次
SELECT add_compression_policy('超表的表名', INTERVAL '7 days');
-- 查询所有任务的视图，包括清理任务、压缩任务等
SELECT * FROM timescaledb_information.jobs;
-- 修改任务执行周期，入参为 jobid，执行完添加时会返回，也可以从任务表查
SELECT alter_job(1000, schedule_interval => INTERVAL '1 hour');


-- 这是 <2.0 版本的方法
-- 删除现有的压缩策略，修改时应先删再加
-- SELECT remove_compress_chunks_policy('超表的表名');
-- 超过 7 天的数据自动转为列式压缩，极大节省空间并加速历史查询，默认为 1 天执行 1 次
SELECT add_compress_chunks_policy('超表的表名', INTERVAL '7 days');
-- 压缩策略执行情况有几个地方可以查看，展示的信息各有不同
SELECT * FROM timescaledb_information.compressed_chunk_stats;
SELECT * FROM timescaledb_information.compressed_hypertable_stats;
SELECT * FROM _timescaledb_config.bgw_job WHERE job_type = 'compress_chunks';
-- 如果需要加快自动压缩的频率可以设置想要压缩的周期手动执行
SELECT compress_chunk(c) FROM show_chunks('超表的表名', older_than => INTERVAL '7 days') c;
```
> 如果不指定分区列但指定压缩列这也是可以的，因为查询时其实压缩列代偿了索引的功能，没有分区列只是不将数据进行物理分块，但压缩列依旧能快速完成数据定位。
>
> 分区列和压缩列都指定时，如果压缩列不包含分区列，那么查询时要么无法快速定位到分区块（条件用的是压缩列），要么无法从分区块里快速定位到数据（条件用的是分区列）。
>
> 周期的配置在修改时都应该先删再加，增加周期时对原策略影响不大，但缩减周期时需要谨慎，因为缩减后删除分区块是物理删除的，压缩后的块也不能自动解压缩。

如果需要自动删除超期的分区块，那么需要添加分区块的清理周期。

```sql
-- 这是 >=2.0 版本的方法
-- 删除现有的清理策略，修改时应先删再加
-- SELECT remove_retention_policy('超表的表名');
-- 超过 90 天的分区自动物理物理 Drop（满足最长保留周期），默认为 1 天执行 1 次
SELECT add_retention_policy('超表的表名', INTERVAL '90 days');
-- 查询所有任务的视图，包括清理任务、压缩任务等
SELECT * FROM timescaledb_information.jobs;
-- 修改任务执行周期，入参为 jobid，执行完添加时会返回，也可以从任务表查
SELECT alter_job(1000, schedule_interval => INTERVAL '1 hour');


-- 这是 <2.0 版本的方法
-- 删除现有的清理策略，修改时应先删再加
-- SELECT remove_drop_chunks_policy('超表的表名');
-- 超过 90 天的分区自动物理物理 Drop（满足最长保留周期），默认为 1 天执行 1 次
SELECT add_drop_chunks_policy('超表的表名', INTERVAL '90 days');
-- 查询所有超表清理周期的视图，查询的地方也不止一个
SELECT * FROM timescaledb_information.drop_chunks_policies;
SELECT * FROM _timescaledb_config.bgw_job WHERE job_type = 'drop_chunks';
-- 老版本没有直接修改执行周期的方法，有需要的话可以设置一个周期手动执行
SELECT drop_chunks(INTERVAL '30 days', '超表的表名');
```

> 需要注意，如果定义的清理周期不能总是刚好覆盖分区块的时间周期，那么当分区块中还有部分数据没有过期时，该分区块不会被删除直到所有数据都大于清理周期。
>
> 例如，分区块时间是 30 天每块，但是清理周期为 365 天，那么虽然清理操作是

持续聚合的定义：

```sql
-- timescaledb 1.x 用普通视图，2.x 用物化视图，不过各版本变化较多，实际创建时可以都尝试下
--   1.x 无法直接修改定义中的 SQL，但可以修改 WITH 定义中的参数，
--   如果要改 SQL 需要 DROP VIEW 重新 CREATE VIEW，这会导致统计结果丢失
-- WITH (timescaledb.continuous)：这是核心开关，告诉 TimescaleDB：“这不是普通的视图，请为它创建一个后台物理表来存结果”。
-- timescaledb.refresh_interval：刷新周期。指后台任务每隔多久运行一次（例如每小时算一次）。
-- timescaledb.refresh_lag：刷新延迟（水位线）。指刷新时忽略最近多久的数据。
--   因为时序数据常有延迟（网络抖动等），如果立即聚合，可能会漏掉还没跑到的数据。
--   设为 1h 表示现在只计算 1 小时前的数据，确保数据到齐。
-- time_bucket：必须存在。它定义了聚合的“颗粒度”（桶大小）。
CREATE VIEW device_summary_hourly 
WITH (
    timescaledb.continuous, 
    timescaledb.refresh_interval = '1h', 
    timescaledb.refresh_lag = '1h'
) 
AS
SELECT 
    time_bucket('1 hour', "time") AS bucket,
    device_id,
    avg(temperature) AS avg_temp
FROM sensor_data
GROUP BY bucket, device_id;
-- 如果想要实现聚合数据实时更新，那么可以修改视图配置，
-- 这样 timescaledb 会联合视图数据和主表数据统计合并后返回，
ALTER VIEW device_summary_hourly SET (timescaledb.materialized_only = false);
-- 如果太久的数据进入可能不会重算，手动触发内部存储过程可以指定补录时间段
-- 例如：手动刷新指定的时间区间（假设是 3 天前到 1 天前的数据）
SELECT _timescaledb_internal.refresh_continuous_aggregate(
    'device_summary_hourly'::regclass, -- 你的聚合视图名称
    '2023-10-01 00:00:00'::timestamptz, -- 窗口起点（必须早于补报数据的时间）
    '2023-10-03 00:00:00'::timestamptz  -- 窗口终点
);
-- 修改视图的刷新周期
ALTER VIEW device_summary_hourly SET (timescaledb.refresh_interval = '30m');
-- 手动触发持续聚合视图刷新
REFRESH MATERIALIZED VIEW device_summary_hourly;
-- 查看持续聚合执行信息
SELECT * FROM timescaledb_information.continuous_aggregates;
```
> 数据聚合这件事非常看业务，由于 1.x 时序表聚合修改难度大，所以最好一开时间定好业务聚合方式。

---

## 3.3. 历史数据补录 (Backfilling) 
前面提到数据一旦压缩就不太好修改，这个修改包含两部分内容，一部分是新的历史数据，另一部分是旧数据的修改，这里要讨论的内容同时涉及这两方面。通常来说补录的处理策略如下：

### 3.3.1.  零星数量补录
- **直接写入**：TimescaleDB 会自动找到对应历史时间的 Chunk 进行解压后再处理。
- **兼容性**：新版本（2.10+）才支持直接向已压缩的 Chunk 写入数据。

<span style="color: red;">**需要注意，如果定义的时间块比较大，那么为了降低解压开销，可以考虑将时间周期减小，例如从一月一块减小到一天一块。**</span>

### 3.3.2.  持续小规模补录

- **拉长压缩周期**：确保自动压缩周期内不会再有数据补录或不再接收超期数据时开始压缩
- **冷热表分离**：将超过自动压缩周期的数据放入冷表，等凌晨再统一发起解压、补录与压缩

自动压缩周期最好不要拉太长，否则过多数据无法压缩，会丧失列式压缩带来的性能优势。使用冷热表时，需要注意查询时应通过 UNION ALL 将两表的数据结合起来。

对于旧数据修改的情况，如果有条件的话可以考虑通过版本管理模式实现补录，增加**版本号**或**修改时间**字段，将修改后的行作为新数据插入，查询时只返回最新那条。

或者增加附表用于存放修改的列信息，查询时先将需要的数据查出来，再根据主键从附表中获取修改的列信息进行合并。


### 3.3.3. 大规模补录流程（性能最优）

1. **解压**：针对目标历史区间执行 `decompress_chunk()`。
2. **导入/修改**：使用 `COPY` 命令或并行导入工具或执行批量更新操作。
3. **重压缩**：导入或修改完成后重新执行 `compress_chunk()`。
4. **同步视图**：调用 `refresh_continuous_aggregate()` 刷新受影响的聚合报表。

---

## 3.4. 大文本列（TEXT/JSONB）专项优化
当表中含有 `TEXT` 等大数据列时，需防止其拖慢主表扫描速度。


| 优化手段     | 操作方法                                                | 核心目的                                                     |
| :----------- | :------------------------------------------------------ | :----------------------------------------------------------- |
| **存储模式** | `ALTER TABLE ... ALTER COLUMN ... SET STORAGE EXTERNAL` | 将大文本强制行外存储，保持主表“苗条”。                       |
| **分区粒度** | 缩短 `chunk_time_interval` (如设为 1 天)                | 防止包含大文本的单个物理 Chunk 过大（控制在 10-20GB）。      |
| **分表策略** | 垂直拆分：指标表（Thin）+ 详情表（Thick）               | 90% 的查询只读指标表，避免加载大文本，具体查询时才从详情表获取大数据列内容。 |
| **检索优化** | 使用 `GIN` 索引 + `pg_trgm`                             | 解决亿级文本下的模糊匹配（LIKE）性能问题。                   |

对整个大数据列应用`GIN`索引可能会导致空间膨胀，极端情况下可能比原表占用还大，所以最好是根据需要提取大数据列中的数据字段建立专用索引，如果对于性能要求较高可以考虑使用生成列（仅限PG12开始的版本可用，之前的版本需要使用触发器模拟这个功能）提取为物理存在的列数据。
> 在 PostgreSQL 中，生成列（Generated Column） 是一种特殊的列，它的值始终由表中其他列计算而来。你可以把它理解为数据库层面的“自动公式”。
>
> 目前 PostgreSQL（从 v12 开始）仅支持 STORED（存储式） 生成列，即计算结果会物理存储在磁盘上。
>
> 生成列通过 `GENERATED ALWAYS AS (表达式) STORED` 来定义。它具有以下特性：
>
> - **自动计算**：插入或更新原始列时，该列自动重新计算。
> - **物理存储**：占用磁盘空间，但查询速度和普通列一样快。
> - **不可手动修改**：你不能直接对生成列进行 `INSERT` 或 `UPDATE`。

---

## 3.5. 简要示例

### 3.5.1. 建表与初始化
```sql
CREATE TABLE sensor_data (
    time        TIMESTAMPTZ NOT NULL,
    device_id   INT NOT NULL,
    cpu_usage   DOUBLE PRECISION,
    payload     TEXT -- 大文本列
);

-- 1. 创建超表
SELECT create_hypertable('sensor_data', 'time', chunk_time_interval => INTERVAL '1 days');

-- 2. 优化大文本列存储，大小远超2KB时使用外部存储方式，如果能分离为附表更佳
ALTER TABLE sensor_data ALTER COLUMN payload SET STORAGE EXTERNAL;
```

### 3.5.2. 配置自动化策略


```sql
-- 开启压缩，按设备 ID 分组以提升压缩率
ALTER TABLE sensor_data SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'device_id'
);

-- 自动压缩 14 天前的数据
SELECT add_compression_policy('sensor_data', INTERVAL '14 days');

-- 自动删除 365 天前的数据（保留策略）
SELECT add_retention_policy('sensor_data', INTERVAL '365 days');
```

### 3.5.3. 查询加速：创建持续聚合

如果你需要查询“每日平均温度”等汇总信息，不要直接扫亿级大表，使用持续聚合视图 [3, 4]。

```sql
-- 创建持续聚合视图（相当于物化视图，但会自动增量更新）
CREATE MATERIALIZED VIEW sensor_day_stats
WITH (timescaledb.continuous) AS
SELECT time_bucket('1 day', time) AS day,
       device_id,
       AVG(cpu_usage) as avg_cpu,
       MAX(temperature) as max_temp
FROM sensor_data
GROUP BY day, device_id;

-- 设置自动刷新策略：每天刷新一次过去 3 天的数据
SELECT add_continuous_aggregate_policy('sensor_day_stats',
    start_offset => INTERVAL '3 days',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 day');
```

### 3.5.4. 核心场景：如何补录历史数据

补录历史数据时，由于数据可能落入**已压缩**的块或**已完成计算**的聚合视图中，需要特殊处理。

#### 步骤 1：向已压缩的时间段插入数据

在 TimescaleDB 2.11+ 版本中，可以直接执行 `INSERT`。但对于**亿级规模**的补录，建议先解压以获得最高写入速度 [5, 6]。

```sql
-- 如果补录范围很大（例如补录 2024 年 1 月的数据）
-- 1. 手动解压特定时间段的 Chunk
SELECT decompress_chunk(c, true) 
FROM show_chunks('sensor_data', '2024-01-01', '2024-01-31') c;

-- 2. 批量导入数据（建议使用 COPY 命令）
-- COPY sensor_data FROM 'data_2024_01.csv' WITH (FORMAT CSV);

-- 3. 补录完成后重新压缩
SELECT compress_chunk(c, true) 
FROM show_chunks('sensor_data', '2024-01-01', '2024-01-31') c;
```

#### 步骤 2：更新补录后的聚合报表

插入历史数据后，持续聚合视图不会自动回溯太远的时间。你需要手动触发一次刷新，确保报表准确 [7, 8]。

```sql
-- 手动刷新指定历史时间段的聚合数据
CALL refresh_continuous_aggregate(
    'sensor_day_stats', 
    '2024-01-01', 
    '2024-02-01'
);
```

### 3.5.5. 总结建议

| 操作           | 建议                                                         |
| :------------- | :----------------------------------------------------------- |
| **日常写入**   | 直接 `INSERT` 即可，TimescaleDB 会自动路由到最新的 Chunk。   |
| **小规模补录** | 直接插入。2.11 后的版本支持在压缩 Chunk 上直接增删改 [5]。   |
| **大规模补录** | **先解压 -> 批量导入 -> 重压缩 -> 刷新持续聚合**，这是性能最优解。 |
| **查询历史**   | 尽量查询**持续聚合视图**而非原始超表，速度可提升百倍。       |

## 3.6. 总结的总结

管理亿级 PG 数据的关键在于：**分而治之（Hypertable）**、**能省则省（Compression）**、**提前计算（Continuous Aggregates）**。对于大文本，应通过**存储模式调整**确保其不成为查询性能的“拖油瓶”。

# 4. TEXT、JSON与JSONB

简单来说，这三者在 PostgreSQL 中代表了从“纯文本”到“结构化二进制”的进化。

以下是它们的直观对比：

## 4.1. 核心区别对照表

| 特性           | **TEXT**             | **JSON**                  | **JSONB** (推荐)              |
| :------------- | :------------------- | :------------------------ | :---------------------------- |
| **存储格式**   | 纯字符串             | 完整文本拷贝              | **解析后的二进制格式**        |
| **写入速度**   | 极快 (无校验)        | 快 (仅验证语法)           | 略慢 (需转换成二进制)         |
| **查询速度**   | 慢 (需正则/全表扫描) | 慢 (每次查询都要重新解析) | **极快** (直接定位 key/value) |
| **索引支持**   | 全文检索/前缀索引    | 极受限                    | **强大 (支持 GIN 索引)**      |
| **空格与顺序** | 保留原始格式         | 保留原始格式              | 去除多余空格，不保留 key 顺序 |
| **重复 Key**   | 保留所有             | 保留所有                  | **自动去重** (保留最后一个)   |

------

## 4.2. 详细解读

**TEXT：原始载体**

- **本质**：就是一段没格式的长字符串。
- **缺点**：数据库完全不理解内容。如果你想查询 `where info ->> 'name' = '张三'`，数据库必须把整段文字读出来再用代码逻辑判断，性能极差。

**JSON：纯文本存储 (Legacy)**

- **本质**：带格式校验的 TEXT。
- **特点**：它会检查你存进去的是不是合法的 JSON 格式。
- **场景**：如果你只需要原封不动地存储并原样取出（例如：前端传什么我就存什么，连空格都要一模一样），可以使用它。但这种场景极少。

**JSONB：结构化二进制 (The Winner)**

- **本质**：**B** 代表 **Binary**。它在入库时就把 JSON 拆解成了树状的二进制结构。
- **优势**：
  - **查询飞快**：寻找某个 key 时不需要从头读字符串，而是直接通过偏移量定位。
  - **GIN 索引**：你可以给整个 JSONB 字段加一个 GIN 索引。哪怕里面有几百个 key，查询其中任何一个 key 的速度都是毫秒级的。
  - **处理能力**：支持多种内置操作符（如 `@>` 包含关系、`?` 键是否存在等）。

------

## 4.3. 选型建议

1. **绝大多数场景直接选 `JSONB`**：它是 PG 的明星特性，支持高效索引和亚秒级查询。
2. **只有在以下极端情况选 `JSON`**：
   - 你对写入性能有极致要求，且几乎从不在数据库层面查询内部字段。
   - 必须严格保留 JSON 原始的空格、缩进和 key 的重复性。
3. **不要选 `TEXT` 存储 JSON**：除非你的 PG 版本太低（低于 9.2），否则没有任何理由用 TEXT 存结构化数据，因为它缺乏语法校验且查询效率最低。

**总结一句话：** 只要你打算在 SQL 里用到 `->` 或 `->>` 这种操作符来查数据，请闭眼选 **`JSONB`**。

## 4.4. 支持情况

只要你的 PostgreSQL 版本在 **9.4**（2014年发布）或更高，你无需安装任何扩展（Extension）或进行额外配置，就可以直接在建表时使用 `JSONB` 类型。

关键特性

- **版本支持**：PostgreSQL 9.2 引入了基础的 `JSON` 类型（仅文本校验），而更强大的 `JSONB`（二进制存储，支持索引）在 **9.4 版本** 正式加入。

- **无需扩展**：与需要手动执行 `CREATE EXTENSION` 的插件（如 `postgis` 或 `timescaledb`）不同，`JSONB` 是核心代码库的一部分。

- **使用方式**：直接在 `CREATE TABLE` 语句中定义即可：

    ```sql
    CREATE TABLE example (
      id serial PRIMARY KEY,
      data JSONB  -- 直接使用，无需额外操作
    );
    ```

为什么说它比 JSON “更好”？

虽然 `JSON` 和 `JSONB` 都是内置的，但业界普遍建议将 `JSONB` 作为默认选择：

- **性能**：`JSONB` 以二进制格式存储，虽然写入时有微小的转换开销，但查询时不需要重新解析，速度远快于 `JSON`。

- **索引支持**：`JSONB` 支持 GIN（通用反向索引），可以对 JSON 内部的键值对进行高效检索。

- **灵活性**：它会自动去除多余空格并压缩存储，且不保留键的重复项。

## 4.5. 大表优化

在处理上亿级（100M+）数据量时，`TEXT`、`JSON` 和 `JSONB` 的性能表现差异巨大。由于数据量极大，优化核心在于减少 I/O 扫描和**索引效率**。

以下是针对这三种类型在 TimescaleDB/PostgreSQL 亿级场景下的专项优化方案：

### 4.5.1. TEXT

作为“原始载体”的优化。在亿级数据中，`TEXT` 通常用于存储日志或描述。

- **优化手段**：`SET STORAGE EXTERNAL`。
- **原理**：强制将长文本移出主表（TOAST 存储）。这样在进行 `COUNT(*)` 或按时间范围聚合数值时，数据库不需要跳过巨大的文本块，扫描速度提升 5-10 倍。
- **搜索**：禁止使用 `LIKE '%word%'`。必须使用 `pg_trgm` 扩展建立 **GIN 索引**。

### 4.5.2. JSON

最不推荐的亿级选项

- **问题**：`JSON` 每次查询都要重新解析整个字符串。在亿级数据下，任何涉及内部字段的查询都会导致 CPU 爆满。
- **优化建议**：**将其转换为 `JSONB` 或 `TEXT`**。
  - 如果你不需要查询内部字段，用 `TEXT` 并配合 `STORAGE EXTERNAL`。
  - 如果你需要查询内部字段，立即迁移到 `JSONB`。

### 4.5.3. JSONB

亿级结构化数据的“王牌”。`JSONB` 是处理非结构化亿级数据的首选，但如果不优化，索引会比数据还大。

A. 索引瘦身：表达式索引 (Expression Index)

不要对整个 `JSONB` 字段建 GIN 索引（索引会非常臃肿）。

- **优化**：只针对高频查询的键建索引。

  ```sql
  -- 仅对 JSONB 内部的 device_id 建索引，而不是整个 JSONB
  CREATE INDEX idx_json_device ON sensor_data ((payload->>'device_id'));
  ```

B. 局部 GIN 索引 (Partial GIN Index)

- **优化**：如果你只关心特定类型的 JSON 数据，可以建立带 `WHERE` 条件的索引。

  ```sql
  CREATE INDEX idx_error_logs ON sensor_data USING GIN (payload) 
  WHERE (payload->>'status' = 'error');
  ```

C. 列式压缩与 JSONB

TimescaleDB 的压缩对 `JSONB` 非常友好。

- **优化**：开启 TimescaleDB 压缩。它能识别 `JSONB` 中的重复键名，并通过列式存储大幅降低冗余，压缩率通常能达到 80% 以上。

------

## 4.6. 综合对比与选型指南 (亿级规模)

| 类型      | 存储占用      | 查询性能 | 推荐优化方案                                                 |
| :-------- | :------------ | :------- | :----------------------------------------------------------- |
| **TEXT**  | 中            | 极低     | `STORAGE EXTERNAL` + `GIN Trigram` 索引                      |
| **JSON**  | 高            | 极低     | **不建议在亿级规模使用**，应转为 JSONB                       |
| **JSONB** | 极高 (索引大) | **极高** | **1. 开启 TimescaleDB 压缩** **2. 使用表达式索引而非全量 GIN** **3. 缩短超表分区区间 (Chunk Interval)** |

专家建议：垂直拆分 (The "Gold" Standard)

对于亿级数据，最极致的优化是**“动静分离”**：

1. **超表 (主表)**：只存放 `time`, `id`, `value` 等固定格式的数值。
2. **详情表 (JSONB 表)**：存放不规则的 `JSONB` 数据。
3. **查询策略**：99% 的时序分析只查主表。只有当用户点击“查看详情”时，再通过 `time` 和 `id` 去 JSONB 表中提取单行数据。

**总结：** 在亿级场景下，**JSONB + TimescaleDB 压缩 + 局部索引** 是兼顾灵活性与性能的最佳组合。

# X. 如何基于源码在 Linux 上部署 PG

官方安装文档地址：https://www.postgresql.org/docs/current/installation.html

源码包下载地址：https://www.postgresql.org/ftp/source/

1. 先从https://www.postgresql.org/ftp/source/下载所需版本的源码（bz2的包）

2. 使用`tar xf postgresql-<version>.tar.bz2`解压源码包并进入其中

3. 使用`./configure`检查编译环境，如果有不满足的会提升，可以试着根据提示加参数屏蔽某些检查

4. 直接执行`make`开始编译，正常来说执行完就编译完了，如果失败了就根据错误信息进行搜索

5. 使用`su`切换到 root 权限，再执行`make install`开始 PG 的安装

6. 添加 postgres 用户：`adduser postgres`并设置密码

7. 为 PG 创建数据目录，可以建在 PG 的安装目录（`/usr/local/pgsql`）也可以另外找目录

   ```sh
   mkdir -p /usr/local/pgsql/data
   或
   mkdir -p /opt/pg-data
   ```

8. 为数据目录设置所属`chown postgres /opt/pg-data`

9. 切换到 postgres 用户`su - postgres`

10. 初始化数据目录`/usr/local/pgsql/bin/initdb -D /opt/pg-data`

11. 启动 PG 服务`/usr/local/pgsql/bin/pg_ctl -D /opt/pg-data -l logfile start`

12. 【可选】超管密码可能需要在 pg_hba.conf 里启用受信地址后登录上去指定

    ```sh
    /usr/local/pgsql/bin/psql postgres
    ALTER USER user_name WITH PASSWORD 'new_password';
    ```

13. 【可选】远程登录需要修改 postgresql.conf 启用 listen_addresses 配置 ( * 表示所有)

14. 【可选】创建数据库`/usr/local/pgsql/bin/createdb test`

15. 【可选】连接数据库`/usr/local/pgsql/bin/psql test`
