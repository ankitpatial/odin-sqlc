package pg_query

import "core:c"

when ODIN_OS == .Windows {
	LIB :: #config(PG_QUERY_LIB, "../vendor/libpg_query/lib/pg_query.lib")
} else {
	LIB :: #config(PG_QUERY_LIB, "../vendor/libpg_query/lib/libpg_query.a")
}

foreign import pg_query_lib {LIB}

Parse_Error :: struct {
	message:   cstring,
	funcname:  cstring,
	filename:  cstring,
	lineno:    c.int,
	cursorpos: c.int,
	ctx:       cstring,
}

Parse_Result :: struct {
	parse_tree:    cstring,
	stderr_buffer: cstring,
	error:         ^Parse_Error,
}

Normalize_Result :: struct {
	normalized_query: cstring,
	error:            ^Parse_Error,
}

Fingerprint_Result :: struct {
	fingerprint:     c.uint64_t,
	fingerprint_str: cstring,
	stderr_buffer:   cstring,
	error:           ^Parse_Error,
}

Split_Stmt :: struct {
	stmt_location: c.int,
	stmt_len:      c.int,
}

Split_Result :: struct {
	stmts:         [^]^Split_Stmt,
	n_stmts:       c.int,
	stderr_buffer: cstring,
	error:         ^Parse_Error,
}

@(default_calling_convention = "c")
foreign pg_query_lib {
	pg_query_parse :: proc(input: cstring) -> Parse_Result ---
	pg_query_normalize :: proc(input: cstring) -> Normalize_Result ---
	pg_query_fingerprint :: proc(input: cstring) -> Fingerprint_Result ---
	pg_query_split_with_scanner :: proc(input: cstring) -> Split_Result ---
	pg_query_free_parse_result      :: proc(result: Parse_Result) ---
	pg_query_free_normalize_result  :: proc(result: Normalize_Result) ---
	pg_query_free_fingerprint_result :: proc(result: Fingerprint_Result) ---
	pg_query_free_split_result      :: proc(result: Split_Result) ---
}
