package cli

import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:slice"

import "../config"
import "../pg_query"
import "../ast"
import "../catalog"
import "../metadata"
import "../codegen"

cmd_generate :: proc(args: []string) {
	// Parse -f flag
	config_path := ""
	for i := 0; i < len(args); i += 1 {
		if args[i] == "-f" && i + 1 < len(args) {
			config_path = args[i + 1]
			i += 1
		}
	}

	cfg, err := config.load(config_path)
	if err != .None {
		fmt.eprintf("error: %s\n", config.error_message(err))
		os.exit(1)
	}

	for sql_cfg in cfg.sql {
		if sql_cfg.engine != "postgresql" {
			fmt.eprintf("warning: engine '%s' not supported, skipping\n", sql_cfg.engine)
			continue
		}

		// Get gen config
		odin_gen, has_gen := sql_cfg.gen.odin.?
		if !has_gen {
			fmt.eprintln("error: no 'gen.odin' config found")
			os.exit(1)
		}

		pkg_name := odin_gen.package_name
		out_dir := odin_gen.out
		if len(pkg_name) == 0 { pkg_name = "db" }
		if len(out_dir) == 0 { out_dir = "db" }

		// Expand schema and query paths
		schema_paths, schema_ok := config.expand_paths(sql_cfg.schema)
		if !schema_ok {
			os.exit(1)
		}

		query_paths, query_ok := config.expand_paths(sql_cfg.queries)
		if !query_ok {
			os.exit(1)
		}

		// Phase 1: Parse schema files and build catalog
		cat := build_catalog_from_files(schema_paths[:])
		if cat == nil {
			os.exit(1)
		}

		// Phase 2: Parse query files and analyze
		queries := analyze_query_files(query_paths[:], cat)

		// Phase 3: Generate code
		files := codegen.generate(cat, queries[:], pkg_name, out_dir)

		// Phase 4: Write files
		if !codegen.write_files(files[:]) {
			os.exit(1)
		}

		fmt.printf("Generated %d file(s) in %s/\n", len(files), out_dir)
	}
}

// Parse all schema SQL files and build the catalog.
build_catalog_from_files :: proc(paths: []string) -> ^catalog.Catalog {
	nodes := make([dynamic]^ast.Node, 0, 64, context.temp_allocator)

	for path in paths {
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil {
			fmt.eprintf("error: cannot read schema file '%s'\n", path)
			return nil
		}

		sql := string(data)
		parsed, parse_err := pg_query.parse(sql)
		if parse_err != nil {
			e := parse_err.?
			fmt.eprintf("%s:%d: %s\n", path, e.cursorpos, e.message)
			return nil
		}

		for stmt in parsed {
			node := ast.translate(stmt.stmt_json)
			if node != nil {
				append(&nodes, node)
			}
		}
	}

	cat := new(catalog.Catalog)
	cat^ = catalog.build(nodes[:])
	return cat
}

// Parse query files, extract metadata, and analyze against catalog.
analyze_query_files :: proc(
	paths: []string,
	cat: ^catalog.Catalog,
) -> [dynamic]codegen.Query {
	queries := make([dynamic]codegen.Query, 0, 32)

	for path in paths {
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil {
			fmt.eprintf("error: cannot read query file '%s'\n", path)
			continue
		}

		sql := string(data)
		base := filepath.base(path)
		entries := metadata.parse_queries(sql, base)

		for &entry in entries {
			// Normalize @param syntax to $N before parsing
			if len(entry.param_names) == 0 {
				normalized, param_names := metadata.normalize_named_params(entry.sql)
				if len(param_names) > 0 {
					entry.sql = normalized
					entry.param_names = param_names
				}
			}

			q, ok := codegen.analyze_query(entry, cat)
			if !ok {
				fmt.eprintf("warning: could not analyze query '%s' in %s\n", entry.meta.name, path)
				continue
			}

			// Re-parse the individual query SQL for AST-based analysis
			parsed, parse_err := pg_query.parse(entry.sql)
			if parse_err != nil {
				e := parse_err.?
				fmt.eprintf("%s: %s: %s\n", path, entry.meta.name, e.message)
				continue
			}

			if len(parsed) > 0 {
				node := ast.translate(parsed[0].stmt_json)
				if node != nil {
					codegen.analyze_from_ast(&q, node, cat)
					// Also resolve params from WHERE context
					resolve_where_params(&q, node, cat)
				}
			}

			// Apply @param names to resolved params
			if len(entry.param_names) > 0 {
				for &p in q.params {
					if name, has := entry.param_names[p.number]; has {
						p.name = name
					}
				}
			}

			append(&queries, q)
		}
	}

	return queries
}

