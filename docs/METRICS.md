# Metrics reference

All 39 series produced by `monerod-exporter`, generated from the exporter itself.

Everything is a gauge. `monerod_*` comes from the node's RPC; `pinodexmr_*` is read from the device.

## Node status

| Metric | Description |
|---|---|
| `monerod_up` | Whether monerod RPC is reachable (1=up, 0=down). |
| `monerod_info{version,network}` | Monerod version and network info labels. |
| `monerod_height` | Current blockchain height. |
| `monerod_target_height` | Target sync height from peers (0 when synced). |
| `monerod_sync_progress` | Sync progress percentage (0-100). |
| `monerod_synchronized` | Whether the node is fully synchronized (1=yes, 0=no). |
| `monerod_busy_syncing` | Whether the node is currently syncing (1=yes, 0=no). |
| `monerod_start_time_seconds` | Unix timestamp when monerod was started. |
| `monerod_update_available` | Whether a monerod update is available (1=yes, 0=no). |

## Network and peers

| Metric | Description |
|---|---|
| `monerod_connections_incoming` | Number of incoming P2P connections. |
| `monerod_connections_outgoing` | Number of outgoing P2P connections. |
| `monerod_rpc_connections` | Number of active RPC connections. |
| `monerod_white_peerlist_size` | Number of peers in the white (known good) peerlist. |
| `monerod_grey_peerlist_size` | Number of peers in the grey (untested) peerlist. |

## Blockchain and mining

| Metric | Description |
|---|---|
| `monerod_difficulty` | Current network mining difficulty. |
| `monerod_cumulative_difficulty` | Cumulative difficulty of the chain. |
| `monerod_tx_count` | Total number of transactions in the blockchain. |
| `monerod_fee_per_byte_atomic` | Estimated fee per byte in atomic units. |
| `monerod_block_size_limit` | Current block size limit in bytes. |
| `monerod_block_weight_limit` | Current block weight limit. |

## Mempool

| Metric | Description |
|---|---|
| `monerod_tx_pool_size` | Number of transactions in the mempool. |
| `monerod_pool_bytes_total` | Total bytes of transactions in the mempool. |
| `monerod_pool_txs_total` | Total transactions in mempool (from pool stats). |
| `monerod_pool_fee_total` | Total fees of transactions in the mempool (atomic units). |
| `monerod_pool_double_spends` | Number of double spend attempts in pool. |

## Last block

| Metric | Description |
|---|---|
| `monerod_last_block_reward` | Block reward of the last block in atomic units. |
| `monerod_last_block_size_bytes` | Size of the last block in bytes. |
| `monerod_last_block_txes` | Number of transactions in the last block. |
| `monerod_last_block_timestamp` | Unix timestamp of the last block. |
| `monerod_last_block_difficulty` | Difficulty of the last block. |

## Hard fork

| Metric | Description |
|---|---|
| `monerod_hardfork_version` | Current hard fork version. |
| `monerod_hardfork_voting` | Hard fork version being voted for. |
| `monerod_hardfork_enabled` | Whether the current hard fork is enabled (1=yes, 0=no). |

## Storage and device

| Metric | Description |
|---|---|
| `monerod_database_size_bytes` | Size of the blockchain database in bytes. |
| `monerod_free_space_bytes` | Free disk space on blockchain volume in bytes. |
| `pinodexmr_cpu_temp_celsius` | SoC temperature of the device. |

## Exporter health

| Metric | Description |
|---|---|
| `monerod_exporter_consecutive_failures` | Consecutive RPC failures. |
| `monerod_exporter_scrape_duration_seconds` | Time taken by the last successful scrape. |
| `monerod_exporter_last_scrape_timestamp_seconds` | Unix time of the last scrape attempt. |

## Notes

**`monerod_target_height` is 0 when the node is synced.** monerod only reports a target while catching up, which is why `monerod_sync_progress` falls back to 100 when `monerod_synchronized` is 1.

**Atomic units.** Rewards and fees are in atomic units: 1 XMR = 10^12 atomic units. The dashboard converts for display.

**`pinodexmr_cpu_temp_celsius` reads 0** when the device exposes no thermal zone the exporter recognises. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md#cpu-temperature-reads-0).

**On failure** the exporter writes only `monerod_up 0`, `monerod_exporter_consecutive_failures` and `monerod_exporter_last_scrape_timestamp_seconds`, so stale values are never served as if current.

**Host metrics come free.** Because these ride node_exporter, every standard `node_*` metric — CPU, memory, disk, network, filesystem — is available on the same endpoint with the same `instance` label.

## Useful queries

```promql
# Blocks added per hour
rate(monerod_height[1h]) * 3600

# Seconds since the last block
time() - monerod_last_block_timestamp

# Node uptime in days
(time() - monerod_start_time_seconds) / 86400

# Database growth per day, in GB
rate(monerod_database_size_bytes[24h]) * 86400 / 1e9

# Last block reward in XMR
monerod_last_block_reward / 1e12

# Total peer connections
monerod_connections_incoming + monerod_connections_outgoing

# Alert: node down for 5 minutes
monerod_up == 0

# Alert: sync stalled (height unchanged for 30 minutes while not synced)
increase(monerod_height[30m]) == 0 and monerod_synchronized == 0

# Alert: free space below 20 GB
monerod_free_space_bytes < 20e9
```
