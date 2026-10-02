#pragma once

#include "duckdb.hpp"
#include "duckdb/main/extension/extension_loader.hpp"

namespace duckdb {

// Registers the `zscore('file.parquet', 'column')` table function: decodes the named INT32 column on
// the FPGA and runs the 2-pass z-score outlier detector, returning one BOOLEAN column `is_outlier`
// (one row per value, true when the value is flagged as an outlier).
void RegisterZScoreFunction(ExtensionLoader &loader);

} // namespace duckdb
