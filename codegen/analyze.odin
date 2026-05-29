package codegen

import "../ast"
import "../catalog"
import "../metadata"
import "core:fmt"

// Analyzed query with resolved types.
Query :: struct {
	name:     string,
	cmd:      metadata.Command,
	sql:      string,
	comments: [dynamic]string,
	columns:  [dynamic]Query_Column, // output columns
	params:   [dynamic]Query_Param, // input parameters
	filename: string,
}

Query_Column :: struct {
	name:      string,
	data_type: string,
	not_null:  bool,
	is_array:  bool,
	is_enum:   bool,
	enum_name: string, // Odin enum type name (PascalCase)
}

Query_Param :: struct {
	number:    i32,
	name:      string, // derived from column context
	data_type: string,
	not_null:  bool,
	is_array:  bool,
	is_enum:   bool,
	enum_name: string,
}

// Analyze a parsed query entry against the catalog.
analyze_query :: proc(
	entry: metadata.Query_Entry,
	cat: ^catalog.Catalog,
	allocator := context.allocator,
) -> (
	Query,
	bool,
) {
	q := Query {
		name     = entry.meta.name,
		cmd      = entry.meta.cmd,
		sql      = entry.meta.cmd == .Exec ? strip_trailing_semicolon(entry.sql) : strip_trailing_semicolon(entry.sql),
		comments = entry.meta.comments,
		columns  = make([dynamic]Query_Column, 0, 8, allocator),
		params   = make([dynamic]Query_Param, 0, 4, allocator),
		filename = entry.meta.filename,
	}

	// Parse the query SQL to get AST
	// We need to import pg_query, but to avoid circular deps,
	// we accept parsed AST nodes from outside.
	// For now, analyze using the raw SQL text with simple heuristics
	// backed by the catalog.

	// Determine the statement type and resolve columns/params
	analyze_from_sql(&q, entry.sql, cat, allocator)

	return q, true
}

// Simple SQL analysis using the catalog.
// Parses the SQL text to determine table references, then resolves types.
analyze_from_sql :: proc(
	q: ^Query,
	sql: string,
	cat: ^catalog.Catalog,
	allocator := context.allocator,
) {
	// This is called after pg_query parsing in the CLI.
	// The CLI will call analyze_from_ast instead for full analysis.
}

// Analyze query using AST node and catalog.
analyze_from_ast :: proc(
	q: ^Query,
	node: ^ast.Node,
	cat: ^catalog.Catalog,
	allocator := context.allocator,
) {
	if node == nil {return}

	#partial switch n in node^ {
	case ast.Select_Stmt:
		resolve_select_columns(q, n, cat, allocator)
		resolve_params_from_node(q, node, cat, allocator)
	case ast.Insert_Stmt:
		resolve_insert_columns(q, n, cat, allocator)
		resolve_insert_params(q, n, cat, allocator)
	case ast.Update_Stmt:
		resolve_update_columns(q, n, cat, allocator)
		resolve_update_params(q, n, cat, allocator)
	case ast.Delete_Stmt:
		resolve_delete_columns(q, n, cat, allocator)
		resolve_params_from_node(q, node, cat, allocator)
	}
}

// ── SELECT column resolution ──────────────────────────────────

resolve_select_columns :: proc(
	q: ^Query,
	sel: ast.Select_Stmt,
	cat: ^catalog.Catalog,
	allocator := context.allocator,
) {
	// Find the table(s) in the FROM clause
	tables := get_from_tables(sel.from_clause, cat)

	for target in sel.target_list {
		if target == nil {continue}
		rt, ok := target^.(ast.Res_Target)
		if !ok {continue}

		if rt.val == nil {continue}

		// Check for * (SELECT *)
		if _, is_star := rt.val^.(ast.Column_Ref); is_star {
			cr := rt.val^.(ast.Column_Ref)
			if is_star_ref(cr) {
				// Expand * using table columns
				expand_star(q, tables, cat, allocator)
				continue
			}
		}

		// Named column
		col := resolve_column_expr(rt, tables, cat, allocator)
		append(&q.columns, col)
	}
}

