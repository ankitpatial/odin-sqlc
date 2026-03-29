package codegen

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "../catalog"
import "../config"
import "../metadata"

// Embed the pg/ package source files at compile time.
// These get written into {out_dir}/pq/ so generated code is self-contained.
PQ_PG_ODIN :: #load("../pg/pg.odin", string)
PQ_ERROR_ODIN :: #load("../pg/error.odin", string)
PQ_VALUE_ODIN :: #load("../pg/value.odin", string)

Generated_File :: struct {
	path:    string,
	content: string,
}

Query_Group :: struct {
	filename: string,
	queries:  [dynamic]^Query,
}

// Which table/enum names a query file references.
Model_Refs :: struct {
	tables: map[string]bool,
	enums:  map[string]bool,
}

// Generate all output files from the catalog and analyzed queries.
generate :: proc(
	cat: ^catalog.Catalog,
	queries: []Query,
	pkg_name: string,
	out_dir: string,
	naming: config.Naming = .pascal,
	allocator := context.allocator,
) -> [dynamic]Generated_File {
	files := make([dynamic]Generated_File, 0, 8, allocator)

	// Group queries by source file
	groups := make(map[string]^Query_Group, 8, context.temp_allocator)
	for &q in queries {
		base := filepath.base(q.filename)
		group, exists := groups[base]
		if !exists {
			g := new(Query_Group, context.temp_allocator)
			g.filename = base
			g.queries = make([dynamic]^Query, 0, 8, context.temp_allocator)
			groups[base] = g
			group = g
		}
		append(&group.queries, &q)
	}

	// Collect model references per file
	file_refs := make(map[string]^Model_Refs, 8, context.temp_allocator)
	for name, group in groups {
		refs := new(Model_Refs, context.temp_allocator)
		refs.tables = make(map[string]bool, 8, context.temp_allocator)
		refs.enums = make(map[string]bool, 8, context.temp_allocator)
		collect_model_refs(group.queries[:], cat, refs)
		file_refs[name] = refs
	}

	// Count how many files reference each model
	table_ref_count := make(map[string]int, 16, context.temp_allocator)
	enum_ref_count := make(map[string]int, 8, context.temp_allocator)
	for _, refs in file_refs {
		for tbl_name, _ in refs.tables {
			table_ref_count[tbl_name] =
				(tbl_name in table_ref_count ? table_ref_count[tbl_name] : 0) + 1
		}
		for enum_name, _ in refs.enums {
			enum_ref_count[enum_name] =
				(enum_name in enum_ref_count ? enum_ref_count[enum_name] : 0) + 1
		}
	}

	// Determine shared vs file-local models
	shared_tables := make(map[string]bool, 8, context.temp_allocator)
	shared_enums := make(map[string]bool, 8, context.temp_allocator)
	for tbl_name, count in table_ref_count {
		if count > 1 {shared_tables[tbl_name] = true}
	}
	for enum_name, count in enum_ref_count {
		if count > 1 {shared_enums[enum_name] = true}
	}

	// Generate models.odin only if there are shared models
	if len(shared_tables) > 0 || len(shared_enums) > 0 {
		models := gen_models(cat, pkg_name, shared_tables, shared_enums, allocator)
		append(
			&files,
			Generated_File {
				path = filepath.join({out_dir, "models.odin"}, allocator) or_else "",
				content = models,
			},
		)
	}

	// Generate query files with their local models
	for name, group in groups {
		refs := file_refs[name]
		out_name := strings.concatenate({group.filename, ".odin"}, allocator)
		content := gen_query_file(
			cat,
			group.queries[:],
			pkg_name,
			refs,
			shared_tables,
			shared_enums,
			naming,
			allocator,
		)
		append(
			&files,
			Generated_File {
				path = filepath.join({out_dir, out_name}, allocator) or_else "",
				content = content,
			},
		)
	}

	// Generate db.odin helper
	db := gen_db_helper(pkg_name, allocator)
	append(
		&files,
		Generated_File {
			path = filepath.join({out_dir, "db.odin"}, allocator) or_else "",
			content = db,
		},
	)

	// Bundle the pg/ (libpq bindings) package.
	// Source files declare "package pq" — rewrite to "package pg" for the output directory name.
	pg_dir := filepath.join({out_dir, "pg"}, allocator) or_else ""
	pg_src, _ := strings.replace(PQ_PG_ODIN, "package pq", "package pg", 1, allocator)
	err_src, _ := strings.replace(PQ_ERROR_ODIN, "package pq", "package pg", 1, allocator)
	val_src, _ := strings.replace(PQ_VALUE_ODIN, "package pq", "package pg", 1, allocator)
	append(
		&files,
		Generated_File {
			path = filepath.join({pg_dir, "pg.odin"}, allocator) or_else "",
			content = pg_src,
		},
	)
	append(
		&files,
		Generated_File {
			path = filepath.join({pg_dir, "error.odin"}, allocator) or_else "",
			content = err_src,
		},
	)
	append(
		&files,
		Generated_File {
			path = filepath.join({pg_dir, "value.odin"}, allocator) or_else "",
			content = val_src,
		},
	)

	return files
}

