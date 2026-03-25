package codegen

// PostgreSQL → Odin type mapping.

Odin_Type :: struct {
	name:     string, // e.g. "i32", "string", "bool"
	nullable: string, // e.g. "Maybe(i32)", "Maybe(string)"
	getter:   string, // e.g. "get_i32", "get_string"
	null_get: string, // e.g. "get_maybe_i32", "get_maybe_string"
}

// Map a PostgreSQL type name to an Odin type.
pg_to_odin :: proc(pg_type: string, is_enum: bool) -> Odin_Type {
	if is_enum {
		return Odin_Type {
			name     = "", // filled in by caller with enum type name
			nullable = "",
			getter   = "get_string",
			null_get = "get_maybe_string",
		}
	}

	switch pg_type {
	// Integer types
	case "int2", "smallint", "smallserial":
		return Odin_Type{"i16", "Maybe(i16)", "get_i16", "get_maybe_i16"}
	case "int4", "integer", "serial", "int":
		return Odin_Type{"i32", "Maybe(i32)", "get_i32", "get_maybe_i32"}
	case "int8", "bigint", "bigserial":
		return Odin_Type{"i64", "Maybe(i64)", "get_i64", "get_maybe_i64"}

	// Float types
	case "float4", "real":
		return Odin_Type{"f32", "Maybe(f32)", "get_f32", "get_maybe_f32"}
	case "float8", "double precision":
		return Odin_Type{"f64", "Maybe(f64)", "get_f64", "get_maybe_f64"}

	// Boolean
	case "bool", "boolean":
		return Odin_Type{"bool", "Maybe(bool)", "get_bool", "get_maybe_bool"}

	// Text types
	case "text", "varchar", "character varying", "char", "character", "name", "citext", "bpchar":
		return Odin_Type{"string", "Maybe(string)", "get_string", "get_maybe_string"}

	// Binary
	case "bytea":
		return Odin_Type{"[]byte", "Maybe([]byte)", "get_bytes", "get_maybe_bytes"}

	// JSON
	case "json", "jsonb":
		return Odin_Type{"[]byte", "Maybe([]byte)", "get_bytes", "get_maybe_bytes"}

	// UUID
	case "uuid":
		return Odin_Type{"string", "Maybe(string)", "get_string", "get_maybe_string"}

	// Timestamp / Date / Time
	case "timestamp", "timestamptz", "timestamp without time zone", "timestamp with time zone":
		return Odin_Type{"string", "Maybe(string)", "get_string", "get_maybe_string"}
	case "date":
		return Odin_Type{"string", "Maybe(string)", "get_string", "get_maybe_string"}
	case "time", "timetz", "time without time zone", "time with time zone":
		return Odin_Type{"string", "Maybe(string)", "get_string", "get_maybe_string"}
	case "interval":
		return Odin_Type{"string", "Maybe(string)", "get_string", "get_maybe_string"}

	// Numeric / Money
	case "numeric", "decimal", "money":
		return Odin_Type{"string", "Maybe(string)", "get_string", "get_maybe_string"}

	// Network
	case "inet", "cidr", "macaddr", "macaddr8":
		return Odin_Type{"string", "Maybe(string)", "get_string", "get_maybe_string"}

	// OID
	case "oid":
		return Odin_Type{"i32", "Maybe(i32)", "get_i32", "get_maybe_i32"}

	// void
	case "void":
		return Odin_Type{"", "", "", ""}
	}

	// Default: treat as string
	return Odin_Type{"string", "Maybe(string)", "get_string", "get_maybe_string"}
}

// Get the Odin type string for a column, considering nullability and arrays.
odin_type_str :: proc(
	pg_type: string,
	not_null: bool,
	is_array: bool,
	is_enum: bool,
	enum_name: string,
) -> string {
	ot := pg_to_odin(pg_type, is_enum)
	base := is_enum ? enum_name : ot.name

	if is_array {
		if not_null {
			return concat("[]", base)
		} else {
			return concat("Maybe([]", base, ")")
		}
	}

	if not_null {
		return base
	}
	if is_enum {
		return concat("Maybe(", enum_name, ")")
	}
	return ot.nullable
}

// Get the pq getter proc name for a column.
odin_getter :: proc(pg_type: string, not_null: bool, is_array: bool, is_enum: bool) -> string {
	if is_array {
		// Arrays need special handling — read as string and parse
		return not_null ? "get_string" : "get_maybe_string"
	}
	ot := pg_to_odin(pg_type, is_enum)
	return not_null ? ot.getter : ot.null_get
}

concat :: proc(parts: ..string) -> string {
	total := 0
	for p in parts {total += len(p)}
	buf := make([]byte, total)
	offset := 0
	for p in parts {
		copy(buf[offset:], transmute([]byte)p)
		offset += len(p)
	}
	return string(buf)
}