resolve_insert_columns :: proc(
	q: ^Query,
	ins: ast.Insert_Stmt,
	cat: ^catalog.Catalog,
	allocator := context.allocator,
) {
	// RETURNING clause
	if len(ins.returning_list) > 0 {
		table_name := ins.relation != nil ? ins.relation.relname : ""
		tbl := catalog.find_table(cat, table_name)
		resolve_returning(q, ins.returning_list, tbl, cat, allocator)
	}
}

resolve_update_columns :: proc(
	q: ^Query,
	upd: ast.Update_Stmt,
	cat: ^catalog.Catalog,
	allocator := context.allocator,
) {
	if len(upd.returning_list) > 0 {
		table_name := upd.relation != nil ? upd.relation.relname : ""
		tbl := catalog.find_table(cat, table_name)
		resolve_returning(q, upd.returning_list, tbl, cat, allocator)
	}
}

resolve_delete_columns :: proc(
	q: ^Query,
	del: ast.Delete_Stmt,
	cat: ^catalog.Catalog,
	allocator := context.allocator,
) {
	if len(del.returning_list) > 0 {
		table_name := del.relation != nil ? del.relation.relname : ""
		tbl := catalog.find_table(cat, table_name)
		resolve_returning(q, del.returning_list, tbl, cat, allocator)
	}
}

resolve_returning :: proc(
	q: ^Query,
	returning_list: [dynamic]^ast.Node,
	tbl: ^catalog.Table,
	cat: ^catalog.Catalog,
	allocator := context.allocator,
) {
	for target in returning_list {
		if target == nil {continue}
		rt, ok := target^.(ast.Res_Target)
		if !ok {continue}

		if rt.val == nil {continue}

		// Check for * (RETURNING *)
		if cr, is_cr := rt.val^.(ast.Column_Ref); is_cr {
			if is_star_ref(cr) {
				// Expand RETURNING * using table columns
				if tbl != nil {
					for col in tbl.columns {
						is_enum := catalog.is_enum_type(cat, col.data_type)
						append(
							&q.columns,
							Query_Column {
								name = col.name,
								data_type = col.data_type,
								not_null = col.not_null,
								is_array = col.is_array,
								is_enum = is_enum,
								enum_name = is_enum ? to_pascal_case(col.data_type) : "",
							},
						)
					}
				}
				continue
			}
		}

		// Named column in RETURNING
		if tbl != nil {
			tables := make([dynamic]^catalog.Table, 1, context.temp_allocator)
			tables[0] = tbl
			col := resolve_column_expr(rt, tables[:], cat, allocator)
			append(&q.columns, col)
		} else {
			append(
				&q.columns,
				Query_Column {
					name = len(rt.name) > 0 ? rt.name : "column",
					data_type = "text",
					not_null = false,
				},
			)
		}
	}
}

// ── Parameter resolution ──────────────────────────────────────