// Collect which tables and enums a set of queries references.
collect_model_refs :: proc(queries: []^Query, cat: ^catalog.Catalog, refs: ^Model_Refs) {
	for q in queries {
		// Check if return type matches a table
		tbl := find_matching_table(q, cat)
		if tbl != nil {
			refs.tables[tbl.name] = true
			// Also check if any column uses an enum type
			for col in tbl.columns {
				if catalog.is_enum_type(cat, col.data_type) {
					refs.enums[col.data_type] = true
				}
			}
		}
		// Check columns for enum refs (custom Row structs too)
		for col in q.columns {
			if col.is_enum {refs.enums[col.data_type] = true}
		}
		// Check params for enum refs
		for p in q.params {
			if p.is_enum {refs.enums[p.data_type] = true}
		}
	}
}

// Write generated files to disk.
write_files :: proc(files: []Generated_File) -> bool {
	for f in files {
		dir := filepath.dir(f.path)
		if !os.exists(dir) {
			err := os.make_directory(dir)
			if err != nil {
				fmt.eprintf("error: cannot create directory '%s'\n", dir)
				return false
			}
		}

		write_err := os.write_entire_file_from_string(f.path, f.content)
		if write_err != nil {
			fmt.eprintf("error: cannot write file '%s'\n", f.path)
			return false
		}
	}
	return true
}

// ── models.odin — only shared models ──────────────────────────

gen_models :: proc(
	cat: ^catalog.Catalog,
	pkg_name: string,
	shared_tables: map[string]bool,
	shared_enums: map[string]bool,
	allocator := context.allocator,
) -> string {
	buf := strings.builder_make(allocator)
	wl(&buf, "// Code generated by sqld. DO NOT EDIT.")
	wl(&buf)
	ws(&buf, "package ")
	wl(&buf, pkg_name)
	wl(&buf)

	for e in cat.enums {
		if !(e.name in shared_enums) {continue}
		write_enum(&buf, e, cat, allocator)
	}
	for tbl in cat.tables {
		if !(tbl.name in shared_tables) {continue}
		write_table_struct(&buf, tbl, cat, allocator)
	}

	return strings.to_string(buf)
}

// ── query file generation ─────────────────────────────────────

gen_query_file :: proc(
	cat: ^catalog.Catalog,
	queries: []^Query,
	pkg_name: string,
	refs: ^Model_Refs,
	shared_tables: map[string]bool,
	shared_enums: map[string]bool,
	naming: config.Naming = .pascal,
	allocator := context.allocator,
) -> string {
	buf := strings.builder_make(allocator)
	wl(&buf, "// Code generated by sqld. DO NOT EDIT.")
	wl(&buf)
	ws(&buf, "package ")
	wl(&buf, pkg_name)
	wl(&buf)

	// Determine if we need imports
	needs_pq := len(queries) > 0
	needs_fmt := false
	for q in queries {
		if len(q.params) > 0 {needs_fmt = true; break}
	}
	if needs_pq {wl(&buf, "import \"pg\"")}
	if needs_fmt {wl(&buf, "import \"core:fmt\"")}
	if needs_pq || needs_fmt {wl(&buf)}

	// Write file-local enum types (not shared)
	for enum_name, _ in refs.enums {
		if enum_name in shared_enums {continue}
		e := catalog.find_enum(cat, enum_name)
		if e != nil {write_enum(&buf, e^, cat, allocator)}
	}

	// Write file-local table structs (not shared)
	for tbl_name, _ in refs.tables {
		if tbl_name in shared_tables {continue}
		tbl := catalog.find_table(cat, tbl_name)
		if tbl != nil {write_table_struct(&buf, tbl^, cat, allocator)}
	}

	// Write query procs
	for q in queries {
		gen_query(&buf, q, cat, naming, allocator)
	}

	return strings.to_string(buf)
}

