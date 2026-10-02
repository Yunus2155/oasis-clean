#include "parcore_metadata_util.hpp"

#include "duckdb/common/exception.hpp"
#include "parquet_types.h"

#include <algorithm>
#include <cstring>

namespace duckdb {

static parcore::metadata::Type parquet_type_to_parcore(duckdb_parquet::Type::type t) {
	switch (t) {
	case duckdb_parquet::Type::BOOLEAN:
		return parcore::metadata::Type::BYTE_T;
	case duckdb_parquet::Type::INT32:
		return parcore::metadata::Type::INT32_T;
	case duckdb_parquet::Type::FLOAT:
		return parcore::metadata::Type::FLOAT_T;
	case duckdb_parquet::Type::INT64:
		return parcore::metadata::Type::INT64_T;
	case duckdb_parquet::Type::DOUBLE:
		return parcore::metadata::Type::DOUBLE_T;
	case duckdb_parquet::Type::BYTE_ARRAY:
		return parcore::metadata::Type::BYTE_ARRAY;
	default:
		throw InvalidInputException("Parquet physical type %d not supported by ParCore", (int)t);
	}
}

static parcore::metadata::Compression parquet_codec_to_parcore(duckdb_parquet::CompressionCodec::type c) {
	switch (c) {
	case duckdb_parquet::CompressionCodec::UNCOMPRESSED:
		return parcore::metadata::Compression::RAW;
	case duckdb_parquet::CompressionCodec::SNAPPY:
		return parcore::metadata::Compression::SNAPPY;
	default:
		throw InvalidInputException("Parquet compression codec %d not supported by ParCore", (int)c);
	}
}

parcore::metadata::Metadata BuildParcoreMetadata(ParquetReader &parquet_reader) {
	auto *file_meta = parquet_reader.GetFileMetadata();

	parcore::metadata::Metadata meta;

	for (auto &col : parquet_reader.columns) {
		meta.column_names.push_back(col.name.GetIdentifierName());
	}

	for (auto &rg : file_meta->row_groups) {
		parcore::metadata::RowGroup parcore_rg;

		for (auto &col_chunk : rg.columns) {
			auto &cmd = col_chunk.meta_data;

			parcore::metadata::ColumnChunk parcore_cc;
			parcore_cc.type = parquet_type_to_parcore(cmd.type);
			parcore_cc.num_values = static_cast<uint64_t>(cmd.num_values);
			parcore_cc.compression = parquet_codec_to_parcore(cmd.codec);
			parcore_cc.offset = static_cast<uint64_t>(cmd.__isset.dictionary_page_offset ? cmd.dictionary_page_offset
			                                                                             : cmd.data_page_offset);
			parcore_cc.total_compressed_size = static_cast<uint64_t>(cmd.total_compressed_size);

			parcore_rg.chunks.push_back(std::move(parcore_cc));
		}

		meta.groups.push_back(std::move(parcore_rg));
	}

	return meta;
}

// Decodes a PLAIN-encoded INT32 statistics value (4 bytes, little endian).
static bool decode_int32_stat(const std::string &raw, int32_t &out) {
	if (raw.size() != sizeof(int32_t)) {
		return false;
	}
	std::memcpy(&out, raw.data(), sizeof(int32_t));
	return true;
}

bool ParquetInt32ColumnAbsMax(ParquetReader &parquet_reader, size_t col_id, int64_t &abs_max) {
	auto *file_meta = parquet_reader.GetFileMetadata();

	int64_t running = 0;

	for (auto &rg : file_meta->row_groups) {
		if (col_id >= rg.columns.size()) {
			return false;
		}
		auto &cmd = rg.columns[col_id].meta_data;
		if (!cmd.__isset.statistics) {
			return false;
		}
		auto &stats = cmd.statistics;

		// Prefer min_value/max_value; fall back to the deprecated min/max that older writers emit.
		const bool have_new = stats.__isset.min_value && stats.__isset.max_value;
		const bool have_old = stats.__isset.min && stats.__isset.max;
		if (!have_new && !have_old) {
			return false;
		}
		const std::string &lo_raw = have_new ? stats.min_value : stats.min;
		const std::string &hi_raw = have_new ? stats.max_value : stats.max;

		int32_t lo = 0;
		int32_t hi = 0;
		if (!decode_int32_stat(lo_raw, lo) || !decode_int32_stat(hi_raw, hi)) {
			return false;
		}

		// Negated in 64-bit: |INT32_MIN| does not fit in an int32_t.
		const int64_t lo_abs = lo < 0 ? -(int64_t)lo : (int64_t)lo;
		const int64_t hi_abs = hi < 0 ? -(int64_t)hi : (int64_t)hi;
		running = std::max(running, std::max(lo_abs, hi_abs));
	}

	abs_max = running;
	return true;
}

} // namespace duckdb
