package cli

import "core:fmt"
import "core:os"

import "../config"
import "../pg_query"
import "../ast"

cmd_compile :: proc(args: []string) {
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

	total_errors := 0
	total_stmts := 0

	for sql_cfg in cfg.sql {
		if sql_cfg.engine != "postgresql" {
			fmt.eprintf("warning: engine '%s' not supported, skipping\n", sql_cfg.engine)
			continue
		}

		// Process schema files
		schema_errors, schema_stmts := compile_files(sql_cfg.schema, "schema")
		total_errors += schema_errors
		total_stmts += schema_stmts

		// Process query files
		query_errors, query_stmts := compile_files(sql_cfg.queries, "query")
		total_errors += query_errors
		total_stmts += query_stmts
	}

	if total_errors > 0 {
		fmt.eprintf("\n%d error(s) in %d statement(s)\n", total_errors, total_stmts)
		os.exit(1)
	}

	fmt.printf("OK: %d statement(s) parsed successfully\n", total_stmts)
}

compile_files :: proc(paths: config.Paths, label: string) -> (errors: int, stmts: int) {
	for path in paths {
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil {
			fmt.eprintf("error: cannot read %s file '%s'\n", label, path)
			errors += 1
			continue
		}

		sql := string(data)
		parsed, parse_err := pg_query.parse(sql)
		if parse_err != nil {
			e := parse_err.?
			fmt.eprintf("%s:%d: %s\n", path, e.cursorpos, e.message)
			errors += 1
			continue
		}

		for stmt in parsed {
			node := ast.translate(stmt.stmt_json)
			if node == nil {
				fmt.eprintf("%s: warning: could not convert statement at offset %d\n", path, stmt.location)
			}
			stmts += 1
		}
	}

	return
}
