// Find all parameter references ($1, $2, ...) in SQL queries using AST walking.
// Also demonstrates fingerprinting and normalization.
//
// Build: odin run examples/find_params/
//
package find_params

import "core:fmt"
import "../../pg_query"
import "../../ast"

main :: proc() {
	queries := []struct {
		name: string,
		sql:  string,
	}{
		{"Simple select",    "SELECT * FROM users WHERE id = $1"},
		{"Insert",           "INSERT INTO users (name, email) VALUES ($1, $2)"},
		{"Complex",          "SELECT * FROM users WHERE name = $1 AND (age > $2 OR role = $3) ORDER BY created_at"},
		{"No params",        "SELECT count(*) FROM users"},
		{"Subquery",         "SELECT * FROM users WHERE id IN (SELECT user_id FROM orders WHERE total > $1)"},
		{"Normalized",       "SELECT * FROM users WHERE id = 42 AND name = 'test'"},
	}

	for q in queries {
		fmt.println("─────────────────────────────────────────")
		fmt.printf("[%s]\n", q.name)
		fmt.printf("  SQL: %s\n", q.sql)

		// Parse and convert
		stmts, err := pg_query.parse(q.sql)
		if err != nil {
			e := err.?
			fmt.printf("  ERROR: %s\n", e.message)
			continue
		}

		if len(stmts) == 0 { continue }

		node := ast.translate(stmts[0].stmt_json)
		if node == nil {
			fmt.println("  Could not convert AST")
			continue
		}

		// Walk to find all Param_Ref nodes
		Params :: struct {
			refs: [dynamic]i32,
		}
		params: Params

		ast.walk(node, proc(n: ^ast.Node, data: rawptr) -> bool {
			p := cast(^Params)data
			if pr, ok := n^.(ast.Param_Ref); ok {
				append(&p.refs, pr.number)
			}
			return true
		}, &params)

		if len(params.refs) > 0 {
			fmt.printf("  Parameters: %d found — ", len(params.refs))
			for ref, i in params.refs {
				if i > 0 { fmt.print(", ") }
				fmt.printf("$%d", ref)
			}
			fmt.println()
		} else {
			fmt.println("  Parameters: none")
		}

		// Normalize (replace constants with $N)
		normalized, norm_err := pg_query.normalize(q.sql)
		if norm_err == nil && len(normalized) > 0 {
			fmt.printf("  Normalized: %s\n", normalized)
		}

		// Fingerprint
		fp, fp_err := pg_query.fingerprint(q.sql)
		if fp_err == nil {
			fmt.printf("  Fingerprint: %s\n", fp)
		}

		fmt.println()
	}
}