resolve_insert_params :: proc(
	q: ^Query,
	ins: ast.Insert_Stmt,
	cat: ^catalog.Catalog,
	allocator := context.allocator,
) {
	table_name := ins.relation != nil ? ins.relation.relname : ""
	tbl := catalog.find_table(cat, table_name)

	// Map column names from INSERT cols
	col_names := make([dynamic]string, 0, len(ins.cols), context.temp_allocator)
	for c in ins.cols {
		if c == nil {continue}
		if rt, ok := c^.(ast.Res_Target); ok {
			append(&col_names, rt.name)
		}
	}

	// Walk the VALUES list to build param→column mapping.
	// Match each VALUES expression to its corresponding INSERT column by position.
	// This correctly handles non-param expressions like NOW(), and also params
	// wrapped in function calls like NULLIF(@param, 0::bigint) or LOWER(@param).
	if ins.select_stmt != nil {
		if sel, ok := ins.select_stmt^.(ast.Select_Stmt); ok {
			for vl in sel.values_lists {
				for val_node, col_idx in vl {
					if val_node == nil {continue}
					if col_idx >= len(col_names) {continue}

					col_name := col_names[col_idx]

					// Walk the value expression tree to find any Param_Ref nodes.
					// This handles both direct params ($1) and params inside
					// function calls like NULLIF($5, ...) or LOWER($1).
					Insert_Param_Ctx :: struct {
						params:    ^[dynamic]Query_Param,
						col_name:  string,
						tbl:       ^catalog.Table,
						cat:       ^catalog.Catalog,
					}
					ictx := Insert_Param_Ctx{&q.params, col_name, tbl, cat}
					ast.walk(val_node, proc(n: ^ast.Node, data: rawptr) -> bool {
						c := cast(^Insert_Param_Ctx)data
						if pr, prok := n^.(ast.Param_Ref); prok {
							param := Query_Param{
								number   = pr.number,
								not_null = true,
							}
							if c.tbl != nil {
								if col := catalog.find_column(c.tbl, c.col_name); col != nil {
									param.name = col.name
									param.data_type = col.data_type
									param.is_array = col.is_array
									param.is_enum = catalog.is_enum_type(c.cat, col.data_type)
									if param.is_enum {param.enum_name = to_pascal_case(col.data_type)}
								}
							}
							if len(param.data_type) == 0 {param.data_type = "text"}
							if len(param.name) == 0 {param.name = c.col_name}
							add_param(c.params, param)
						}
						return true
					}, &ictx)
				}
			}
		}
	}
}

resolve_update_params :: proc(
	q: ^Query,
	upd: ast.Update_Stmt,
	cat: ^catalog.Catalog,
	allocator := context.allocator,
) {
	table_name := upd.relation != nil ? upd.relation.relname : ""
	tbl := catalog.find_table(cat, table_name)

	// Build a mapping from $N → column name from SET clause.
	// Walk value expressions to find params inside function calls
	// like NULLIF($4, 0::bigint) or LOWER($1).
	set_map := make(map[i32]string, 8, context.temp_allocator)
	for target in upd.target_list {
		if target == nil {continue}
		if rt, ok := target^.(ast.Res_Target); ok {
			if rt.val != nil {
				Set_Map_Ctx :: struct {
					set_map:  ^map[i32]string,
					col_name: string,
				}
				sctx := Set_Map_Ctx{&set_map, rt.name}
				ast.walk(rt.val, proc(n: ^ast.Node, data: rawptr) -> bool {
					c := cast(^Set_Map_Ctx)data
					if pr, prok := n^.(ast.Param_Ref); prok {
						c.set_map[pr.number] = c.col_name
					}
					return true
				}, &sctx)
			}
		}
	}

	// Walk entire statement for params
	Update_Ctx :: struct {
		params:  ^[dynamic]Query_Param,
		set_map: ^map[i32]string,
		tbl:     ^catalog.Table,
		cat:     ^catalog.Catalog,
	}

	upd_node := new(ast.Node, context.temp_allocator)
	upd_node^ = upd

	ctx := Update_Ctx{&q.params, &set_map, tbl, cat}

	ast.walk(
		upd_node,
		proc(n: ^ast.Node, user_data: rawptr) -> bool {
			c := cast(^Update_Ctx)user_data
			if pr, ok := n^.(ast.Param_Ref); ok {
				param := Query_Param {
					number   = pr.number,
					not_null = true,
				}

				// Check SET map first
				if col_name, has := c.set_map[pr.number]; has {
					if c.tbl != nil {
						if col := catalog.find_column(c.tbl, col_name); col != nil {
							param.name = col.name
							param.data_type = col.data_type
							param.is_array = col.is_array
							param.is_enum = catalog.is_enum_type(c.cat, col.data_type)
							if param.is_enum {param.enum_name = to_pascal_case(col.data_type)}
						}
					}
				}

				if len(param.data_type) == 0 {
					param = resolve_param_from_context(pr, c.tbl, c.cat)
				}

				if len(param.data_type) == 0 {param.data_type = "text"}
				if len(param.name) == 0 {param.name = param.data_type}
				add_param(c.params, param)
			}
			return true
		},
		&ctx,
	)
}