// ── Reusable model writers ────────────────────────────────────

write_enum :: proc(
	buf: ^strings.Builder,
	e: catalog.Enum_Type,
	cat: ^catalog.Catalog,
	allocator := context.allocator,
) {
	enum_name := to_pascal_case(e.name, allocator)
	if len(e.comment) > 0 {
		ws(buf, "// ")
		wl(buf, e.comment)
	}
	ws(buf, enum_name)
	wl(buf, " :: enum {")
	for val in e.vals {
		ws(buf, "\t")
		ws(buf, enum_val_to_variant(val, allocator))
		wl(buf, ",")
	}
	wl(buf, "}")
	wl(buf)

	// _from_string
	ws(buf, enum_name)
	ws(buf, "_from_string :: proc(s: string) -> ")
	ws(buf, enum_name)
	wl(buf, " {")
	wl(buf, "\tswitch s {")
	for val in e.vals {
		ws(buf, "\tcase \"")
		ws(buf, val)
		ws(buf, "\": return .")
		wl(buf, enum_val_to_variant(val, allocator))
	}
	wl(buf, "\t}")
	ws(buf, "\treturn .")
	wl(buf, len(e.vals) > 0 ? enum_val_to_variant(e.vals[0], allocator) : "")
	wl(buf, "}")
	wl(buf)

	// _to_string
	ws(buf, enum_name)
	ws(buf, "_to_string :: proc(v: ")
	ws(buf, enum_name)
	wl(buf, ") -> string {")
	wl(buf, "\tswitch v {")
	for val in e.vals {
		ws(buf, "\tcase .")
		ws(buf, enum_val_to_variant(val, allocator))
		ws(buf, ": return \"")
		ws(buf, val)
		wl(buf, "\"")
	}
	wl(buf, "\t}")
	wl(buf, "\treturn \"\"")
	wl(buf, "}")
	wl(buf)
}

write_table_struct :: proc(
	buf: ^strings.Builder,
	tbl: catalog.Table,
	cat: ^catalog.Catalog,
	allocator := context.allocator,
) {
	struct_name := table_to_struct(tbl.name, allocator)
	if len(tbl.comment) > 0 {
		ws(buf, "// ")
		wl(buf, tbl.comment)
	}
	ws(buf, struct_name)
	wl(buf, " :: struct {")
	for col in tbl.columns {
		ws(buf, "\t")
		ws(buf, col.name)
		ws(buf, ": ")
		is_enum := catalog.is_enum_type(cat, col.data_type)
		type_str := odin_type_str(
			col.data_type,
			col.not_null,
			col.is_array,
			is_enum,
			is_enum ? to_pascal_case(col.data_type, allocator) : "",
		)
		ws(buf, type_str)
		wl(buf, ",")
	}
	wl(buf, "}")
	wl(buf)
}

// ── Query code generation ─────────────────────────────────────

