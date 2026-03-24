package pg_query

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:mem"

Error_Info :: struct {
	message:   string,
	funcname:  string,
	filename:  string,
	lineno:    int,
	cursorpos: int,
	ctx:       string,
}

Parsed_Stmt :: struct {
	stmt_json: json.Value,
	location:  i32,
	length:    i32,
}

parse :: proc(
	sql: string,
	allocator := context.allocator,
) -> (stmts: [dynamic]Parsed_Stmt, err: Maybe(Error_Info)) {
	c_sql := strings.clone_to_cstring(sql, context.temp_allocator)
	result := pg_query_parse(c_sql)
	defer pg_query_free_parse_result(result)

	if result.error != nil {
		e := result.error
		return {}, Error_Info{
			message   = _clone_cstring(e.message, allocator),
			funcname  = _clone_cstring(e.funcname, allocator),
			filename  = _clone_cstring(e.filename, allocator),
			lineno    = int(e.lineno),
			cursorpos = int(e.cursorpos),
			ctx       = _clone_cstring(e.ctx, allocator),
		}
	}

	if result.parse_tree == nil {
		return {}, nil
	}

	json_str := string(result.parse_tree)
	parsed, json_err := json.parse_string(json_str, .JSON, false, allocator)
	if json_err != nil {
		return {}, Error_Info{
			message = fmt.aprintf("failed to parse libpg_query JSON output: %v", json_err, allocator = allocator),
		}
	}

	root, root_ok := parsed.(json.Object)
	if !root_ok {
		return {}, Error_Info{message = "expected JSON object from libpg_query"}
	}

	stmts_val, stmts_ok := root["stmts"]
	if !stmts_ok {
		return {}, nil
	}

	stmts_arr, arr_ok := stmts_val.(json.Array)
	if !arr_ok {
		return {}, Error_Info{message = "expected stmts to be a JSON array"}
	}

	result_stmts := make([dynamic]Parsed_Stmt, 0, len(stmts_arr), allocator)

	for stmt_val in stmts_arr {
		stmt_obj, obj_ok := stmt_val.(json.Object)
		if !obj_ok {
			continue
		}

		ps := Parsed_Stmt{}

		if s, ok := stmt_obj["stmt"]; ok {
			ps.stmt_json = s
		}

		if loc, ok := stmt_obj["stmt_location"]; ok {
			#partial switch v in loc {
			case json.Integer:
				ps.location = i32(v)
			case json.Float:
				ps.location = i32(v)
			case:
			// ignore
			}
		}

		if slen, ok := stmt_obj["stmt_len"]; ok {
			#partial switch v in slen {
			case json.Integer:
				ps.length = i32(v)
			case json.Float:
				ps.length = i32(v)
			case:
			// ignore
			}
		}

		append(&result_stmts, ps)
	}

	return result_stmts, nil
}

normalize :: proc(sql: string, allocator := context.allocator) -> (string, Maybe(Error_Info)) {
	c_sql := strings.clone_to_cstring(sql, context.temp_allocator)
	result := pg_query_normalize(c_sql)
	defer pg_query_free_normalize_result(result)

	if result.error != nil {
		e := result.error
		return "", Error_Info{
			message = _clone_cstring(e.message, allocator),
		}
	}

	if result.normalized_query == nil {
		return "", nil
	}

	return strings.clone_from_cstring(result.normalized_query, allocator), nil
}

fingerprint :: proc(sql: string, allocator := context.allocator) -> (string, Maybe(Error_Info)) {
	c_sql := strings.clone_to_cstring(sql, context.temp_allocator)
	result := pg_query_fingerprint(c_sql)
	defer pg_query_free_fingerprint_result(result)

	if result.error != nil {
		e := result.error
		return "", Error_Info{
			message = _clone_cstring(e.message, allocator),
		}
	}

	if result.fingerprint_str == nil {
		return "", nil
	}

	return strings.clone_from_cstring(result.fingerprint_str, allocator), nil
}

_clone_cstring :: proc(cs: cstring, allocator: mem.Allocator) -> string {
	if cs == nil {
		return ""
	}
	return strings.clone_from_cstring(cs, allocator)
}
