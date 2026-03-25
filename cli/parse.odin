package cli

import "core:fmt"
import "core:os"

import "../config"
import "../pg_query"
import "../ast"

cmd_parse :: proc(args: []string) {
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
			continue
		}

		parse_and_print(sql_cfg.schema, "schema")
		parse_and_print(sql_cfg.queries, "query")
	}
}

parse_and_print :: proc(paths: config.Paths, label: string) {
	for path in paths {
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil {
			fmt.eprintf("error: cannot read '%s'\n", path)
			continue
		}

		sql := string(data)
		parsed, parse_err := pg_query.parse(sql)
		if parse_err != nil {
			e := parse_err.?
			fmt.eprintf("%s: parse error: %s\n", path, e.message)
			continue
		}

		fmt.printf("── %s (%s, %d statements) ──\n", path, label, len(parsed))

		for stmt, i in parsed {
			node := ast.translate(stmt.stmt_json)
			if node == nil {
				fmt.printf("  [%d] <unknown>\n", i)
				continue
			}

			fmt.printf("  [%d] ", i)
			print_stmt_summary(node)
		}
		fmt.println()
	}
}

print_stmt_summary :: proc(node: ^ast.Node) {
	#partial switch n in node^ {
	case ast.Select_Stmt:
		fmt.printf("SELECT (%d targets", len(n.target_list))
		if len(n.from_clause) > 0 { fmt.printf(", %d tables", len(n.from_clause)) }
		if n.where_clause != nil { fmt.print(", WHERE") }
		if len(n.sort_clause) > 0 { fmt.print(", ORDER BY") }
		if n.limit_count != nil { fmt.print(", LIMIT") }
		fmt.println(")")

	case ast.Insert_Stmt:
		name := n.relation != nil ? n.relation.relname : "?"
		fmt.printf("INSERT INTO %s (%d cols", name, len(n.cols))
		if len(n.returning_list) > 0 { fmt.print(", RETURNING") }
		fmt.println(")")

	case ast.Update_Stmt:
		name := n.relation != nil ? n.relation.relname : "?"
		fmt.printf("UPDATE %s (SET %d cols", name, len(n.target_list))
		if n.where_clause != nil { fmt.print(", WHERE") }
		fmt.println(")")

	case ast.Delete_Stmt:
		name := n.relation != nil ? n.relation.relname : "?"
		fmt.printf("DELETE FROM %s", name)
		if n.where_clause != nil { fmt.print(" WHERE") }
		fmt.println()

	case ast.Create_Table_Stmt:
		name := n.relation != nil ? n.relation.relname : "?"
		fmt.printf("CREATE TABLE %s (%d columns)\n", name, len(n.table_elts))

	case ast.Create_Enum_Stmt:
		fmt.printf("CREATE TYPE ... AS ENUM (%d values)\n", len(n.vals))

	case ast.Alter_Table_Stmt:
		name := n.relation != nil ? n.relation.relname : "?"
		fmt.printf("ALTER TABLE %s (%d cmds)\n", name, len(n.cmds))

	case ast.Drop_Stmt:
		fmt.printf("DROP %v (%d objects)\n", n.remove_type, len(n.objects))

	case ast.Create_View_Stmt:
		name := n.view != nil ? n.view.relname : "?"
		fmt.printf("CREATE VIEW %s\n", name)

	case ast.Create_Function_Stmt:
		fmt.printf("CREATE FUNCTION (%d params)\n", len(n.parameters))

	case ast.Index_Stmt:
		fmt.printf("CREATE INDEX %s\n", n.idxname)

	case:
		fmt.printf("%T\n", node^)
	}
}