gen_query :: proc(
	buf: ^strings.Builder,
	q: ^Query,
	cat: ^catalog.Catalog,
	naming: config.Naming = .pascal,
	allocator := context.allocator,
) {
	// Doc comments
	for c in q.comments {
		if len(c) > 0 {
			ws(buf, "// ")
			wl(buf, c)
		}
	}

	const_name := strings.to_upper(to_snake_case(q.name, allocator), allocator)
	proc_name := to_snake_case(q.name, allocator)

	// SQL constant
	ws(buf, const_name)
	ws(buf, " :: `")
	ws(buf, q.sql)
	wl(buf, "`")
	wl(buf)

	// Sort params by number
	sort_params(q)

	needs_params_struct := len(q.params) > 1

	// Helper to build a type name respecting the naming config.
	make_type_name :: proc(name: string, suffix: string, n: config.Naming, alloc := context.allocator) -> string {
		switch n {
		case .pascal_snake: return strings.concatenate({to_pascal_snake(name, alloc), "_", suffix}, alloc)
		case .pascal:       return strings.concatenate({to_pascal_case(name, alloc), suffix}, alloc)
		}
		return strings.concatenate({to_pascal_case(name, alloc), suffix}, alloc)
	}

	// Params struct
	if needs_params_struct {
		params_struct := make_type_name(q.name, "Params", naming, allocator)
		ws(buf, params_struct)
		wl(buf, " :: struct {")
		for p in q.params {
			ws(buf, "\t")
			ws(buf, p.name)
			ws(buf, ": ")
			ws(buf, odin_type_str(p.data_type, p.not_null, p.is_array, p.is_enum, p.enum_name))
			wl(buf, ",")
		}
		wl(buf, "}")
		wl(buf)
	}

	// Result struct (for multi-column results that don't match a table)
	has_columns := len(q.columns) > 0
	needs_result_struct := has_columns && !matches_table_struct(q, cat) && len(q.columns) > 1
	result_struct_name := ""

	if needs_result_struct {
		result_struct_name = make_type_name(q.name, "Row", naming, allocator)
		ws(buf, result_struct_name)
		wl(buf, " :: struct {")
		for col in q.columns {
			ws(buf, "\t")
			ws(buf, col.name)
			ws(buf, ": ")
			ws(
				buf,
				odin_type_str(
					col.data_type,
					col.not_null,
					col.is_array,
					col.is_enum,
					col.enum_name,
				),
			)
			wl(buf, ",")
		}
		wl(buf, "}")
		wl(buf)
	}

	return_type := get_return_type(q, cat, result_struct_name, allocator)

	switch q.cmd {
	case .One:
		gen_one_proc(
			buf,
			q,
			cat,
			proc_name,
			const_name,
			return_type,
			needs_params_struct,
			naming,
			allocator,
		)
	case .Many:
		gen_many_proc(
			buf,
			q,
			cat,
			proc_name,
			const_name,
			return_type,
			needs_params_struct,
			naming,
			allocator,
		)
	case .Exec:
		gen_exec_proc(buf, q, cat, proc_name, const_name, needs_params_struct, naming, allocator)
	case .Exec_Result:
		gen_exec_result_proc(buf, q, cat, proc_name, const_name, needs_params_struct, naming, allocator)
	case .Exec_Rows:
		gen_exec_rows_proc(buf, q, cat, proc_name, const_name, needs_params_struct, naming, allocator)
	}
}

get_return_type :: proc(
	q: ^Query,
	cat: ^catalog.Catalog,
	result_struct: string,
	allocator := context.allocator,
) -> string {
	if len(q.columns) == 0 {return ""}
	if len(result_struct) > 0 {return result_struct}
	tbl := find_matching_table(q, cat)
	if tbl != nil {return table_to_struct(tbl.name, allocator)}
	if len(q.columns) == 1 {
		col := q.columns[0]
		return odin_type_str(col.data_type, col.not_null, col.is_array, col.is_enum, col.enum_name)
	}
	return ""
}

matches_table_struct :: proc(q: ^Query, cat: ^catalog.Catalog) -> bool {
	return find_matching_table(q, cat) != nil
}

find_matching_table :: proc(q: ^Query, cat: ^catalog.Catalog) -> ^catalog.Table {
	if len(q.columns) == 0 {return nil}
	for &tbl in cat.tables {
		if len(tbl.columns) != len(q.columns) {continue}
		all_match := true
		for i := 0; i < len(tbl.columns); i += 1 {
			if tbl.columns[i].name != q.columns[i].name {
				all_match = false
				break
			}
		}
		if all_match {return &tbl}
	}
	return nil
}

// ── Query function generators ─────────────────────────────────

