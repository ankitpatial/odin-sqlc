// Parse DDL statements and extract schema information using translate.
// Demonstrates NOT NULL detection, primary key extraction, and type parsing.
//
// Build: odin run examples/schema_info/
//
package schema_info

import "core:fmt"
import "../../pg_query"
import "../../ast"

main :: proc() {
	schema_sql := `
		CREATE TABLE users (
			id    serial PRIMARY KEY,
			name  text NOT NULL,
			email text UNIQUE,
			bio   text,
			created_at timestamptz NOT NULL DEFAULT now()
		);

		CREATE TABLE orders (
			id       serial PRIMARY KEY,
			user_id  integer NOT NULL REFERENCES users(id),
			total    numeric(10, 2) NOT NULL,
			status   text NOT NULL DEFAULT 'pending',
			items    text[]
		);

		CREATE TYPE order_status AS ENUM ('pending', 'shipped', 'delivered', 'cancelled');

		ALTER TABLE orders ADD COLUMN tracking_number text;
	`

	stmts, err := pg_query.parse(schema_sql)
	if err != nil {
		e := err.?
		fmt.printf("Parse error: %s\n", e.message)
		return
	}

	fmt.printf("Parsed %d statements from schema SQL\n\n", len(stmts))

	for stmt in stmts {
		node := ast.translate(stmt.stmt_json)
		if node == nil { continue }

		#partial switch n in node^ {
		case ast.Create_Table_Stmt:
			print_create_table(n)
		case ast.Create_Enum_Stmt:
			print_create_enum(n)
		case ast.Alter_Table_Stmt:
			print_alter_table(n)
		}
	}
}

print_create_table :: proc(ct: ast.Create_Table_Stmt) {
	name := ct.relation != nil ? ct.relation.relname : "<unknown>"
	fmt.printf("CREATE TABLE %s\n", name)
	fmt.println("  Columns:")

	for elt in ct.table_elts {
		if elt == nil { continue }
		#partial switch col in elt^ {
		case ast.Column_Def:
			type_str := "<unknown>"
			is_array := false
			if col.type_name != nil {
				type_str = col.type_name.name
				is_array = len(col.type_name.array_bounds) > 0
			}

			fmt.printf("    %-15s %-15s", col.colname, type_str)
			if is_array { fmt.print("[]") } else { fmt.print("  ") }
			if col.is_not_null { fmt.print(" NOT NULL") } else { fmt.print("         ") }

			// Check for constraints
			for c in col.constraints {
				if c == nil { continue }
				if con, ok := c^.(ast.Constraint); ok {
					#partial switch con.contype {
					case .Primary_Key: fmt.print(" PRIMARY KEY")
					case .Unique:      fmt.print(" UNIQUE")
					case .Foreign_Key: fmt.print(" REFERENCES")
					case .Default:     fmt.print(" DEFAULT")
					}
				}
			}
			fmt.println()

		case ast.Constraint:
			// Table-level constraint
			if len(col.conname) > 0 {
				fmt.printf("    CONSTRAINT %s (%v)\n", col.conname, col.contype)
			}
		}
	}
	fmt.println()
}

print_create_enum :: proc(ce: ast.Create_Enum_Stmt) {
	// Extract type name from node list
	type_name := "<unknown>"
	for n in ce.type_name {
		if n == nil { continue }
		if s, ok := n^.(ast.String_Node); ok {
			type_name = s.sval
		}
	}

	fmt.printf("CREATE TYPE %s AS ENUM\n", type_name)
	fmt.print("  Values: ")
	for val, i in ce.vals {
		if val == nil { continue }
		if s, ok := val^.(ast.String_Node); ok {
			if i > 0 { fmt.print(", ") }
			fmt.printf("'%s'", s.sval)
		}
	}
	fmt.println("\n")
}

print_alter_table :: proc(at: ast.Alter_Table_Stmt) {
	name := at.relation != nil ? at.relation.relname : "<unknown>"
	fmt.printf("ALTER TABLE %s\n", name)

	for cmd in at.cmds {
		if cmd == nil { continue }
		if c, ok := cmd^.(ast.Alter_Table_Cmd); ok {
			fmt.printf("  %v", c.subtype)
			if len(c.name) > 0 {
				fmt.printf(": %s", c.name)
			}
			if c.def != nil {
				if cd, cdok := c.def^.(ast.Column_Def); cdok {
					type_str := cd.type_name != nil ? cd.type_name.name : "?"
					fmt.printf(" %s", type_str)
				}
			}
			fmt.println()
		}
	}
	fmt.println()
}
