// Parse SQL statements and inspect the resulting AST.
//
// Build: odin run examples/parse_inspect/
//
package parse_inspect

import "core:fmt"
import "../../pg_query"
import "../../ast"

main :: proc() {
	queries := []string{
		"SELECT id, name FROM users WHERE active = true",
		"INSERT INTO orders (user_id, total) VALUES ($1, $2) RETURNING id",
		"UPDATE users SET name = $1 WHERE id = $2",
		"DELETE FROM sessions WHERE expires_at < now()",
		"SELECT u.name, count(*) FROM users u JOIN orders o ON o.user_id = u.id GROUP BY u.name ORDER BY count(*) DESC LIMIT 10",
	}

	for sql in queries {
		fmt.println("─────────────────────────────────────────")
		fmt.printf("SQL: %s\n", sql)

		stmts, err := pg_query.parse(sql)
		if err != nil {
			e := err.?
			fmt.printf("  ERROR: %s\n", e.message)
			continue
		}

		for stmt, i in stmts {
			node := ast.translate(stmt.stmt_json)
			if node == nil {
				fmt.printf("  stmt[%d]: nil (could not convert)\n", i)
				continue
			}

			fmt.printf("  stmt[%d]: ", i)
			print_node(node, 2)
		}
		fmt.println()
	}
}

print_node :: proc(node: ^ast.Node, indent: int) {
	if node == nil {
		fmt.println("<nil>")
		return
	}

	pad :: proc(n: int) {
		for _ in 0 ..< n { fmt.print(" ") }
	}

	#partial switch n in node^ {
	case ast.Select_Stmt:
		fmt.println("Select_Stmt")
		pad(indent)
		fmt.printf("  target_list: %d items\n", len(n.target_list))
		for t in n.target_list {
			pad(indent + 2)
			fmt.print("- ")
			print_node(t, indent + 4)
		}
		pad(indent)
		fmt.printf("  from_clause: %d items\n", len(n.from_clause))
		for f in n.from_clause {
			pad(indent + 2)
			fmt.print("- ")
			print_node(f, indent + 4)
		}
		if n.where_clause != nil {
			pad(indent)
			fmt.print("  where: ")
			print_node(n.where_clause, indent + 4)
		}
		if len(n.group_clause) > 0 {
			pad(indent)
			fmt.printf("  group_by: %d items\n", len(n.group_clause))
		}
		if len(n.sort_clause) > 0 {
			pad(indent)
			fmt.printf("  order_by: %d items\n", len(n.sort_clause))
		}
		if n.limit_count != nil {
			pad(indent)
			fmt.print("  limit: ")
			print_node(n.limit_count, indent + 4)
		}

	case ast.Insert_Stmt:
		fmt.printf("Insert_Stmt into ")
		if n.relation != nil {
			fmt.printf("%s", n.relation.relname)
		}
		fmt.printf(" (%d cols)", len(n.cols))
		if len(n.returning_list) > 0 {
			fmt.printf(" RETURNING %d cols", len(n.returning_list))
		}
		fmt.println()

	case ast.Update_Stmt:
		fmt.printf("Update_Stmt on ")
		if n.relation != nil {
			fmt.printf("%s", n.relation.relname)
		}
		fmt.printf(" SET %d cols", len(n.target_list))
		if n.where_clause != nil {
			fmt.print(" WHERE ...")
		}
		fmt.println()

	case ast.Delete_Stmt:
		fmt.printf("Delete_Stmt from ")
		if n.relation != nil {
			fmt.printf("%s", n.relation.relname)
		}
		if n.where_clause != nil {
			fmt.print(" WHERE ...")
		}
		fmt.println()

	case ast.Res_Target:
		if n.val != nil {
			s := ast.format_node(n.val)
			if len(n.name) > 0 {
				fmt.printf("ResTarget: %s AS %s\n", s, n.name)
			} else {
				fmt.printf("ResTarget: %s\n", s)
			}
		} else {
			fmt.printf("ResTarget: %s\n", n.name)
		}

	case ast.Column_Ref:
		fmt.printf("ColumnRef: %s\n", ast.format_node(node))

	case ast.Range_Var:
		if n.alias != nil && len(n.alias.aliasname) > 0 {
			fmt.printf("RangeVar: %s (alias: %s)\n", n.relname, n.alias.aliasname)
		} else {
			fmt.printf("RangeVar: %s\n", n.relname)
		}

	case ast.Join_Expr:
		fmt.printf("JoinExpr: %v\n", n.jointype)
		pad(indent)
		fmt.print("  left: ")
		print_node(n.larg, indent + 4)
		pad(indent)
		fmt.print("  right: ")
		print_node(n.rarg, indent + 4)

	case ast.A_Expr:
		fmt.printf("A_Expr(%v): %s\n", n.kind, ast.format_node(node))

	case ast.Func_Call:
		fmt.printf("FuncCall: %s\n", ast.format_node(node))

	case ast.Param_Ref:
		fmt.printf("$%d\n", n.number)

	case ast.A_Const:
		fmt.printf("Const: %s\n", ast.format_node(node))

	case:
		fmt.printf("<%T>\n", node^)
	}
}
