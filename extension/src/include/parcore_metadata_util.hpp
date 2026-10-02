#pragma once

#include "duckdb.hpp"
#include "parcore/metadata/metadata.hpp"
#include "parquet_reader.hpp"

namespace duckdb {

// Builds the ParCore metadata (column names, row groups, per-column-chunk type/compression/offset)
// from an already-opened DuckDB ParquetReader's footer. Throws InvalidInputException for Parquet
// physical types or compression codecs that ParCore does not support.
parcore::metadata::Metadata BuildParcoreMetadata(ParquetReader &parquet_reader);

// Largest absolute value of INT32 column `col_id`, taken from the per-row-group statistics in the
// footer (no data pages are read). Returns false -- leaving `abs_max` untouched -- if any row group
// omits min/max for that column, since a bound derived from only some groups is not a bound at all.
// Parquet statistics are allowed to be conservative (wider than the true range), which is the safe
// direction for an overflow check.
bool ParquetInt32ColumnAbsMax(ParquetReader &parquet_reader, size_t col_id, int64_t &abs_max);

} // namespace duckdb