// Walk the AST to resolve parameter types from WHERE comparisons.
// For patterns like: column = $N, we look up column's type in the catalog.
resolve_where_params :: proc(q: ^codegen.Query, node: ^ast.Node, cat: ^catalog.Catalog) {
	// Get the primary table
	tbl: ^catalog.Table
	#partial switch n in node^ {
	case ast.Select_Stmt:
		for f in n.from_clause {
			if f == nil { continue }
			if rv, ok := f^.(ast.Range_Var); ok {
				tbl = catalog.find_table(cat, rv.relname)
				break
			}
		}
		resolve_where_expr(q, n.where_clause, tbl, cat)
	case ast.Update_Stmt:
		name := n.relation != nil ? n.relation.relname : ""
		tbl = catalog.find_table(cat, name)
		resolve_where_expr(q, n.where_clause, tbl, cat)
		// Also resolve SET params
		for target in n.target_list {
			if target == nil { continue }
			if rt, ok := target^.(ast.Res_Target); ok {
				if rt.val != nil {
					if pr, prok := rt.val^.(ast.Param_Ref); prok {
						resolve_param_by_column(q, pr.number, rt.name, tbl, cat)
					}
				}
			}
		}
	case ast.Delete_Stmt:
		name := n.relation != nil ? n.relation.relname : ""
		tbl = catalog.find_table(cat, name)
		resolve_where_expr(q, n.where_clause, tbl, cat)
	case ast.Insert_Stmt:
		// Already handled in analyze_from_ast
	}
}

resolve_where_expr :: proc(q: ^codegen.Query, node: ^ast.Node, tbl: ^catalog.Table, cat: ^catalog.Catalog) {
	if node == nil || tbl == nil { return }

	#partial switch n in node^ {
	case ast.A_Expr:
		// Look for column = $N patterns
		resolve_comparison(q, n, tbl, cat)
	case ast.Bool_Expr:
		for arg in n.args {
			resolve_where_expr(q, arg, tbl, cat)
		}
	case ast.Null_Test:
		// IS NULL / IS NOT NULL on a param
		if n.arg != nil {
			if pr, ok := n.arg^.(ast.Param_Ref); ok {
				_ = pr // can't resolve type from null test alone
			}
		}
	}
}

resolve_comparison :: proc(q: ^codegen.Query, expr: ast.A_Expr, tbl: ^catalog.Table, cat: ^catalog.Catalog) {
	// Pattern: Column_Ref op Param_Ref  or  Param_Ref op Column_Ref
	col_name := ""
	param_num: i32 = 0

	if expr.lexpr != nil {
		if cr, ok := expr.lexpr^.(ast.Column_Ref); ok {
			col_name = extract_column_name(cr)
		}
		if pr, ok := expr.lexpr^.(ast.Param_Ref); ok {
			param_num = pr.number
		}
	}
	if expr.rexpr != nil {
		if cr, ok := expr.rexpr^.(ast.Column_Ref); ok {
			if len(col_name) == 0 { col_name = extract_column_name(cr) }
		}
		if pr, ok := expr.rexpr^.(ast.Param_Ref); ok {
			if param_num == 0 { param_num = pr.number }
		}
	}

	if len(col_name) > 0 && param_num > 0 {
		resolve_param_by_column(q, param_num, col_name, tbl, cat)
	}
}

resolve_param_by_column :: proc(
	q: ^codegen.Query, param_num: i32, col_name: string,
	tbl: ^catalog.Table, cat: ^catalog.Catalog,
) {
	if tbl == nil { return }
	col := catalog.find_column(tbl, col_name)
	if col == nil { return }

	is_enum := catalog.is_enum_type(cat, col.data_type)

	// Update existing param or it's already there
	for &p in q.params {
		if p.number == param_num {
			p.name = col.name
			p.data_type = col.data_type
			p.is_array = col.is_array
			p.is_enum = is_enum
			if is_enum {
				p.enum_name = codegen.to_pascal_case(col.data_type)
			}
			return
		}
	}

	// Add new param
	append(&q.params, codegen.Query_Param{
		number    = param_num,
		name      = col.name,
		data_type = col.data_type,
		not_null  = true,
		is_array  = col.is_array,
		is_enum   = is_enum,
		enum_name = is_enum ? codegen.to_pascal_case(col.data_type) : "",
	})
}

extract_column_name :: proc(cr: ast.Column_Ref) -> string {
	// Return the last string field (handles table.column and just column)
	last := ""
	for f in cr.fields {
		if f == nil { continue }
		if s, ok := f^.(ast.String_Node); ok {
			last = s.sval
		}
	}
	return last
}