gen_one_proc :: proc(
	buf: ^strings.Builder,
	q: ^Query,
	cat: ^catalog.Catalog,
	proc_name, const_name, return_type: string,
	has_params_struct: bool,
	naming: config.Naming = .pascal,
	allocator := context.allocator,
) {
	ws(buf, proc_name)
	ws(buf, " :: proc(conn: pg.Conn")
	write_proc_params(buf, q, has_params_struct, naming, allocator)
	ws(buf, ") -> (")
	ws(buf, return_type)
	ws(buf, ", pg.Error) {\n")
	write_exec_query(buf, q, const_name, has_params_struct, allocator)
	ws(buf, "\terr := pg.check_result(res)\n")
	ws(buf, "\tif err != .None { return {}, err }\n")
	ws(buf, "\tdefer pg.clear(res)\n\n")
	ws(buf, "\tif pg.n_tuples(res) == 0 { return {}, .Fatal_Error }\n\n")

	if len(q.columns) == 1 && !is_struct_type(return_type) {
		col := q.columns[0]
		getter := odin_getter(col.data_type, col.not_null, col.is_array, col.is_enum)
		if col.is_enum && col.not_null {
			ws(buf, "\trow := ")
			ws(buf, col.enum_name)
			ws(buf, "_from_string(pg.get_string(res, 0, 0) or_else \"\")\n")
		} else if col.not_null {
			ws(buf, "\trow, _ := pg.")
			ws(buf, getter)
			ws(buf, "(res, 0, 0)\n")
		} else {
			ws(buf, "\trow := pg.")
			ws(buf, getter)
			ws(buf, "(res, 0, 0)\n")
		}
	} else {
		ws(buf, "\trow := ")
		ws(buf, return_type)
		ws(buf, "{\n")
		write_scan_columns(buf, q, cat, "0", "\t\t", allocator)
		ws(buf, "\t}\n")
	}
	ws(buf, "\treturn row, .None\n}\n\n")
}

is_struct_type :: proc(t: string) -> bool {
	if len(t) == 0 {return false}
	scalars := []string{"i16", "i32", "i64", "f32", "f64", "bool", "string", "[]byte"}
	for s in scalars {if t == s {return false}}
	if strings.has_prefix(t, "Maybe(") {return false}
	if strings.has_prefix(t, "[]") {return false}
	return true
}

gen_many_proc :: proc(
	buf: ^strings.Builder,
	q: ^Query,
	cat: ^catalog.Catalog,
	proc_name, const_name, return_type: string,
	has_params_struct: bool,
	naming: config.Naming = .pascal,
	allocator := context.allocator,
) {
	ws(buf, proc_name)
	ws(buf, " :: proc(conn: pg.Conn")
	write_proc_params(buf, q, has_params_struct, naming, allocator)
	ws(buf, ", allocator := context.allocator) -> ([]")
	ws(buf, return_type)
	ws(buf, ", pg.Error) {\n")
	write_exec_query(buf, q, const_name, has_params_struct, allocator)
	ws(buf, "\terr := pg.check_result(res)\n")
	ws(buf, "\tif err != .None { return nil, err }\n")
	ws(buf, "\tdefer pg.clear(res)\n\n")
	ws(buf, "\tn := pg.n_tuples(res)\n")
	ws(buf, "\tresults := make([]")
	ws(buf, return_type)
	ws(buf, ", n, allocator)\n")
	ws(buf, "\tfor i: i32 = 0; i < n; i += 1 {\n")
	ws(buf, "\t\tresults[i] = ")
	ws(buf, return_type)
	ws(buf, "{\n")
	write_scan_columns(buf, q, cat, "i", "\t\t\t", allocator)
	ws(buf, "\t\t}\n")
	ws(buf, "\t}\n")
	ws(buf, "\treturn results[:], .None\n}\n\n")
}

gen_exec_proc :: proc(
	buf: ^strings.Builder,
	q: ^Query,
	cat: ^catalog.Catalog,
	proc_name, const_name: string,
	has_params_struct: bool,
	naming: config.Naming = .pascal,
	allocator := context.allocator,
) {
	ws(buf, proc_name)
	ws(buf, " :: proc(conn: pg.Conn")
	write_proc_params(buf, q, has_params_struct, naming, allocator)
	ws(buf, ") -> pg.Error {\n")
	write_exec_query(buf, q, const_name, has_params_struct, allocator)
	ws(buf, "\terr := pg.check_result(res)\n")
	ws(buf, "\tif err != .None { return err }\n")
	ws(buf, "\tpg.clear(res)\n")
	ws(buf, "\treturn .None\n}\n\n")
}