resolve_params_from_node :: proc(
	q: ^Query,
	node: ^ast.Node,
	cat: ^catalog.Catalog,
	allocator := context.allocator,
) {
	// Get the table for context
	tbl: ^catalog.Table
	#partial switch n in node^ {
	case ast.Select_Stmt:
		tables := get_from_tables(n.from_clause, cat)
		if len(tables) > 0 {tbl = tables[0]}
	case ast.Delete_Stmt:
		name := n.relation != nil ? n.relation.relname : ""
		tbl = catalog.find_table(cat, name)
	}

	// Walk for param refs, trying to resolve from comparison context
	Ctx :: struct {
		params: ^[dynamic]Query_Param,
		tbl:    ^catalog.Table,
		cat:    ^catalog.Catalog,
	}
	ctx := Ctx{&q.params, tbl, cat}

	ast.walk(node, proc(n: ^ast.Node, data: rawptr) -> bool {
			c := cast(^Ctx)data
			if pr, ok := n^.(ast.Param_Ref); ok {
				param := resolve_param_from_context(pr, c.tbl, c.cat)
				if len(param.data_type) == 0 {param.data_type = "text"}
				if len(param.name) == 0 {param.name = param.data_type}
				add_param(c.params, param)
			}
			return true
		}, &ctx)
}

// Try to resolve param type by searching for col = $N patterns.
resolve_param_from_context :: proc(
	pr: ast.Param_Ref,
	tbl: ^catalog.Table,
	cat: ^catalog.Catalog,
) -> Query_Param {
	param := Query_Param {
		number   = pr.number,
		not_null = true,
	}
	// We can't easily walk back up the AST from the Param_Ref.
	// But we already set up WHERE-based resolution in the CLI layer
	// using pre-analysis. For now, the param stays as the default type.
	return param
}

// ── Helpers ───────────────────────────────────────────────────

is_star_ref :: proc(cr: ast.Column_Ref) -> bool {
	for f in cr.fields {
		if f == nil {continue}
		if _, ok := f^.(ast.A_Star); ok {
			return true
		}
	}
	return false
}

get_from_tables :: proc(
	from_clause: [dynamic]^ast.Node,
	cat: ^catalog.Catalog,
) -> []^catalog.Table {
	tables := make([dynamic]^catalog.Table, 0, 4, context.temp_allocator)
	for f in from_clause {
		if f == nil {continue}
		if rv, ok := f^.(ast.Range_Var); ok {
			tbl := catalog.find_table(cat, rv.relname)
			if tbl != nil {
				append(&tables, tbl)
			}
		} else if je, ok := f^.(ast.Join_Expr); ok {
			// Recurse into join
			collect_join_tables(&tables, f, cat)
		}
	}
	return tables[:]
}

collect_join_tables :: proc(
	tables: ^[dynamic]^catalog.Table,
	node: ^ast.Node,
	cat: ^catalog.Catalog,
) {
	if node == nil {return}
	if rv, ok := node^.(ast.Range_Var); ok {
		tbl := catalog.find_table(cat, rv.relname)
		if tbl != nil {append(tables, tbl)}
	} else if je, ok := node^.(ast.Join_Expr); ok {
		collect_join_tables(tables, je.larg, cat)
		collect_join_tables(tables, je.rarg, cat)
	}
}