gen_exec_result_proc :: proc(
	buf: ^strings.Builder,
	q: ^Query,
	cat: ^catalog.Catalog,
	proc_name, const_name: string,
	has_params_struct: bool,
	naming: config.Naming = .pascal,
	allocator := context.allocator,
) {
	ws(buf, proc_name)
	ws(buf, " :: proc(conn: pg.Conn")
	write_proc_params(buf, q, has_params_struct, naming, allocator)
	ws(buf, ") -> (pg.Result, pg.Error) {\n")
	write_exec_query(buf, q, const_name, has_params_struct, allocator)
	ws(buf, "\terr := pg.check_result(res)\n")
	ws(buf, "\tif err != .None { return nil, err }\n")
	ws(buf, "\treturn res, .None\n}\n\n")
}

gen_exec_rows_proc :: proc(
	buf: ^strings.Builder,
	q: ^Query,
	cat: ^catalog.Catalog,
	proc_name, const_name: string,
	has_params_struct: bool,
	naming: config.Naming = .pascal,
	allocator := context.allocator,
) {
	ws(buf, proc_name)
	ws(buf, " :: proc(conn: pg.Conn")
	write_proc_params(buf, q, has_params_struct, naming, allocator)
	ws(buf, ") -> (i64, pg.Error) {\n")
	write_exec_query(buf, q, const_name, has_params_struct, allocator)
	ws(buf, "\terr := pg.check_result(res)\n")
	ws(buf, "\tif err != .None { return 0, err }\n")
	ws(buf, "\tdefer pg.clear(res)\n")
	ws(buf, "\tcount, _ := pg.get_rows_affected(res)\n")
	ws(buf, "\treturn count, .None\n}\n\n")
}

// ── Shared helpers ────────────────────────────────────────────

write_proc_params :: proc(
	buf: ^strings.Builder,
	q: ^Query,
	has_params_struct: bool,
	naming: config.Naming = .pascal,
	allocator := context.allocator,
) {
	if len(q.params) == 0 {return}
	if has_params_struct {
		ws(buf, ", params: ")
		switch naming {
		case .pascal_snake:
			ws(buf, to_pascal_snake(q.name, allocator))
			ws(buf, "_Params")
		case .pascal:
			ws(buf, to_pascal_case(q.name, allocator))
			ws(buf, "Params")
		}
	} else if len(q.params) == 1 {
		p := q.params[0]
		ws(buf, ", ")
		ws(buf, p.name)
		ws(buf, ": ")
		ws(buf, odin_type_str(p.data_type, p.not_null, p.is_array, p.is_enum, p.enum_name))
	}
}

write_exec_query :: proc(
	buf: ^strings.Builder,
	q: ^Query,
	const_name: string,
	has_params_struct: bool,
	allocator := context.allocator,
) {
	if len(q.params) == 0 {
		ws(buf, "\tres := pg.exec(conn, ")
		ws(buf, const_name)
		ws(buf, ")\n")
		return
	}

	n_str := fmt.aprintf("%d", len(q.params))
	ws(buf, "\tparam_values: [")
	ws(buf, n_str)
	ws(buf, "][^]byte\n")

	for p, i in q.params {
		idx := fmt.aprintf("%d", i)
		param_access := has_params_struct ? fmt.aprintf("params.%s", p.name) : p.name

		if p.is_enum && p.not_null {
			ws(buf, "\tbuf_")
			ws(buf, idx)
			ws(buf, " := ")
			ws(buf, p.enum_name)
			ws(buf, "_to_string(")
			ws(buf, param_access)
			ws(buf, ")\n")
		} else {
			ws(buf, "\tbuf_")
			ws(buf, idx)
			ws(buf, " := fmt.aprintf(\"%v\", ")
			ws(buf, param_access)
			ws(buf, ")\n")
		}

		ws(buf, "\tparam_values[")
		ws(buf, idx)
		ws(buf, "] = raw_data(transmute([]byte)buf_")
		ws(buf, idx)
		ws(buf, ")\n")
	}

	ws(buf, "\tres := pg.exec_params(\n")
	ws(buf, "\t\tconn,\n")
	ws(buf, "\t\t")
	ws(buf, const_name)
	ws(buf, ",\n")
	ws(buf, "\t\t")
	ws(buf, n_str)
	ws(buf, ",\n")
	ws(buf, "\t\tnil,\n")
	ws(buf, "\t\traw_data(&param_values),\n")
	ws(buf, "\t\tnil,\n")
	ws(buf, "\t\tnil,\n")
	ws(buf, "\t\t.Text,\n")
	ws(buf, "\t)\n")
}