expand_star :: proc(
	q: ^Query,
	tables: []^catalog.Table,
	cat: ^catalog.Catalog,
	allocator := context.allocator,
) {
	for tbl in tables {
		for col in tbl.columns {
			is_enum := catalog.is_enum_type(cat, col.data_type)
			append(
				&q.columns,
				Query_Column {
					name = col.name,
					data_type = col.data_type,
					not_null = col.not_null,
					is_array = col.is_array,
					is_enum = is_enum,
					enum_name = is_enum ? to_pascal_case(col.data_type) : "",
				},
			)
		}
	}
}

resolve_column_expr :: proc(
	rt: ast.Res_Target,
	tables: []^catalog.Table,
	cat: ^catalog.Catalog,
	allocator := context.allocator,
) -> Query_Column {
	col_name := rt.name // alias if present

	// Try to get the column reference name
	if rt.val != nil {
		if cr, ok := rt.val^.(ast.Column_Ref); ok {
			for f in cr.fields {
				if f == nil {continue}
				if s, sok := f^.(ast.String_Node); sok {
					if len(col_name) == 0 {col_name = s.sval}
					// Try to find in catalog tables
					for tbl in tables {
						if c := catalog.find_column(tbl, s.sval); c != nil {
							is_enum := catalog.is_enum_type(cat, c.data_type)
							name := len(rt.name) > 0 ? rt.name : c.name
							return Query_Column {
								name = name,
								data_type = c.data_type,
								not_null = c.not_null,
								is_array = c.is_array,
								is_enum = is_enum,
								enum_name = is_enum ? to_pascal_case(c.data_type) : "",
							}
						}
					}
				}
			}
		}

		// Check for function calls like count(*)
		if fc, ok := rt.val^.(ast.Func_Call); ok {
			fname := get_func_name(fc)
			col_name = len(rt.name) > 0 ? rt.name : fname
			odin_type := func_return_type(fname)
			return Query_Column{name = col_name, data_type = odin_type, not_null = true}
		}

		// Type cast
		if tc, ok := rt.val^.(ast.Type_Cast); ok {
			name := len(rt.name) > 0 ? rt.name : "column"
			dt := "text"
			if tc.type_name != nil {
				dt = tc.type_name.name
			}
			return Query_Column{name = name, data_type = dt, not_null = true}
		}
	}

	if len(col_name) == 0 {col_name = "column"}
	return Query_Column{name = col_name, data_type = "text", not_null = false}
}

get_func_name :: proc(fc: ast.Func_Call) -> string {
	for n in fc.funcname {
		if n == nil {continue}
		if s, ok := n^.(ast.String_Node); ok {
			return s.sval
		}
	}
	return "unknown"
}

func_return_type :: proc(name: string) -> string {
	switch name {
	case "count":
		return "int8"
	case "sum":
		return "numeric"
	case "avg":
		return "numeric"
	case "min", "max":
		return "text" // depends on arg
	case "now":
		return "timestamptz"
	case "current_timestamp":
		return "timestamptz"
	case "current_date":
		return "date"
	case "coalesce":
		return "text"
	case "array_agg":
		return "text"
	case "string_agg":
		return "text"
	case "json_agg":
		return "jsonb"
	case "jsonb_agg":
		return "jsonb"
	case "row_to_json":
		return "json"
	case "to_json":
		return "json"
	case "to_jsonb":
		return "jsonb"
	case "gen_random_uuid":
		return "uuid"
	}
	return "text"
}

add_param :: proc(params: ^[dynamic]Query_Param, p: Query_Param) {
	// Don't add duplicate param numbers
	for &existing in params {
		if existing.number == p.number {
			// Update if we have better info
			if len(p.data_type) > 0 && p.data_type != "text" {
				existing = p
			}
			return
		}
	}
	append(params, p)
}

strip_trailing_semicolon :: proc(s: string) -> string {
	result := s
	for len(result) > 0 &&
	    (result[len(result) - 1] == ';' ||
			    result[len(result) - 1] == ' ' ||
			    result[len(result) - 1] == '\n' ||
			    result[len(result) - 1] == '\r' ||
			    result[len(result) - 1] == '\t') {
		result = result[:len(result) - 1]
	}
	return result
}