write_scan_columns :: proc(
	buf: ^strings.Builder,
	q: ^Query,
	cat: ^catalog.Catalog,
	row_var: string,
	indent: string = "\t\t",
	allocator := context.allocator,
) {
	for col, i in q.columns {
		idx := fmt.aprintf("%d", i)
		getter := odin_getter(col.data_type, col.not_null, col.is_array, col.is_enum)

		ws(buf, indent)
		ws(buf, col.name)
		ws(buf, " = ")

		if col.is_enum && col.not_null && !col.is_array {
			ws(buf, col.enum_name)
			ws(buf, "_from_string(pg.get_string(res, ")
			ws(buf, row_var)
			ws(buf, ", ")
			ws(buf, idx)
			ws(buf, ") or_else \"\"),\n")
		} else if col.is_enum && !col.not_null && !col.is_array {
			ws(buf, "pg.get_maybe_string(res, ")
			ws(buf, row_var)
			ws(buf, ", ")
			ws(buf, idx)
			ws(buf, ") == nil ? nil : ")
			ws(buf, col.enum_name)
			ws(buf, "_from_string(pg.get_string(res, ")
			ws(buf, row_var)
			ws(buf, ", ")
			ws(buf, idx)
			ws(buf, ") or_else \"\"),\n")
		} else if col.not_null && needs_allocator(getter) {
			ws(buf, "pg.")
			ws(buf, getter)
			ws(buf, "(res, ")
			ws(buf, row_var)
			ws(buf, ", ")
			ws(buf, idx)
			ws(buf, ") or_else \"\",\n")
		} else if col.not_null {
			ws(buf, "pg.")
			ws(buf, getter)
			ws(buf, "(res, ")
			ws(buf, row_var)
			ws(buf, ", ")
			ws(buf, idx)
			ws(buf, ") or_else ")
			ws(buf, zero_value(col.data_type))
			ws(buf, ",\n")
		} else {
			ws(buf, "pg.")
			ws(buf, getter)
			ws(buf, "(res, ")
			ws(buf, row_var)
			ws(buf, ", ")
			ws(buf, idx)
			ws(buf, "),\n")
		}
	}
}

sort_params :: proc(q: ^Query) {
	if len(q.params) <= 1 {return}
	slice.sort_by(q.params[:], proc(a, b: Query_Param) -> bool {
		return a.number < b.number
	})
}

needs_allocator :: proc(getter: string) -> bool {
	return(
		getter == "get_string" ||
		getter == "get_maybe_string" ||
		getter == "get_bytes" ||
		getter == "get_maybe_bytes" \
	)
}

zero_value :: proc(pg_type: string) -> string {
	switch pg_type {
	case "int2",
	     "smallint",
	     "smallserial",
	     "int4",
	     "integer",
	     "serial",
	     "int",
	     "int8",
	     "bigint",
	     "bigserial",
	     "oid":
		return "0"
	case "float4", "real", "float8", "double precision":
		return "0"
	case "bool", "boolean":
		return "false"
	}
	return "\"\""
}

// ── db.odin helper ────────────────────────────────────────────

gen_db_helper :: proc(pkg_name: string, allocator := context.allocator) -> string {
	buf := strings.builder_make(allocator)
	wl(&buf, "// Code generated by sqld. DO NOT EDIT.")
	wl(&buf)
	ws(&buf, "package ")
	wl(&buf, pkg_name)
	wl(&buf)
	wl(&buf, "import \"pg\"")
	wl(&buf)
	wl(&buf, "// DBTX wraps a database connection for query execution.")
	wl(&buf, "DBTX :: struct {")
	wl(&buf, "\tconn: pg.Conn,")
	wl(&buf, "}")
	wl(&buf)
	wl(&buf, "new_dbtx :: proc(conn: pg.Conn) -> DBTX {")
	wl(&buf, "\treturn DBTX{conn = conn}")
	wl(&buf, "}")
	wl(&buf)
	return strings.to_string(buf)
}

// ── String builder shortcuts ──────────────────────────────────

ws :: proc(buf: ^strings.Builder, s: string) {
	strings.write_string(buf, s)
}

wl :: proc(buf: ^strings.Builder, s: string = "") {
	strings.write_string(buf, s)
	strings.write_byte(buf, '\n')
}
